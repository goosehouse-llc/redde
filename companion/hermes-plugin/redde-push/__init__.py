"""Redde push: notifications on a paired iPhone when the agent finishes a reply, waits on a person
(an approval, a question, a sudo password, a secret) or gives up on a turn. See README.md here,
and `core.py` for how a note is sealed and sent.

    hermes redde-push pair      pair a phone (shows a QR code for Redde to scan)
    hermes redde-push list      the paired phones
    hermes redde-push test      send each of them a test notification
    hermes redde-push remove <name>
    hermes redde-push notify mine|all

The app itself uses the slash command `/redde-push`, over the Dashboard: `watch <session>
<device,...>` says which conversations it has taken part in (only those notify, and every turn
over the Hermes API), `rooms <device,...> <room,...>` which group chats it follows (`rooms.py`),
`mutes <device,...> <key=until,...>` which chats it has muted, `calls <device,...> <profile,...>`
which agents may ring it (`calls.py`), and `offer` then `accept <offer> <key> <box>` pair it
without a code.

And cards (`cards.py`): `redde_show`, a map, places, the weather or the time the app draws under a reply;
the weather and the time are looked up (`forecast.py`, Open-Meteo).

The plugin also offers the agent phone tools, carried out by the app on the iPhone (the calendar,
reminders, contacts, photos, a folder of files): see `device.py`. They need no pairing, and the
agent is offered none of them until the phone turns some on (`/redde-push device …`).
"""

from __future__ import annotations

import atexit
import logging
import os
import sys
import threading
import time
from pathlib import Path

from . import calls, cards, core, qr, rooms, routines
from . import device as phone_tools   # (`device` is a paired phone, in this file)

log = logging.getLogger("redde_push")

_store: core.Store | None = None
_pusher: core.Pusher | None = None
_turns: core.Turns | None = None
_waiting: core.Waiting | None = None
_rooms: rooms.Rooms | None = None
_routines: routines.Routines | None = None
_offers = core.Offers()
#: The platforms a turn over the Dashboard runs on: the ones that can put a question to a client.
DASHBOARD = ("desktop", "tui")
#: session id -> the platform its turns run on ("desktop" or "tui" for the Dashboard, "api_server",
#: "cli", a messaging platform). The approval hook isn't told, so the turn's earlier hooks remember.
_platforms: dict[str, str] = {}
#: Turns no person is waiting on as such: a subagent's goes to the agent that asked, and a bot's in
#: a group chat to the room, whose notes come from the room itself (`rooms.py`).
NOBODYS = ("subagent", "bot_room")


def _home() -> Path:
    try:
        from hermes_constants import get_hermes_home
        return Path(get_hermes_home())
    except Exception:
        return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


def _title(session: str) -> str:
    """The conversation's title, for the notification's heading. Best effort."""
    try:
        from hermes_state import SessionDB
        row = SessionDB().get_session(session)
        return (row or {}).get("title") or ""
    except Exception:
        return ""


def _to_widget(title: str, text: str, start: str = "", end: str = "") -> int:
    """Sends what the agent wrote for its widget to every paired phone, sealed like any note;
    to how many. For a turn no phone is following (device.py). Empty: the widget is cleared."""
    store, pusher = _state()
    devices = store.devices
    if not devices:
        return 0
    return pusher.send(devices, core.widget_note(title, text, start, end))


_stores: dict[str, core.Store] = {}


def _store_in(home: Path) -> core.Store:
    """The paired phones a Hermes home keeps: for calls, the main home's, whichever profile calls."""
    store, _ = _state()
    if store.dir == Path(home) / "redde-push":
        return store
    return _stores.setdefault(str(home), core.Store(home))


def _state() -> tuple[core.Store, core.Pusher]:
    global _store, _pusher
    if _store is None or _pusher is None:
        _store = core.Store(_home())
        _pusher = core.Pusher(_store, title_of=_title)
        atexit.register(_leave)
    return _store, _pusher


def _watchers() -> tuple[core.Turns, core.Waiting]:
    global _turns, _waiting
    if _turns is None or _waiting is None:
        _turns = core.Turns(failed=_failed, finished=_tasks_came_back)
        _waiting = core.Waiting(peek=_peek, found=_asked_for)
    return _turns, _waiting


def _group_chats() -> rooms.Rooms:
    """The group chats the paired phones follow, read for what is new (`rooms.py`)."""
    global _rooms
    if _rooms is None:
        store, pusher = _state()
        _rooms = rooms.Rooms(store, pusher.send)
    return _rooms


def _watch_schedules() -> None:
    """The bots' schedules on this machine, read for runs (`routines.py`). Only from the main
    profile's home, whose store has the phones."""
    global _routines
    try:
        home = _home()
        if home.parent.name == "profiles":
            return
        if _routines is None:
            store, pusher = _state()
            _routines = routines.Routines(store, pusher.send, routines.Stores(home))
        if _routines.store.devices:
            _routines.start()
    except Exception:
        log.debug("redde-push: couldn't start reading the schedules", exc_info=True)


def _follow_group_chats_if_any() -> None:
    """At load: a phone follows some group chat here, so this process reads them too."""
    try:
        if _state()[0].rooms_followed():
            _group_chats().start()
    except Exception:
        log.debug("redde-push: couldn't start reading the group chats", exc_info=True)


#: Set as the process exits: what is said from then on is sent at once (`core.Pusher.submit`).
_leaving = False


def _leave() -> None:
    """The process is going: a turn still being waited on won't get its reply from here."""
    global _leaving
    _leaving = True
    if _turns is not None:
        _turns.later.flush()
    if _pusher is not None:
        _pusher.drain()


# ---- Hooks. Each runs inside a turn: it must be quick, and nothing it does may break the turn. ----

def _remember_platform(session_id: str = "", platform: str = "", **_) -> None:
    if session_id and platform:
        _platforms.pop(session_id, None)
        _platforms[session_id] = platform
        while len(_platforms) > 2000:
            _platforms.pop(next(iter(_platforms)))


def _on_approval(command: str = "", description: str = "", session_id: str = "", session_key: str = "", surface: str = "", **_) -> None:
    try:
        # "smart": a model is being asked first. A person is asked only if it can't decide, and
        # the hook fires again for that.
        if surface == "smart":
            return
        session = session_id or session_key
        if _platforms.get(session, "") == "bot_room":   # the room says so, to those following it
            return
        _state()[1].submit("approval", session, _platforms.get(session, ""), body=command, detail=description)
    except Exception:
        log.debug("redde-push: approval hook failed", exc_info=True)


#: session id -> the turn whose reply has gone to the phone, so a turn Hermes then calls failed
#: isn't announced twice.
_replied: dict[str, str] = {}


def _on_reply(session_id: str = "", assistant_response: str = "", platform: str = "", turn_id: str = "", **_) -> None:
    try:
        platform = platform or _platforms.get(session_id, "")
        if platform in NOBODYS:
            return
        turns, waiting = _watchers()
        turns.ended(session_id)
        waiting.forget(session_id)
        if isinstance(assistant_response, str) and assistant_response.strip():
            # A reply nobody asked for just now, in a conversation whose handed-off task just
            # came back: Hermes started this turn itself, to say what came of the task.
            kind = "task" if turns.reply_is_of_a_task(session_id) else "reply"
            if _state()[1].submit(kind, session_id, platform, body=assistant_response) and turn_id:
                _replied.pop(session_id, None)
                _replied[session_id] = turn_id
                while len(_replied) > 500:
                    _replied.pop(next(iter(_replied)))
    except Exception:
        log.debug("redde-push: reply hook failed", exc_info=True)


def _on_turn(session_id: str = "", platform: str = "", turn_id: str = "", user_message=None, **_) -> dict | None:
    """`pre_llm_call`: a turn starts. Asked the time or the weather, the agent is told the
    person's time and to show the card (`cards.turn_note`); asked to call, how (`calls.turn_note`)."""
    try:
        _remember_platform(session_id, platform)
        if platform not in NOBODYS:
            _watchers()[0].began(session_id, turn_id)
    except Exception:
        log.debug("redde-push: turn hook failed", exc_info=True)
    notes = []
    try:
        notes.append(cards.turn_note(_home(), user_message, platform))
    except Exception:
        log.debug("redde-push: card note failed", exc_info=True)
    try:
        # Asked to call: how (calls.py), for an agent the phone takes calls from.
        notes.append(calls.turn_note(_home(), _store_in, user_message))
    except Exception:
        log.debug("redde-push: call note failed", exc_info=True)
    notes = [n for n in notes if n]
    return {"context": "\n".join(notes)} if notes else None


def _on_request(session_id: str = "", **_) -> None:
    """`pre_api_request`: the turn is asking the model (again): it is alive, and whatever tools it
    was running are done."""
    try:
        turns, waiting = _watchers()
        turns.moved(session_id)
        waiting.forget(session_id)
    except Exception:
        log.debug("redde-push: request hook failed", exc_info=True)


def _on_answer(session_id: str = "", platform: str = "", assistant_message=None, **_) -> None:
    """`post_api_request`: the model answered. If it calls the clarify tool, a person is about to
    be asked a question; and whatever tools it calls, one of them may stop for a sudo password or
    a secret, which only the Dashboard's own list shows (`core.Waiting`).

    Read here, from the answer, not in `pre_tool_call`: Hermes 0.21.0 and 0.21.3 refuse a tool
    when a plugin's `pre_tool_call` is still busy with another call, and no notification is
    worth a refused tool."""
    try:
        turns, waiting = _watchers()
        turns.moved(session_id)
        platform = platform or _platforms.get(session_id, "")
        if platform in NOBODYS or not session_id:
            return
        calls = core.tool_calls(assistant_message)
        if not calls:
            return
        store, pusher = _state()
        for name, arguments in calls:
            if name == "clarify":
                asked, listed, choices = core.question(arguments)
                if asked:
                    # Answered from the notification only where the app can ask Hermes what it
                    # is waiting on, and so answer that very question (0.21.3 and later).
                    pusher.submit("question", session_id, platform, body=asked, detail=listed,
                                  choices=choices if _lists_what_it_waits_on() else None)
        if platform in DASHBOARD and store.targets(session_id, platform):
            waiting.watch(session_id)
    except Exception:
        log.debug("redde-push: answer hook failed", exc_info=True)


def _on_request_error(session_id: str = "", platform: str = "", retryable=None, reason: str = "", status_code=None, error=None, **_) -> None:
    """`api_request_error`: a request to the model failed. Hermes may try again or give up, and
    says neither (`core.Turns`)."""
    try:
        platform = platform or _platforms.get(session_id, "")
        if platform in NOBODYS or not _state()[0].targets(session_id, platform):
            return
        _watchers()[0].request_failed(session_id, platform, retryable, reason, core.failure(status_code, error))
    except Exception:
        log.debug("redde-push: request error hook failed", exc_info=True)


def _failed(session: str, platform: str, why: str) -> None:
    _state()[1].submit("failed", session, platform, body=why, now=_leaving)


def _on_turn_end(session_id: str = "", platform: str = "", turn_id: str = "", failed=False, turn_exit_reason: str = "", **_) -> None:
    """`on_session_end`. With a turn id it is a turn ending; the Dashboard also sends it, without
    one, when it closes a session, which says nothing about a turn."""
    try:
        if not turn_id or not session_id:
            return
        platform = platform or _platforms.get(session_id, "")
        turns, waiting = _watchers()
        turns.ended(session_id)
        waiting.forget(session_id)
        # Failed, and no reply went out for it: most turns Hermes calls failed still end on a
        # few words about what went wrong, and those have been sent as the reply.
        if failed is True and platform not in NOBODYS and _replied.get(session_id) != turn_id:
            why = core.clipped(str(turn_exit_reason or "").replace("_", " "), 120)
            _failed(session_id, platform, f"The turn ended with an error ({why})." if why else "The turn ended with an error.")
    except Exception:
        log.debug("redde-push: turn end hook failed", exc_info=True)


def _on_stopped(session_key: str = "", session_id: str = "", **_) -> None:
    """`agent_loop_stopped` (Hermes 0.21.3 and later): the person stopped the turn. Nothing to
    announce, whatever was failing."""
    try:
        turns, waiting = _watchers()
        for session in {session_key, session_id} - {""}:
            turns.ended(session)
            waiting.forget(session)
    except Exception:
        log.debug("redde-push: stop hook failed", exc_info=True)


def _on_task_done(parent_session_id: str = "", child_status: str = "", child_summary: str = "", **_) -> None:
    """`subagent_stop`: a task the agent handed off is finished. (One a subagent handed on is
    that subagent's business.)"""
    try:
        if _platforms.get(parent_session_id or "") == "subagent":
            return
        _watchers()[0].task_finished(parent_session_id or "", child_status or "", child_summary or "")
    except Exception:
        log.debug("redde-push: task hook failed", exc_info=True)


def _tasks_came_back(session: str, tasks: list[tuple[str, str]]) -> None:
    """Tasks came back and Hermes started no turn to say so (`core.Turns`): their own words go."""
    summary, about = core.task_report(tasks)
    _state()[1].submit("task", session, _platforms.get(session, ""), body=summary or "The task has finished.", detail=about, now=_leaving)


def _lists_what_it_waits_on() -> bool:
    """Whether this is a Dashboard that keeps a list of the questions it has put to a client
    (Hermes 0.21.3 and later): what `_peek` reads, and what a client is handed when it resumes."""
    return "tui_gateway.server_requests" in sys.modules


def _peek() -> list[tuple[str, str, str, dict]]:
    """What the Dashboard is waiting on a client for, as (session, request id, method, params),
    from the modules that keep it, if this process has them loaded: the Dashboard's has, from
    Hermes 0.21.3. The session is given as Hermes stores it, which is how the hooks name it; the
    Dashboard's own name for it is something else."""
    requests, server = sys.modules.get("tui_gateway.server_requests"), sys.modules.get("tui_gateway.server")
    if requests is None or server is None:
        return []
    waiting = list(getattr(requests, "_open", {}).values())
    if not waiting:
        return []
    sessions = dict(getattr(server, "_sessions", {}))
    found = []
    for request in waiting:
        kept = sessions.get(request.sid) or {}
        for session in dict.fromkeys((getattr(kept.get("agent"), "session_id", None), kept.get("session_key"))):
            if session:
                found.append((str(session), str(request.id), str(request.method), dict(request.params or {})))
    return found


def _asked_for(session: str, method: str, params: dict) -> None:
    """A sudo password or a secret is being asked for in a conversation someone follows."""
    pusher, platform = _state()[1], _platforms.get(session, DASHBOARD[0])
    if method == core.PASSWORD:
        pusher.submit(core.PASSWORD, session, platform, body=str(params.get("command") or ""))
    elif method == "secret":
        pusher.submit("secret", session, platform, body=str(params.get("prompt") or ""), detail=str(params.get("env_var") or ""))


# ---- /redde-push, for the app ------------------------------------------------------------------

def _relay() -> str:
    return os.environ.get("REDDE_PUSH_RELAY") or core.DEFAULT_RELAY


def _slash(raw_args: str = "") -> str:
    """What the app says to the plugin. Every reply starts with "redde-push " and a word the app
    reads: watching, status, offer, paired, refused."""
    words = (raw_args or "").split()
    if words[:1] == ["device"]:
        # Phone tools: which the agent is offered, what it has asked for, and the phone's answers.
        return phone_tools.slash(phone_tools.Phone(_home()), words[1:])
    if words[:1] == ["cards"]:
        # Cards in replies (cards.py): on unless the phone turned them off.
        return cards.slash(_home(), words[1:])
    if words[:1] == ["calls"]:
        # Which agents may ring the phone (calls.py): kept in the main home, with the phones.
        return calls.slash(_store_in(calls.caller(_home())[1]), words[1:])
    store, pusher = _state()
    if len(words) == 3 and words[0] == "watch":
        following = store.watch(words[1], [w for w in words[2].split(",") if w])
        return f"redde-push watching {len(following)}"
    if len(words) in (2, 3) and words[0] == "rooms":
        # The group chats the phone lists (less those it has muted): those notify, no others.
        following = store.follow_rooms([w for w in words[1].split(",") if w],
                                       [r for r in (words[2] if len(words) == 3 else "").split(",") if r])
        if following and store.rooms_followed():
            _group_chats().start()
        _watch_schedules()
        return f"redde-push following {len(following)}"
    if len(words) in (2, 3) and words[0] == "mutes":
        # What the phone has muted, all of it: "s:<session>=<until>,g:<room>=<until>" (0: until it says).
        mutes = {}
        for pair in (words[2] if len(words) == 3 else "").split(","):
            key, _, until = pair.rpartition("=")
            if key and until.isdigit():
                mutes[key] = int(until)
        return f"redde-push muted {len(store.set_mutes([w for w in words[1].split(',') if w], mutes))}"
    if words == ["status"]:
        return f"redde-push status {len(store.devices)}"
    if words == ["offer"]:
        # Pairing without a code, for an app already signed in to this Dashboard: the same key
        # agreement as `hermes redde-push pair`, with this connection carrying the two halves.
        offer = _offers.make(_relay())
        return f"redde-push offer {core.b64u(offer.public)} {offer.relay}"
    if len(words) == 4 and words[0] == "accept":
        offer = _offers.take(words[1])
        if offer is None:
            return "redde-push refused: that offer has expired"
        try:
            device = offer.accept({"pub": words[2], "box": words[3]})
        except ValueError:
            return "redde-push refused: that answer isn't to this offer"
        store.add(device)
        # The first note, which the phone takes as proof that notes reach it. Not sent from here:
        # the app is waiting on this reply.
        threading.Thread(target=pusher.send, args=([device], core.note("paired")), name="redde-push-paired", daemon=True).start()
        return f"redde-push paired {core.host_name()}"
    return "redde-push: this command is for the Redde app. In a terminal: hermes redde-push pair"


# ---- hermes redde-push, for a person at the terminal -------------------------------------------

def _cli_setup(parser) -> None:
    actions = parser.add_subparsers(dest="action")
    pair = actions.add_parser("pair", help="pair an iPhone: shows a QR code for Redde to scan")
    pair.add_argument("--relay", default=_relay(), help="the push relay to use")
    pair.add_argument("--wait", type=int, default=600, help="seconds to wait for the phone")
    actions.add_parser("list", help="the paired phones")
    actions.add_parser("test", help="send each paired phone a test notification")
    remove = actions.add_parser("remove", help="forget a phone")
    remove.add_argument("phone", help="its name or id, as `list` shows them")
    notify = actions.add_parser("notify", help="which conversations notify")
    notify.add_argument("which", choices=["mine", "all"], help="mine: the ones the phone took part in. all: every one")


def _cli(args) -> None:
    store, pusher = _state()
    action = getattr(args, "action", None)
    if action == "pair":
        _pair(store, pusher, args.relay, args.wait)
    elif action == "list":
        if not store.devices:
            print("No phone is paired. Run: hermes redde-push pair")
        for device in store.devices:
            print(f"{device.get('name', 'iPhone')}  {device['id']}  paired {time.strftime('%Y-%m-%d', time.localtime(device.get('paired_at', 0)))}")
        if store.devices:
            print("Notifying about: " + ("every conversation" if store.notify_all else "the conversations the phone took part in"))
    elif action == "test":
        if not store.devices:
            print("No phone is paired. Run: hermes redde-push pair")
            return
        count = len(store.devices)
        sent = pusher.send(store.devices, core.note("test", body="Notifications from this Hermes reach your phone."))
        print(f"Sent to {sent} of {count} phone{'s' if count != 1 else ''}.")
    elif action == "remove":
        matches = [d for d in store.devices if args.phone in (d["id"], d.get("name"))]
        if len(matches) != 1:
            print("No phone by that name or id." if not matches else "More than one phone has that name; use its id.")
            return
        store.remove(matches[0]["id"])
        print(f"Forgot {matches[0].get('name', 'the phone')}. It can be paired again from Redde.")
    elif action == "notify":
        store.set_notify_all(args.which == "all")
        print("Every conversation on this Hermes notifies." if args.which == "all" else "Only the conversations the phone took part in notify.")
    else:
        print(__doc__.strip())


def _pair(store: core.Store, pusher: core.Pusher, relay: str, wait: int) -> None:
    offer = core.Offer(relay)
    print("In Redde on your iPhone: Settings › Notifications › When Redde is closed › Scan pairing code.")
    print("Or open this link on the phone:\n")
    print("  " + offer.link + "\n")
    if sys.stdout.isatty():
        try:
            print(qr.render(qr.matrix(offer.link.encode())) + "\n")
        except ValueError:
            pass   # a relay address too long for the code: the link still works
    print("Waiting for the phone… (Ctrl-C to give up)", flush=True)
    deadline, complained = time.time() + wait, False
    answer = None
    try:
        while answer is None and time.time() < deadline:
            try:
                answer = core.take_answer(offer.relay, offer.rendezvous)
            except Exception as error:
                if not complained:
                    print(f"Couldn't reach the relay at {offer.relay} ({error}). Still trying.")
                    complained = True
            if answer is None:
                time.sleep(2)
    except KeyboardInterrupt:
        print("\nStopped. Nothing was paired.")
        return
    if answer is None:
        print("No phone answered. Run the command again for a new code.")
        return
    try:
        device = offer.accept(answer)
    except ValueError as error:
        print(f"Pairing failed: {error}.")
        return
    store.add(device)
    sent = pusher.send([device], core.note("paired"))
    print(f"Paired with {device['name']}." + (" A notification is on its way to confirm it." if sent else " (The first notification couldn't be sent; try: hermes redde-push test)"))
    print("Restart Hermes if it was running before the plugin was enabled.")


def register(ctx) -> None:
    ctx.register_hook("on_session_start", _remember_platform)
    ctx.register_hook("pre_llm_call", _on_turn)
    ctx.register_hook("pre_approval_request", _on_approval)
    ctx.register_hook("post_llm_call", _on_reply)
    ctx.register_hook("pre_api_request", _on_request)
    ctx.register_hook("post_api_request", _on_answer)
    ctx.register_hook("api_request_error", _on_request_error)
    ctx.register_hook("on_session_end", _on_turn_end)
    ctx.register_hook("subagent_stop", _on_task_done)
    try:    # (not a hook Hermes 0.21.0 has, and it warns about a name it doesn't know)
        from hermes_cli.plugins import VALID_HOOKS
        known = "agent_loop_stopped" in VALID_HOOKS
    except Exception:
        known = False
    if known:
        ctx.register_hook("agent_loop_stopped", _on_stopped)
    ctx.register_command("redde-push", _slash, description="Used by the Redde app to follow a conversation",
                         args_hint="watch <session> <device> | rooms <device> <room,...>")
    # Phone tools (device.py): offered to the agent only for what the phone has turned on.
    phone_tools.register(ctx, lambda: phone_tools.Phone(_home()), to_widget=_to_widget)
    # Calls (calls.py): the agent rings the phone, if the phone takes calls from it.
    calls.register(ctx, _home, _store_in)
    # Cards (cards.py): a map, places, the weather, the time, drawn by the app under a reply.
    cards.register(ctx, _home)
    ctx.register_cli_command("redde-push", "Notifications on your iPhone from Redde", _cli_setup, _cli)
    _follow_group_chats_if_any()
    _watch_schedules()

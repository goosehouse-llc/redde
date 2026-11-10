"""Redde push: notifications on a paired iPhone, iPad or Mac when the agent finishes a reply, waits on a person
(an approval, a question, a sudo password, a secret) or gives up on a turn. See README.md here,
and `core.py` for how a note is sealed and sent.

    hermes redde-push pair      pair a device (shows a QR code for Redde to scan)
    hermes redde-push list      the paired devices
    hermes redde-push test      send each of them a test notification
    hermes redde-push remove <name>
    hermes redde-push notify mine|all

The app itself uses the slash command `/redde-push`, over the Dashboard: `watch <session>
<device,...>` says which conversations it has taken part in (only those notify, and every turn
over the Hermes API), `rooms <device,...> <room,...>` which group chats it follows (`rooms.py`),
`mutes <device,...> <key=until,...>` which chats it has muted, `calls <device,...> <profile,...>`
which agents may ring it (`calls.py`), `here <device,...> <until>` that it is in use until then
(0: no longer), so notes go only where the person is while a device is (from 1.19.0), `leave set <device> <wakes>` when to wake it for Leave-By
Alerts' traffic re-check (`leave.py`), and `offer` then `accept <offer> <key> <box>` pair it
without a code. From 1.15.0, `skip <profile> <job> <when>` skips a repeating job's next run
(`routines.py`), `goals list` lists every agent's goals and `goals end <profile> <goal>` ends
one (`goals.py`). From 1.16.0, `mail …` is the app's inbox (`mail.py`). From 1.20.0, `lists list`
and `lists do <change>` are the person's lists on the Today row (`lists.py`).

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

from . import calls, cards, core, followups, goals, handoffs, headsup, ideas, keys, leave, lists, longterm, mail, qr, remember, remind, rooms, routines, turnnote, watches, work, work_runs
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


def _main_home() -> Path:
    return calls.caller(_home())[1]


def _remind(profile: str, home: Path, job: dict, text: str) -> int:
    """A reminder's notification, as its run starts (remind.py): the same note the reader of the
    schedules would send after the run, to the same phones. To how many it went."""
    root = _main_home()
    store = _store_in(root)
    targets = store.unmuted(store.unmuted(store.devices, "b:" + profile), routines.job_mute(profile, str(job.get("id") or "")))
    if not targets:
        return 0
    main, pusher = _state()
    sender = pusher if store is main else core.Pusher(store, title_of=_title)
    title = routines.untagged(remind.plain(str(job.get("name") or "")))
    made = core.routine_note(profile, routines.Stores(root).name(home, profile), title, text, brief=str(job.get("id") or ""))
    return sender.send(targets, made)


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
    profile's home, whose store has the phones. From 1.15.0 read with no phone paired too: runs
    Redde asked to skip are moved on whether or not a phone can hear of the rest."""
    global _routines
    try:
        home = _home()
        if home.parent.name == "profiles":
            return
        if _routines is None:
            store, pusher = _state()
            _routines = routines.Routines(store, pusher.send, routines.Stores(home))
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
        if _work_waits(session, command, description):   # a workstream's: needs you (work.py)
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
        # A scheduled run's quiet answer ([SILENT], a watch's NOTHING NEW, "No change."), which
        # Hermes doesn't deliver, isn't pushed as a reply either, under Notify All (issue 55).
        if platform == "cron" and isinstance(assistant_response, str) and (
                routines.settle(assistant_response)[1] or watches.quiet(assistant_response)):
            return
        if _work_reply(session_id, assistant_response):   # a workstream's (work.py): its report says it
            return
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


#: How much of a long message a turn's notes look at, in characters: this much of its start and
#: of its end, where the asking is. The notes' patterns are for a sentence someone said; over a
#: pasted log with no full stop in it, "is … or … better" took 0.25 s at 8 KB and 1.9 s at 16 KB,
#: before every answer (measured 2026-11-09).
LOOKED_AT = 2000


def _said(message) -> str:
    """The turn's message as its notes look at it: its text (of a message with pictures, the text
    parts), and of a long one only the start and the end, cut between words with a full stop
    between the two, so that no pattern runs from one into the other."""
    if isinstance(message, dict):
        message = message.get("content")
    if isinstance(message, list):
        text = " ".join(str(p.get("text") or "") for p in message if isinstance(p, dict))
    else:
        text = message if isinstance(message, str) else ""
    if len(text) <= 2 * LOOKED_AT:
        return text
    start, end = text[:LOOKED_AT], text[-LOOKED_AT:]
    if not text[LOOKED_AT].isspace() and (cut := max(start.rfind(" "), start.rfind("\n"))) > 0:
        start = start[:cut]
    if not text[-LOOKED_AT - 1].isspace() and (cut := min((i for i in (end.find(" "), end.find("\n")) if i >= 0), default=-1)) >= 0:
        end = end[cut + 1:]
    return start + "\n.\n" + end


def _on_turn(session_id: str = "", platform: str = "", turn_id: str = "", user_message=None, **_) -> dict | None:
    """`pre_llm_call`: a turn starts. Asked the time or the weather, the agent is told the
    person's time and to show the card (`cards.turn_note`); asked to call, how (`calls.turn_note`)."""
    try:
        _remember_platform(session_id, platform)
        if platform not in NOBODYS:
            _watchers()[0].began(session_id, turn_id)
    except Exception:
        log.debug("redde-push: turn hook failed", exc_info=True)
    try:
        routines.remember_run(_home(), session_id, platform)   # a briefing's run, for its note (issue 62)
    except Exception:
        log.debug("redde-push: couldn't write the run's session down", exc_info=True)
    try:
        cards.turn_began(session_id)   # a reminder card needs this turn's setter (1.14.6)
    except Exception:
        log.debug("redde-push: card turn start failed", exc_info=True)
    notes = []
    try:
        work.turn_began(_home(), session_id)   # a workstream's turn (work.py)
        notes.append(work.digest(_home(), session_id))   # how the chat's workstreams stand
        notes.append(work.turn_note(_home(), session_id, platform))   # that it can hand a long job to one
    except Exception:
        log.debug("redde-push: workstream note failed", exc_info=True)
    # What was said, for the notes that go by its words; a run's own mark (a watch's, a goal's
    # check-in's, a briefing's) is looked for in the whole of it.
    said = _said(user_message)
    try:
        cards.announce()   # its calls told to the Dashboard's clients as they happen (issue 35)
        keys.announce()    # and request_secret's, so its card shows at once
    except Exception:
        log.debug("redde-push: couldn't have redde_show announced", exc_info=True)
    try:
        # What the app said goes with this message (turnnote.py, 1.21.0): the reply language, the
        # units, where they are. First, as when it was written after the message itself.
        notes.append(turnnote.turn_note(calls.caller(_home())[1], session_id, user_message))
    except Exception:
        log.debug("redde-push: the app's note failed", exc_info=True)
    try:
        notes.append(cards.turn_note(_home(), said, platform, session=session_id))
    except Exception:
        log.debug("redde-push: card note failed", exc_info=True)
    try:
        # Asked to call: how (calls.py), for an agent the phone takes calls from.
        notes.append(calls.turn_note(_home(), _store_in, said))
    except Exception:
        log.debug("redde-push: call note failed", exc_info=True)
    try:
        # A watch's run: what it told the person last time (watches.py).
        notes.append(watches.turn_note(_home(), routines.Stores(_home()), user_message))
    except Exception:
        log.debug("redde-push: watch note failed", exc_info=True)
    try:
        # Asked for something on a schedule: how its answers reach the phone (routines.py).
        notes.append(routines.turn_note(_home(), _store_in, said, platform))
        # A scheduled run: its answer goes to the phone as written (routines.py).
        notes.append(routines.cron_note(_home(), _store_in, platform))
    except Exception:
        log.debug("redde-push: schedule note failed", exc_info=True)
    try:
        # Something to do later, said in passing: that a follow-up can be set (followups.py).
        notes.append(followups.turn_note(_home(), _store_in, said, platform))
        # Asked to hear when something happens: that a watch can be set (watches.py).
        notes.append(watches.ask_note(_home(), _store_in, said, platform))
    except Exception:
        log.debug("redde-push: follow-up note failed", exc_info=True)
    try:
        # Something that sounds like a goal: that one can be set (goals.py); a goal's check-in:
        # its steps and how to answer.
        notes.append(goals.turn_note(said, platform))
        notes.append(goals.checkin_note(_home(), user_message, platform))
    except Exception:
        log.debug("redde-push: goal note failed", exc_info=True)
    try:
        # One of their lists (lists.py, 1.20.0): redde_list, not the agent's own todo tool.
        notes.append(lists.turn_note(said, platform))
    except Exception:
        log.debug("redde-push: list note failed", exc_info=True)
    try:
        # Asked about email (mail.py, 1.16.0): redde_mail, email as data, the inbox card; and a
        # briefing's run: the inbox as sorted.
        root = calls.caller(_home())[1]
        notes.append(mail.turn_note(root, said, platform))
        notes.append(mail.brief_note(root, user_message, platform))
    except Exception:
        log.debug("redde-push: mail note failed", exc_info=True)
    try:
        # "Remember that…" / "Forget that…" (remember.py): how to use the memory tool, so Redde's
        # Memory page shows one clean entry and a forget really removes it.
        notes.append(remember.turn_note(said, platform))
        # The app's "Save to long-term memory:" (longterm.py): exactly those, with the provider's tool.
        notes.append(longterm.turn_note(user_message, platform, _config()))
    except Exception:
        log.debug("redde-push: memory note failed", exc_info=True)
    try:
        # A key it asked for (keys.py): set or declined since, said once.
        notes.append(keys.turn_note(_home()))
    except Exception:
        log.debug("redde-push: key note failed", exc_info=True)
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
        # A reminder card counts only after its reminder is set (1.14.6): seen here, before the tools run.
        cards.saw_calls(session_id, core.tool_calls(assistant_message))
    except Exception:
        log.debug("redde-push: card setter watch failed", exc_info=True)
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


def _on_tool_done(tool_name: str = "", args=None, result=None, session_id: str = "", **_) -> None:
    """`post_tool_call`: a reminder, timer, alarm or job tool finished; its job id goes onto the
    reminder card that follows (1.14.6); a bot's hand-off is kept past its chat's close
    (`handoffs`, 1.23.1). Nothing else, and quickly: it runs after every tool."""
    try:
        cards.saw_result(session_id, tool_name, args, result)
    except Exception:
        log.debug("redde-push: tool result watch failed", exc_info=True)
    try:
        handoffs.keep(tool_name)
    except Exception:
        log.debug("redde-push: hand-off keep failed", exc_info=True)


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


def _on_turn_end(session_id: str = "", platform: str = "", turn_id: str = "", failed=False, turn_exit_reason: str = "",
                 interrupted=False, **_) -> None:
    """`on_session_end`. With a turn id it is a turn ending; the Dashboard also sends it, without
    one, when it closes a session, which says nothing about a turn."""
    try:
        if not turn_id or not session_id:
            return
        if _work_ended(session_id, failed is True, interrupted is True):   # a workstream's (work.py)
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


# ---- Workstreams (work.py, 1.22.0) ----

#: A workstream's last reply, by its session, for the report its turn's end makes.
_work_said: dict[str, str] = {}


def _work_note(row: dict, what: str, body: str) -> None:
    """A workstream finished, failed or waits on the person: told to the phones, as its bot's."""
    home = _home()
    profile, root = calls.caller(home)
    # The phones are paired with the main home, whichever bot's workstream it is (as for reminders).
    store = _store_in(root)
    targets = store.unmuted(store.devices, "b:" + profile)
    if targets:
        main, pusher = _state()
        sender = pusher if store is main else core.Pusher(store, title_of=_title)
        made = core.work_note(profile, row["ref"], row["title"], what, body, row.get("session") or "",
                              bot=routines.Stores(root).name(home, profile), engine=row.get("engine") or "serve")
        threading.Thread(target=sender.send, args=(targets, made), name="redde-work-note", daemon=True).start()


def _work_waits(session: str, command: str, description: str) -> bool:
    try:
        # The command itself, as an approval's note carries it: the app puts it in words.
        row = work.needs_you(_home(), session, command or description)
        if row is None:
            return False
        _work_note(row, "needs", command or description)
        return True
    except Exception:
        log.debug("redde-push: workstream approval failed", exc_info=True)
        return False


def _work_reply(session: str, reply) -> bool:
    try:
        if not work.Store(_home()).of_session(session):
            return False
        if isinstance(reply, str) and reply.strip():
            _work_said[session] = reply
        return True
    except Exception:
        return False


def _work_ended(session: str, failed: bool, interrupted: bool) -> bool:
    try:
        home = _home()
        row = work.turn_ended(home, session, failed, interrupted, _work_said.pop(session, ""))
        if row is None:
            return False
        if row["status"] in ("done", "failed"):
            _work_note(row, row["status"], row.get("last") or "")
            if row.get("chat"):
                work.report(row["chat"], calls.caller(home)[0], work.report_text(row), row.get("engine") or "serve")
        return True
    except Exception:
        log.debug("redde-push: workstream end failed", exc_info=True)
        return False


def _on_approval_answered(session_id: str = "", session_key: str = "", **_) -> None:
    """`post_approval_response`: a workstream waiting on the person works again."""
    try:
        work.answered(_home(), session_id or session_key)
    except Exception:
        log.debug("redde-push: workstream answer failed", exc_info=True)


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
    if words[:1] == ["turn"]:
        # What goes to the agent with the app's next message (turnnote.py), kept in the main home.
        return turnnote.slash(calls.caller(_home())[1], words[1:])
    if words[:1] == ["cards"]:
        # Cards in replies (cards.py): on unless the phone turned them off.
        return cards.slash(_home(), words[1:])
    if words[:1] == ["autonomy"]:
        # How much each agent may do unasked (cards.py), kept in the main home.
        return cards.autonomy_slash(_home(), words[1:])
    if words[:1] == ["gated"]:
        # Agents whose actions Hermes already asks about: no review cards first (cards.py).
        return cards.gated_slash(_home(), words[1:])
    if words[:1] == ["keys"]:
        # Keys a bot asked for (keys.py): the app lists them, and answers one with the key sealed
        # to that request alone, or declines it. Kept in the main home.
        said = keys.slash(calls.caller(_home())[1], words[1:])
        if said.startswith("redde-push keys set REDDE_MAIL_"):
            mail._usable_cache.clear()   # (read from .env each time: counts at once, no restart)
        return said
    if words[:1] == ["calls"]:
        # Which agents may ring the phone (calls.py): kept in the main home, with the phones.
        return calls.slash(_store_in(calls.caller(_home())[1]), words[1:])
    if words[:1] == ["work"]:
        # Workstreams (work.py): the app's Work sheet lists them and stops one, per profile.
        return work.slash(calls.caller(_home())[1], words[1:])
    if words[:1] == ["job-model"]:
        # A job's own model at once (routines.py, Run On): `job-model <profile> <job> <model|-> <provider|->`.
        return _job_model_slash(words[1:])
    if words[:1] == ["skip"]:
        # Skip a repeating job's next run at once (routines.py): `skip <profile> <job> <when>`.
        return _skip_slash(words[1:])
    if words[:2] == ["goals", "list"]:
        # Every agent's goals, with their steps and latest progress (goals.py), as JSON.
        import json
        return "redde-push goals " + json.dumps(goals.listing(routines.Stores(calls.caller(_home())[1])), ensure_ascii=False)
    if words[:2] == ["goals", "end"]:
        # End a goal: its check-in job deleted, the goal marked ended (goals.py).
        return _end_goal_slash(words[2:])
    if words[:1] == ["lists"]:
        # The person's lists (lists.py): every one as JSON, and a change from the phone. The main home's.
        return lists.slash(calls.caller(_home())[1], words[1:])
    if words[:1] == ["memory"]:
        # An import's facts to long-term memory (longterm.py): which store, and a memory MCP server
        # written to with no model call.
        return longterm.slash(words[1:], raw_args, _config(), _tool_names(), _dispatch, _tool_schema)
    if words[:1] == ["mail"]:
        # Email (mail.py, 1.16.0): the app's inbox, its taps, drafts, rules, the log; JSON answers.
        return mail.slash(mail.Inbox(calls.caller(_home())[1]), words[1:], raw_args)
    if words[:1] == ["leave"]:
        # When to wake a device for Leave-By Alerts' traffic re-check (leave.py): kept in the main
        # home, with the phones; the schedules' thread sends each at its time.
        said = leave.slash(_store_in(calls.caller(_home())[1]), words[1:])
        _watch_schedules()
        return said
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
    if len(words) == 3 and words[0] == "here" and words[2].isdigit():
        # Where the person is: these devices are in use until then (0: no longer).
        return f"redde-push here {len(store.set_here([w for w in words[1].split(',') if w], int(words[2])))}"
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


def _end_goal_slash(words: list[str], remove=None) -> str:
    """`/redde-push goals end <profile> <goal>`: "redde-push goals ended <goal>", or "redde-push
    goals unknown"."""
    if len(words) != 2 or not calls.PROFILE.fullmatch(words[0]) or not goals.goal_id(f"[redde-goal:{words[1]}]"):
        return "redde-push goals: this command is for the Redde app."
    root = calls.caller(_home())[1]
    said = goals.end(root if words[0] == "default" else root / "profiles" / words[0], words[1], remove)
    return f"redde-push goals ended {words[1]}" if "ended" in said else "redde-push goals unknown"


def _skip_slash(words: list[str], cron=None) -> str:
    """`/redde-push skip <profile> <job> <when>`: "redde-push skipped <job> <next run>", or
    "redde-push skip <outcome>" (gone, waiting, failed, unknown)."""
    if len(words) != 3 or not words[2].isdigit() or not calls.PROFILE.fullmatch(words[0]):
        return "redde-push skip: this command is for the Redde app."
    root = calls.caller(_home())[1]
    home = root if words[0] == "default" else root / "profiles" / words[0]
    stores = routines.Stores(root)
    job = next((j for j in stores.jobs(home) if str(j.get("id")) == words[1]), None)
    if job is None:
        return "redde-push skip unknown"
    outcome = routines.skip(home, job, int(words[2]), cron)
    if outcome != "skipped":
        return f"redde-push skip {outcome}"
    moved = next((j for j in stores.jobs(home) if str(j.get("id")) == words[1]), {})
    return f"redde-push skipped {words[1]} {moved.get('next_run_at') or ''}".rstrip()


def _job_model_slash(words: list[str], cron=None) -> str:
    """`/redde-push job-model <profile> <job> <model|-> <provider|->`: "redde-push job-model set
    <job> <model>" ("-": the main model again), or "redde-push job-model <outcome>" (unknown, failed)."""
    if len(words) != 4 or not calls.PROFILE.fullmatch(words[0]) or not all(words[1:]) \
            or any(c in w for w in words[2:] for c in "]|\n"):
        return "redde-push job-model: this command is for the Redde app."
    root = calls.caller(_home())[1]
    home = root if words[0] == "default" else root / "profiles" / words[0]
    job = next((j for j in routines.Stores(root).jobs(home) if str(j.get("id")) == words[1]), None)
    if job is None:
        return "redde-push job-model unknown"
    model = "" if words[2] == "-" else words[2]
    provider = "" if words[3] == "-" else words[3]
    outcome = routines.set_model(home, job, model, provider, cron)
    if outcome != "set":
        return f"redde-push job-model {outcome}"
    return f"redde-push job-model set {words[1]} {model or '-'}"


# ---- hermes redde-push, for a person at the terminal -------------------------------------------

def _cli_setup(parser) -> None:
    actions = parser.add_subparsers(dest="action")
    pair = actions.add_parser("pair", help="pair an iPhone, iPad or Mac: shows a QR code for Redde to scan")
    pair.add_argument("--relay", default=_relay(), help="the push relay to use")
    pair.add_argument("--wait", type=int, default=600, help="seconds to wait for the device")
    actions.add_parser("list", help="the paired devices")
    actions.add_parser("test", help="send each paired device a test notification")
    remove = actions.add_parser("remove", help="forget a device")
    remove.add_argument("phone", help="its name or id, as `list` shows them")
    notify = actions.add_parser("notify", help="which conversations notify")
    notify.add_argument("which", choices=["mine", "all"], help="mine: the ones the device took part in. all: every one")


def _cli(args) -> None:
    store, pusher = _state()
    action = getattr(args, "action", None)
    if action == "pair":
        _pair(store, pusher, args.relay, args.wait)
    elif action == "list":
        if not store.devices:
            print("No device is paired. Run: hermes redde-push pair")
        for device in store.devices:
            # Which it is, when the app said (a Redde from before 2026-10-30 didn't): an iPhone, an iPad, a Mac.
            kind = f" ({core.KIND_NAMES[core.device_kind(device)]})" if device.get("kind") else ""
            print(f"{device.get('name', 'iPhone')}{kind}  {device['id']}  paired {time.strftime('%Y-%m-%d', time.localtime(device.get('paired_at', 0)))}")
        if store.devices:
            print("Notifying about: " + ("every conversation" if store.notify_all else "the conversations each device took part in"))
    elif action == "test":
        if not store.devices:
            print("No device is paired. Run: hermes redde-push pair")
            return
        count = len(store.devices)
        sent = pusher.send(store.devices, core.note("test", body="Notifications from this Hermes reach you here."))
        print(f"Sent to {sent} of {count} device{'s' if count != 1 else ''}.")
    elif action == "remove":
        matches = [d for d in store.devices if args.phone in (d["id"], d.get("name"))]
        if len(matches) != 1:
            print("No device by that name or id." if not matches else "More than one device has that name; use its id.")
            return
        store.remove(matches[0]["id"])
        print(f"Forgot {matches[0].get('name', 'the device')}. It can be paired again from Redde.")
    elif action == "notify":
        store.set_notify_all(args.which == "all")
        print("Every conversation on this Hermes notifies." if args.which == "all" else "Only the conversations each device took part in notify.")
    else:
        print(__doc__.strip())


def _pair(store: core.Store, pusher: core.Pusher, relay: str, wait: int) -> None:
    offer = core.Offer(relay)
    print("In Redde on your iPhone, iPad or Mac: Settings › Notifications › Alerts When Redde Is Closed, then scan the code or paste the link.")
    print("Or open this link on the device:\n")
    print("  " + offer.link + "\n")
    if sys.stdout.isatty():
        try:
            print(qr.render(qr.matrix(offer.link.encode())) + "\n")
        except ValueError:
            pass   # a relay address too long for the code: the link still works
    print("Waiting for the device… (Ctrl-C to give up)", flush=True)
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
        print("No device answered. Run the command again for a new code.")
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


_plugin_ctx = None


def _config() -> dict:
    try:
        from hermes_cli.config import load_config
        return load_config() or {}
    except Exception:
        return {}


def _tool_names() -> list[str]:
    try:
        from tools.registry import registry
        return registry.get_all_tool_names()
    except Exception:
        return []


def _tool_schema(name: str):
    try:
        from tools.registry import registry
        return registry.get_schema(name)
    except Exception:
        return None


def _dispatch(name: str, args: dict) -> str:
    if _plugin_ctx is None:
        raise RuntimeError("the plugin isn't registered")
    return _plugin_ctx.dispatch_tool(name, args)


def register(ctx) -> None:
    global _plugin_ctx
    _plugin_ctx = ctx
    ctx.register_hook("on_session_start", _remember_platform)
    ctx.register_hook("pre_llm_call", _on_turn)
    ctx.register_hook("pre_approval_request", _on_approval)
    ctx.register_hook("post_llm_call", _on_reply)
    ctx.register_hook("pre_api_request", _on_request)
    ctx.register_hook("post_api_request", _on_answer)
    ctx.register_hook("post_tool_call", _on_tool_done)
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
    try:
        if "post_approval_response" in VALID_HOOKS:
            ctx.register_hook("post_approval_response", _on_approval_answered)
    except Exception:
        pass
    # A reminder's run answered here, with no model (remind.py, 1.14.6; Hermes 0.22+ has middleware).
    register_middleware = getattr(ctx, "register_middleware", None)
    if callable(register_middleware):
        register_middleware("llm_execution", remind.Reminders(_main_home, lambda: _store_in(_main_home()), _remind).turn)
    ctx.register_command("redde-push", _slash, description="Used by the Redde app to follow a conversation",
                         args_hint="watch <session> <device> | rooms <device> <room,...>")
    # Phone tools (device.py): offered to the agent only for what the phone has turned on.
    phone_tools.register(ctx, lambda: phone_tools.Phone(_home()), to_widget=_to_widget)
    # Calls (calls.py): the agent rings the phone, if the phone takes calls from it.
    calls.register(ctx, _home, _store_in)
    # Cards (cards.py): a map, places, the weather, the time, drawn by the app under a reply.
    cards.register(ctx, _home)
    # Ideas (ideas.py): things the agent could do, as cards on the phone to take or put away.
    ideas.register(ctx, _home, _store_in)
    # Follow-ups (followups.py): a loose end the person mentioned, offered back as an idea later.
    followups.register(ctx, _home, _store_in)
    # Heads-ups (headsup.py): before an event, what the person needs for it, as a notification.
    headsup.register(ctx, _home, _store_in)
    # Watches the agent sets itself (watches.py): "let me know when…".
    watches.register(ctx, _home, _store_in)
    # Goals (goals.py): a plan on the Kanban board, check-ins, progress on the phone.
    goals.register(ctx, _home)
    # Lists (lists.py): to-do lists and the like, a tile each on the phone's Today row.
    lists.register(ctx, _home)
    # Email (mail.py): redde_mail while an account is set up, and one way to send.
    mail.register(ctx, _home)
    # Workstreams (work.py): a job handed to a hidden chat of the agent's own.
    work.register(ctx, _home, lambda home: calls.caller(home)[0], lambda session: _platforms.get(session, ""))
    # The app's way to these commands over the Hermes API, with no Dashboard (work_runs.py, 1.23.0).
    register_handler = getattr(ctx, "register_platform_handler", None)
    if callable(register_handler):
        try:
            register_handler("api_server", work_runs.wire(_slash))
        except Exception:
            log.debug("redde-push: no route on the Hermes API", exc_info=True)
    # Keys a bot asks for (keys.py): pasted into a card in Redde, straight into the profile's .env.
    keys.register(ctx, _home, _store_in, lambda home, profile: routines.Stores(calls.caller(home)[1]).name(home, profile))
    ctx.register_cli_command("redde-push", "Notifications on your iPhone, iPad or Mac from Redde", _cli_setup, _cli)
    _follow_group_chats_if_any()
    _watch_schedules()

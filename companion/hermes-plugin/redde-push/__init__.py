"""Redde push: notifications on a paired iPhone when the agent finishes a reply or waits for an
approval. See README.md here, and `core.py` for how a note is sealed and sent.

    hermes redde-push pair      pair a phone (shows a QR code for Redde to scan)
    hermes redde-push list      the paired phones
    hermes redde-push test      send each of them a test notification
    hermes redde-push remove <name>
    hermes redde-push notify mine|all

The app itself uses one slash command, `/redde-push watch <session> <device,...>`, to say which
conversations it has taken part in; only those notify (and every turn over the Hermes API).
"""

from __future__ import annotations

import atexit
import logging
import os
import sys
import time
from pathlib import Path

from . import core, qr

log = logging.getLogger("redde_push")

_store: core.Store | None = None
_pusher: core.Pusher | None = None
#: session id -> the platform its turns run on ("tui" for the Dashboard, "api_server", "cli", a
#: messaging platform). The approval hook isn't told, so the turn's earlier hooks remember.
_platforms: dict[str, str] = {}


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


def _state() -> tuple[core.Store, core.Pusher]:
    global _store, _pusher
    if _store is None or _pusher is None:
        _store = core.Store(_home())
        _pusher = core.Pusher(_store, title_of=_title)
        atexit.register(_pusher.drain)
    return _store, _pusher


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
        _state()[1].submit("approval", session, _platforms.get(session, ""), body=command, detail=description)
    except Exception:
        log.debug("redde-push: approval hook failed", exc_info=True)


def _on_reply(session_id: str = "", assistant_response: str = "", platform: str = "", **_) -> None:
    try:
        if isinstance(assistant_response, str) and assistant_response.strip():
            _state()[1].submit("reply", session_id, platform or _platforms.get(session_id, ""), body=assistant_response)
    except Exception:
        log.debug("redde-push: reply hook failed", exc_info=True)


# ---- /redde-push, for the app ------------------------------------------------------------------

def _slash(raw_args: str = "") -> str:
    words = (raw_args or "").split()
    store, _ = _state()
    if len(words) == 3 and words[0] == "watch":
        following = store.watch(words[1], [w for w in words[2].split(",") if w])
        return f"redde-push watching {len(following)}"
    if words[:1] == ["status"]:
        return f"redde-push paired {len(store.devices)}"
    return "redde-push: this command is for the Redde app. In a terminal: hermes redde-push pair"


# ---- hermes redde-push, for a person at the terminal -------------------------------------------

def _cli_setup(parser) -> None:
    actions = parser.add_subparsers(dest="action")
    pair = actions.add_parser("pair", help="pair an iPhone: shows a QR code for Redde to scan")
    pair.add_argument("--relay", default=os.environ.get("REDDE_PUSH_RELAY") or core.DEFAULT_RELAY, help="the push relay to use")
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
    ctx.register_hook("pre_llm_call", _remember_platform)
    ctx.register_hook("pre_approval_request", _on_approval)
    ctx.register_hook("post_llm_call", _on_reply)
    ctx.register_command("redde-push", _slash, description="Used by the Redde app to follow a conversation", args_hint="watch <session> <device>")
    ctx.register_cli_command("redde-push", "Notifications on your iPhone from Redde", _cli_setup, _cli)

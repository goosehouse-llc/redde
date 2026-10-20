"""Group chats: a note to the phones that follow one when a bot says something in it, and when a
bot waits on the person there (a command to approve, a turn to try again).

No Hermes release has a hook for a bot's message in a group chat. (0.21.3's
`on_room_member_activity` streams a turn's words, not the message the room keeps, and fires only
where the bot's own profile has this plugin.) So the room's own log is read: every few seconds,
from a thread of this plugin's, in whichever of Hermes's processes has it loaded (the Dashboard's
once the app has said which group chats it follows; the gateway's once it has run a turn). How far
each room has been read is kept on disk, under a lock, so two processes reading it send each
message once. What a bot waits on is kept in memory by the process running the room: the
Dashboard's, which is the one the app asks too, so what is announced is what the app can answer.

`HermesRooms` is all that touches Hermes, so `Rooms` can be tested alone.
"""

from __future__ import annotations

import logging
import sys
import threading
import time

from . import core

log = logging.getLogger("redde_push")

#: How often the rooms are read while some are followed, and while none are, in seconds.
EVERY = 4.0
IDLE = 30.0
#: Pages of a room's log read in one look (100 events each): past that, the rest waits for the next.
PAGES = 5


class HermesRooms:
    """Hermes's group chats: the room store every process can read, and the room service of the
    process this runs in, when it runs rooms."""

    @staticmethod
    def _store():
        from gateway import hosted_rooms
        return hosted_rooms, hosted_rooms.default_db_path()

    def rooms(self) -> dict[str, dict]:
        """room id -> its name, its members' names by member id, and its latest event."""
        module, db = self._store()
        found = {}
        for row in module.list_rooms(db):
            members = {}
            for member in row.get("members") or []:
                member_id = str(member.get("member_id") or "")
                members[member_id] = str(member.get("display_name") or member.get("profile") or member.get("handle") or member_id)
            found[str(row.get("room_id"))] = {"name": str(row.get("name") or ""), "members": members,
                                              "latest": int(row.get("latest_seq") or 0)}
        return found

    def events(self, room: str, since: int) -> tuple[list[dict], int]:
        """The room's events after `since`, oldest first, and how far that reads."""
        module, db = self._store()
        found, cursor = [], since
        for _ in range(PAGES):
            page = module.read_events(db, room_id=room, since_seq=cursor, limit=100)
            events = list(page.get("events") or [])
            found += events
            last = max([int(e.get("seq") or 0) for e in events] or [cursor])
            cursor = max(cursor, int(page.get("cursor") or 0), last)
            if not page.get("has_more") or not events:
                break
        return found, cursor

    def waits(self, room: str) -> list[dict] | None:
        """What the room waits on the person for, as this process's room service has it: None when
        this process runs no rooms (it can't say)."""
        groups = sys.modules.get("tui_gateway.methods_groups")
        service = getattr(groups, "_service", None) if groups else None
        if service is None:
            return None
        try:
            return [dict(action) for action in service.status(room).get("pending_actions") or []]
        except Exception:
            return None


def message_note(room_id: str, room: dict, event: dict) -> dict | None:
    """A note for a bot's message in a room, or None for anything else in its log."""
    if event.get("kind") != "message.member":
        return None
    payload = event.get("payload") or {}
    text = str(payload.get("text") or "")
    if not text.strip():
        return None
    actor = event.get("actor") or {}
    member = str(payload.get("member_id") or actor.get("id") or "")
    who = room["members"].get(member) or str(actor.get("display_name") or actor.get("profile") or member)
    return core.room_note("group", room_id, room["name"], body=text, detail=who)


def wait_note(room_id: str, room: dict, action: dict) -> tuple[str, dict] | None:
    """What a room waits on, as a note and the key it is announced under once, or None."""
    kind = action.get("kind")
    if kind == "approval":
        asked = action.get("approval") or {}
        command = str(asked.get("command") or "")
        who = room["members"].get(str(action.get("member_id") or ""), "")
        key = f"{room_id}|approval|{action.get('request_id') or core.digest(command)}"
        return key, core.room_note("group_wait", room_id, room["name"], body=command, detail=who, waits="approval",
                                   asked=str(asked.get("description") or ""))
    if kind == "retry" and action.get("task_id"):
        task = str(action["task_id"])
        return f"{room_id}|retry|{task}", core.room_note("group_wait", room_id, room["name"], waits="retry", task=task)
    return None


class Rooms:
    """Reads the followed rooms and sends what is new in them: `look` once, `start` for good."""

    def __init__(self, store: core.Store, send, source=None, every: float = EVERY):
        self.store = store
        self.send = send   # (devices, note) -> how many it reached
        self.source = source or HermesRooms()
        self.every = every
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()

    def start(self) -> None:
        with self._lock:
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="redde-push-rooms", daemon=True)
                self._thread.start()

    def _run(self) -> None:
        while True:
            busy = False
            try:
                busy = bool(self.store.rooms_followed())
                if busy:
                    self.look()
            except Exception:
                log.debug("redde-push: reading the group chats failed", exc_info=True)
            time.sleep(self.every if busy else IDLE)

    def look(self) -> int:
        """Reads each followed room once: notes for what is new, sent to the phones following it.
        How many notes went. Another process reading at the same moment: this one leaves it."""
        followed = self.store.rooms_followed()
        if not followed:
            return 0
        outgoing: list[tuple[list[str], dict]] = []
        with self.store.rooms_lock() as mine:
            if not mine:
                return 0
            rooms = self.source.rooms()
            cursors, announced = self.store.room_cursors(), self.store.room_waits()
            for room_id, devices in followed.items():
                room = rooms.get(room_id)
                if room is None:
                    continue
                since = cursors.get(room_id)
                if since is None:
                    # First seen: what it said before isn't news.
                    cursors[room_id] = room["latest"]
                else:
                    events, cursors[room_id] = self.source.events(room_id, int(since))
                    outgoing += [(devices, made) for made in (message_note(room_id, room, e) for e in events) if made]
                waits = self.source.waits(room_id)
                if waits is None:
                    continue
                pending = set()
                for action in waits:
                    found = wait_note(room_id, room, action)
                    if not found:
                        continue
                    key, made = found
                    pending.add(key)
                    if key not in announced:
                        announced[key] = int(time.time())
                        outgoing.append((devices, made))
                # Answered or gone: it may be asked again.
                for key in [k for k in announced if k.startswith(room_id + "|") and k not in pending]:
                    announced.pop(key)
            self.store.set_room_cursors({r: c for r, c in cursors.items() if r in rooms})
            self.store.set_room_waits(announced)
        sent = 0
        for devices, made in outgoing:
            targets = [d for d in self.store.devices if d.get("id") in devices]
            if targets:
                sent += self.send(targets, made)
        return sent

"""When you've gone quiet (1.36.0, 2026-11-22, after Heartbeat 2.0's "when silent 24h" wakes): a
scheduled job that runs only once the person hasn't written to any agent for so many hours, and
once for each quiet stretch, so the agent looks at what may need them (an approval waiting, a
follow-up due, tomorrow) and says so only when something does.

The job is an ordinary Hermes cron job that runs every hour, its prompt opening with a mark
("[redde-quiet:24h] …"; Redde's Settings › Your Day › Daily Jobs › When You've Gone Quiet makes
it). Each hourly run that isn't due is answered here, as reminders are (`remind.py`, an
llm_execution middleware, Hermes 0.22+): "[SILENT]", no model, nothing sent. A due run goes on to
the model, and the stretch counts as woken until the person writes again.

When the person last wrote is kept in the main home's store (`said.json`), from every turn of
theirs the plugin sees: hermes serve and the gateway both load it. Bots' turns in a group chat,
scheduled runs and subagents aren't the person.
"""
from __future__ import annotations

import json
import logging
import re
import threading
import time
from pathlib import Path

from . import proactive, remind

log = logging.getLogger("redde_push")

MARK = re.compile(r"^\s*\[redde-quiet:(\d{1,3})h\]", re.I)
FILE = "said.json"
#: Hours a quiet wake may wait for: half a day to two weeks.
SHORTEST, LONGEST = 6, 336
#: How often a person's turns are written down (a long chat isn't a write a message).
EVERY = 60


def hours(job: dict) -> int | None:
    """The quiet a job waits for, in hours, or None for a job that isn't one."""
    found = MARK.match(str(job.get("prompt") or ""))
    if not found:
        return None
    return max(SHORTEST, min(LONGEST, int(found.group(1))))


class Said:
    """When the person last wrote, and when each quiet job last woke: one small file, read and
    written by every process that loads the plugin."""

    def __init__(self, root: Path):
        self.file = Path(root) / "redde-push" / FILE
        self._lock = threading.Lock()

    def _read(self) -> dict:
        try:
            data = json.loads(self.file.read_text())
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}

    def _write(self, data: dict) -> None:
        self.file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.file.with_suffix(f".{threading.get_ident()}.new")
        tmp.write_text(json.dumps(data))
        tmp.replace(self.file)

    def wrote(self, now: float | None = None) -> None:
        now = time.time() if now is None else now
        with self._lock:
            data = self._read()
            if now - float(data.get("at") or 0) < EVERY:
                return
            data["at"] = int(now)
            self._write(data)

    def last(self, now: float | None = None) -> float:
        """When they last wrote; a store that has never heard them starts the clock now."""
        with self._lock:
            data = self._read()
            if not data.get("at"):
                data["at"] = int(time.time() if now is None else now)
                self._write(data)
            return float(data["at"])

    def due(self, key: str, wait_hours: int, now: float | None = None) -> bool:
        """Whether a quiet job may wake now: quiet long enough, and not woken since they last
        wrote. A wake is kept as soon as it's said, so a retried call doesn't wake it twice."""
        now = time.time() if now is None else now
        last = self.last(now)
        with self._lock:
            data = self._read()
            woke = data.setdefault("woke", {})
            if now - last < wait_hours * 3600 or float(woke.get(key) or 0) >= last:
                return False
            woke[key] = int(now)
            self._write(data)
        return True


def person(platform: str, message) -> bool:
    """Whether a turn is the person's own (not a schedule, a subagent or a bot in a room)."""
    if platform in ("cron", "subagent", "bot_room"):
        return False
    text = message if isinstance(message, str) else " ".join(
        str(p.get("text") or "") for p in message or [] if isinstance(p, dict)) if isinstance(message, list) else ""
    return bool(text.strip())


class QuietWakes:
    """The middleware. `root_of()` is the main Hermes home."""

    def __init__(self, root_of):
        self.root_of = root_of
        self._waking: dict[str, float] = {}   # runs let through: their later model calls go on too
        self._lock = threading.Lock()

    def turn(self, request=None, next_call=None, **context):
        session = str(context.get("session_id") or "")
        if not session.startswith("cron_"):
            return next_call(request)
        with self._lock:
            if session in self._waking:
                return next_call(request)
        try:
            found = remind.find(self.root_of(), session)
            if found and proactive.stands_down(proactive.level(self.root_of()), found[2]):
                # Agents Bring Up is Off (1.58.0): a run only there to suggest things ends here.
                return remind.as_response("[SILENT]", str(context.get("api_mode") or ""))
            wait = hours(found[2]) if found else None
            if wait is None:
                return next_call(request)
            profile, _, job = found
            woke = Said(self.root_of()).due(f"{profile}|{job.get('id')}", wait)
        except Exception:
            log.debug("redde-push: reading a quiet wake failed", exc_info=True)
            return next_call(request)
        if woke:
            with self._lock:
                now = time.time()
                self._waking = {s: t for s, t in self._waking.items() if now - t < 6 * 3600}
                self._waking[session] = now
            return next_call(request)
        return remind.as_response("[SILENT]", str(context.get("api_mode") or ""))

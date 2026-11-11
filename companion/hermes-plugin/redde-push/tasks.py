"""Reports of tasks the agent handed off, kept for the chat (1.27.0, GitHub issue 63).

A task the agent hands to a subagent in the background can finish while nobody has the chat
open. On the Dashboard, Hermes keeps the result until a client is in that chat again; only then
does it write its "[ASYNC DELEGATION …]" row into the chat and start the agent's answer. The
plugin doesn't wait that long: when no turn reports a task within `core.Turns.REPORT` seconds,
the phone is told the task's own summary. Opened from that, the chat had none of those words:
the row wasn't written yet, and the agent's answer, once it came, said it differently.

So every report the phone was told is kept here, by the session it belongs to, and the app asks
for them (`/redde-push tasks <session>`): it shows a report as a card at the end of the chat until
Hermes's own row for it is there, and it opens the report that a tap on its notification was for.
"""
from __future__ import annotations

import json
import os
import re
import time
from contextlib import contextmanager
from pathlib import Path

FILE = "task-reports.json"
KEPT_FOR = 3 * 86400    # a chat opened days later still shows what the notification said
AT_MOST = 60            # reports kept, every session together
PER_SESSION = 10        # ...and of one session, the newest
LONGEST = 6000          # characters of a summary

_SESSION = re.compile(r"[A-Za-z0-9_.:\-]{1,160}")


def path(home: Path) -> Path:
    return Path(home) / "redde-push" / FILE


@contextmanager
def _locked(home: Path):
    """Held while the file is read and written: a profile's hook and the app's command may be at
    it at once, from two processes."""
    folder = Path(home) / "redde-push"
    folder.mkdir(parents=True, exist_ok=True)
    handle = open(os.open(folder / "task-reports.lock", os.O_WRONLY | os.O_CREAT, 0o600), "w")
    try:
        try:
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX)
        except (ImportError, OSError):
            pass
        yield
    finally:
        handle.close()


def _load(home: Path, now: float) -> list[dict]:
    try:
        kept = json.loads(path(home).read_text())
    except (OSError, ValueError):
        return []
    if not isinstance(kept, list):
        return []
    return [r for r in kept if isinstance(r, dict) and isinstance(r.get("session"), str)
            and isinstance(r.get("at"), (int, float)) and 0 <= now - r["at"] < KEPT_FOR]


def _save(home: Path, reports: list[dict]) -> None:
    target = path(home)
    if not reports:
        try:
            target.unlink()
        except OSError:
            pass
        return
    temporary = target.with_suffix(".tmp")
    # What a task found is the person's to read, like the chat it came from.
    with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as handle:
        json.dump(reports, handle, ensure_ascii=False)
    os.replace(temporary, target)


def keep(home: Path, session: str, done: list[tuple[str, str]], summary: str, about: str,
         now: float | None = None) -> dict | None:
    """Keeps the report the phone was just told for `session`: `done` as `subagent_stop` gave the
    tasks, (status, summary) each; `summary` and `about` as `core.task_report` put them."""
    if not session or not _SESSION.fullmatch(session):
        return None
    now = time.time() if now is None else now
    statuses = [str(status or "") for status, _ in done]
    report = {
        "id": f"{int(now * 1000):x}",
        "session": session,
        "at": now,
        "summary": (summary or "")[:LONGEST],
        "about": about or "",
        "tasks": len(done),
        "failed": sum(1 for s in statuses if s and s not in ("completed", "success", "done")),
    }
    with _locked(home):
        reports = _load(home, now)
        reports.append(report)
        mine = [r for r in reports if r["session"] == session]
        for old in mine[:-PER_SESSION]:
            reports.remove(old)
        _save(home, reports[-AT_MOST:])
    return report


def of(home: Path, session: str, now: float | None = None) -> list[dict]:
    """The reports kept for `session`, oldest first."""
    now = time.time() if now is None else now
    if not path(home).exists():
        return []
    with _locked(home):
        return [r for r in _load(home, now) if r["session"] == session]


def slash(home: Path, words: list[str]) -> str:
    """`/redde-push tasks <session>`: "redde-push tasks {"tasks": [...]}", each with its `id`, `at`
    (seconds), `summary`, `about`, how many `tasks` and how many of them `failed`."""
    if len(words) != 1 or not _SESSION.fullmatch(words[0]):
        return "redde-push tasks: this command is for the Redde app."
    shown = [{key: r.get(key) for key in ("id", "at", "summary", "about", "tasks", "failed")} for r in of(home, words[0])]
    return "redde-push tasks " + json.dumps({"tasks": shown}, ensure_ascii=False)

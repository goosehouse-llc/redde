"""What the app says to the agent with a message (1.21.0, GitHub issue 72).

A reply language, the units, which calendars to look at, roughly where the person is on a place
question, "short, I'm driving": settings of the person's that the agent has to hear with a
message. The Hermes API takes them as the turn's instructions. The Dashboard's `prompt.submit`
takes none, so Redde wrote them after the message as a note, which it hides and every other app
shows, and which the chat list's first line showed too.

With this plugin the app hands the note over just before it sends the message
(`/redde-push turn <session> <mark> <note>`), and `pre_llm_call` gives it to the model as the
turn's context: Hermes puts that after the message for the model alone, and keeps the message
as it was typed. The app goes on writing the note itself on a Hermes whose plugin is older.

A note is kept for one message: by its session and by a mark of the message's own words, so
that a message queued behind a running turn, or behind a turn Hermes started itself, still gets
its own.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import time
from contextlib import contextmanager
from pathlib import Path

FILE = "turn-notes.json"
KEPT_FOR = 2 * 3600        # a message queued behind a long turn still finds its note
UNMARKED_FOR = 10 * 60     # ...and one whose words Hermes changed on the way, for this long
AT_MOST = 40               # notes waiting, every session together
LONGEST = 16_000           # characters: a live call's note carries the spoken exchange

_SESSION = re.compile(r"[A-Za-z0-9_.:\-]{1,120}")
_MARK = re.compile(r"[0-9a-f]{16}")


def mark(message) -> str:
    """A message by its own words: the same on the phone (`TurnNotes.mark`), whatever happens to
    its blank lines on the way."""
    if isinstance(message, dict):
        message = message.get("content")
    if isinstance(message, list):
        message = "\n".join(str(p.get("text") or "") for p in message if isinstance(p, dict))
    words = " ".join((message if isinstance(message, str) else "").split())
    return hashlib.sha256(words.encode()).hexdigest()[:16]


def path(home: Path) -> Path:
    return Path(home) / "redde-push" / FILE


@contextmanager
def _locked(home: Path):
    """Held while the file is read and written: the app's command and a turn's hook may be at it
    at once, from two processes."""
    folder = Path(home) / "redde-push"
    folder.mkdir(parents=True, exist_ok=True)
    handle = open(os.open(folder / "turn-notes.lock", os.O_WRONLY | os.O_CREAT, 0o600), "w")
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
    return [n for n in kept if isinstance(n, dict) and isinstance(n.get("text"), str)
            and isinstance(n.get("at"), (int, float)) and 0 <= now - n["at"] < KEPT_FOR] if isinstance(kept, list) else []


def _save(home: Path, notes: list[dict]) -> None:
    target = path(home)
    if not notes:
        try:
            target.unlink()
        except OSError:
            pass
        return
    temporary = target.with_suffix(".tmp")
    # Where the person is can be in one: theirs to read, like the message it goes with.
    with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as handle:
        json.dump(notes, handle, ensure_ascii=False)
    os.replace(temporary, target)


def keep(home: Path, session: str, marked: str, text: str, now: float | None = None) -> int:
    """Keeps a note for the message with that mark in that session; how many are waiting."""
    now = time.time() if now is None else now
    with _locked(home):
        notes = _load(home, now)
        # The same message sent again (a retry): its newest note is the one.
        notes = [n for n in notes if (n.get("session"), n.get("mark")) != (session, marked)]
        notes.append({"session": session, "mark": marked, "text": text, "at": now})
        notes = notes[-AT_MOST:]
        _save(home, notes)
        return len(notes)


def take(home: Path, session: str, message, now: float | None = None) -> str | None:
    """The note that goes with this message, once: its own (by session and words), or the one
    with its words in another session (Hermes gives a conversation a new id when it sums it up),
    or, the words changed on the way, the oldest recent one of its session."""
    now = time.time() if now is None else now
    if not path(home).exists():
        return None   # (nearly every turn: no lock, no read)
    marked = mark(message)
    with _locked(home):
        notes = _load(home, now)
        found = (next((n for n in notes if n.get("session") == session and n.get("mark") == marked), None)
                 or next((n for n in notes if n.get("mark") == marked), None)
                 or next((n for n in notes if n.get("session") == session and now - n["at"] < UNMARKED_FOR), None))
        if found is not None:
            notes.remove(found)
        _save(home, notes)   # (the outdated ones go with it)
    return found["text"] if found is not None else None


def slash(home: Path, words: list[str]) -> str:
    """`/redde-push turn <session> <mark> <note, base64url>`: "redde-push turn kept". The app
    takes anything else to mean the note has to ride on the message, as before."""
    if len(words) != 3 or not _SESSION.fullmatch(words[0]) or not _MARK.fullmatch(words[1]):
        return "redde-push turn: this command is for the Redde app."
    try:
        text = base64.urlsafe_b64decode(words[2] + "=" * (-len(words[2]) % 4)).decode().strip()
    except (ValueError, UnicodeDecodeError):
        return "redde-push turn refused: unreadable"
    if not text or len(text) > LONGEST:
        return "redde-push turn refused: empty or too long"
    keep(home, words[0], words[1], text)
    return "redde-push turn kept"


def turn_note(home: Path, session: str, message) -> str | None:
    """`pre_llm_call`: what the app said goes with this message, for the model alone."""
    return take(home, session or "", message)

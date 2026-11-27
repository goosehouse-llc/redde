"""Forget a Topic (1.58.0; asked 2026-11-27, "now build the muse gaps", after Meta's Muse's "forget
this topic"): what every agent keeps about one topic, found by its words and let go in one step,
over either connection.

- **Each agent's own memory** (Hermes's built-in, `memories/USER.md` and `memories/MEMORY.md` in its
  home, entries split by "\\n§\\n"), changed under the lock Hermes's memory tool takes (a `.lock`
  file beside each, `fcntl.flock`, Hermes 0.23), the file read again inside it and replaced whole:
  an entry the agent wrote meanwhile stays. An agent reads its memory as a conversation starts, so
  chats already open keep what they began with.
- **Things to Keep in Mind** (facts.py), the main home's.
- **Ideas about it** blocked (Don't Suggest This, ideas.py), when asked.
A memory provider (Honcho, Mem0, …) only its agent can reach: the app sends that agent a message.

`/redde-push memory find <topic, base64url>` lists what matches; `/redde-push memory forget
<base64url JSON>` lets go of exactly what the person kept ticked."""
from __future__ import annotations

import json
import os
import re
import tempfile
from contextlib import contextmanager
from pathlib import Path

try:
    import fcntl
except ImportError:   # (not on Windows)
    fcntl = None

from . import core, facts, ideas, wire

DELIMITER = "\n§\n"
FILES = {"user": "USER.md", "memory": "MEMORY.md"}
LONGEST_TOPIC = 80

#: In a person's own message: asked to forget a whole topic.
_FORGET = re.compile(r"\bforget\s+(?:about|everything(?:\s+(?:about|on|regarding))?|all\s+(?:about|of)|"
                     r"(?:what|anything|everything) you (?:know|have|remember) (?:about|on))\b", re.IGNORECASE)
_KEEP = re.compile(r"\b(?:don['’]?t|do not|never|not|won['’]?t|shouldn['’]?t)\s+forget\b", re.IGNORECASE)
NOTE = ("[Redde: if they're asking you to forget a whole topic, let go of all of it: every memory entry about it "
        "(memory remove, both targets), any of their Things to Keep in Mind about it (redde_fact remove), and your "
        "long-term memory's, if you have one. Then say in a line what you let go. Redde has Forget a Topic too, in "
        "Settings › Agent › What Your Agent Remembers.]")


def _words(topic: str) -> list[str]:
    return sorted(ideas._words(topic))


def matches(text: str, topic: str) -> bool:
    """The whole topic in the text, or every word of it that means something (each as the start of
    a word: "job" finds "jobs")."""
    said = " ".join(str(text or "").casefold().split())
    topic = " ".join(str(topic or "").casefold().split())
    if not topic or not said:
        return False
    if re.search(rf"(?<!\w){re.escape(topic)}(?!\w)", said):
        return True
    words = _words(topic)
    return bool(words) and all(re.search(rf"(?<!\w){re.escape(w)}", said) for w in words)


def _path(home: Path, target: str) -> Path:
    return Path(home) / "memories" / FILES[target]


def entries(home: Path, target: str) -> list[str]:
    try:
        raw = _path(home, target).read_text(encoding="utf-8")
    except OSError:
        return []
    return [e for e in (x.strip() for x in raw.split(DELIMITER)) if e]


@contextmanager
def _locked(path: Path):
    lock = path.with_suffix(path.suffix + ".lock")
    fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        if fcntl is not None:
            fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        if fcntl is not None:
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _drop(home: Path, target: str, gone: list[str]) -> int:
    """Removes these entries (as they read, whitespace aside); how many went."""
    path = _path(home, target)
    if not gone or not path.exists():
        return 0
    wanted = {" ".join(g.split()) for g in gone}
    with _locked(path):
        kept = entries(home, target)
        left = [e for e in kept if " ".join(e.split()) not in wanted]
        if len(left) == len(kept):
            return 0
        fd, tmp = tempfile.mkstemp(prefix=".mem_", dir=path.parent)
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(DELIMITER.join(left))
        os.chmod(tmp, path.stat().st_mode & 0o777)
        os.replace(tmp, path)
    return len(kept) - len(left)


def find(root: Path, topic: str, provider: str | None = None) -> dict:
    """What matches, agent by agent, and among Things to Keep in Mind; `provider` names the memory
    provider only the agent can reach, for the app to offer asking it."""
    from .routines import Stores
    stores = Stores(Path(root))
    agents = []
    for profile, home in stores.homes():
        found = {target: [e for e in entries(home, target) if matches(e, topic)] for target in FILES}
        if any(found.values()):
            agents.append({"profile": profile, "name": stores.name(home, profile), **found})
    return {"topic": topic, "agents": agents, "facts": [t for t in facts.texts(Path(root)) if matches(t, topic)],
            **({"provider": provider} if provider else {})}


def forget(root: Path, request: dict) -> dict:
    """Lets go of exactly what's listed: `agents` [{profile, user, memory}], `facts`, and with
    `block` the topic's ideas. How many went, and how many had already gone."""
    from .routines import Stores
    homes = dict(Stores(Path(root)).homes())
    removed = asked = 0
    for agent in request.get("agents") or []:
        home = homes.get(str(agent.get("profile") or ""))
        for target in FILES:
            gone = [str(e) for e in agent.get(target) or [] if str(e).strip()]
            asked += len(gone)
            if home is not None:
                removed += _drop(home, target, gone)
    for text in request.get("facts") or []:
        asked += 1
        removed += int("removed" in facts.remove(Path(root), str(text)))
    topic = " ".join(str(request.get("topic") or "").split())[:LONGEST_TOPIC]
    blocked = bool(request.get("block")) and bool(topic) and ideas.block(Path(root), topic)
    return {"removed": removed, "missed": asked - removed, "blocked": blocked}


def turn_note(message, platform: str = "") -> str | None:
    """For `pre_llm_call`: a person's own message asking to forget a topic."""
    if platform in ("cron", "subagent", "bot_room"):
        return None
    text = message if isinstance(message, str) else " ".join(
        str(p.get("text") or "") for p in message or [] if isinstance(p, dict)) if isinstance(message, list) else ""
    if not text or text.lstrip().startswith("[") or _KEEP.search(text):
        return None   # ("don't forget the dentist" is a reminder)
    return NOTE if _FORGET.search(text) else None


def slash(root: Path, words: list[str], provider: str | None = None) -> str:
    """`memory find <topic>` and `memory forget <JSON>`, each base64url: "redde-push memory found
    <JSON>" and "redde-push memory forgot <JSON>"."""
    if len(words) != 2:
        return "redde-push refused: memory find|forget <base64url>"
    try:
        raw = core.unb64u(words[1]).decode()
    except Exception:
        return "redde-push refused: not base64url"
    if words[0] == "find":
        topic = " ".join(raw.split())[:LONGEST_TOPIC]
        if not topic:
            return "redde-push refused: say the topic"
        return wire.reply("memory found", find(root, topic, provider))
    try:
        request = json.loads(raw)
    except ValueError:
        return "redde-push refused: not JSON"
    return wire.reply("memory forgot", forget(root, request if isinstance(request, dict) else {}))

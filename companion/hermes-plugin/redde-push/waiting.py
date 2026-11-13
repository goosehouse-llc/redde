"""What the bots wait on the person for, read from the server so every device shows the same.

A bot (a plugin answering for it, such as Coder's) lists what waits on the person in its profile's
home, in `redde-waiting.json`: server steps to approve, a finished change to put in, a card's
commands. Each entry: `id`, `title`, `detail`, `word` (what saying it in the bot's chat brings back,
"go" or "put it in") and `at` (seconds). The bot rewrites the file as things are asked and
answered, so a wait answered on one device is gone from all of them.

Redde asks with `/redde-push waiting` and shows them in its drawer (asked 2026-11-13: Coder's wait
showed on the phone, which had its notification, and not on the iPad, which hadn't been paired).
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

FILE = "redde-waiting.json"
#: Older than this, the person has moved on (Coder keeps a card's wait a week too).
KEPT_FOR = 7 * 86_400


def homes(root: Path) -> list[tuple[str, Path]]:
    """Every profile's home under one Hermes home: its own, and each in profiles/."""
    found = [("default", Path(root))]
    profiles = Path(root) / "profiles"
    if profiles.is_dir():
        found += [(home.name, home) for home in sorted(profiles.iterdir()) if home.is_dir()]
    return found


def read(home: Path, now: float | None = None) -> list[dict]:
    """A profile's waits, as it listed them; anything malformed or too old left out."""
    now = time.time() if now is None else now
    try:
        items = json.loads((Path(home) / FILE).read_text())
    except (OSError, ValueError):
        return []
    out = []
    for item in items if isinstance(items, list) else []:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not isinstance(item.get("title"), str):
            continue
        try:
            at = float(item.get("at") or 0)
        except (TypeError, ValueError):
            continue
        if now - at > KEPT_FOR:
            continue
        out.append({"id": item["id"], "title": item["title"][:200], "detail": str(item.get("detail") or "")[:1_000],
                    "word": str(item.get("word") or "go")[:40], "at": int(at)})
    return out


def listing(root: Path, now: float | None = None) -> list[dict]:
    """Every profile's waits, newest first, each with its profile."""
    found = [{**item, "profile": profile} for profile, home in homes(root) for item in read(home, now)]
    return sorted(found, key=lambda item: item["at"], reverse=True)


def write(home: Path, items: list[dict]) -> None:
    """A profile's waits, replacing what was there (for a plugin answering for a bot)."""
    path = Path(home) / FILE
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(items, ensure_ascii=False))
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def slash(root: Path, words: list[str]) -> str:
    """`/redde-push waiting`: every profile's waits, as JSON."""
    return "redde-push waiting " + json.dumps({"waiting": listing(root)}, ensure_ascii=False)

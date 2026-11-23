"""Usual buys (1.40.0, asked 2026-11-23 with bills, trips and meeting prep): what the person ticks
off a shopping list again and again is learned, and offered back when it's about due ("Milk
again? You get it about every 6 days"). Each tick on a shopping list (`lists.py`) is noted here;
three or more, a fairly steady gap between them, and nothing of it on a list now: a card, once
per gap. No model.
"""
from __future__ import annotations

import json
import os
import re
import statistics
import time
from datetime import datetime
from pathlib import Path

FILE = "habits.json"
KEEP, AT_LEAST, CARDS_AT_ONCE, EVERY = 12, 3, 3, 6 * 3600
#: Ticks closer than this are one shop; a gap past this isn't a habit.
SAME_SHOP, LONGEST = 12 * 3600, 60 * 86400


def key(text: str) -> str:
    text = re.sub(r"\([^)]*\)", " ", str(text or "").casefold())
    text = re.sub(r"^\s*(?:\d+\s*(?:x\s*)?|a |an |some |more )", "", text)
    return " ".join(re.findall(r"[\w']+", text))[:60]


def _path(home: Path) -> Path:
    return Path(home) / "redde-push" / FILE


def load(home: Path) -> dict:
    try:
        data = json.loads(_path(home).read_text())
    except (OSError, ValueError):
        data = {}
    return data if isinstance(data, dict) else {}


def save(home: Path, data: dict) -> None:
    path = _path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    if len(data.get("items") or {}) > 300:
        items = data["items"]
        data["items"] = dict(sorted(items.items(), key=lambda kv: max(kv[1].get("times") or [0]))[-300:])
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False))
    os.chmod(temp, 0o600)
    temp.replace(path)


def note(home: Path, text: str, list_id: str, list_title: str, at: float) -> None:
    """A tick on a shopping list."""
    k = key(text)
    if len(k) < 2:
        return
    data = load(home)
    items = data.setdefault("items", {})
    entry = items.setdefault(k, {"name": str(text)[:60], "times": []})
    entry.update(name=str(text)[:60], list=list_id, list_title=list_title)
    times = [t for t in entry["times"] if abs(t - at) >= SAME_SHOP] + [at]
    entry["times"] = sorted(times)[-KEEP:]
    save(home, data)


def gap(times: list[float]) -> float | None:
    """The usual gap between buys, when there's a steady one."""
    if len(times) < AT_LEAST:
        return None
    gaps = [b - a for a, b in zip(times, times[1:]) if b - a >= SAME_SHOP]
    if len(gaps) < AT_LEAST - 1:
        return None
    usual = statistics.median(gaps)
    if not SAME_SHOP <= usual <= LONGEST:
        return None
    # steady enough: most gaps within half of the usual one either way
    near = [g for g in gaps if abs(g - usual) <= usual * 0.5]
    return usual if len(near) >= max(2, len(gaps) * 0.6) else None


def due(home: Path, now: float) -> list[dict]:
    """Cards for usual buys that are about due and not on a list now."""
    from . import lists
    data = load(home)
    open_now = {key(i.get("text")) for kept in lists.load(home) for i in kept.get("items") or [] if not i.get("done")}
    cards = []
    for k, entry in data.get("items", {}).items():
        times = entry.get("times") or []
        usual = gap(times)
        if not usual or k in open_now or now - times[-1] < usual * 0.95:
            continue
        if float(entry.get("offered") or 0) > times[-1]:
            continue
        days = round(usual / 86400)
        last = datetime.fromtimestamp(times[-1]).strftime("%A" if now - times[-1] < 6 * 86400 else "%B %-d")
        name, title = entry.get("name") or k, entry.get("list_title") or "shopping"
        cards.append((times[-1], k, {"title": f"{name} again?"[:60],
                                     "why": f"You get it about every {days} day{'s' if days != 1 else ''}; last {last}"[:140],
                                     "request": f"Add {name} to my {title} list."}))
    cards.sort(key=lambda c: c[0])
    return [dict(c[2], _key=c[1]) for c in cards[:CARDS_AT_ONCE]]


def look(home: Path, offer, now: float | None = None) -> int:
    from . import followthrough
    now = now or time.time()
    if not followthrough.DAY_FROM <= datetime.fromtimestamp(now).hour < followthrough.DAY_TO:
        return 0
    if not followthrough.on(home, "habits"):
        return 0
    data = load(home)
    if now - float(data.get("at") or 0) < EVERY:
        return 0
    data["at"] = now
    cards = due(home, now)
    if cards and offer([{k: v for k, v in c.items() if k != "_key"} for c in cards]):
        for c in cards:
            data["items"][c["_key"]]["offered"] = now
    save(home, data)
    return len(cards)

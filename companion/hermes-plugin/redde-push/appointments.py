"""Appointments that come round again (1.54.0, asked 2026-11-26 "do 4": "Redde learns your usual
gap from past calendar events, like a haircut every 5 weeks or a dentist visit every 6 months.
When one is due and nothing is booked, it offers to book it or set a reminder. After a doctor's
visit, it asks whether there's a follow-up to schedule").

The calendar is the phone's, so Redde reads it there: each device with full calendar access
sends what it found of a few kinds of appointment (`follow appts <device> <base64url JSON>`): for
each, the starts of its visits, when the last ended, where, and the next one booked. Nothing else
of the calendar leaves the phone. Here the devices' finds are put together, the usual gap is
worked out (three visits or more, a fairly steady gap) and, in the day's hours with
Follow-Through's Appointments switch on, two kinds of card go through Follow-Through's offer:

- due: past nine tenths of the usual gap with nothing of that kind booked ahead, once per visit;
- after: a visit to a doctor, dentist, vet and the like, the same day or the morning after, once.

No model: the agent runs only when a card is taken.
"""
from __future__ import annotations

import base64
import contextlib
import json
import os
import re
import statistics
import time
from datetime import datetime
from pathlib import Path

FILE = "appointments.json"

#: kind → (what it's called, the card when it's due, what the visit is, the card after one or None)
KINDS: dict[str, tuple[str, str, str, str | None]] = {
    "haircut": ("Haircut", "Time for a haircut?", "haircut", None),
    "dentist": ("Dentist", "Dentist check-up due?", "dentist appointment", "How did the dentist go?"),
    "doctor": ("Doctor", "Check-up due?", "doctor's appointment", "How did the doctor's visit go?"),
    "eyes": ("Eye exam", "Eye exam due?", "eye exam", "How did the eye exam go?"),
    "skin": ("Dermatologist", "Skin check due?", "dermatologist appointment", "How did the dermatologist go?"),
    "physio": ("Physio", "Physio due?", "physio appointment", "How did physio go?"),
    "vet": ("Vet", "Vet visit due?", "vet appointment", "How did the vet visit go?"),
    "grooming": ("Grooming", "Grooming due?", "grooming appointment", None),
    "nails": ("Nails", "Nails due?", "nail appointment", None),
    "massage": ("Massage", "Time for a massage?", "massage", None),
    "car": ("Car service", "Car service due?", "car service", None),
}

DAY = 86400.0
#: A usual gap is from three visits; between these, in days.
AT_LEAST, SHORTEST, LONGEST = 3, 14, 400
#: Due at this part of the usual gap; one device's find kept this long.
DUE_AT, DEVICE_FOR = 0.9, 30 * DAY
#: The card after a visit: from this long after it ended, until this long after.
AFTER_FROM, AFTER_TO = 2 * 3600, 30 * 3600
#: Looked at this often; at most this many cards at once.
EVERY, CARDS_AT_ONCE = 3 * 3600, 2
VISITS = 12


def _path(home: Path) -> Path:
    return Path(home) / "redde-push" / FILE


@contextlib.contextmanager
def _locked(home: Path):
    folder = Path(home) / "redde-push"
    folder.mkdir(parents=True, exist_ok=True)
    handle = open(os.open(folder / "appointments.lock", os.O_WRONLY | os.O_CREAT, 0o600), "w")
    try:
        try:
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX)
        except (ImportError, OSError):
            pass
        yield
    finally:
        handle.close()


def load(home: Path) -> dict:
    try:
        data = json.loads(_path(home).read_text())
    except (OSError, ValueError):
        data = {}
    data = data if isinstance(data, dict) else {}
    for key in ("devices", "offered", "asked"):
        if not isinstance(data.get(key), dict):
            data[key] = {}
    return data


def save(home: Path, data: dict) -> None:
    for key in ("offered", "asked"):   # the newest few hundred
        if len(data[key]) > 300:
            data[key] = dict(sorted(data[key].items(), key=lambda kv: kv[1])[-300:])
    path = _path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False))
    os.chmod(temp, 0o600)
    temp.replace(path)


def _moment(text) -> float | None:
    try:
        moment = datetime.fromisoformat(str(text).strip().replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return moment.timestamp() if moment.tzinfo else None


def _clean(found) -> list[dict]:
    """A device's find, as kept: known kinds only, times as seconds."""
    kinds = []
    for entry in found if isinstance(found, list) else []:
        if not isinstance(entry, dict) or entry.get("kind") not in KINDS:
            continue
        visits = sorted({v for v in (_moment(t) for t in entry.get("visits") or []) if v is not None})[-VISITS:]
        if not visits:
            continue
        where = re.sub(r"\s+", " ", str(entry.get("where") or "")).strip()[:80]
        kinds.append({"kind": entry["kind"], "visits": visits, "ended": _moment(entry.get("ended")),
                      "next": _moment(entry.get("next")), "where": where or None})
    return kinds


def take(home: Path, device: str, found, now: float | None = None) -> int:
    """A device's find, kept in place of the one before: how many kinds."""
    now = time.time() if now is None else now
    device = re.sub(r"[^A-Za-z0-9-]", "", str(device or ""))[:64] or "phone"
    kinds = _clean(found)
    with _locked(home):
        data = load(home)
        data["devices"][device] = {"at": now, "kinds": kinds}
        data["devices"] = {d: v for d, v in data["devices"].items()
                           if isinstance(v, dict) and now - float(v.get("at") or 0) < DEVICE_FOR}
        save(home, data)
    return len(kinds)


def merged(data: dict, now: float) -> dict[str, dict]:
    """Every device's find put together: each kind's visits (one a day), the last one's end and
    place, and the soonest booked ahead."""
    kinds: dict[str, dict] = {}
    for found in data["devices"].values():
        if not isinstance(found, dict) or now - float(found.get("at") or 0) >= DEVICE_FOR:
            continue
        for entry in found.get("kinds") or []:
            kind = kinds.setdefault(entry["kind"], {"visits": [], "ended": None, "next": None, "where": None})
            kind["visits"].extend(v for v in entry.get("visits") or [] if v <= now)
            last = max(entry.get("visits") or [0])
            if last <= now and last >= max(kind["visits"] or [0]):
                kind["ended"], kind["where"] = entry.get("ended") or kind["ended"], entry.get("where") or kind["where"]
            ahead = [t for t in [entry.get("next")] + list(entry.get("visits") or []) if t and t > now]
            if ahead and (kind["next"] is None or min(ahead) < kind["next"]):
                kind["next"] = min(ahead)
    for kind in kinds.values():
        days = sorted({datetime.fromtimestamp(v).date(): v for v in sorted(kind["visits"])}.values())
        kind["visits"] = days[-VISITS:]
    return kinds


def gap(visits: list[float]) -> float | None:
    """The usual gap between visits, in seconds, when there's a steady one."""
    if len(visits) < AT_LEAST:
        return None
    gaps = [b - a for a, b in zip(visits, visits[1:])]
    usual = statistics.median(gaps)
    if not SHORTEST * DAY <= usual <= LONGEST * DAY:
        return None
    near = [g for g in gaps if abs(g - usual) <= usual * 0.4]
    return usual if len(near) >= max(2, len(gaps) * 0.6) else None


def every(seconds: float) -> str:
    """"5 weeks", "6 months", "3 weeks"."""
    days = seconds / DAY
    if days < 56:
        weeks = round(days / 7)
        return f"{weeks} week{'s' if weeks != 1 else ''}"
    months = round(days / 30.4)
    return "year" if months == 12 else f"{months} month{'s' if months != 1 else ''}"


def _day(ts: float, now: float) -> str:
    when = datetime.fromtimestamp(ts)
    return when.strftime("%B %-d" if when.year == datetime.fromtimestamp(now).year else "%B %-d, %Y")


def due(home: Path, now: float, data: dict | None = None) -> list[dict]:
    """The cards whose time has come, oldest reason first; each with `_key` (what it's once for)."""
    data = load(home) if data is None else data
    cards = []
    for name, kind in merged(data, now).items():
        visits = kind["visits"]
        if not visits:
            continue
        called, due_title, visit, after_title = KINDS[name]
        last, where = visits[-1], f" at {kind['where']}" if kind["where"] else ""
        # After a visit: the same day or the morning after, once.
        ended = kind["ended"] if kind["ended"] and kind["ended"] >= last else last + 3600
        key = f"{name}:{int(last)}"
        if after_title and AFTER_FROM <= now - ended <= AFTER_TO and key not in data["asked"]:
            today = datetime.fromtimestamp(ended).date() == datetime.fromtimestamp(now).date()
            said = "today" if today else "yesterday"
            cards.append((ended, "asked", key, {
                "title": after_title,
                "why": f"You were there {said} at {datetime.fromtimestamp(last).strftime('%-I:%M %p')}{where}"[:140],
                "request": (f"I had my {visit} {said}{where}. Ask me what came out of it: a next visit to book, a "
                            "prescription to pick up, a result or a bill to watch for, anything to remember. Then "
                            "set up what I tell you, on my calendar or as reminders.")}))
        # Due: nothing booked ahead, past most of the usual gap, once per visit.
        usual = gap(visits)
        if not usual or kind["next"] or now - last < usual * DUE_AT or key in data["offered"]:
            continue
        often = every(usual)
        cards.append((last, "offered", key, {
            "title": due_title,
            "why": f"You go about every {often}; the last was {_day(last, now)}{where}"[:140],
            "request": (f"My {visit} is about due: I go about every {often}, and the last was {_day(last, now)}{where}. "
                        "Look at my calendar for the next two weeks and offer me two or three times that fit. When I "
                        "pick one, put it on my calendar, and if it has to be booked with them, remind me that "
                        "morning to call.")}))
    cards.sort(key=lambda c: c[0])
    return [dict(c[3], _key=c[2], _kept=c[1]) for c in cards[:CARDS_AT_ONCE]]


def look(home: Path, offer, now: float | None = None) -> int:
    """Offers the cards whose time has come, in the day's hours with the Appointments switch on."""
    from . import followthrough
    now = time.time() if now is None else now
    if not followthrough.DAY_FROM <= datetime.fromtimestamp(now).hour < followthrough.DAY_TO:
        return 0
    if not followthrough.on(home, "appointments"):
        return 0
    with _locked(home):
        data = load(home)
        if not data["devices"] or now - float(data.get("at") or 0) < EVERY:
            return 0
        data["at"] = now
        cards = due(home, now, data)
        if cards and offer([{k: v for k, v in c.items() if not k.startswith("_")} for c in cards]):
            for c in cards:
                data[c["_kept"]][c["_key"]] = now
        save(home, data)
    return len(cards)


def slash(home: Path, words: list[str]) -> dict | None:
    """`follow appts <device> <base64url JSON>`: a device's find; what was kept, or None. With the
    Appointments switch off nothing is kept, and what was is forgotten."""
    if len(words) != 3 or words[0] != "appts":
        return None
    from . import followthrough
    if not followthrough.on(home, "appointments"):
        with _locked(home):
            data = load(home)
            if data["devices"]:
                data["devices"] = {}
                save(home, data)
        return {"kinds": 0, "off": True}
    try:
        raw = words[2] + "=" * (-len(words[2]) % 4)
        found = json.loads(base64.urlsafe_b64decode(raw.encode()).decode())
    except (ValueError, UnicodeDecodeError):
        return {"error": "not JSON"}
    return {"kinds": take(home, words[1], found)}

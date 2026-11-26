"""Outings (1.48.0, asked 2026-11-26 of "We're going mini golfing today", which nothing caught, and
"add whatever you feel would be good here"). A day out today or tonight, said in passing, in
English: the reply gets what helps them go (the place's hours on a holiday, the weather while
they're out, somewhere near if they haven't said where: `note`), and afterwards one card from the
plugin, with no model: the photos from it, the best few ready to share (`look`). Not Plan For It
(a trip, a move, an occasion: cards.py), and no reminder, event or list. Only with the phone's
Photos tool on for the main agent; Follow-Through's Outings switch turns the card off.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import time
from datetime import datetime, timedelta
from pathlib import Path

FILE = "outings.json"
KEEP = 30
#: A card that couldn't go (the hour's ideas used up, no phone) is tried again until this long after its time.
STALE = 20 * 3600

# Who's going: they, or they and others. "The kids are going to the zoo" isn't their outing.
_WHO = (r"(?:\b(?:i['’]?m|i am|we['’]?re|we are|i['’]?ll be|we['’]?ll be|[\w'’]+ and i are)\s+"
        r"(?:all\s+|also\s+|finally\s+|just\s+|gonna\s+be\s+)?|(?:^|[,.!;:—–])\s*)")
# Words after "going" that aren't the activity's: "going to bring", "going back home".
_NOT_A_MODIFIER = (r"(?!(?:to|out|back|home|through|on|over|up|down|for|with|and|the|a|an|my|our|in|into|away|by|off|there|"
                   r"here|be|get|so|too|really|very|well|not|just|still|all|right|now|today|tonight)\b)")
# -ing words that aren't something to go and do.
_NOT_AN_ACTIVITY = (r"(?!(?:nothing|something|anything|everything|missing|morning|evening|during|thing|king|ring|wing|bring|sing|"
                    r"string|spring|ceiling|according|being|having|doing|going|getting|feeling|working|sleeping|napping|resting|"
                    r"studying|cleaning|cooking|crying|dying|lying|waiting|trying|thinking|looking|leaving|coming|starting|"
                    r"stopping|living|losing|failing|freaking|camping|hiking|skiing|fishing|backpacking|surfing)\b)")
_ACTIVITY = (r"going\s+(?P<act>(?:" + _NOT_A_MODIFIER + r"[a-z'’-]+\s+){0,2}?" + _NOT_AN_ACTIVITY + r"[a-z-]{2,}ing)\b")
# Somewhere to spend the day: not the day's errand (the store, work, the doctor).
_PLACES = (r"(?:beach|park|zoo|aquarium|fair|carnival|festival|museum|game|ballgame|ball game|match|parade|pool|lake|springs|"
           r"river|pumpkin patch|farm|orchard|movies|cinema|theater|theatre|concert|show|circus|rodeo|races|arcade|"
           r"trampoline park|water park|theme park|amusement park|bowling alley|rink|playground|gardens?|science center|"
           r"planetarium|lights|light show|tree lighting|christmas market|farmers market|flea market|boardwalk|pier|mountains|"
           r"woods|trail|state park|national park|stadium|arena|ballpark|golf course|driving range|escape room|winery|brewery|"
           r"vineyard|corn maze|hayride|haunted house|batting cages|mini golf|putt-putt|go-karts?|drive-in|botanical garden)")
_PLACE = r"(?P<place>(?:the|a|an|our|my)\s+(?:[\w'’-]+\s+){0,2}?" + _PLACES + r")\b"
_TO_A_PLACE = r"(?:going|heading|off)\s+(?:out\s+|over\s+|down\s+|up\s+)?to\s+" + _PLACE
_TAKING = (r"taking\s+(?:the|my|our)\s+(?:kids|family|boys|girls|grandkids|parents|dog|nephews?|nieces?|son|daughter|wife|husband|"
           r"partner|mom|dad)\s+(?:to\s+" + _PLACE.replace("?P<place>", "?P<place2>") + r"|" +
           _ACTIVITY.replace("going\\s+", "").replace("?P<act>", "?P<act2>") + r")")
_OUTING = re.compile(_WHO + r"(?:" + _ACTIVITY + r"|" + _TO_A_PLACE + r"|" + _TAKING + r")", re.IGNORECASE)

_TODAY = re.compile(
    r"\b(?:today|tonight|tonite|this (?:morning|afternoon|evening)|later(?: today| on)?|(?:right )?now|soon|"
    r"in (?:a bit|a few|a little(?: while)?|an hour|a couple(?: of)? hours|\d+ (?:min(?:ute)?s?|hours?))|"
    r"after (?:lunch|breakfast|brunch|dinner|work|school|church|nap(?:time)?))\b", re.IGNORECASE)
_WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
_ANOTHER_DAY = re.compile(
    r"\b(?:tomorrow|tmrw|(?:this |next )?weekend|next \w+|(?<!black )(?<!cyber )(?:mon|tues|wednes|thurs|fri|satur|sun)days?|"
    r"in (?:a|two|three|\d+) (?:days?|weeks?|months?)|the \d{1,2}(?:st|nd|rd|th)|\d{1,2}/\d{1,2}|"
    r"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? \d{1,2}\b)", re.IGNORECASE)
_EVENING = re.compile(r"\b(?:tonight|tonite|this evening|after dinner)\b", re.IGNORECASE)
_MORNING = re.compile(r"\b(?:this morning|after breakfast)\b", re.IGNORECASE)


def find(text: str, now: datetime | None = None) -> dict | None:
    """The outing a message tells of, today's: {what, kind ("activity" or "place"), when ("morning",
    "day" or "evening")}; None for anything else (another day, no outing)."""
    text = re.sub(r"\[[^\]]*\]", " ", str(text or ""))   # (notes the app or Hermes put on the message)
    m = _OUTING.search(text)
    if not m:
        return None
    today = _WEEKDAYS[(now or datetime.now()).weekday()]
    # Another day's ("tomorrow", "Saturday"), but for today's own name ("Thursday", said on one).
    if any(other.group(0).lower() != today for other in _ANOTHER_DAY.finditer(text)):
        return None
    place = m.group("place") or m.group("place2")
    act = m.group("act") or m.group("act2")
    if place:
        what, kind = re.sub(r"^(?:a|an|our|my)\s+", "the ", place.strip(), flags=re.IGNORECASE), "place"
    else:
        what, kind = act.strip(), "activity"
    when = "evening" if _EVENING.search(text) else "morning" if _MORNING.search(text) else "day"
    return {"what": what if kind == "place" else what.lower(), "kind": kind, "when": when}


def offer_at(said: float, when: str) -> float:
    """When the card comes, server time: an afternoon's at 5 or four hours after, whichever is later;
    a morning's at 1; an evening's (or a day out said late) the next morning at 10."""
    from .followthrough import DAY_TO
    start = datetime.fromtimestamp(said)
    if when == "morning" and start.hour < 12:
        at = start.replace(hour=13, minute=0, second=0, microsecond=0)
    else:
        at = start + timedelta(hours=4)
        at = (at + timedelta(hours=1)).replace(minute=0, second=0, microsecond=0) if at.minute or at.second else at
        at = max(at, start.replace(hour=17, minute=0, second=0, microsecond=0))
    if when == "evening" or at.hour >= DAY_TO or at.date() != start.date():
        at = (start + timedelta(days=1)).replace(hour=10, minute=0, second=0, microsecond=0)
    return at.timestamp()


# ---- the file ------------------------------------------------------------------------------------

def _path(root: Path) -> Path:
    return Path(root) / "redde-push" / FILE


def load(root: Path) -> list[dict]:
    try:
        data = json.loads(_path(root).read_text())
    except (OSError, ValueError):
        return []
    return [o for o in data if isinstance(o, dict)] if isinstance(data, list) else []


def save(root: Path, outings: list[dict]) -> None:
    path = _path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(outings[-KEEP:], ensure_ascii=False))
    os.chmod(temp, 0o600)
    temp.replace(path)


def remember(root: Path, found: dict, said: float | None = None) -> dict:
    """Kept, to come back as a card afterwards: once a day for the same outing, however often it's said."""
    said = time.time() if said is None else said
    day = datetime.fromtimestamp(said).date().isoformat()
    oid = hashlib.sha1(f"{found['what'].lower()}\x1f{day}".encode()).hexdigest()[:12]
    outings = load(root)
    for kept in outings:
        if kept.get("id") == oid:
            return kept
    kept = {**found, "id": oid, "said": said, "at": offer_at(said, found["when"])}
    save(root, outings + [kept])
    return kept


# ---- the turn's note -----------------------------------------------------------------------------

def photos_on(root: Path) -> bool:
    try:
        from .device import Phone
        return "photos" in Phone(root).areas()
    except Exception:
        return False


def note(tool: str, photos: bool, time_line: str) -> str:
    """For the reply: what helps them go, briefly; nothing to answer."""
    return (f"[Redde: they told you about a day out, in passing, and asked for nothing. Answer in two or three warm lines with "
            "what helps them go: if today is a holiday where they are, say the place may keep holiday hours (look them up if you "
            f"can); if it's outdoors, the weather while they're out, from a 'weather' card with {tool} (no 'place': where they "
            "are); if they haven't said where, one to three places near them, as a 'places' card. Don't ask them anything, and "
            "no plan card, reminder, event or list."
            + (" Afterwards Redde offers them the photos from it, so don't." if photos else "")
            + f" {time_line}]")


# ---- the card afterwards -------------------------------------------------------------------------

def _clock(ts: float) -> str:
    local = datetime.fromtimestamp(ts)
    return local.strftime("%I %p").lstrip("0") if not local.minute else local.strftime("%I:%M %p").lstrip("0")


def card(outing: dict, now: float) -> dict:
    """{title, why, request}: the photos from it, the best few ready to share."""
    said, what = float(outing["said"]), outing["what"]
    same_day = datetime.fromtimestamp(said).date() == datetime.fromtimestamp(now).date()
    evening = outing.get("when") == "evening" or datetime.fromtimestamp(said).hour >= 17
    if same_day:
        day = "This morning" if outing.get("when") == "morning" else "Today"
    else:
        day = "Last night" if evening else "Yesterday"
    start, end = said - 1800, min(now, said + 12 * 3600)
    took = f"at {what}" if outing.get("kind") == "place" else what
    said_day = "today" if same_day else "last night" if evening else "yesterday"
    return {"title": f"Photos from {what}"[:60],
            "why": f"{day} · the best few, ready to share"[:140],
            "request": (f"Find the photos I took {took} {said_day} (between {_clock(start)} and {_clock(end)}) on my iPhone, "
                        "and show me the best few, ready to share.")}


def look(root: Path, offer, now: float | None = None) -> int:
    """The outings whose time has come, one card each; with Follow-Through's Outings switch on and
    the phone's Photos tool on, in the day's hours."""
    from . import followthrough
    now = time.time() if now is None else now
    if not followthrough.DAY_FROM <= datetime.fromtimestamp(now).hour < followthrough.DAY_TO:
        return 0
    outings = load(root)
    due = [o for o in outings if not o.get("offered") and o.get("at", now + 1) <= now < o.get("at", 0) + STALE]
    if not due or not followthrough.on(root, "outings") or not photos_on(root):
        return 0
    cards = [card(o, now) for o in due[:2]]
    if not offer(cards):
        return 0
    for o in due[:2]:
        o["offered"] = now
    save(root, outings)
    return len(cards)

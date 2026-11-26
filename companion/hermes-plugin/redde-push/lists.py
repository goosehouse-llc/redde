"""Lists: the person's own to-do lists ("make me a grocery list", "add milk", "check off the eggs"),
each a tile on Redde's Today row, next to the Inbox, where they stay until the list is deleted
(asked 2026-11-09). Several lists, by name; kept in the main home's `redde-push/lists.json`, so
every bot reads and changes the same ones, and the phone can check things off with the app's
`/redde-push lists …`, the same changes the agent makes with `redde_list`.

Never the agent's own `todo` tool: that is its plan for one turn, shown under its reply.

From 1.37.0 (asked 2026-11-23, of a list of Christmas films: "Is there a way to make these lists a
bit more fun? This is really boring") each list has a look: a `kind` (a watch list of films and
series, a to-do list, shopping, reading, packing, gifts or any other), an `emoji` and a `color`,
which the agent gives when it makes the list or which are guessed from its title, and which the
agent or the person changes with 'style'. A watch list's films and series get their posters,
looked up as a show card's are (`posters.lookup`, no key), off the agent's turn: a thread fills
them in and the phone shows them on its next look (`fill_posters`).

Plans (1.38.0, asked 2026-11-23: "Donnie Brasco, Thanksgiving night, with Robin" sat in a note
file where nothing would ever look at it; "this is proactive in the sense of the example I gave
before. We need more like this"): an item can be planned for a time, with someone. 'plan' keeps
when and with whom on the item and sets two one-off jobs on the agent that planned it, as a
follow-up is set (`followups.py`): on the day, a card reminding them; after it (the next morning
for an evening plan), a follow-through run that finds out with the agent's own tools whether it
happened (for a film or a series, whether their media server shows it as played), ticks it off if
it did, and offers it back as a card to find another time if it didn't.

Nights on the calendar (1.50.0, asked 2026-11-26: "When a movie on list is given a time and date,
have it added to the calendar"): Redde puts a watch list's films and series with a night on the
phone's calendar itself and keeps the event in step with the list. The app says so with
`lists nights on` (again each day while it does; `off` when it's switched off), and while it does,
a night planned on a watch list tells the agent to leave the calendar to Redde, so there's one
event, not two (`calendar_by_app`).

One device at a time (1.51.0, the same day: an iPhone and an iPad opened together each put every
film on the calendar before either saw the other's). `lists nights on <device>` asks to be the one;
the plugin, under the lists' lock, gives it to the first to ask and keeps it theirs while they ask
again within three days (`NIGHTS_LEASE`), then to whichever asks next. The answer says whether it's
the asker's (`mine`), and only that device changes the calendar.
"""

from __future__ import annotations

import base64
import json
import os
import re
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, wait
from datetime import datetime, timedelta, timezone
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import urlsplit

from . import posters, wire

TOOLSET = "redde_ideas"
TOOL = "redde_list"
FILE = "lists.json"
#: When a phone last said it puts a watch list's nights on its calendar (1.50.0).
NIGHTS = "nights.json"
#: How long a phone's word lasts: it says it again each day it opens Redde.
NIGHTS_FOR = 14 * 86400
#: How long the device that keeps the calendar stays the one without asking again (1.51.0).
NIGHTS_LEASE = 3 * 86400
#: At most this many lists, items on one, and characters in a title or an item.
MOST, ITEMS, TITLE, TEXT = 30, 300, 60, 200
ACTIONS = ("show", "make", "add", "check", "uncheck", "remove", "clear_done", "rename", "edit", "style", "plan", "unplan",
           "help", "delete")
#: A to-do's help line at most this long: what the agent could do for it (1.46.0).
HELP = 80
PLAN_TAG = "[redde-plan:"
#: A plan this far ahead at most; the follow-through this long after a daytime plan, or the next
#: morning at this hour for one from 5 pm.
PLAN_AHEAD, PLAN_AFTER, PLAN_MORNING = timedelta(days=60), timedelta(hours=3), 10
KINDS = ("watch", "todo", "shopping", "reading", "packing", "gifts", "other")
COLORS = ("red", "orange", "yellow", "green", "mint", "teal", "blue", "indigo", "purple", "pink", "brown", "gray")
#: A list's look from its title, the first that fits: (words, kind or None, emoji, color). A
#: season's look wins over its kind's ("Christmas Movies": a watch list, 🎄, red).
LOOKS = (
    (r"christmas|xmas|holiday|advent|festive", None, "🎄", "red"),
    (r"hallowe.?en|spooky|horror", None, "🎃", "orange"),
    (r"thanksgiving", None, "🦃", "orange"),
    (r"birthday|party", None, "🎉", "pink"),
    (r"summer|beach", None, "🏖️", "teal"),
    (r"movie|film|watch|shows?\b|series|tv\b|cinema|binge", "watch", "🍿", "indigo"),
    (r"grocer|shopping|supermarket|costco|market|buy", "shopping", "🛒", "green"),
    (r"pack|trip|travel|vacation|holiday", "packing", "🧳", "teal"),
    (r"reading|books?\b|novels?\b", "reading", "📚", "brown"),
    (r"gift|present|wish", "gifts", "🎁", "red"),
    (r"to.?do|tasks?|chores?|errands?|jobs|today|week", "todo", "✅", "blue"),
)
#: Each kind's own, for what the title doesn't say.
KIND_LOOKS = {"watch": ("🍿", "indigo"), "todo": ("✅", "blue"), "shopping": ("🛒", "green"), "reading": ("📚", "brown"),
              "packing": ("🧳", "teal"), "gifts": ("🎁", "red"), "other": ("📝", "blue")}
_WORDS = [(re.compile(rf"\b(?:{w})", re.IGNORECASE), k, e, c) for w, k, e, c in LOOKS]
#: A watch list's posters: at most this many looked up a time, for this long in all.
POSTERS_AT_ONCE, POSTER_WAIT = 24, 20.0
#: A title none was found for is looked for again this long after, this many times in all (1.42.1:
#: a new film's page may have no poster yet, or a site be out of reach for a moment). One missed by
#: an older plugin's search, which matched the page's name letter for letter, is looked for at once.
POSTER_RETRY, POSTER_TRIES = 12 * 3600, 4
_YEAR = re.compile(r"\s*\((1[89]\d\d|20\d\d)\)\s*$")

#: What sounds like one of their lists, in English: cheap to look for, said in a turn's note only.
_LISTISH = re.compile(
    r"\b(?:to-?\s?do(?:s| list)?|todo list|(?:grocery|groceries|shopping|packing|chore|chores|errand|errands|"
    r"wish|reading|watch|bucket|task|checklist)\s*list|check ?list|my lists?|the list|(?:check|cross|tick|mark) (?:\w+ ){0,4}off|"
    r"(?:add|put|write) .{1,80}? (?:to|on|onto) (?:my|the|our) .{0,30}?list)\b",
    re.IGNORECASE)

def guess(title: str) -> tuple[str, str, str]:
    """A list's kind, emoji and color from its title."""
    kind = emoji = color = None
    for words, k, e, c in _WORDS:
        if words.search(title or ""):
            kind = kind or k
            if emoji is None:
                emoji, color = e, c
    kind = kind or "other"
    own = KIND_LOOKS[kind]
    return kind, emoji or own[0], color or own[1]


def _emoji(value) -> str | None:
    """One emoji (with its joiners and selectors), else None."""
    text = str(value or "").strip()
    if not text or len(text) > 12 or any(ch.isalnum() and ord(ch) < 0x2000 for ch in text):
        return None
    return text


def look(kept: dict) -> dict:
    """The list's kind, emoji and color: as kept, else guessed from its title (and a kind given
    that isn't the title's brings its own emoji and color)."""
    guessed, emoji, color = guess(str(kept.get("title") or ""))
    kind = kept.get("kind") if kept.get("kind") in KINDS else guessed
    if kind != guessed:
        emoji, color = KIND_LOOKS[kind]
    return {"kind": kind, "emoji": _emoji(kept.get("emoji")) or emoji,
            "color": kept.get("color") if kept.get("color") in COLORS else color}


def _styled(kept: dict, args: dict) -> list[str]:
    """The look the agent or the phone gave, kept: what was wrong with it."""
    wrong = []
    if args.get("kind") is not None:
        kind = str(args.get("kind")).lower()
        kept["kind"] = kind if kind in KINDS else kept.get("kind")
        if kind not in KINDS:
            wrong.append(f"kind is one of {', '.join(KINDS)}")
    if args.get("emoji") is not None:
        emoji = _emoji(args.get("emoji"))
        kept["emoji"] = emoji or kept.get("emoji")
        if not emoji:
            wrong.append("emoji is one emoji")
    if args.get("color") is not None:
        color = str(args.get("color")).lower()
        kept["color"] = color if color in COLORS else kept.get("color")
        if color not in COLORS:
            wrong.append(f"color is one of {', '.join(COLORS)}")
    return wrong


NOTE = (f"[Redde: their lists (to-do, groceries, packing…) live in Redde and show on their phone's Today row: keep them "
        f"with {TOOL} (find it with tool_search if it isn't among your tools). 'show' first when you don't know which "
        "list they mean. Anything with a day or a time goes on with `when` (ISO 8601 with offset), so it shows under "
        "that day. A to-do you could do part of yourself (find a number or hours, look up what's needed, compare, "
        "book, draft) gets a help line with 'help': a few words of what you'd do, which they tap to have you do it. "
        "Not your own todo tool, which is only your plan for this turn, and not reminders unless they ask "
        "for a reminder.]")

DESCRIPTION = (
    "The user's own lists in Redde (to-dos, groceries, packing…), several by name, each a tile on their phone's "
    "Today row. Actions: 'show' (every list, or one: `list`), 'make' (title, items), "
    "'add' (list, items: texts; give `when` for anything with a day or time, so it shows under that day), "
    "'check' / 'uncheck' / 'remove' (list, items: numbers as 'show' gives them, or "
    "their words), 'clear_done' (list: removes checked items), 'rename' (list, title), 'edit' (list, items: one, "
    "title: its new words), 'help' (list, items, `help`: a few words of what you could do for it; '' clears), "
    "'delete' (list). `list`: id or title (optional with one list). 'make' and 'style' (list) take a look: "
    "`kind` (watch: films and series, which Redde shows as posters, one title per item; todo, shopping, reading, "
    "packing, gifts, other), an `emoji` and a `color`; left out, they're guessed from the title. 'plan' (list, "
    "items: one item or its text, `when` ISO 8601 with offset, `with` who): Redde reminds them on the day and "
    "afterwards checks it happened; 'unplan' (list, item) takes the date back off. Not your own todo tool, nor reminders.")

PLAN_NOTE = (f"[Redde: if they're planning something for a set time (a film to watch with someone, a book, a dinner, a "
             f"trip), keep it as a plan on one of their lists with {TOOL} 'plan' (item, when, with), not in a note: "
             "Redde reminds them on the day and checks afterwards that it happened.]")
# A film or a series in the plan: its show card too, poster and all, beside the plan (asked
# 2026-11-24, of "I'm going to watch Behind the Candelabra the day after Thanksgiving": the plan
# was right, and the film's card should come with it).
SHOW_NOTE = ("[Redde: if it's a film or a series, show it too, as a 'show' card with redde_show (title, year, format, "
             "ratings, a short overview, where they can watch it), so they see its poster with the plan.]")
# An item added with its day or time only in its words (asked 2026-11-24, of "Black Friday subscription
# sale starts 11/26 7PM EST" left undated at the top of To Do): the agent hears it, to give it a date.
_MONTH = (r"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|"
          r"oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?")
_DATED = re.compile(
    r"\b(?:(?!24/7\b)\d{1,2}/\d{1,2}(?:/\d{2,4})?|\d{1,2}(?::\d\d)?\s?(?:am|pm)|today|tonight|tomorrow|"
    r"(?:mon|tues|wednes|thurs|fri|satur|sun)day|"
    rf"(?!may\b){_MONTH}\s\d{{1,2}}(?:st|nd|rd|th)?|\d{{1,2}}(?:st|nd|rd|th)?\s{_MONTH})(?!\w)", re.IGNORECASE)
DATED_SAID = ("These name a day or a time in their words but have no date of their own, so they sit undated on the "
              f"list. If one is for that day, give it its date with {TOOL} 'plan' (items: its number or words, `when` "
              "ISO 8601 with offset): it goes under that day and Redde reminds them.")
_WATCHISH = re.compile(r"\b(?:watch|re-?watch|binge|see)\b", re.IGNORECASE)
_PLANISH = re.compile(
    r"\b(?:watch|see|read|cook|make|play|visit|try|go to|have)\b.{0,80}?\b(?:tonight|tomorrow|this (?:weekend|week)|"
    r"next \w+|on (?:mon|tues|wednes|thurs|fri|satur|sun)day|(?:mon|tues|wednes|thurs|fri|satur|sun)day (?:night|evening)|"
    r"thanksgiving|christmas|new year['’]?s|easter|halloween|\d{1,2}(?::\d\d)?\s?(?:am|pm))\b", re.IGNORECASE)


# ---- the file ------------------------------------------------------------------------------------

def path(home: Path) -> Path:
    return Path(home) / "redde-push" / FILE


@contextmanager
def _locked(home: Path):
    """Held while lists.json is read and written: the agent's tool and the app's command may be
    at it at once, from two processes."""
    folder = Path(home) / "redde-push"
    folder.mkdir(parents=True, exist_ok=True)
    handle = open(os.open(folder / "lists.lock", os.O_WRONLY | os.O_CREAT, 0o600), "w")
    try:
        try:
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX)
        except (ImportError, OSError):
            pass
        yield
    finally:
        handle.close()


def calendar_by_app(home: Path | None, at: float | None = None) -> bool:
    """Whether a phone puts a watch list's nights on its calendar itself: said in the last two weeks."""
    if home is None:
        return False
    try:
        said = json.loads((Path(home) / "redde-push" / NIGHTS).read_text())
        return bool(said.get("on")) and (at if at is not None else time.time()) - float(said.get("at") or 0) < NIGHTS_FOR
    except (OSError, ValueError, TypeError, AttributeError):
        return False


def nights(home: Path, on: bool, at: float | None = None, device: str = "") -> dict:
    """The phone's word: it puts the nights on its calendar (on), or no longer does (off). With a
    device, one at a time: the first to ask, while it asks again within `NIGHTS_LEASE`. What's kept
    after, with `mine` for the asker."""
    target = Path(home) / "redde-push" / NIGHTS
    now = int(at if at is not None else time.time())
    with _locked(home):
        try:
            kept = json.loads(target.read_text())
            kept = kept if isinstance(kept, dict) else {}
        except (OSError, ValueError):
            kept = {}
        by = str(kept.get("by") or "")
        held = bool(kept.get("on")) and by and now - float(kept.get("at") or 0) < NIGHTS_LEASE
        if not on:
            if not device or not held or by == device:
                target.unlink(missing_ok=True)
                return {"nights": False}
            return {"nights": True, "by": by, "mine": False}   # (another device still does it)
        if device and held and by != device:
            return {"nights": True, "by": by, "mine": False}
        kept = {"on": True, "at": now, **({"by": device} if device else {})}
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(kept))
        os.chmod(target, 0o600)
        return {"nights": True, **({"by": device, "mine": True} if device else {})}


def load(home: Path) -> list[dict]:
    try:
        data = json.loads(path(home).read_text())
    except (OSError, ValueError):
        return []
    lists = data.get("lists") if isinstance(data, dict) else data
    return [l for l in lists or [] if isinstance(l, dict) and l.get("id")]


def save(home: Path, lists: list[dict]) -> None:
    target = path(home)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps({"lists": lists}, ensure_ascii=False, indent=1))
    os.chmod(temporary, 0o600)
    os.replace(temporary, target)


# ---- changing them -------------------------------------------------------------------------------

def _clean(text, most: int) -> str:
    return " ".join(str(text or "").split())[:most].strip()


def _texts(items) -> list[str]:
    if isinstance(items, str):
        items = [items]
    return [t for t in (_clean(i, TEXT) for i in items or [] if not isinstance(i, (dict, list))) if t]


def _find(lists: list[dict], which) -> dict | None:
    """A list by its id or its title (any case); none named and only one kept: that one."""
    which = _clean(which, TITLE)
    if not which:
        return lists[0] if len(lists) == 1 else None
    for kept in lists:
        if kept["id"] == which:
            return kept
    folded = which.casefold()
    for kept in lists:
        if str(kept.get("title") or "").casefold() == folded:
            return kept
    # "groceries" for "Grocery List", "the to-do" for "To Do": a single list whose title holds it.
    loose = [k for k in lists if folded.rstrip("s") in str(k.get("title") or "").casefold()]
    return loose[0] if len(loose) == 1 else None


def _picked(items: list[dict], refs) -> tuple[list[dict], list[str]]:
    """The items `refs` name: numbers as `show` gives them (1 is the first), ids, or their words
    (exactly, else the only one that holds them). Also what named nothing."""
    if isinstance(refs, (str, int)):
        refs = [refs]
    found, missed = [], []
    for ref in refs or []:
        # An id first: one of eight hex digits can be all digits ("40417253"), which the phone
        # sends to tick it off (1.38.0: about one tick in 43 was read as an item number and missed).
        hit = next((i for i in items if isinstance(ref, str) and i.get("id") == ref.strip()), None)
        if hit is not None:
            pass
        elif isinstance(ref, int) or (isinstance(ref, str) and ref.strip().isdigit()):
            n = int(ref)
            hit = items[n - 1] if 1 <= n <= len(items) else None
        else:
            words = _clean(ref, TEXT)
            folded = words.casefold()
            hit = next((i for i in items if i.get("id") == words), None) \
                or next((i for i in items if str(i.get("text") or "").casefold() == folded), None)
            if hit is None and folded:
                loose = [i for i in items if folded in str(i.get("text") or "").casefold()]
                hit = loose[0] if len(loose) == 1 else None
        if hit is None:
            missed.append(str(ref))
        elif hit not in found:
            found.append(hit)
    return found, missed


def _shown(kept: dict) -> dict:
    items = kept.get("items") or []
    return {"id": kept["id"], "title": kept.get("title"), **look(kept),
            "items": [f"{n}. [{'x' if i.get('done') else ' '}] {i.get('text')}{_planned(i)}"
                      f"{' (you could: ' + i['help'] + ')' if i.get('help') else ''}" for n, i in enumerate(items, 1)],
            "open": sum(1 for i in items if not i.get("done")), "done": sum(1 for i in items if i.get("done"))}


def _planned(item: dict) -> str:
    if not item.get("when"):
        return ""
    with_ = f" with {item['with']}" if item.get("with") else ""
    return f" (planned {item['when']}{with_})"


def _item_id() -> str:
    """Eight hex digits with a letter among them, so it never reads as an item's number."""
    while True:
        made = uuid.uuid4().hex[:8]
        if not made.isdigit():
            return made


def _new_items(texts: list[str], by: str, now: int) -> list[dict]:
    return [{"id": _item_id(), "text": t, "done": False, "added": now, "by": by} for t in texts]


def change(home: Path, args: dict, by: str = "default", now: float | None = None) -> dict:
    """One change, the agent's or the phone's, under the lock: what it did, for the one asking. A
    watch list it touched has its new titles' posters looked up after, the lock let go."""
    touched: list[dict] = []
    said = _change(home, args, by, now, touched)
    for kept in touched:
        _posters_later(home, kept)
    return said


def _change(home: Path, args: dict, by: str, now: float | None, touched: list[dict]) -> dict:
    args = args if isinstance(args, dict) else {}
    action = str(args.get("action") or "show")
    if action not in ACTIONS:
        return {"error": f"Unknown action {action!r}: one of {', '.join(ACTIONS)}."}
    at = int(now if now is not None else time.time())
    with _locked(home):
        lists = load(home)
        if action == "show":
            if args.get("list"):
                kept = _find(lists, args.get("list"))
                return _shown(kept) if kept else _missing(lists, args.get("list"))
            return {"lists": [_shown(k) for k in lists]} if lists else {"lists": [], "said": "No lists yet."}
        if action == "make":
            title = _clean(args.get("title") or args.get("list"), TITLE)
            if not title:
                return {"error": "A list needs a title."}
            kept = next((k for k in lists if str(k.get("title") or "").casefold() == title.casefold()), None)
            fresh = kept is None
            if fresh:
                if len(lists) >= MOST:
                    return {"error": f"There are {MOST} lists already: delete one first."}
                kept = {"id": uuid.uuid4().hex[:10], "title": title, "made": at, "by": by, "changed": at, "items": []}
                lists.append(kept)
            wrong = _styled(kept, args)
            added = _texts(args.get("items"))[: max(0, ITEMS - len(kept["items"]))]
            kept["items"] += _new_items(added, by, at)
            kept["changed"] = at
            save(home, lists)
            touched.append(kept)
            # (A list by that title already: the items go on it, not on a second list of the same name.)
            return {"made" if fresh else "already_there": kept["id"], **_shown(kept),
                    "said": "It's on their Today row in Redde now.", **({"not_kept": wrong} if wrong else {})}
        kept = _find(lists, args.get("list"))
        if kept is None:
            return _missing(lists, args.get("list"))
        items = kept.setdefault("items", [])
        if action == "add":
            texts = _texts(args.get("items"))
            if not texts:
                return {"error": "Nothing to add: give items as texts."}
            when = _when(args, at) if args.get("when") else None
            if isinstance(when, str):
                return {"error": when}
            room = ITEMS - len(items)
            if room <= 0:
                return {"error": f"{kept.get('title')} has {ITEMS} items: clear the done ones first."}
            new = _new_items(texts[:room], by, at)
            items += new
            said = {"added": len(new)}
            if when:
                with_ = _clean(args.get("with"), 60)
                for item in new:
                    said["said"] = _date(kept, item, when, with_, at, home)
                said["planned"], said["when"] = [i["text"] for i in new], new[0]["when"]
            elif dated := [i["text"] for i in new if _DATED.search(i["text"])]:
                said["no_date"], said["said"] = dated, DATED_SAID
        elif action in ("check", "uncheck", "remove"):
            found, missed = _picked(items, args.get("items"))
            if not found:
                return {"error": "No item by that number or those words.", **_shown(kept)}
            for item in found:
                if action == "remove":
                    items.remove(item)
                else:
                    item["done"] = action == "check"
                    item["done_at"] = at if action == "check" else None
                    if action == "check" and look(kept)["kind"] == "shopping":
                        try:   # usual buys (habits.py, 1.40.0)
                            from . import habits
                            habits.note(home, item.get("text"), kept["id"], kept.get("title") or "", at)
                        except Exception:
                            pass
            said = {action + ("ed" if action != "remove" else "d"): [i.get("text") for i in found]}
            if missed:
                said["not_found"] = missed
        elif action == "clear_done":
            gone = [i for i in items if i.get("done")]
            kept["items"] = items = [i for i in items if not i.get("done")]
            said = {"cleared": len(gone)}
        elif action == "rename":
            title = _clean(args.get("title"), TITLE)
            if not title:
                return {"error": "Give the new title."}
            kept["title"] = title
            said = {"renamed": title}
        elif action == "edit":
            edited = _edit(kept, args, at, home)
            if "error" in edited:
                return {**edited, **_shown(kept)}
            said = edited
        elif action == "plan":
            planned = _plan(kept, args, by, at, home)
            if "error" in planned:
                return {**planned, **_shown(kept)}
            said = planned
        elif action == "help":
            found, missed = _picked(items, args.get("items"))
            if not found:
                return {"error": "Say which items: their numbers or words.", **_shown(kept)}
            line = _clean(args.get("help"), HELP)
            for item in found:
                if line:
                    item["help"] = line
                else:
                    item.pop("help", None)
            said = {"help": line, "for": [i.get("text") for i in found],
                    "said": "Redde shows it under each, for them to tap." if line else "Taken off."}
            if missed:
                said["not_found"] = missed
        elif action == "unplan":
            unplanned = _unplan(kept, args)
            if "error" in unplanned:
                return {**unplanned, **_shown(kept)}
            said = unplanned
        elif action == "style":
            given = [k for k in ("kind", "emoji", "color") if args.get(k) is not None]
            if not given:
                return {"error": "Give a kind, an emoji or a color."}
            wrong = _styled(kept, args)
            if len(wrong) == len(given):
                return {"error": "; ".join(wrong) + "."}
            said = {"styled": look(kept), **({"not_kept": wrong} if wrong else {})}
        else:   # delete
            lists.remove(kept)
            save(home, lists)
            return {"deleted": kept.get("title"), "said": "Its tile is gone from their Today row."}
        kept["changed"] = at
        save(home, lists)
        if action in ("add", "style", "edit"):
            touched.append(kept)
        return {**said, **_shown(kept)}


def _missing(lists: list[dict], which) -> dict:
    titles = [k.get("title") for k in lists]
    if not titles:
        return {"error": "There are no lists yet: 'make' one."}
    if not _clean(which, TITLE):
        return {"error": "Which list? Name it.", "lists": titles}
    return {"error": f"No list called {_clean(which, TITLE)!r}.", "lists": titles}


# ---- plans ---------------------------------------------------------------------------------------

#: Hermes's `cron.jobs.create_job` and `remove_job`; stand-ins in tests.
MAKE_JOB = None
REMOVE_JOB = None


def _cron():
    make, remove = MAKE_JOB, REMOVE_JOB
    if make is None:
        try:
            from cron.jobs import create_job as make, remove_job as remove
        except Exception:
            return None, None
    return make, remove


def _moment(text) -> datetime | str:
    try:
        moment = datetime.fromisoformat(str(text or "").strip().replace("Z", "+00:00"))
    except ValueError:
        return "`when` is a date and time with its UTC offset, like 2026-11-26T19:00:00-05:00."
    if moment.tzinfo is None:
        return "`when` needs its UTC offset (2026-11-26T19:00:00-05:00), so it's their time."
    return moment


def plan_times(when: datetime, now: datetime) -> tuple[datetime | None, datetime]:
    """When to remind them (the morning of the day, or two hours before a morning plan; none once
    past) and when to follow through (three hours after, or the next morning for an evening plan)."""
    morning = when.replace(hour=PLAN_MORNING, minute=0, second=0, microsecond=0)
    before = morning if when.hour >= 13 else when - timedelta(hours=2)
    after = (morning + timedelta(days=1)) if when.hour >= 17 else when + PLAN_AFTER
    return (before if before > now else None), after


def _plan(kept: dict, args: dict, by: str, at: int, home: Path | None = None) -> dict:
    refs = args.get("items")
    found, _ = _picked(kept.get("items") or [], refs)
    if not found:
        texts = _texts(refs)
        if len(texts) != 1:
            return {"error": "Plan one item: its number, its words, or the text of a new one."}
        found = _new_items(texts, by, at)
        kept["items"].append(found[0])
    item = found[0]
    when = _when(args, at)
    if isinstance(when, str):
        return {"error": when}
    with_ = _clean(args.get("with"), 60)
    said = _date(kept, item, when, with_, at, home)
    return {"planned": item["text"], "when": item["when"], **({"with": with_} if with_ else {}), "said": said}


def _when(args: dict, at: int) -> datetime | str:
    """The time a plan or a dated item is for, or what's wrong with it."""
    when = _moment(args.get("when"))
    if isinstance(when, str):
        return when
    if when - datetime.fromtimestamp(at, timezone.utc) > PLAN_AHEAD:
        return "That's more than 60 days off: plan it nearer the time."
    return when


def _date(kept: dict, item: dict, when: datetime, with_: str, at: int, home: Path | None = None) -> str:
    """Puts an item on its day, with the reminder and the check that go with it (any old ones
    dropped): what Redde will do, for the agent. A watch list's night goes on the calendar by the
    phone, when a phone says it does that (`calendar_by_app`), else by the agent."""
    now = datetime.fromtimestamp(at, timezone.utc)
    by_app = look(kept)["kind"] == "watch" and calendar_by_app(home, at)
    calendar = ("Redde puts it on their calendar itself and moves it with the plan: don't add it with a calendar "
                "tool." if by_app else "If it isn't on their calendar, put it there with your calendar tool too.")
    make, remove = _cron()
    for old in item.get("plan_jobs") or []:
        try:
            remove and remove(old)
        except Exception:
            pass
    item["when"], item["with"], item["plan_jobs"] = when.isoformat(timespec="minutes"), with_ or None, []
    before, after = plan_times(when, now)
    if make is None:
        return "Kept on the list; this Hermes can't schedule the reminder or the check (no cron). " + calendar
    plan = uuid.uuid4().hex[:10]
    for moment, words in ((before, plan_reminder(kept, item, when)), (after, plan_check(kept, item, when, by_app))):
        if moment is None:
            continue
        try:
            job = make(words, moment.isoformat(timespec="minutes"), name=f"{PLAN_TAG}{plan}] {item['text'][:60]}", deliver="local")
            if isinstance(job, dict) and job.get("id"):
                item["plan_jobs"].append(job["id"])
        except Exception:
            pass
    return (f"Redde reminds them {'on the day' if before else 'no more today'} and checks on "
            f"{after.strftime('%A %-d %B')} that it happened. " + calendar)


def _edit(kept: dict, args: dict, at: int, home: Path | None = None) -> dict:
    """New words for one item (Edit in Redde's long-press menu, asked 2026-11-24). A film's poster is
    looked for again under its new title; a dated item's reminder and check say the new words."""
    found, _ = _picked(kept.get("items") or [], args.get("items"))
    if len(found) != 1:
        return {"error": "Say which one item to edit: its number or its words."}
    words = _texts(args.get("title"))
    if not words:
        return {"error": "Give the item's new words as `title`."}
    item, before = found[0], found[0].get("text")
    if words[0] != before:
        item["text"] = words[0]
        for field in ("poster", "year", "poster_tried", "poster_misses", "poster_tmdb", "poster_again", "help"):
            item.pop(field, None)
        if item.get("when"):
            when, now = datetime.fromisoformat(item["when"]), datetime.fromtimestamp(at, timezone.utc)
            if plan_times(when, now)[1] > now:
                _date(kept, item, when, item.get("with") or "", at, home)
    return {"edited": before, "now": item["text"]}


def _unplan(kept: dict, args: dict) -> dict:
    """Takes the date off one item (Remove Date in Redde, 1.42.0), with its reminder and check."""
    found, _ = _picked(kept.get("items") or [], args.get("items"))
    if len(found) != 1:
        return {"error": "Say which one item to take the date off: its number or its words."}
    item = found[0]
    _, remove = _cron()
    for old in item.get("plan_jobs") or []:
        try:
            remove and remove(old)
        except Exception:
            pass
    for field in ("when", "with", "plan_jobs"):
        item.pop(field, None)
    return {"unplanned": item["text"], "said": "Its date, reminder and check are gone."}


def _when_words(when: datetime) -> str:
    return when.strftime("%A %-d %B at %-I:%M %p").replace(":00 ", " ")


def plan_reminder(kept: dict, item: dict, when: datetime) -> str:
    name, with_ = item["text"], f" with {item['with']}" if item.get("with") else ""
    ready = f"Get {name} ready to play" if look(kept)["kind"] == "watch" else f"Help me get ready for {name}"
    return (f"{PLAN_TAG}{kept['id']}:{item['id']}] The user planned {name}{with_} for {_when_words(when)}, on their "
            f"list '{kept.get('title')}'. Unless it's been called off or is already ticked off ({TOOL} show), remind "
            f"them with suggest_to_user: title \"{when.strftime('%-I:%M %p').replace(':00 ', ' ')}: {name}{with_}\", why "
            f"\"You planned it\", request \"{ready}\". Nothing else. If a tool isn't among yours, find it with tool_search.")


def plan_check(kept: dict, item: dict, when: datetime, by_app: bool = False) -> str:
    name, with_ = item["text"], f" with {item['with']}" if item.get("with") else ""
    watch = look(kept)["kind"] == "watch"
    how = ("It's a film or a series: see whether their media server (Jellyfin, Plex) shows it played since then; if "
           "you can't reach it yourself, ask the bot that can with an @mention." if watch else
           "Look for signs it was done in what your tools can see: their calendar, mail, reminders, messages.")
    question = f"Did you watch {name}?" if watch else f"Did {name} happen?"
    # (With the phone putting a watch list's nights on its calendar, the new night is all the agent gives.)
    again = (f"We haven't watched {name} yet: find another night{with_} and plan it on my list" if watch and by_app
             else f"We haven't watched {name} yet: find another night{with_} and put it on my calendar" if watch
             else f"{name} didn't happen: find another time{with_} and put it on my calendar")
    return (f"{PLAN_TAG}{kept['id']}:{item['id']}] Follow-through for the user: they planned {name}{with_} for "
            f"{_when_words(when)}, on their list '{kept.get('title')}' (list {kept['id']}, item {item['id']}). If it's "
            f"already ticked off ({TOOL} show), stop. Otherwise find out whether it happened with your tools, without "
            f"asking them. {how} If it happened, tick it off with {TOOL} (action check, list {kept['id']}, items "
            f"[\"{item['id']}\"]) and say nothing. If it plainly didn't, or you can't tell, offer it back with "
            f"suggest_to_user: title \"{question}\", why a few words on when it was planned, request \"{again}\". If a "
            "tool isn't among yours, find it with tool_search.")


# ---- for the app ---------------------------------------------------------------------------------

#: What the app may offer of these lists beyond their items (1.46.0): help lines.
CAN = ["help"]

def listing(home: Path) -> list[dict]:
    """Every list, as kept, for the phone's Today row: oldest first (the order they were made). A
    watch list with titles not yet looked up sets their posters looking."""
    kept = load(home)
    for k in kept:
        _posters_later(home, k)
    return [{"id": k["id"], "title": k.get("title") or "", "changed": k.get("changed") or k.get("made"), **look(k),
             "items": [{"id": i.get("id"), "text": i.get("text") or "", "done": bool(i.get("done")),
                        **{f: i[f] for f in ("poster", "year", "when", "with", "help") if i.get(f)}}
                       for i in k.get("items") or [] if i.get("id")]}
            for k in kept]


# ---- a watch list's posters ----------------------------------------------------------------------

#: How a title's poster is found: (title, year or None, deadline) → its address or None. Tests swap it.
FIND = lambda title, year, deadline: posters.lookup(title, year, None, deadline)   # noqa: E731


def _find_on_tmdb(title: str, year: str | None, deadline: float, series: bool | None) -> str | None:
    key = posters.KEY()
    return posters.tmdb(title, year, series, deadline, key) if key else None


#: 1.44.0: a poster found before there was a TMDb key, looked for there (2026-11-24: "refetch the
#: old posters too"): FIND's shape and whether it's a series, TMDb's alone. KEYED says if there's a
#: key. Tests swap both.
FIND_AGAIN = _find_on_tmdb
KEYED = lambda: bool(posters.KEY())   # noqa: E731
#: The round of that look an item has had (`poster_again`). The first (marked `poster_tmdb`) took
#: TMDb's most watched this week, and gave Home Alone and Love Actually TV shows' posters: those
#: are looked at again.
AGAIN = 2


def _series_by(poster: str) -> bool | None:
    """Whether the old poster was a series' or a film's, by where it came from."""
    host = urlsplit(poster).hostname or ""
    return True if host.endswith("tvmaze.com") else False if host.endswith(("wikimedia.org", "wikipedia.org")) else None
#: Off the turn, in a thread; tests run it there and then.
BACKGROUND = True
_running: set[str] = set()
_running_lock = threading.Lock()


def _untried(kept: dict, now: float | None = None) -> list[dict]:
    if look(kept)["kind"] != "watch":
        return []
    now = time.time() if now is None else now
    keyed = KEYED()
    return [i for i in kept.get("items") or [] if i.get("id") and _wants_poster(i, now, keyed)][:POSTERS_AT_ONCE]


def _wants_poster(item: dict, now: float, keyed: bool = False) -> bool:
    if not item.get("poster_tried"):
        return True
    if item.get("poster"):
        # Found elsewhere before there was a TMDb key, or by the first such look: looked for there, once (1.44.0).
        if not keyed or (int(item["poster_again"]) if str(item.get("poster_again", "")).isdigit() else 0) >= AGAIN:
            return False
        return bool(item.get("poster_tmdb")) or not str(item["poster"]).startswith(posters.TMDB_IMAGES)
    misses = item.get("poster_misses")
    if not isinstance(misses, int):
        return True   # missed before 1.42.1
    return misses < POSTER_TRIES and now - float(item["poster_tried"]) >= POSTER_RETRY


def _posters_later(home: Path, kept: dict) -> None:
    if not _untried(kept):
        return
    key = str(Path(home).resolve())
    with _running_lock:
        if key in _running:
            return
        _running.add(key)

    def run():
        try:
            fill_posters(home)
        except Exception:   # never the list's undoing: tried again on the next look
            pass
        finally:
            with _running_lock:
                _running.discard(key)

    if BACKGROUND:
        threading.Thread(target=run, name="redde-list-posters", daemon=True).start()
    else:
        run()


def fill_posters(home: Path, now: float | None = None) -> int:
    """Looks up the posters of every watch list's titles not tried yet, a few at once and for
    POSTER_WAIT seconds at most, and keeps what was found: how many. With a TMDb key, a poster
    found elsewhere before is looked for on TMDb once, and kept when TMDb has none."""
    at = int(now if now is not None else time.time())
    with _locked(home):
        wanted = [(k["id"], i["id"], str(i.get("text") or ""), str(i.get("poster") or "")) for k in load(home) for i in _untried(k, at)]
    if not wanted:
        return 0
    deadline = time.monotonic() + POSTER_WAIT
    titled, again = {}, {item: _series_by(had) for _, item, _, had in wanted if had}
    for _, item, text, _ in wanted:
        year = _YEAR.search(text)
        titled[item] = (_YEAR.sub("", text).strip(), year.group(1) if year else None)
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = {(pool.submit(FIND_AGAIN, title, year, deadline, again[item]) if item in again else pool.submit(FIND, title, year, deadline)): item
                   for item, (title, year) in titled.items() if title}
        done, _ = wait(futures, timeout=POSTER_WAIT + 1)
    found = {item: f.result() for f, item in futures.items() if f in done and f.exception() is None}
    asked = set(futures.values())
    with _locked(home):
        lists = load(home)
        for k in lists:
            for i in k.get("items") or []:
                if i.get("id") not in asked:
                    continue
                if i["id"] in again:
                    if found.get(i["id"]):
                        i["poster"] = found[i["id"]]
                    if i["id"] in found:
                        i["poster_again"] = AGAIN
                        i.pop("poster_tmdb", None)
                    continue
                if found.get(i["id"]):
                    i["poster"] = found[i["id"]]
                    i.pop("poster_misses", None)
                if titled[i["id"]][1]:
                    i["year"] = int(titled[i["id"]][1])
                if i["id"] in found:     # (one not back in time is tried again)
                    i["poster_tried"] = at
                    if not found[i["id"]]:
                        misses = i.get("poster_misses")
                        i["poster_misses"] = (misses if isinstance(misses, int) else 0) + 1
        save(home, lists)
    return sum(1 for v in found.values() if v)


def slash(home: Path, words: list[str]) -> str:
    """`/redde-push lists list`: "redde-push lists <JSON>", every list. `lists do <base64url JSON>`:
    one change, `redde_list`'s arguments (items by id), then the lists as they are now. `lists nights
    on|off [device]`: the phone puts a watch list's nights on its calendar itself, or no longer does
    (1.50.0); with its device, whether it's the one that does (1.51.0)."""
    if words == ["list"]:
        return wire.reply("lists", {"lists": listing(home), "can": CAN})
    if len(words) in (2, 3) and words[0] == "nights" and words[1] in ("on", "off"):
        device = re.sub(r"[^A-Za-z0-9-]", "", words[2])[:64] if len(words) == 3 else ""
        return wire.reply("lists", nights(home, words[1] == "on", device=device))
    if len(words) == 2 and words[0] == "do":
        try:
            raw = words[1] + "=" * (-len(words[1]) % 4)
            args = json.loads(base64.urlsafe_b64decode(raw.encode()).decode())
        except (ValueError, UnicodeDecodeError):
            return "redde-push lists: this command is for the Redde app."
        said = change(home, args, by="phone")
        return wire.reply("lists", {"said": said, "lists": listing(home), "can": CAN})
    return "redde-push lists: this command is for the Redde app."


# ---- turn notes ----------------------------------------------------------------------------------

def _text(message) -> str:
    if isinstance(message, str):
        return message
    if isinstance(message, list):
        return " ".join(str(p.get("text") or "") for p in message if isinstance(p, dict))
    return ""


def turn_note(message, platform: str = "") -> str | None:
    """For `pre_llm_call`: a person's message about one of their lists. Not a scheduled run, nor a
    bot's turn in a group chat."""
    if platform in ("cron", "subagent", "bot_room"):
        return None
    text = _text(message)
    if not text or text.lstrip().startswith("["):
        return None
    listish, planish = _LISTISH.search(text), _PLANISH.search(text)
    if not (listish or planish):
        return None
    watching = planish and _WATCHISH.search(text)
    return " ".join(n for n in (NOTE if listish else None, PLAN_NOTE if planish else None,
                                SHOW_NOTE if watching else None) if n)


def register(ctx, home_of) -> None:
    """Offers `redde_list`, deferred with the other Redde tools of its kind. The lists are the main
    home's, whichever bot asks."""
    from .calls import caller

    def handle(args, **kwargs) -> str:
        profile, root = caller(Path(home_of()))
        return json.dumps(change(root, args if isinstance(args, dict) else {}, by=profile), ensure_ascii=False)

    schema = {"name": TOOL, "description": DESCRIPTION,
              "parameters": {"type": "object",
                             "properties": {"action": {"type": "string", "enum": list(ACTIONS)},
                                            "list": {"type": "string", "description": "The list's id or title"},
                                            "title": {"type": "string"},
                                            "kind": {"type": "string", "enum": list(KINDS)},
                                            "emoji": {"type": "string"},
                                            "color": {"type": "string", "enum": list(COLORS)},
                                            "when": {"type": "string"},
                                            "with": {"type": "string"},
                                            "help": {"type": "string"},
                                            "items": {"type": "array", "items": {"type": "string"},
                                                      "description": "Texts to add, or the items' numbers or words"}},
                             "required": ["action"]}}
    ctx.register_tool(name=TOOL, toolset=TOOLSET, schema=schema, handler=handle, emoji="✅")

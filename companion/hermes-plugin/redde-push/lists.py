"""Lists: the person's own to-do lists ("make me a grocery list", "add milk", "check off the eggs"),
each a tile on Redde's Today row, next to the Inbox, where they stay until the list is deleted
(asked 2026-11-09). Several lists, by name; kept in the main home's `redde-push/lists.json`, so
every bot reads and changes the same ones, and the phone can check things off with the app's
`/redde-push lists …`, the same changes the agent makes with `redde_list`.

Never the agent's own `todo` tool: that is its plan for one turn, shown under its reply.
"""

from __future__ import annotations

import base64
import json
import os
import re
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from . import wire

TOOLSET = "redde_ideas"
TOOL = "redde_list"
FILE = "lists.json"
#: At most this many lists, items on one, and characters in a title or an item.
MOST, ITEMS, TITLE, TEXT = 30, 300, 60, 200
ACTIONS = ("show", "make", "add", "check", "uncheck", "remove", "clear_done", "rename", "delete")

#: What sounds like one of their lists, in English: cheap to look for, said in a turn's note only.
_LISTISH = re.compile(
    r"\b(?:to-?\s?do(?:s| list)?|todo list|(?:grocery|groceries|shopping|packing|chore|chores|errand|errands|"
    r"wish|reading|watch|bucket|task|checklist)\s*list|check ?list|my lists?|the list|(?:check|cross|tick|mark) (?:\w+ ){0,4}off|"
    r"(?:add|put|write) .{1,80}? (?:to|on|onto) (?:my|the|our) .{0,30}?list)\b",
    re.IGNORECASE)

NOTE = (f"[Redde: their lists (to-do, groceries, packing…) live in Redde and show on their phone's Today row: keep them "
        f"with {TOOL} (find it with tool_search if it isn't among your tools). 'show' first when you don't know which "
        "list they mean. Not your own todo tool, which is only your plan for this turn, and not reminders unless they "
        "ask for a reminder.]")

DESCRIPTION = (
    "The user's own lists in Redde (to-do lists, groceries, packing, chores…), several by name, each shown as a tile "
    "on their phone's Today row until deleted. Actions: 'show' (every list, or one: `list`), 'make' (title, items), "
    "'add' (list, items: texts), 'check' / 'uncheck' / 'remove' (list, items: numbers as 'show' gives them, or "
    "their words), 'clear_done' (list: removes checked items), 'rename' (list, title), 'delete' (list). `list` is a "
    "list's id or its title; with only one list it may be left out. Not your own todo tool (your plan for this "
    "turn) and not reminders.")


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
        hit = None
        if isinstance(ref, int) or (isinstance(ref, str) and ref.strip().isdigit()):
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
    return {"id": kept["id"], "title": kept.get("title"),
            "items": [f"{n}. [{'x' if i.get('done') else ' '}] {i.get('text')}" for n, i in enumerate(items, 1)],
            "open": sum(1 for i in items if not i.get("done")), "done": sum(1 for i in items if i.get("done"))}


def _new_items(texts: list[str], by: str, now: int) -> list[dict]:
    return [{"id": uuid.uuid4().hex[:8], "text": t, "done": False, "added": now, "by": by} for t in texts]


def change(home: Path, args: dict, by: str = "default", now: float | None = None) -> dict:
    """One change, the agent's or the phone's, under the lock: what it did, for the one asking."""
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
            added = _texts(args.get("items"))[: max(0, ITEMS - len(kept["items"]))]
            kept["items"] += _new_items(added, by, at)
            kept["changed"] = at
            save(home, lists)
            # (A list by that title already: the items go on it, not on a second list of the same name.)
            return {"made" if fresh else "already_there": kept["id"], **_shown(kept),
                    "said": "It's on their Today row in Redde now."}
        kept = _find(lists, args.get("list"))
        if kept is None:
            return _missing(lists, args.get("list"))
        items = kept.setdefault("items", [])
        if action == "add":
            texts = _texts(args.get("items"))
            if not texts:
                return {"error": "Nothing to add: give items as texts."}
            room = ITEMS - len(items)
            if room <= 0:
                return {"error": f"{kept.get('title')} has {ITEMS} items: clear the done ones first."}
            items += _new_items(texts[:room], by, at)
            said = {"added": len(texts[:room])}
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
        else:   # delete
            lists.remove(kept)
            save(home, lists)
            return {"deleted": kept.get("title"), "said": "Its tile is gone from their Today row."}
        kept["changed"] = at
        save(home, lists)
        return {**said, **_shown(kept)}


def _missing(lists: list[dict], which) -> dict:
    titles = [k.get("title") for k in lists]
    if not titles:
        return {"error": "There are no lists yet: 'make' one."}
    if not _clean(which, TITLE):
        return {"error": "Which list? Name it.", "lists": titles}
    return {"error": f"No list called {_clean(which, TITLE)!r}.", "lists": titles}


# ---- for the app ---------------------------------------------------------------------------------

def listing(home: Path) -> list[dict]:
    """Every list, as kept, for the phone's Today row: oldest first (the order they were made)."""
    return [{"id": k["id"], "title": k.get("title") or "", "changed": k.get("changed") or k.get("made"),
             "items": [{"id": i.get("id"), "text": i.get("text") or "", "done": bool(i.get("done"))}
                       for i in k.get("items") or [] if i.get("id")]}
            for k in load(home)]


def slash(home: Path, words: list[str]) -> str:
    """`/redde-push lists list`: "redde-push lists <JSON>", every list. `lists do <base64url JSON>`:
    one change, `redde_list`'s arguments (items by id), then the lists as they are now."""
    if words == ["list"]:
        return wire.reply("lists", {"lists": listing(home)})
    if len(words) == 2 and words[0] == "do":
        try:
            raw = words[1] + "=" * (-len(words[1]) % 4)
            args = json.loads(base64.urlsafe_b64decode(raw.encode()).decode())
        except (ValueError, UnicodeDecodeError):
            return "redde-push lists: this command is for the Redde app."
        said = change(home, args, by="phone")
        return wire.reply("lists", {"said": said, "lists": listing(home)})
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
    if not text or text.lstrip().startswith("[") or not _LISTISH.search(text):
        return None
    return NOTE


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
                                            "items": {"type": "array", "items": {"type": "string"},
                                                      "description": "Texts to add, or the items' numbers or words"}},
                             "required": ["action"]}}
    ctx.register_tool(name=TOOL, toolset=TOOLSET, schema=schema, handler=handle, emoji="✅")

"""Ideas from the agent: things it could do for the person, offered as cards on their iPhone that
they take with a swipe one way or put away with a swipe the other (asked 2026-10-28, after
OpenDuet's suggestion cards). Nothing is done until they take one.

How ideas travel. The agent calls `suggest_to_user` with up to five ideas, each a few words of what
it would do, a line of why now, and the request it would carry out, in the person's words. The
plugin seals one note for each paired phone (kind "ideas") and the relay hands it to Apple as a
notification ("Sol has 3 ideas for you"); Redde keeps the cards, with Redde closed too. Taken,
a card's request goes to that agent as the person's message, in its chat. Put away, it is gone.

Usually from a morning schedule Redde sets up for the person (Settings, Agent, Morning Ideas):
it asks the agent to look at the day and offer what it could do. An agent may also offer ideas
when asked for some. One agent's ideas at most ten times an hour, so a loop can't fill the
phone.
"""

from __future__ import annotations

import json
import logging
import re
import time
import uuid
from pathlib import Path

from . import core
from .calls import caller
from .routines import Stores

log = logging.getLogger("redde_push")

TOOLSET = "redde_ideas"
TOOL = "suggest_to_user"
MOST = 5
#: How many times an hour one agent may send ideas: enough to try it out, not enough for a loop
#: to fill the phone (3 turned the owner's tries away, 2026-10-28).
HOURLY = 10
#: How long Apple keeps trying a phone that is off, in seconds: ideas for the day are good all day.
TTL = 43200

DESCRIPTION = (
    "Offers the user things you could do for them, as cards on their iPhone, through the Redde app: they take one "
    "with a swipe and put the rest away. Nothing is done until they take one: a card taken comes back to you as their "
    "message, with your request in it, in your chat with them. For a scheduled look at their day (Morning Ideas), or "
    "when they ask what you could do. Offer only what is worth their time, based on what you know and have just "
    "checked (their calendar, reminders, mail, the board, what they asked you lately); never more than five. Don't "
    "do any of it now, and don't offer what they already asked you to do.")
IDEAS = "One to five ideas, the most useful first."
TITLE = "What you would do, in a few words, as a card's heading (\"Book the vet for Pickles\")."
WHY = "One short line on why now (\"His jab is due Friday and Thursday is free\")."
REQUEST = ("The request you would carry out if they take the card, as they would say it to you, complete in itself "
           "(\"Book Pickles in at the vet on Thursday afternoon and add it to my calendar\").")


#: Redde's own jobs whose ideas are the point (Settings, Agent: Morning Ideas, Routine
#: Suggestions). A run of one that offered nothing with the tool still reaches the phone: the
#: ideas it wrote out in its answer as cards, else the answer as a briefing (`routines.py`). Hermes
#: 0.22 keeps plugin tools behind tool_search, and a model that doesn't look there writes the ideas
#: out instead (the owner's first Morning Ideas, 2026-10-29: nothing came).
JOBS = ("[redde] Morning ideas", "[redde] Routine suggestions")
#: How such an answer writes an idea: "IDEA: Book the vet | His jab is due Friday | Book Pickles in…".
_WRITTEN = re.compile(r"^\s*(?:[-*•]\s*)?\**IDEA\**\s*[:：]\**\s*(.+)$", re.IGNORECASE | re.MULTILINE)


def from_answer(text: str) -> list[dict]:
    """The ideas a job's answer wrote out ("IDEA: title | why | request"), as the tool keeps them."""
    found = []
    for line in _WRITTEN.findall(text or ""):
        parts = [part.strip(" *") for part in line.split("|")]
        if len(parts) >= 3:
            title, why, request = parts[0], parts[1], " | ".join(parts[2:])
        elif len(parts) == 2:
            title, why, request = parts[0], "", parts[1]
        else:
            title, why, request = parts[0], "", parts[0]
        found.append({"title": title, "why": why, "request": request})
    return cleaned(found)


def sent_lately(home: Path, profile: str, now: float) -> list[float]:
    """When this agent sent ideas in the last hour."""
    try:
        seen = json.loads((home / "redde-push" / "ideas.json").read_text())
    except Exception:
        seen = {}
    return [t for t in seen.get(profile, []) if now - t < 3600]


def remember(home: Path, profile: str, now: float) -> None:
    path = home / "redde-push" / "ideas.json"
    try:
        seen = json.loads(path.read_text())
    except Exception:
        seen = {}
    seen[profile] = sent_lately(home, profile, now) + [now]
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".new")
    tmp.write_text(json.dumps(seen))
    tmp.replace(path)


# ---- what not to suggest (1.36.0, after hermes-muse's "stop bringing this up", 2026-11-22) ---------
#: Don't Suggest This on an idea's card in Redde: the card's heading kept, for every agent. An idea
#: that matches one is left out, and a run that offers ideas is told the list.

BLOCKED = "ideas-blocked.json"
BLOCKED_MOST = 50
_SMALL = {"the", "and", "for", "with", "from", "into", "your", "you", "their", "them", "this", "that", "what", "about",
          "out", "off", "our", "its", "his", "her", "a", "an", "to", "of", "in", "on", "at", "my", "me", "it", "up"}


def _words(text: str) -> set[str]:
    return {w for w in re.findall(r"[^\W_]+", str(text or "").lower()) if len(w) > 2 and w not in _SMALL}


def blocked(home: Path) -> list[str]:
    """What the person said not to suggest, newest first."""
    try:
        kept = json.loads((Path(home) / "redde-push" / BLOCKED).read_text())
    except Exception:
        return []
    return [str(entry.get("t")) for entry in kept if isinstance(entry, dict) and entry.get("t")]


def _keep_blocked(home: Path, titles: list[str]) -> None:
    path = Path(home) / "redde-push" / BLOCKED
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".new")
    tmp.write_text(json.dumps([{"t": t} for t in titles[:BLOCKED_MOST]], ensure_ascii=False))
    tmp.replace(path)


def block(home: Path, title: str) -> bool:
    title = core.clipped(" ".join(str(title or "").split()), 60)
    if not _words(title):
        return False
    _keep_blocked(home, [title] + [t for t in blocked(home) if t.lower() != title.lower()])
    return True


def unblock(home: Path, title: str) -> bool:
    titles = blocked(home)
    left = [t for t in titles if t.lower() != " ".join(str(title or "").split()).lower()]
    if len(left) == len(titles):
        return False
    _keep_blocked(home, left)
    return True


def unwanted(idea: dict, titles: list[str]) -> bool:
    """Whether an idea (as `cleaned` keeps it) is one they said not to suggest: most of a blocked
    heading's words in its heading or request."""
    said = _words(f"{idea.get('t', '')} {idea.get('r', '')}")
    for title in titles:
        words = _words(title)
        if words and len(words & said) >= max(1, round(len(words) * 0.6)):
            return True
    return False


def wanted(home: Path, ideas: list[dict]) -> list[dict]:
    titles = blocked(home)
    return [idea for idea in ideas if not unwanted(idea, titles)] if titles else ideas


def run_note(home: Path, message, platform: str = "") -> str | None:
    """For `pre_llm_call`: a run that offers ideas (it names the tool or is one of Redde's idea
    jobs), told what not to suggest."""
    if platform != "cron":
        return None
    text = message if isinstance(message, str) else " ".join(
        str(p.get("text") or "") for p in message or [] if isinstance(p, dict)) if isinstance(message, list) else ""
    if TOOL not in text and "IDEA:" not in text:
        return None
    titles = blocked(home)
    if not titles:
        return None
    return ("[Redde: they asked not to be offered ideas like these again: " + "; ".join(f"\"{t}\"" for t in titles[:20])
            + ". Leave anything like them out.]")


# ---- left alone (1.36.0, after Heartbeat 2.0's mute after unanswered messages, 2026-11-22) ------
#: An agent's ideas that nobody took, put away or put off, set after set: from the IGNORED-th in a
#: row they come quietly, into the deck with no sound or banner, until the person touches one of
#: that agent's cards again (Redde says so: `/redde-push ideas touched <profile>`).

IGNORED = 3
UNTOUCHED = "ideas-untouched.json"


def _untouched(home: Path) -> dict:
    try:
        kept = json.loads((Path(home) / "redde-push" / UNTOUCHED).read_text())
        return kept if isinstance(kept, dict) else {}
    except Exception:
        return {}


def _keep_untouched(home: Path, kept: dict) -> None:
    path = Path(home) / "redde-push" / UNTOUCHED
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".new")
    tmp.write_text(json.dumps(kept))
    tmp.replace(path)


def untouched(home: Path, profile: str) -> int:
    return int(_untouched(home).get(profile) or 0)


def quiet_if_ignored(home: Path, profile: str, made: dict) -> bool:
    """Counts a set of ideas going out, and makes it quiet (`z` "drawer") when the ones before it
    were left alone; whether it is quiet."""
    kept = _untouched(home)
    left = int(kept.get(profile) or 0)
    kept[profile] = left + 1
    _keep_untouched(home, kept)
    if left >= IGNORED:
        made["z"] = "drawer"
        return True
    return False


def touched(home: Path, profile: str) -> None:
    kept = _untouched(home)
    if kept.pop(profile, None) is not None:
        _keep_untouched(home, kept)


def cleaned(ideas) -> list[dict]:
    """What the phone is given of each idea: `t` the heading, `w` why now, `r` the request."""
    kept = []
    for idea in ideas if isinstance(ideas, list) else []:
        if not isinstance(idea, dict):
            continue
        request = core.clipped(str(idea.get("request") or ""), 300)
        title = core.clipped(str(idea.get("title") or ""), 60) or core.clipped(request, 60)
        if not request:
            continue
        made = {"t": title, "r": request}
        why = core.clipped(str(idea.get("why") or ""), 120)
        if why:
            made["w"] = why
        kept.append(made)
    return kept[:MOST]


def offer(store: core.Store, home: Path, profile: str, name: str, ideas, now: float | None = None) -> dict:
    """Sends the ideas to every paired phone; what the tool answers."""
    now = time.time() if now is None else now
    given = cleaned(ideas)
    kept = wanted(home, given)
    if given and not kept:
        return {"error": "They asked not to be offered ideas like these (Don't Suggest This in Redde): offer something "
                         "else, or nothing."}
    if not kept:
        return {"error": "No ideas to send: give each one a \"request\" (and a \"title\")."}
    if len(sent_lately(home, profile, now)) >= HOURLY:
        return {"error": f"You've sent ideas {HOURLY} times in the last hour: wait, and offer them together."}
    phones = store.devices
    if not phones:
        return {"error": "No iPhone is paired with Redde's notifications here, so the ideas can't reach them. Tell "
                         "them in words instead."}
    made = core.ideas_note(profile, name, kept, uuid.uuid4().hex[:16])
    quiet_if_ignored(home, profile, made)   # (left alone set after set: quietly, 1.36.0)
    away = made if made.get("z") else {**made, "z": "away"}   # (the devices not in use, quietly: 1.42.0)
    sends = [(d, made) for d in store.where_you_are(phones, "ideas")] + [(d, away) for d in store.elsewhere(phones, "ideas")]
    sent = 0
    for device, words in sends:
        try:
            core.push(device, words, ttl=TTL)
            sent += 1
        except core.Gone:
            store.remove(device["id"])
            log.info("redde-push: %s is no longer registered; forgotten", device.get("name"))
        except Exception as error:   # the network, the relay, Apple: let it go
            log.warning("redde-push: couldn't send ideas to %s: %s", device.get("name"), error)
    if not sent:
        return {"error": "The ideas didn't go through: the relay or Apple didn't take them. Tell them in words "
                         "instead, or try later."}
    remember(home, profile, now)
    return {"sent": f"{len(kept)} idea{'s' if len(kept) != 1 else ''} are on their iPhone. Nothing more to do now: "
                    "one they take comes back to you as their message.", "phones": sent}


def register(ctx, home_of, store_in) -> None:
    """Offers `suggest_to_user` once a phone is paired for notifications."""

    def offered() -> bool:
        try:
            return bool(store_in(caller(home_of())[1]).devices)
        except Exception:
            return False
    offered.__qualname__ = "redde_ideas_offered"
    try:
        from tools.registry import no_cache_check_fn
        no_cache_check_fn(offered)
    except Exception:
        pass

    def handle(args, **kwargs) -> str:
        args = args if isinstance(args, dict) else {}
        home = Path(home_of())
        profile, main = caller(home)
        return json.dumps(offer(store_in(main), main, profile, Stores(main).name(home, profile), args.get("ideas")))

    idea = {"type": "object", "properties": {"title": {"type": "string", "description": TITLE},
                                             "why": {"type": "string", "description": WHY},
                                             "request": {"type": "string", "description": REQUEST}},
            "required": ["title", "request"]}
    schema = {"name": TOOL, "description": DESCRIPTION,
              "parameters": {"type": "object",
                             "properties": {"ideas": {"type": "array", "items": idea, "maxItems": MOST, "description": IDEAS}},
                             "required": ["ideas"]}}
    ctx.register_tool(name=TOOL, toolset=TOOLSET, schema=schema, handler=handle, check_fn=offered, emoji="💡")

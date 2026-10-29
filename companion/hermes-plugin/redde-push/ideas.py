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
    kept = cleaned(ideas)
    if not kept:
        return {"error": "No ideas to send: give each one a \"request\" (and a \"title\")."}
    if len(sent_lately(home, profile, now)) >= HOURLY:
        return {"error": f"You've sent ideas {HOURLY} times in the last hour: wait, and offer them together."}
    phones = store.devices
    if not phones:
        return {"error": "No iPhone is paired with Redde's notifications here, so the ideas can't reach them. Tell "
                         "them in words instead."}
    made = core.ideas_note(profile, name, kept, uuid.uuid4().hex[:16])
    sent = 0
    for device in phones:
        try:
            core.push(device, made, ttl=TTL)
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

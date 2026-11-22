"""Things to keep in mind (1.36.0, 2026-11-22): what is always true for the person, said once and
checked whenever it matters. The example the owner brought (someone else's agent, pasted into the
chat): "Whenever I drive across the border, I have to buy a special 3-day car insurance policy." A heads-up for
tonight's hotel over the border should say that Wednesday's policy runs out before tomorrow's
checkout, and that no newer one turned up. That isn't a trigger nobody could have written; it is a
fact the agent was told once, and two things on the calendar read together.

So each fact is kept here, in the main home, for every agent (`redde_fact`, or Redde's Settings ›
Your Day › Things to Keep in Mind), and the runs that plan ahead (Heads-Ups, Morning Ideas, the
Week Ahead) are told them with what to do with them: look at the days around each event too (the
trip before it, the stay after), for anything one of the facts makes the person need, or that
runs out before the event is over, and check their mail and calendar for it. A person's message
that sounds like one ("always", "whenever I", "every time I") is told it can be kept.

Hermes's own memory reaches chats, not scheduled runs, and isn't one list for every bot; these
are few and short, and the person sees and changes every one of them in Redde.
"""
from __future__ import annotations

import json
import re
import threading
import time
from pathlib import Path

from . import core

TOOLSET = "redde_ideas"
TOOL = "redde_fact"
FILE = "facts.json"
MOST = 40
LONGEST = 240
ACTIONS = ("add", "remove", "list")
_lock = threading.Lock()

DESCRIPTION = (
    "Keeps something that is always true for the user, for Redde's runs that plan ahead (Heads-Ups, Morning Ideas, "
    "the Week Ahead) to check whenever it matters: a rule of their life, not an event (\"Driving into France I need "
    "3-day car insurance\", \"Pickles needs his jab every March\", \"I can't do calls before 9\"). Add one when they "
    "tell you something like that and want it remembered, in their words, one fact each; remove one they say no "
    "longer holds. They see and change the list in Redde.")

#: The runs that plan ahead, by how Redde's prompts start (MorningIdeasView.swift).
PLANNING = re.compile(r"^\s*(Heads-ups, \d+ minutes before\.|Morning ideas\.|Week ahead for the user\.)", re.I)

#: A person's message that sounds like a standing fact.
_STANDING = re.compile(
    r"\b(whenever i|every time i|each time i|always (need|have to|must|forget)|i always\b|remember (that|this)|"
    r"keep in mind|don't let me forget|never let me)\b", re.I)

NOTE = (f"[Redde: this may be something always true for them. If they'd like it kept, keep it with {TOOL} action "
        "\"add\" (in their words, one fact each) and say so in a few words: Redde's Heads-Ups and Morning Ideas "
        "will check it whenever it matters.]")


def path(home: Path) -> Path:
    return Path(home) / "redde-push" / FILE


def load(home: Path) -> list[dict]:
    try:
        kept = json.loads(path(home).read_text())
    except Exception:
        return []
    return [f for f in kept if isinstance(f, dict) and str(f.get("t") or "").strip()] if isinstance(kept, list) else []


def _save(home: Path, facts: list[dict]) -> None:
    file = path(home)
    file.parent.mkdir(parents=True, exist_ok=True)
    tmp = file.with_suffix(".new")
    tmp.write_text(json.dumps(facts[:MOST], ensure_ascii=False))
    tmp.replace(file)


def texts(home: Path) -> list[str]:
    return [str(f["t"]) for f in load(home)]


def _same(a: str, b: str) -> bool:
    return " ".join(a.lower().split()).strip(" .") == " ".join(b.lower().split()).strip(" .")


def add(home: Path, text: str, by: str = "", now: float | None = None) -> dict:
    text = core.clipped(" ".join(str(text or "").split()), LONGEST)
    if len(text) < 4:
        return {"error": "Say the fact, as \"text\"."}
    with _lock:
        facts = load(home)
        if any(_same(f["t"], text) for f in facts):
            return {"kept": text, "said": "That's already kept."}
        if len(facts) >= MOST:
            return {"error": f"There are already {MOST}: ask them which to let go first."}
        facts.append({"t": text, "at": int(now or time.time()), **({"by": by} if by else {})})
        _save(home, facts)
    return {"kept": text, "said": "Kept. Tell them in a few words."}


def remove(home: Path, which: str) -> dict:
    which = str(which or "").strip()
    with _lock:
        facts = load(home)
        left = [f for i, f in enumerate(facts, 1)
                if not (_same(f["t"], which) or (which.isdigit() and int(which) == i))]
        if len(left) == len(facts):
            return {"error": "No such fact: call action \"list\" for them."}
        _save(home, left)
    return {"removed": len(facts) - len(left)}


def change(home: Path, args: dict, by: str = "") -> dict:
    action = str(args.get("action") or "")
    if action == "add":
        return add(home, args.get("text"), by)
    if action == "remove":
        return remove(home, args.get("text"))
    if action == "list":
        return {"facts": [f"{i}. {t}" for i, t in enumerate(texts(home), 1)]}
    return {"error": f"\"action\" is one of {', '.join(ACTIONS)}."}


def _text(message) -> str:
    if isinstance(message, str):
        return message
    if isinstance(message, list):
        return " ".join(str(p.get("text") or "") for p in message if isinstance(p, dict))
    return ""


def run_note(home: Path, message, platform: str = "") -> str | None:
    """For `pre_llm_call`: a run that plans ahead, told what is always true for them and how to
    use it."""
    if platform != "cron" or not PLANNING.match(_text(message)):
        return None
    kept = texts(home)
    if not kept:
        return None
    return ("[Redde: things always true for them, which they asked you to keep in mind: "
            + "; ".join(f"\"{t}\"" for t in kept[:MOST])
            + ". For each event you look at, read the days around it too (the calendar from three days before to three "
              "days after: a trip before it, a stay after it), and ask of each fact whether it makes them need "
              "something for this event, or whether something they have runs out before the event is over. Check "
              "their mail and calendar for it (a booking, a policy, a confirmation) before you say so. If it's "
              "missing or runs out, say it plainly in that event's heads-up or idea: what, until when, and what to "
              "do, with a link when you have one. Say nothing about a fact that doesn't bear on it.]")


def turn_note(message, platform: str = "") -> str | None:
    """For `pre_llm_call`: a person's message that sounds like a standing fact."""
    if platform in ("cron", "subagent", "bot_room"):
        return None
    text = _text(message)
    if not text or text.lstrip().startswith("[") or not _STANDING.search(text):
        return None
    return NOTE


def register(ctx, home_of) -> None:
    """Offers `redde_fact`, with the other Redde tools of its kind. The facts are the main home's,
    whichever bot asks."""
    from .calls import caller

    def handle(args, **kwargs) -> str:
        profile, root = caller(Path(home_of()))
        return json.dumps(change(root, args if isinstance(args, dict) else {}, by=profile), ensure_ascii=False)

    schema = {"name": TOOL, "description": DESCRIPTION,
              "parameters": {"type": "object",
                             "properties": {"action": {"type": "string", "enum": list(ACTIONS)},
                                            "text": {"type": "string",
                                                     "description": "The fact, in their words (add); the fact or its number (remove)"}},
                             "required": ["action"]}}
    ctx.register_tool(name=TOOL, toolset=TOOLSET, schema=schema, handler=handle, emoji="📌")

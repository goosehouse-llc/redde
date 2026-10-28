"""Follow-ups: a loose end the person mentions in passing ("I'll call the plumber tomorrow",
"remind me to look at that later") comes back to them when it is due, as an idea card they take
or put away (asked 2026-10-28, after Meta's Muse, which suggests from what it remembers).

When a message sounds like one, and only then, the turn is told the agent may set a follow-up
(`turn_note`): a few words in that turn alone, so every other prompt stays as it was. The agent
calls `follow_up_later` with what it is, when, and what it could do then. That makes a Hermes cron
job that runs once at that time, named `[redde-followup:<id>] <what>`, whose prompt has the agent
offer it with `suggest_to_user` (`ideas.py`) unless it is plainly done.
"""

from __future__ import annotations

import json
import re
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .calls import caller

TOOLSET = "redde_ideas"
TOOL = "follow_up_later"
TAG = "[redde-followup:"
#: At most this many waiting, per agent, and this far ahead.
MOST = 30
AHEAD = timedelta(days=60)

#: What sounds like something to do later, in English: cheap to look for, said in a turn's note only.
_LOOSE_END = re.compile(
    r"\b(i'?ll|i will|i need to|i have to|i must|i should|i ought to|i'm going to|i am going to|remind me|"
    r"don'?t let me forget|need to remember|later today|later on|tomorrow|tonight|this weekend|next week|"
    r"by (monday|tuesday|wednesday|thursday|friday|saturday|sunday)|on (monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b",
    re.IGNORECASE)

NOTE = ("[Redde: the user may have mentioned something to do later. If it is a real loose end they haven't asked "
        "you to handle now, you may set a follow-up with the follow_up_later tool (find it with tool_search if it "
        "isn't among your tools) for when it's due: they get it back then as an idea card to take or put away. "
        "If you set one, say so in a few words. Don't set one for what you're doing now.]")

DESCRIPTION = (
    "Sets a follow-up for a loose end the user mentioned (\"I'll call the plumber tomorrow\"): at the time given, "
    "you are asked to offer it back to them as an idea card on their iPhone, through Redde, which they take or put "
    "away; if it is plainly done by then, nothing is offered. For what they mean to do later, not for what they "
    "asked you to do now, and not as an alarm (an alarm rings; this offers a card).")
ABOUT = "What it is, in a few words, as the card's heading (\"Call the plumber\")."
WHEN = ("When to offer it: a date and time with its UTC offset, ISO 8601 (\"2026-10-29T09:00:00-04:00\"), in the "
        "user's time. Mornings work well for things due that day.")
REQUEST = ("What you could do for them then, as they would ask you (\"Find the plumber's number and remind me to "
           "call before lunch\").")


def turn_note(home: Path, store_in, message, platform: str = "") -> str | None:
    """For `pre_llm_call`: a person's message that sounds like a loose end, where a follow-up can
    reach a phone. Not in a scheduled run, nor a bot's turn in a group chat."""
    if platform in ("cron", "subagent", "bot_room"):
        return None
    text = message if isinstance(message, str) else " ".join(
        str(p.get("text") or "") for p in message or [] if isinstance(p, dict)) if isinstance(message, list) else ""
    if not text or text.lstrip().startswith("[") or not _LOOSE_END.search(text):
        return None
    try:
        return NOTE if store_in(caller(home)[1]).devices else None
    except Exception:
        return None


def waiting(home: Path) -> int:
    try:
        data = json.loads((Path(home) / "cron" / "jobs.json").read_text())
    except (OSError, ValueError):
        return 0
    jobs = data.get("jobs") if isinstance(data, dict) else data
    return sum(1 for j in jobs or [] if isinstance(j, dict) and str(j.get("name") or "").startswith(TAG))


def when_of(text: str, now: datetime | None = None) -> datetime | str:
    """The moment given, or why it won't do."""
    try:
        moment = datetime.fromisoformat(str(text).strip().replace("Z", "+00:00"))
    except ValueError:
        return "\"when\" must be a date and time like 2026-10-29T09:00:00-04:00."
    if moment.tzinfo is None:
        return "\"when\" needs its UTC offset (2026-10-29T09:00:00-04:00), so it is the user's time."
    now = now or datetime.now(timezone.utc)
    if moment <= now:
        return "\"when\" is in the past: give a time still to come."
    if moment - now > AHEAD:
        return "\"when\" is more than 60 days off: set a follow-up nearer the time."
    return moment


def prompt(follow: str, about: str, request: str, set_on: str) -> str:
    return (f"{TAG}{follow}] Follow-up for the user, set {set_on}: {about}. If it still needs doing, offer it with "
            f"suggest_to_user: title \"{about}\", why a few words on when they mentioned it, request \"{request}\". "
            "If it's plainly done already, offer nothing and stop. If suggest_to_user isn't among your tools, find it "
            "with tool_search first.")


def set_up(home: Path, about: str, when: str, request: str, make=None, now: datetime | None = None) -> dict:
    """Makes the job; what the tool answers. `make` is Hermes's `cron.jobs.create_job` (a stand-in in tests)."""
    about = " ".join(str(about or "").split())[:80]
    request = " ".join(str(request or "").split())[:300] or about
    if not about:
        return {"error": "Say what it is, as \"about\"."}
    moment = when_of(when, now)
    if isinstance(moment, str):
        return {"error": moment}
    if waiting(home) >= MOST:
        return {"error": f"There are already {MOST} follow-ups waiting: let some come due first."}
    if make is None:
        try:
            from cron.jobs import create_job as make
        except Exception:
            return {"error": "This Hermes can't schedule follow-ups (no cron). Tell them in words instead."}
    follow = uuid.uuid4().hex[:12]
    set_on = (now or datetime.now(timezone.utc)).astimezone(moment.tzinfo).strftime("%A %-d %B")
    make(prompt(follow, about, request, set_on), moment.isoformat(timespec="minutes"),
         name=f"{TAG}{follow}] {about}", deliver="local")
    return {"set": f"On {moment.strftime('%A %-d %B at %-H:%M')} you'll offer it back to them as an idea card. "
                   "Tell them in a few words that you will."}


def register(ctx, home_of, store_in) -> None:
    """Offers `follow_up_later` once a phone is paired, as `suggest_to_user` is."""

    def offered() -> bool:
        try:
            return bool(store_in(caller(home_of())[1]).devices)
        except Exception:
            return False
    offered.__qualname__ = "redde_followups_offered"
    try:
        from tools.registry import no_cache_check_fn
        no_cache_check_fn(offered)
    except Exception:
        pass

    def handle(args, **kwargs) -> str:
        args = args if isinstance(args, dict) else {}
        return json.dumps(set_up(Path(home_of()), args.get("about"), args.get("when"), args.get("request")))

    schema = {"name": TOOL, "description": DESCRIPTION,
              "parameters": {"type": "object",
                             "properties": {"about": {"type": "string", "description": ABOUT},
                                            "when": {"type": "string", "description": WHEN},
                                            "request": {"type": "string", "description": REQUEST}},
                             "required": ["about", "when"]}}
    ctx.register_tool(name=TOOL, toolset=TOOLSET, schema=schema, handler=handle, check_fn=offered, emoji="⏰")

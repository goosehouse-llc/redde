"""Heads-ups before events (asked 2026-10-28, after Meta's Muse, which comes back when it is time):
a few minutes before something on the person's calendar, a short note of what they need for it,
where it is, who is coming, what to bring, the weather if it is outdoors, as a notification.

Each morning a job the app sets up (Settings → Agent → Heads-Ups) has the agent look at the day
and call `heads_up_before` for each event worth one. That makes a Hermes cron job that runs once,
the given minutes before the event starts, named `[redde-notify] Heads-up: <event>`: its answer is
sent to the paired phones as any `[redde-notify]` job's is (`routines.py`) and kept there with the
person's other briefings. The same event and time asked twice makes one job.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .calls import caller
from .followups import when_of
from .routines import NOTIFY

TOOLSET = "redde_ideas"
TOOL = "heads_up_before"
PREFIX = f"{NOTIFY} Heads-up: "
#: At most this many waiting, and how far before an event one may come.
MOST = 20
LEADS = (5, 120)
DEFAULT_LEAD = 30

DESCRIPTION = (
    "Sets a heads-up before an event on the user's calendar: a few minutes before it starts, you are asked "
    "to tell them in two or three short lines what they need for it (where, who, what to bring or prepare, the "
    "weather if it's outdoors), and your answer reaches their iPhone as a notification, through Redde. One per "
    "event; the same event and time again makes no second one. For events today or soon, not for reminders "
    "of tasks (follow_up_later does those).")
EVENT = "The event as the calendar names it (\"Dentist\", \"Lunch with Ana\")."
STARTS = ("When it starts, ISO 8601 with its UTC offset, in the user's time (\"2026-10-29T14:30:00-04:00\").")
MINUTES = f"How many minutes before it starts to send the heads-up ({LEADS[0]} to {LEADS[1]}; {DEFAULT_LEAD} if not given)."
CHECK = ("What to look at then, as notes to yourself: the place, who is coming, what to bring, whether it is "
         "outdoors (\"at Dr. Lee's on Main St; bring the insurance card\").")


def name_of(event: str) -> str:
    return PREFIX + event


def prompt(event: str, starts: datetime, check: str) -> str:
    at = starts.strftime("%-H:%M")
    return (f"Heads-up for the user: \"{event}\" starts at {at} today. In two or three short lines, tell them what "
            f"they need for it now: where it is, who is coming, what to bring or prepare, the weather if it is "
            f"outdoors. {('Notes from this morning: ' + check + '. ') if check else ''}Check the calendar first: if "
            "it was cancelled or moved, say so in one line. Your answer is what they read, as a notification.")


def waiting(home: Path) -> list[dict]:
    try:
        data = json.loads((Path(home) / "cron" / "jobs.json").read_text())
    except (OSError, ValueError):
        return []
    jobs = data.get("jobs") if isinstance(data, dict) else data
    return [j for j in jobs or [] if isinstance(j, dict) and str(j.get("name") or "").startswith(PREFIX)]


def _next_run(job: dict) -> datetime | None:
    schedule = job.get("schedule") if isinstance(job.get("schedule"), dict) else {}
    for value in (job.get("next_run_at"), schedule.get("run_at")):
        try:
            moment = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def _near(moment: datetime | None, at: datetime) -> bool:
    """The same event's heads-up: due within three hours of this one (or of unknown time)."""
    return moment is None or abs((moment - at).total_seconds()) < 3 * 3600


def set_up(home: Path, event: str, starts: str, minutes=None, check: str = "", make=None,
           now: datetime | None = None) -> dict:
    """Makes the job; what the tool answers. `make` is Hermes's `cron.jobs.create_job` (a stand-in in tests)."""
    event = " ".join(str(event or "").split())[:80]
    check = " ".join(str(check or "").split())[:300]
    if not event:
        return {"error": "Say which event, as \"event\"."}
    moment = when_of(starts, now)
    if isinstance(moment, str):
        return {"error": moment.replace("\"when\"", "\"starts\"")}
    try:
        lead = int(minutes) if minutes not in (None, "") else DEFAULT_LEAD
    except (TypeError, ValueError):
        lead = DEFAULT_LEAD
    lead = max(LEADS[0], min(LEADS[1], lead))
    now = now or datetime.now(timezone.utc)
    at = max(moment - timedelta(minutes=lead), now + timedelta(minutes=1))
    schedule = at.isoformat(timespec="minutes")
    jobs = waiting(home)
    if any(j.get("name") == name_of(event) and _near(_next_run(j), at) for j in jobs):
        return {"set": "A heads-up for it is already set."}
    if len(jobs) >= MOST:
        return {"error": f"There are already {MOST} heads-ups waiting."}
    if make is None:
        try:
            from cron.jobs import create_job as make
        except Exception:
            return {"error": "This Hermes can't schedule heads-ups (no cron)."}
    make(prompt(event, moment, check), schedule, name=name_of(event), deliver="local")
    return {"set": f"A heads-up for \"{event}\" comes at {at.strftime('%-H:%M')}."}


def register(ctx, home_of, store_in) -> None:
    """Offers `heads_up_before` once a phone is paired, as `suggest_to_user` is."""

    def offered() -> bool:
        try:
            return bool(store_in(caller(home_of())[1]).devices)
        except Exception:
            return False
    offered.__qualname__ = "redde_headsup_offered"
    try:
        from tools.registry import no_cache_check_fn
        no_cache_check_fn(offered)
    except Exception:
        pass

    def handle(args, **kwargs) -> str:
        args = args if isinstance(args, dict) else {}
        return json.dumps(set_up(Path(home_of()), args.get("event"), args.get("starts"), args.get("minutes"), args.get("check") or ""))

    schema = {"name": TOOL, "description": DESCRIPTION,
              "parameters": {"type": "object",
                             "properties": {"event": {"type": "string", "description": EVENT},
                                            "starts": {"type": "string", "description": STARTS},
                                            "minutes": {"type": "integer", "description": MINUTES},
                                            "check": {"type": "string", "description": CHECK}},
                             "required": ["event", "starts"]}}
    ctx.register_tool(name=TOOL, toolset=TOOLSET, schema=schema, handler=handle, check_fn=offered, emoji="🔔")

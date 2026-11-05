"""Goals: something the person wants to reach over weeks ("run a 10K by March", "save $2,000 for
the trip"), with a plan, check-ins on a schedule and their progress on the phone (asked 2026-11-02,
after Meta's Muse, whose goals are its signature; Redde 2.4).

The agent proposes a short plan, the person agrees, and the agent calls `redde_goal` with action
"set". That keeps the goal in this profile's `redde-push/goals.json`, puts each step on the Hermes
Kanban board as a card in triage (tenant `redde-goal-<id>`, so no worker starts on it before the
person approves it in Redde) where this Hermes has a board, and makes a cron job that checks in on
it, named `[redde-goal:<id>] <title>` and delivered "local". Each check-in's answer starts with a
line `PROGRESS: <done>/<steps> | <headline> | <next>`, which the schedules' reader (`routines.py`)
keeps here and sends to the phones as a briefing with the goal's id (`o`) and progress (`q`).

Hermes has a `/goal` command and Kanban `goal_mode` of its own (a chat kept working until a goal is
met): unrelated, and the agent is told not to use them for these.

A turn is told about goals only when the person's message sounds like one (`turn_note`), and a
check-in's turn its own goal's steps (`checkin_note`); every other prompt stays as it was.
"""

from __future__ import annotations

import json
import os
import re
import time
import uuid
from contextlib import contextmanager
from datetime import date, datetime, timedelta
from pathlib import Path

TOOLSET = "redde_ideas"
TOOL = "redde_goal"
TAG = "[redde-goal:"
FILE = "goals.json"
#: At most this many goals at once per agent, and steps per goal.
MOST, STEPS = 12, 12
#: The default check-ins (his pick 2026-11-02): Mondays at 9:00, or every other day at 9:00 when
#: the goal is under two weeks away.
WEEKLY, OTHER_DAY, DAILY = "0 9 * * 1", "0 9 */2 * *", "0 9 * * *"
SOON = timedelta(days=14)
EVERY = {"weekly": WEEKLY, "other_day": OTHER_DAY, "daily": DAILY}
_ID = re.compile(r"\[redde-goal:([A-Za-z0-9_-]{1,40})\]")
#: The check-in's first line: "PROGRESS: 3/7 | Ran 5K on Saturday | Book the race".
_PROGRESS = re.compile(r"^\W*progress\W*:?\s*(\d{1,3})\s*/\s*(\d{1,3})[*_\s]*(?:\|\s*([^|\n]*?)\s*)?(?:\|\s*([^\n]*?)\s*)?\W*$",
                       re.IGNORECASE | re.MULTILINE)

#: What sounds like a goal, in English: cheap to look for, said in a turn's note only.
_GOALISH = re.compile(
    r"\b(?:my goal is|set (?:a|me a|up a) goal|new goal|a goal (?:of|to|for)|"
    r"i(?: want| need| hope| plan|'d like|’d like| would like) to .{3,80}?\b(?:by|before) (?:the end of |end of )?"
    r"(?:\d|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|next|this|spring|summer|fall|autumn|winter|christmas)[a-z]*|my )|"
    r"i(?: want| need| hope| plan|'d like|’d like| would like) to .{3,80}?\bwithin (?:a|\d+|two|three|six) (?:days?|weeks?|months?|years?)|"
    r"help me (?:get to|reach|hit|train for|prepare for|get ready for|save (?:up )?for|stick to|work towards?)|"
    r"track my progress|keep me on track|hold me accountable|i'?m (?:training|saving up|studying) for)\b",
    re.IGNORECASE)

NOTE = (f"[Redde: this may be a goal. If they want help reaching it, propose a short plan (3-7 steps) and when you'll "
        "check in (default: Mondays at 9:00, every other day if it's under two weeks away), ask them to confirm with "
        f"your question tool, and once they agree call {TOOL} with action \"set\" (find it with tool_search if it isn't "
        "among your tools). Not Hermes's /goal command.]")

DESCRIPTION = (
    "The user's goals in Redde: something to reach over days or weeks, with a plan, check-ins on a schedule and "
    "progress on their iPhone. 'set' (after they agree to the plan: title, by, steps, every), 'update' (id; done: "
    "step numbers now done; add: new steps; by; every), 'status' (all, or one id), 'end' (id). Not Hermes's /goal.")


# ---- the file ------------------------------------------------------------------------------------

def path(home: Path) -> Path:
    return Path(home) / "redde-push" / FILE


@contextmanager
def _locked(home: Path):
    """Held while goals.json is read and written: the agent's tool and the schedules' reader may
    both be at it, from two processes."""
    folder = Path(home) / "redde-push"
    folder.mkdir(parents=True, exist_ok=True)
    handle = open(os.open(folder / "goals.lock", os.O_WRONLY | os.O_CREAT, 0o600), "w")
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
    goals = data.get("goals") if isinstance(data, dict) else data
    return [g for g in goals or [] if isinstance(g, dict) and g.get("id")]


def save(home: Path, goals: list[dict]) -> None:
    target = path(home)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps({"goals": goals}, ensure_ascii=False, indent=1))
    os.chmod(temporary, 0o600)
    os.replace(temporary, target)


def _jobs(home: Path) -> list[dict] | None:
    """The profile's cron jobs, or None when its store can't be read (then nothing is concluded
    from a job not being there)."""
    try:
        data = json.loads((Path(home) / "cron" / "jobs.json").read_text())
    except FileNotFoundError:
        return []
    except (OSError, ValueError):
        return None
    jobs = data.get("jobs") if isinstance(data, dict) else data
    return [j for j in jobs or [] if isinstance(j, dict)]


def _expr(job: dict) -> str:
    schedule = job.get("schedule")
    if isinstance(schedule, dict):
        return str(schedule.get("expr") or schedule.get("display") or job.get("schedule_display") or "")
    return str(schedule or job.get("schedule_display") or "")


def sweep(home: Path, jobs: list[dict] | None = None) -> list[dict]:
    """The goals still going, kept in step with their check-in jobs, which are the truth: a goal
    whose job is gone (Redde's End Goal deletes it, over either connection) is ended, and one
    whose job's schedule was changed (Redde's check-in picker edits the job alone) takes it."""
    jobs = _jobs(home) if jobs is None else jobs
    with _locked(home):
        goals = load(home)
        if jobs is None:
            return [g for g in goals if not g.get("ended")]
        by_goal = {goal_id(str(j.get("name") or "")): j for j in jobs if is_goal(j)}
        changed = False
        for kept in goals:
            if kept.get("ended"):
                continue
            job = by_goal.get(kept["id"])
            if job is None:
                kept["ended"], changed = int(time.time()), True
                continue
            expr, job_id = _expr(job), str(job.get("id") or "")
            if expr and expr != kept.get("every"):
                kept["every"], changed = expr, True
            if job_id and job_id != kept.get("job"):
                kept["job"], changed = job_id, True
        if changed:
            save(home, goals)
    return [g for g in goals if not g.get("ended")]


def goal_id(text: str) -> str | None:
    match = _ID.search(text or "")
    return match.group(1) if match else None


def is_goal(job: dict) -> bool:
    return str(job.get("name") or "").startswith(TAG)


def title(name: str) -> str:
    return name.split("]", 1)[1].strip() if name.startswith(TAG) and "]" in name else name


# ---- what a check-in said ------------------------------------------------------------------------

def progress(answer: str) -> tuple[dict | None, str]:
    """The PROGRESS line of a check-in's answer, as {done, total, headline, next}, and the answer
    without it. None when there is no such line."""
    text = (answer or "").strip()
    match = _PROGRESS.search(text)
    if not match:
        return None, text
    done, total = int(match.group(1)), int(match.group(2))
    found = {"done": min(done, total) if total else done, "total": total,
             "headline": (match.group(3) or "").strip(" *_"), "next": (match.group(4) or "").strip(" *_")}
    rest = (text[:match.start()] + text[match.end():]).strip()
    return found, rest


def remember(home: Path, goal: str, found: dict, at: float | None = None) -> bool:
    """Keeps a check-in's progress on the goal; whether there was such a goal."""
    with _locked(home):
        goals = load(home)
        for kept in goals:
            if kept.get("id") == goal:
                kept["progress"] = {**found, "at": int(at or time.time())}
                save(home, goals)
                return True
    return False


# ---- turn notes ----------------------------------------------------------------------------------

def _text(message) -> str:
    if isinstance(message, str):
        return message
    if isinstance(message, list):
        return " ".join(str(p.get("text") or "") for p in message if isinstance(p, dict))
    return ""


def turn_note(message, platform: str = "") -> str | None:
    """For `pre_llm_call`: a person's message that sounds like a goal. Not a scheduled run, nor a
    bot's turn in a group chat."""
    if platform in ("cron", "subagent", "bot_room"):
        return None
    text = _text(message)
    if not text or text.lstrip().startswith("[") or not _GOALISH.search(text):
        return None
    return NOTE


def checkin_note(home: Path, message, platform: str = "", board=None) -> str | None:
    """For `pre_llm_call`: a goal's check-in starts. It is told the goal's steps, how each stands
    (from the Kanban board, where they are cards), what it said last time, and how to answer."""
    if platform and platform != "cron":
        return None
    found = goal_id(_text(message))
    if not found:
        return None
    kept = next((g for g in sweep(home) if g.get("id") == found), None)
    if kept is None:
        return None
    statuses = _card_statuses(found, board)
    steps = kept.get("steps") or []
    lines = []
    for number, step in enumerate(steps, 1):
        status = statuses.get(str(step.get("card") or "")) or ("done" if step.get("done") else "to do")
        lines.append(f"{number}. {step.get('title')} ({status})")
    last = kept.get("progress") or {}
    said = (f" Last check-in: {last.get('done')}/{last.get('total')}, \"{last.get('headline')}\"." if last else "")
    by = f" Target: {kept['by']}." if kept.get("by") else ""
    late = (" The target date has passed: ask them whether to end it or set a new date."
            if kept.get("by") and str(kept["by"]) < date.today().isoformat() else "")
    return (f"[Redde: goal \"{kept.get('title')}\".{by}{said} Steps: " + "; ".join(lines) + f".{late} "
            "Check how it is going with your tools and what you know. Start your answer with one line exactly "
            "\"PROGRESS: <steps done>/<steps> | <a few words on how it's going> | <the next step>\", then at most "
            f"three short lines for them. Mark finished steps with {TOOL} action \"update\". Anything that needs "
            "their approval or a choice, offer with suggest_to_user. Not Hermes's /goal command.]")


# ---- the Kanban board (where this Hermes has one) ------------------------------------------------

@contextmanager
def _board_conn():
    """(kanban module, connection) on this profile's board. Raises where there is none."""
    from hermes_cli import kanban_db as kb
    try:
        from hermes_cli import kanban_db_connect as connector   # 0.21.3 and later
        conn = connector.connect()
    except ImportError:
        conn = kb.connect()                                      # 0.21.0
    try:
        yield kb, conn
    finally:
        try:
            conn.close()
        except Exception:
            pass


def _make_cards(goal: str, steps: list[str], assignee: str, body: str, board=None, first: int = 1) -> list[str | None]:
    """A card in triage for each step, under tenant `redde-goal-<id>`, or None each where there is
    no board here (or it refused). `board` stands in for `_board_conn` in tests."""
    try:
        with (board or _board_conn)() as (kb, conn):
            made = []
            for number, step in enumerate(steps, first):
                made.append(str(kb.create_task(conn, title=step, body=body, assignee=assignee,
                                               tenant=f"redde-goal-{goal}", triage=True,
                                               idempotency_key=f"redde-goal-{goal}-{number}")))
            return made
    except Exception:
        return [None] * len(steps)


def _card_statuses(goal: str, board=None) -> dict[str, str]:
    try:
        with (board or _board_conn)() as (kb, conn):
            return {str(t.id): str(t.status) for t in kb.list_tasks(conn, tenant=f"redde-goal-{goal}")}
    except Exception:
        return {}


# ---- the tool's actions --------------------------------------------------------------------------

def schedule_for(by: str | None, every: str | None = None, today: date | None = None) -> str:
    """The check-ins' cron expression: one asked for by name or as cron, else the default."""
    every = str(every or "").strip()
    if every in EVERY:
        return EVERY[every]
    if every and len(every.split()) == 5 and re.fullmatch(r"[\d*/,\- ]+", every):
        return every
    try:
        target = date.fromisoformat(str(by)[:10]) if by else None
    except ValueError:
        target = None
    if target and target - (today or date.today()) < SOON:
        return OTHER_DAY
    return WEEKLY


def prompt(goal: str, what: str) -> str:
    return (f"{TAG}{goal}] Check-in on the user's goal: {what}. See how it is going with your tools and what you "
            "know, then answer as the turn's note says: the PROGRESS line first, then a few short lines for them.")


def set_up(home: Path, profile: str, what: str, by: str | None = None, steps=None, every: str | None = None,
           make=None, board=None, today: date | None = None) -> dict:
    """Makes the goal, its cards and its check-in job; what the tool answers. `make` is Hermes's
    `cron.jobs.create_job` (a stand-in in tests)."""
    what = " ".join(str(what or "").split())[:80]
    if not what:
        return {"error": "Say what the goal is, as \"title\"."}
    if by:
        try:
            by = date.fromisoformat(str(by)[:10]).isoformat()
        except ValueError:
            return {"error": "\"by\" must be a date like 2026-03-01."}
    planned = [" ".join(str(s or "").split())[:120] for s in (steps or []) if str(s or "").strip()][:STEPS]
    if len(sweep(home)) >= MOST:
        return {"error": f"There are already {MOST} goals: ask them which to end first."}
    if make is None:
        try:
            from cron.jobs import create_job as make
        except Exception:
            return {"error": "This Hermes can't schedule check-ins (no cron). Tell them in words instead."}
    goal = uuid.uuid4().hex[:10]
    schedule = schedule_for(by, every, today)
    cards = _make_cards(goal, planned, profile, f"A step toward the user's goal \"{what}\" (Redde).", board)
    job = make(prompt(goal, what), schedule, name=f"{TAG}{goal}] {what}", deliver="local")
    kept = {"id": goal, "title": what, "by": by, "every": schedule, "profile": profile,
            "job": str((job or {}).get("id") or "") if isinstance(job, dict) else "",
            "steps": [{"title": s, "card": c, "done": False} for s, c in zip(planned, cards)],
            "made": int(time.time())}
    with _locked(home):
        goals = load(home)
        goals.append(kept)
        save(home, goals)
    on_board = any(cards)
    return {"set": goal, "check_ins": schedule,
            "said": ("The plan is on the Kanban board, waiting for them to approve each step in Redde. " if on_board else "")
                    + "Tell them in a few words when you'll check in."}


def update(home: Path, goal: str, done=None, add=None, by: str | None = None, every: str | None = None,
           board=None, edit=None) -> dict:
    """Steps done or added, a new date or new check-ins. `edit` is Hermes's `cron.jobs.update_job`."""
    with _locked(home):
        goals = load(home)
        kept = next((g for g in goals if g.get("id") == goal), None)
        if kept is None:
            return {"error": f"No goal {goal}: call {TOOL} with action \"status\" for their ids."}
        steps = kept.setdefault("steps", [])
        for number in done or []:
            try:
                steps[int(number) - 1]["done"] = True
            except (ValueError, TypeError, IndexError):
                pass
        added = [" ".join(str(s or "").split())[:120] for s in (add or []) if str(s or "").strip()][:max(0, STEPS - len(steps))]
        if added:
            # (their cards' idempotency keys follow on from the steps already there)
            cards = _make_cards(goal, added, str(kept.get("profile") or "default"),
                                f"A step toward the user's goal \"{kept.get('title')}\" (Redde).", board, first=len(steps) + 1)
            steps += [{"title": s, "card": c, "done": False} for s, c in zip(added, cards)]
        if by:
            try:
                kept["by"] = date.fromisoformat(str(by)[:10]).isoformat()
            except ValueError:
                return {"error": "\"by\" must be a date like 2026-03-01."}
        if every:
            kept["every"] = schedule_for(kept.get("by"), every)
            if kept.get("job"):
                try:
                    if edit is None:
                        from cron.jobs import update_job as edit
                    edit(kept["job"], {"schedule": kept["every"]})
                except Exception:
                    pass
        save(home, goals)
    total, finished = len(steps), sum(1 for s in steps if s.get("done"))
    return {"updated": goal, "steps_done": f"{finished}/{total}"}


def status(home: Path, goal: str | None = None) -> dict:
    goals = [g for g in sweep(home) if not goal or g.get("id") == goal]
    return {"goals": [{"id": g["id"], "title": g.get("title"), "by": g.get("by"), "check_ins": g.get("every"),
                       "steps": [f"{i}. {s.get('title')}{' (done)' if s.get('done') else ''}"
                                 for i, s in enumerate(g.get("steps") or [], 1)],
                       "progress": g.get("progress")} for g in goals]}


def end(home: Path, goal: str, remove=None) -> dict:
    """Ends a goal: its check-ins stop, its job deleted from the profile's own store. `remove` is
    Hermes's `cron.jobs.remove_job` (a stand-in in tests)."""
    with _locked(home):
        goals = load(home)
        kept = next((g for g in goals if g.get("id") == goal), None)
        if kept is None:
            return {"error": f"No goal {goal}."}
        kept["ended"] = int(time.time())
        save(home, goals)
    job = next((str(j.get("id")) for j in _jobs(home) or [] if goal_id(str(j.get("name") or "")) == goal and j.get("id")),
               kept.get("job"))
    if job:
        try:
            if remove is None:
                from cron import jobs as cron
                with cron.use_cron_store(home):
                    cron.remove_job(job)
            else:
                remove(job)
        except Exception:
            pass
    return {"ended": goal, "said": "Its check-ins have stopped. Tell them in a few words."}


# ---- for the app: every agent's goals ------------------------------------------------------------

def listing(stores) -> list[dict]:
    """Every profile's goals, newest progress first, for `/redde-push goals list`. A check-in that
    ran since its progress was kept (no phone paired, so the schedules' reader didn't) is read now."""
    found = []
    for profile, home in stores.homes():
        if not path(home).exists():
            continue
        listed = _jobs(home)
        goals = sweep(home, listed)   # (ended where its job is gone; its schedule the job's)
        if not goals:
            continue
        jobs = {goal_id(str(j.get("name") or "")): j for j in listed or [] if is_goal(j)}
        for kept in goals:
            job = jobs.get(kept["id"]) or {}
            last = kept.get("progress") or {}
            ran = _seconds(job.get("last_run_at"))
            if job.get("id") and ran and ran > float(last.get("at") or 0):
                read, _ = progress(stores.output(home, str(job["id"])))
                if read:
                    last = {**read, "at": int(ran)}
            found.append({"id": kept["id"], "profile": profile, "title": kept.get("title"), "by": kept.get("by"),
                          "every": kept.get("every"), "job": str(job.get("id") or kept.get("job") or ""),
                          "next": job.get("next_run_at"), "paused": job.get("state") == "paused" or job.get("enabled") is False,
                          "steps": [{"title": s.get("title"), "card": s.get("card"), "done": bool(s.get("done"))}
                                    for s in kept.get("steps") or []],
                          "progress": last or None})
    return found


def _seconds(text) -> float | None:
    try:
        return datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp() if text else None
    except ValueError:
        return None


def register(ctx, home_of) -> None:
    """Offers `redde_goal`, deferred with the other Redde tools of its kind."""
    from .calls import caller

    def handle(args, **kwargs) -> str:
        args = args if isinstance(args, dict) else {}
        home = Path(home_of())
        action = str(args.get("action") or "status")
        if action == "set":
            said = set_up(home, caller(home)[0], args.get("title"), args.get("by"), args.get("steps"), args.get("every"))
        elif action == "update":
            said = update(home, str(args.get("id") or ""), args.get("done"), args.get("add"), args.get("by"), args.get("every"))
        elif action == "end":
            said = end(home, str(args.get("id") or ""))
        else:
            said = status(home, args.get("id"))
        return json.dumps(said)

    schema = {"name": TOOL, "description": DESCRIPTION,
              "parameters": {"type": "object",
                             "properties": {"action": {"type": "string", "enum": ["set", "update", "status", "end"]},
                                            "id": {"type": "string"},
                                            "title": {"type": "string"},
                                            "by": {"type": "string", "description": "YYYY-MM-DD"},
                                            "steps": {"type": "array", "items": {"type": "string"}},
                                            "done": {"type": "array", "items": {"type": "integer"}},
                                            "add": {"type": "array", "items": {"type": "string"}},
                                            "every": {"type": "string", "description": "weekly, other_day, daily or cron"}},
                             "required": ["action"]}}
    ctx.register_tool(name=TOOL, toolset=TOOLSET, schema=schema, handler=handle, emoji="🎯")

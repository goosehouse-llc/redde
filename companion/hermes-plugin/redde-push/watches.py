"""Watches: something the agent keeps an eye on for the person, telling them only when it changes
(asked 2026-10-28, after Meta's Muse, which comes back when something changes): a price, a
parcel, a page, a pull request, a sensor at home.

A watch is a Hermes cron job Redde makes in the agent's store, named `[redde-watch:<id>] <what>`,
its prompt opening with the same tag. Each run the agent checks, and answers either NOTHING NEW or
a line or two worth telling. As a run's turn starts (`pre_llm_call`), the agent is told what it
told the person last time, from the job's saved answers (`turn_note`), so it can tell a change from
the same again. As a run finishes, the schedules' reader (`routines.py`) sends what it said, unless
it was NOTHING NEW, as a note of kind "watch" to the paired phones.

A watch can be another agent's (its job in that bot's store: Home watching the doors) and can hand
what it sees to an agent (asked 2026-10-28, "bots that bring each other in"): its job delivers
`bot-chat:<profile>`, so Hermes gives each answer to that agent's Bot Chat as a turn, where it acts
with its own tools, `message_agent` and `call_user` among them. Such a watch answers `[SILENT]`
when nothing changed, which Hermes delivers nowhere (every release), and its turn is told so.
"""

from __future__ import annotations

import re
import time
from pathlib import Path

TAG = "[redde-watch:"
QUIET = "NOTHING NEW"
#: Hermes's own word for a run with nothing to deliver.
SILENT = "[SILENT]"
_ID = re.compile(r"\[redde-watch:([A-Za-z0-9_-]{1,40})\]")


def watch_id(text: str) -> str | None:
    match = _ID.search(text or "")
    return match.group(1) if match else None


def is_watch(job: dict) -> bool:
    return str(job.get("name") or "").startswith(TAG)


def hands_off(job: dict | None) -> bool:
    """Its answers go to an agent's Bot Chat, not straight to the person."""
    return bool(job) and str(job.get("deliver") or "").startswith("bot-chat")


def title(name: str) -> str:
    """A watch's name less its tag."""
    return name.split("]", 1)[1].strip() if name.startswith(TAG) and "]" in name else name


def quiet(answer: str) -> bool:
    """The run found nothing worth telling."""
    said = answer.strip()
    return said.upper().startswith(SILENT) or said.strip(".!*_ ").upper().startswith(QUIET)


def last_told(home: Path, job_id: str) -> tuple[str, float] | None:
    """What the newest run that had something to say said, and when."""
    folder = Path(home) / "cron" / "output" / job_id
    try:
        runs = sorted(folder.glob("*.md"), key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError:
        return None
    for run in runs[:50]:
        try:
            text = run.read_text()
        except OSError:
            continue
        answer = text.rpartition("## Response")[2].strip() if "## Response" in text else text.strip()
        if answer and not quiet(answer):
            return answer, run.stat().st_mtime
    return None


def turn_note(home: Path, stores, message) -> str | None:
    """For `pre_llm_call`: a watch's run starts. It is told what it told the person last time, or
    that this is the first look."""
    text = message if isinstance(message, str) else " ".join(
        str(p.get("text") or "") for p in message or [] if isinstance(p, dict)) if isinstance(message, list) else ""
    found = watch_id(text)
    if not found:
        return None
    job = next((j for j in stores.jobs(Path(home)) if watch_id(str(j.get("name") or "")) == found), None)
    told = last_told(Path(home), str(job.get("id"))) if job and job.get("id") else None
    quiet = SILENT if hands_off(job) else QUIET
    if not told:
        if hands_off(job):
            return (f"[Redde: this is the first look at this watch. Answer {SILENT} unless something needs acting on "
                    "now; whatever else you answer goes to the agent it is handed to.]")
        return ("[Redde: this is the first look at this watch. Tell the user briefly what you find now, so they "
                "know it is being watched.]")
    answer, when = told
    ago = max(1, round((time.time() - when) / 3600))
    return (f"[Redde: the last time you had something to say about this watch, about {ago} hour"
            f"{'s' if ago != 1 else ''} ago, you said: \"{answer[:600]}\". Answer {quiet} unless it has changed "
            "since in a way that matters.]")


# ---- watches the agent sets itself (asked 2026-10-28, "proactive": "when the agent says I'll keep an eye on it")

TOOLSET = "redde_ideas"
TOOL = "keep_an_eye_on"
#: How often, as the app names them (Echo/Views/WatchesView.swift `Watches.Often`), and how many looks a day.
EVERY = {"15m": ("*/15 * * * *", 96), "30m": ("*/30 * * * *", 48), "1h": ("0 * * * *", 24),
         "4h": ("0 */4 * * *", 6), "morning": ("0 8 * * *", 1)}
#: At most this many of the agent's own waiting, and this many days each.
MOST = 15
DAYS = (1, 30)

DESCRIPTION = (
    "Keeps an eye on something for the user and tells them, on their iPhone through Redde, only when it changes: "
    "a reply they're waiting for, a parcel, a price, a page, a pull request, a sensor at home. Use it when they ask "
    "you to let them know when something happens, or when you say you'll keep an eye on something. It looks on a "
    "schedule with your tools, for a number of days, then stops; they see and stop it in Redde's Watches.")
WHAT = ("What to look at and what counts as a change, as a note to yourself (\"the reply from Ana in my inbox, "
        "subject 'Lease'; tell me when it comes\").")
_LET_ME_KNOW = re.compile(r"\b(?:let me know|tell me|notify me|ping me|alert me)\b.{0,40}\b(?:when|if|once|as soon as)\b"
                          r"|\bkeep an eye on\b|\bwatch (?:for|out for)\b|\bkeep (?:me )?posted\b", re.IGNORECASE)
NOTE = (f"[Redde: if they want to hear when something happens, set a watch with {TOOL} (find it with tool_search "
        "if it isn't among your tools) rather than promising to remember; say in a few words that you have.]")


def title_of(what: str) -> str:
    first = " ".join(str(what or "").split())
    return first[:60]


def prompt(watch: str, what: str) -> str:
    """The same words the app's watches use (`Watches.prompt`), so the two kinds read alike."""
    return (f"{TAG}{watch}] Watch, for the user: {what}. Check it now with your tools. If nothing has changed since "
            f"last time in a way they would want to know, answer with exactly {QUIET}. Otherwise answer with one or "
            "two short lines saying what changed: that is what they are sent. If it can't wait and you may call them, "
            "you can also use call_user.")


def mine(home: Path) -> int:
    try:
        import json
        data = json.loads((Path(home) / "cron" / "jobs.json").read_text())
    except (OSError, ValueError):
        return 0
    jobs = data.get("jobs") if isinstance(data, dict) else data
    return sum(1 for j in jobs or [] if isinstance(j, dict) and str(j.get("name") or "").startswith(TAG))


def set_up(home: Path, what: str, every: str = "1h", days=7, make=None) -> dict:
    what = " ".join(str(what or "").split())[:400]
    if not what:
        return {"error": "Say what to keep an eye on, as \"what\"."}
    schedule, per_day = EVERY.get(str(every or "1h").lower(), EVERY["1h"])
    try:
        days = max(DAYS[0], min(DAYS[1], int(days)))
    except (TypeError, ValueError):
        days = 7
    if mine(home) >= MOST:
        return {"error": f"There are already {MOST} watches: ask them which to stop first."}
    if make is None:
        try:
            from cron.jobs import create_job as make
        except Exception:
            return {"error": "This Hermes can't schedule watches (no cron). Tell them in words instead."}
    import uuid
    watch = uuid.uuid4().hex[:8]
    make(prompt(watch, what), schedule, name=f"{TAG}{watch}] {title_of(what)}", deliver="local", repeat=per_day * days)
    return {"set": f"Watching for {days} day{'s' if days != 1 else ''}; they'll hear only when it changes, and can stop it "
                   "in Redde's Watches. Tell them in a few words."}


def ask_note(home: Path, store_in, message, platform: str = "") -> str | None:
    """For `pre_llm_call`: the person wants to hear when something happens, where a watch can reach a phone."""
    if platform in ("cron", "subagent", "bot_room"):
        return None
    text = message if isinstance(message, str) else " ".join(
        str(p.get("text") or "") for p in message or [] if isinstance(p, dict)) if isinstance(message, list) else ""
    if not text or text.lstrip().startswith("[") or not _LET_ME_KNOW.search(text):
        return None
    try:
        from .calls import caller
        return NOTE if store_in(caller(Path(home))[1]).devices else None
    except Exception:
        return None


def register(ctx, home_of, store_in) -> None:
    """Offers `keep_an_eye_on` once a phone is paired, as `suggest_to_user` is."""
    import json

    def offered() -> bool:
        try:
            from .calls import caller
            return bool(store_in(caller(home_of())[1]).devices)
        except Exception:
            return False
    offered.__qualname__ = "redde_watches_offered"
    try:
        from tools.registry import no_cache_check_fn
        no_cache_check_fn(offered)
    except Exception:
        pass

    def handle(args, **kwargs) -> str:
        args = args if isinstance(args, dict) else {}
        return json.dumps(set_up(Path(home_of()), args.get("what"), args.get("every") or "1h", args.get("days") or 7))

    schema = {"name": TOOL, "description": DESCRIPTION,
              "parameters": {"type": "object",
                             "properties": {"what": {"type": "string", "description": WHAT},
                                            "every": {"type": "string", "enum": list(EVERY)},
                                            "days": {"type": "integer"}},
                             "required": ["what"]}}
    ctx.register_tool(name=TOOL, toolset=TOOLSET, schema=schema, handler=handle, check_fn=offered, emoji="👀")

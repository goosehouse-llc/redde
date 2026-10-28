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

"""A reminder's run, answered here (2026-11-03: main 1.14.6, 2.4 1.16.1).

"Remind me to stretch in 5 mins": Sol made the job right ("[redde-notify] Stretch", once, prompt
"Tell the person in one line: stretch."), but each run asked the model again, with every tool. The
7:58 run looked up the time and the weather first and finished at 8:00:15. The 8:05 run set out to
put a phone alarm at 7:00, waited four minutes for a phone that wasn't listening, and said "I'm
unable to set the alarm right now". Neither said "stretch" on time.

Now a reminder's run never reaches the model: an llm_execution middleware (Hermes 0.22+, the way
the claude-code plugin answers its bots) answers it with the line ("Reminder: stretch."), no tools,
and the notification goes out from here as the run starts. The half-minute reader of the schedules
(`routines.Routines.look`) then leaves that run alone. A reminder is a [redde-notify] job whose
prompt is "Tell the person in one line: <what>", as cards.REMINDER_NOTE asks; every other run goes
on to its model. A Hermes without middleware runs reminders on the model, as before.
"""
from __future__ import annotations

import logging
import re
import threading
import uuid
from pathlib import Path
from types import SimpleNamespace

from . import routines

log = logging.getLogger("redde_push")

#: The prompt cards.REMINDER_NOTE has the agent give a reminder's job.
PROMPT = re.compile(r"^\s*Tell the person in one line[^:\n]{0,40}:\s*(?P<what>\S.*?)\s*$", re.S | re.I)
#: A cron run's session id: cron_<job id>_<date>_<time>.
RUN = re.compile(r"^cron_(?P<job>[A-Za-z0-9]{6,40})_\d{8}_\d{6}")
#: How long after a reminder was told from here the reader of the schedules keeps quiet about its run.
TOLD_FOR = 15 * 60
MODEL = "redde-reminder"


def plain(name: str) -> str:
    """A job's name less the marks the app adds (2.4's skips and models), where this plugin has them."""
    unmarked = getattr(routines, "unmarked", None)
    return unmarked(name) if unmarked else name


def what(job: dict) -> str | None:
    """What a reminder says ("stretch"), or None for a job that isn't one."""
    name = plain(str(job.get("name") or ""))
    if not name.startswith(routines.NOTIFY) or job.get("no_agent"):
        return None
    found = PROMPT.match(str(job.get("prompt") or ""))
    said = found.group("what").strip().rstrip(".").strip().strip("\"'“”").strip() if found else ""
    return said or None


def line(said: str) -> str:
    said = said.strip()
    return f"Reminder: {said}" + ("" if said.endswith((".", "!", "?")) else ".")


def find(root: Path, session: str) -> tuple[str, Path, dict] | None:
    """The job a cron run's session belongs to: (profile, its home, the job), or None."""
    run = RUN.match(session or "")
    if not run:
        return None
    stores = routines.Stores(root)
    for profile, home in stores.homes():
        for job in stores.jobs(home):
            if str(job.get("id")) == run.group("job"):
                return profile, home, job
    return None


def as_response(text: str, api_mode: str):
    """The reply in the shape the turn loop has from a provider call in this API mode: finished,
    text only (the claude-code plugin's shape, proven on 0.22)."""
    rid = "redde-reminder-" + uuid.uuid4().hex[:12]
    if api_mode == "anthropic_messages":
        return SimpleNamespace(id=rid, type="message", role="assistant", model=MODEL,
                               content=[SimpleNamespace(type="text", text=text)],
                               stop_reason="end_turn", stop_sequence=None, usage=None)
    if api_mode == "codex_responses":
        items = [SimpleNamespace(type="message", role="assistant", status="completed", id="msg_" + rid,
                                 content=[SimpleNamespace(type="output_text", text=text, annotations=[])])]
        return SimpleNamespace(id=rid, object="response", status="completed", model=MODEL, output=items,
                               output_text=text, incomplete_details=None, error=None, usage=None)
    message = SimpleNamespace(role="assistant", content=text, tool_calls=None, reasoning_content=None, refusal=None)
    return SimpleNamespace(id=rid, model=MODEL, usage=None, provider=None,
                           choices=[SimpleNamespace(index=0, message=message, finish_reason="stop")])


class Reminders:
    """The middleware. `root_of()` is the main Hermes home; `store_of()` its store (the paired
    phones, the told marks); `send(profile, home, job, text)` notifies, and says to how many phones."""

    def __init__(self, root_of, store_of, send):
        self.root_of = root_of
        self.store_of = store_of
        self.send = send
        self._told: set[str] = set()   # runs told already (a retried model call is answered again, told once)
        self._lock = threading.Lock()

    def turn(self, request=None, next_call=None, **context):
        session = str(context.get("session_id") or "")
        try:
            found = find(self.root_of(), session)
            said = what(found[2]) if found else None
            text = line(said) if said else ""
            reply = as_response(text, str(context.get("api_mode") or "")) if text else None
        except Exception:
            log.debug("redde-push: reading a reminder's job failed", exc_info=True)
            reply = None
        if reply is None:
            return next_call(request)
        try:
            self._tell(session, found, text)
        except Exception:
            log.debug("redde-push: telling a reminder failed", exc_info=True)
        return reply

    def _tell(self, session: str, found: tuple[str, Path, dict], text: str) -> None:
        with self._lock:
            if session in self._told:
                return
            self._told.add(session)
            if len(self._told) > 200:
                self._told.clear()
                self._told.add(session)
        profile, home, job = found
        key = f"{profile}|{job.get('id')}"
        store = self.store_of()
        # Marked before the run can end, so the reader of the schedules never sends it too.
        store.tell_reminder(key)

        def go() -> None:
            reached = 0
            try:
                reached = self.send(profile, home, job, text)
            except Exception:
                log.debug("redde-push: sending a reminder failed", exc_info=True)
            if not reached:
                store.untell_reminder(key)   # the reader of the schedules sends the run's answer instead

        threading.Thread(target=go, name="redde-push-reminder", daemon=True).start()


def told_lately(store, key: str, now: float) -> bool:
    return store.reminders_told().get(key, 0) > now - TOLD_FOR

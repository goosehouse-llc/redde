"""A bot's schedules: a note to the paired phones when one has run, with what it came up with.

Redde makes a bot's schedules as Hermes Desktop makes its Routines: cron jobs in the bot's own
store that deliver into its Bot Chat (`deliver: bot-chat…`), where the bot answers them. No Hermes
release has a hook for a cron run finishing (a run's turn fires the ordinary hooks in the bot's
own profile, which may not have this plugin), so the stores themselves are read: every profile's
`cron/jobs.json` on this machine, every half minute, from a thread of this plugin's. A job whose
last run moved on since the last look has run: its saved output (`cron/output/<job>/…`, the part
after "## Response") is the note's words. How far each has been seen is on disk under a lock, so
two processes reading send each run once. A phone that muted the bot (`b:<profile>`) hears
nothing of it.

`Stores` is all that touches Hermes's files, so `Routines` can be tested alone.

The same thread sends Leave-By Alerts' traffic re-checks at their time (`leave.py`).
"""

from __future__ import annotations

import importlib
import json
import re
import logging
import threading
import time
import uuid
from pathlib import Path

from . import core, goals, leave, watches

log = logging.getLogger("redde_push")

#: How often the stores are read, in seconds.
EVERY = 30.0
#: A job the agent made for the person whose answers should reach the phone (asked 2026-10-28:
#: "I want Sol to be able to do this", a daily meeting brief): its name starts with this.
NOTIFY = "[redde-notify]"
#: What sounds like asking for something on a schedule, in English: a turn's note, said then only.
_SCHEDULED = re.compile(
    r"\b(every (day|morning|evening|night|week|weekday|hour|monday|tuesday|wednesday|thursday|friday|saturday|sunday)|"
    r"daily|weekly|each (morning|day|week)|on weekdays|schedule|cron|recurring)\b", re.IGNORECASE)
NOTE = ("[Redde: if you make a scheduled job for this, make it yourself with cronjob_manage (don't hand the user a "
        "command), start its name with \"[redde-notify] \" (\"[redde-notify] Daily meeting brief\") and deliver it "
        "\"local\": each run's answer then reaches the user's iPhone as a notification through Redde, so no chat "
        "platform is needed. Write the job's prompt so its answer is what they want to read. If a run can find "
        "nothing new (a check, a watch, a monitor), the prompt says to answer exactly [SILENT] then, never \"No "
        "change\", and to keep nothing in files between runs: each run looks afresh.]")


#: A scheduled run's answer goes to the phone as it is written (asked 2026-10-31, after the morning's
#: briefings began "Now let me compile the morning meeting brief." and quiet evenings came as
#: "Nothing to report. [SILENT]"): said to every cron turn where a phone is paired.
CRON_NOTE = ("[Redde: your final answer reaches the user's phone exactly as you write it. Start with the answer "
             "itself: no notes on what you are doing (\"Now let me…\", \"Here's the notification:\") and no \"---\" "
             "before it. If there is nothing worth telling them, answer exactly [SILENT] and nothing else. Call "
             "deferred tools one at a time, each by its exact name.]")
#: Ways a model opens with what it is doing rather than what it found.
_NARRATION = re.compile(
    r"^(now\b|ok(ay)?\b|good\b|great\b|alright\b|all right\b|perfect\b|let me\b|let's\b|i'll\b|i will\b|"
    r"i have\b|i've\b|i now have\b|i've got\b|i need to\b|first,|next,|here's\b|here is\b|time to\b)", re.IGNORECASE)
_RULE = re.compile(r"^\s*([-*_])(\s*\1){2,}\s*$")
#: An answer whose last word is that nothing changed ("No change.", "**Nothing new.**"): a run that had
#: nothing to tell, as quiet as [SILENT] (2026-11-05: a Strata watch Sol wrote said "No change" to the
#: phone every four hours, its own prompt asking for that over Hermes's [SILENT]).
_NO_NEWS = re.compile(r"(no (new )?changes?|nothing (new|changed|to report)|no (new )?updates?|no news)"
                      r"( (since|from) (the )?(last|previous) (check|run|look|time))?( (yet|today|so far))?", re.IGNORECASE)


#: How Hermes writes a run that said nothing (0.22): its record's status line, or a script gate's note.
_QUIET_STATUS = re.compile(r"^\*\*Status:\*\*\s*(silent|no_change)\b", re.IGNORECASE | re.MULTILINE)
_GATE_SKIPPED = re.compile(r"wakeAgent\s*=\s*false|agent skipped", re.IGNORECASE)
#: Hermes's other words for silence, alone (`gateway.response_filters`: SILENT, NO_REPLY, NO REPLY).
_BARE_SILENCE = re.compile(r"(silent|no[_ ]reply)[.!]?", re.IGNORECASE)


def quiet_record(text: str) -> bool:
    """A run's record (no "## Response" in it) that says the run was quiet."""
    return bool(_QUIET_STATUS.search(text or "") or _GATE_SKIPPED.search(text or ""))


def job_mute(profile: str, job: str) -> str:
    """The phone's mute for one job's runs (Redde's Don't Show on a briefing): "j:<profile>|<job id>"."""
    return f"j:{profile}|{job}"


def settle(words: str) -> tuple[str, bool, bool]:
    """A run's answer as the person should read it: (words, silent, failed). `[SILENT]` anywhere in
    it is silence (Hermes keeps quiet only for exactly that, and models write it after a line of
    their own), and so is a last paragraph that only says nothing changed (`_NO_NEWS`);
    `[CRON_FAILURE]` is a failure, said in what follows it; and the model's account of
    what it was doing ahead of the answer ("Now I have everything. Let me compose the
    notification." and a "---") is left out."""
    text = (words or "").strip()
    if "[SILENT]" in text.upper() or _BARE_SILENCE.fullmatch(text):
        return "", True, False
    if text.upper().startswith("[CRON_FAILURE]"):
        return text[len("[CRON_FAILURE]"):].strip(), False, True
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    # Up to a rule within the first short paragraphs: what is before it is the model talking to itself.
    for i, p in enumerate(paragraphs[:4]):
        if _RULE.match(p) and 0 < i < len(paragraphs) - 1 and sum(len(x) for x in paragraphs[:i]) <= 600:
            paragraphs = paragraphs[i + 1:]
            break
    # Leading paragraphs whose every sentence is such talk ("I have all the information needed.
    # Here's the notification:").
    while len(paragraphs) > 1 and len(paragraphs[0]) <= 300 and all(
            _NARRATION.match(s) for s in re.split(r"(?<=[.:!])\s+", paragraphs[0]) if s.strip()):
        paragraphs = paragraphs[1:]
    if paragraphs and _NO_NEWS.fullmatch(paragraphs[-1].strip("*_`#> \t").rstrip(".!").strip("*_` ")):
        return "", True, False
    return "\n\n".join(paragraphs), False, False


def cron_note(home, store_in, platform: str = "") -> str | None:
    """For `pre_llm_call`: a scheduled run, where a phone is paired (`CRON_NOTE`)."""
    if platform != "cron":
        return None
    try:
        from .calls import caller
        return CRON_NOTE if store_in(caller(Path(home))[1]).devices else None
    except Exception:
        return None


def turn_note(home, store_in, message, platform: str = "") -> str | None:
    """For `pre_llm_call`: the person asks for something on a schedule, where a phone is paired."""
    if platform in ("cron", "subagent", "bot_room"):
        return None
    text = message if isinstance(message, str) else " ".join(
        str(p.get("text") or "") for p in message or [] if isinstance(p, dict)) if isinstance(message, list) else ""
    if not text or text.lstrip().startswith("[") or not _SCHEDULED.search(text):
        return None
    try:
        from .calls import caller
        return NOTE if store_in(caller(Path(home))[1]).devices else None
    except Exception:
        return None


class Stores:
    """Every profile's cron store under one Hermes home: its own, and each in profiles/."""

    def __init__(self, root: Path):
        self.root = Path(root)

    def homes(self) -> list[tuple[str, Path]]:
        found = [("default", self.root)]
        profiles = self.root / "profiles"
        if profiles.is_dir():
            found += [(home.name, home) for home in sorted(profiles.iterdir()) if (home / "cron").is_dir()]
        return found

    def jobs(self, home: Path) -> list[dict]:
        try:
            data = json.loads((home / "cron" / "jobs.json").read_text())
        except (OSError, ValueError):
            return []
        return [j for j in (data.get("jobs") if isinstance(data, dict) else data) or [] if isinstance(j, dict)]

    def output(self, home: Path, job_id: str) -> str:
        """The latest run's answer: what follows its "## Response", or the whole of it; nothing for a
        run Hermes recorded as quiet (issue 55: a script job's "**Status:** silent (wakeAgent=false)",
        "silent (empty output)", a monitor's "no_change", a script gate's "agent skipped"), as
        Hermes's own reader of these records passes them over (cron/scheduler_prompt.py)."""
        folder = home / "cron" / "output" / job_id
        try:
            latest = max(folder.glob("*.md"), key=lambda p: p.stat().st_mtime)
            text = latest.read_text()
        except (OSError, ValueError):
            return ""
        if "## Response" in text:
            return text.rpartition("## Response")[2].strip()
        if quiet_record(text):
            return ""
        return text.strip()

    def said_nothing(self, home: Path, job_id: str) -> bool:
        """The latest run's record is there and says nothing: quiet (`quiet_record`) or an empty
        "## Response". (No record at all isn't this: the run is still told of, as before.)"""
        folder = home / "cron" / "output" / job_id
        try:
            latest = max(folder.glob("*.md"), key=lambda p: p.stat().st_mtime)
            text = latest.read_text()
        except (OSError, ValueError):
            return False
        if "## Response" in text:
            return not text.rpartition("## Response")[2].strip()
        return quiet_record(text)

    def name(self, home: Path, profile: str) -> str:
        """What the bot is called (its Bot Mode title), or its profile's name. Hermes's own reader
        where it has one (0.22), else the file read here: 0.22 reads YAML with a module of its own,
        and its Python has no `yaml`."""
        try:
            from hermes_cli.profiles import read_profile_meta
            title = str(read_profile_meta(Path(home)).get("bot_title") or "").strip()
            if title:
                return title
        except Exception:
            pass
        for module in ("hermes_yaml", "yaml"):
            try:
                loader = importlib.import_module(module)
                meta = (loader.safe_load((Path(home) / "profile.yaml").read_text()) or {}).get("ui_meta") or {}
                title = str((meta.get("hermes-bots") or {}).get("title") or "").strip()
                if title:
                    return title
                break
            except Exception:
                continue
        return "Hermes" if profile == "default" else profile


def untagged(name: str) -> str:
    """A job's name less Hermes Desktop's tag for a bot's ("[bot:scout] What to wear"), or Redde's
    for one whose answers go to the phone."""
    name = unmarked(name)
    if (name.startswith("[bot:") or name.startswith(NOTIFY)) and "]" in name:
        return name.split("]", 1)[1].strip()
    return name


# ---- Skipping a run (Redde 2.4's Coming Up, 2026-11-02) ------------------------------------------
#
# The app skips the next run of a repeating job by adding ` [redde-skip:<when>]` to its name, when
# being that run's time in seconds since 1970: the one change both connections can make (the
# Hermes API's PATCH api/jobs takes a name but no next_run_at). Every half minute, phone paired or
# not, each marked job whose next run is that one is moved on to the run after it, with Hermes's
# own `compute_next_run` (so it is on the schedule's lattice, which Hermes's stale-schedule check
# leaves alone), and the mark is taken off. Over the Dashboard the app can also skip at once:
# `/redde-push skip <profile> <job> <when>`.

SKIP = re.compile(r"\s*\[redde-skip:(\d{9,11})\]")
#: How near a job's next run must be to the one asked to be skipped, in seconds, to be that run.
SKIP_NEAR = 90


def unskipped(name: str) -> str:
    return SKIP.sub("", name or "").rstrip()


def skip_marked(name: str) -> int | None:
    match = SKIP.search(name or "")
    return int(match.group(1)) if match else None


def _instant(text) -> float | None:
    from datetime import datetime
    try:
        return datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp() if text else None
    except ValueError:
        return None


def skip(home: Path, job: dict, when: int, cron=None, rename: bool = True) -> str:
    """Skips the run of `job` at `when`: "skipped" (moved on to the run after), "gone" (that run is
    past, or the job runs once: only the mark is taken off), "waiting" (an earlier run comes first:
    left for later) or "failed". `cron` is Hermes's `cron.jobs` (a stand-in in tests)."""
    if cron is None:
        try:
            from cron import jobs as cron
        except Exception:
            return "failed"
    name, job_id = str(job.get("name") or ""), str(job.get("id") or "")
    # (only the skip mark: a model mark is taken off with its model, `set_model`)
    updates = {"name": SKIP.sub("", name).rstrip()} if rename and skip_marked(name) is not None else {}
    schedule = job.get("schedule") if isinstance(job.get("schedule"), dict) else {}
    upcoming = _instant(job.get("next_run_at"))
    outcome = "gone"
    if schedule.get("kind") not in (None, "once") and upcoming is not None:
        if upcoming < when - SKIP_NEAR:
            return "waiting"
        if abs(upcoming - when) <= SKIP_NEAR:
            from datetime import datetime, timezone
            after = cron.compute_next_run(schedule, last_run_at=datetime.fromtimestamp(upcoming, timezone.utc).isoformat())
            if after:
                updates["next_run_at"], outcome = after, "skipped"
    if not updates:
        return outcome
    try:
        with cron.use_cron_store(home):
            changed = cron.update_job(job_id, updates)
    except Exception:
        log.debug("redde-push: couldn't skip %s", job_id, exc_info=True)
        return "failed"
    return outcome if changed else "failed"


def skip_due(stores: "Stores", cron=None) -> int:
    """Every store's marked jobs, each skipped once its run is next; how many were skipped."""
    skipped = 0
    for profile, home in stores.homes():
        for job in stores.jobs(home):
            when = skip_marked(str(job.get("name") or ""))
            if when is not None and job.get("id") and skip(home, job, when, cron) == "skipped":
                skipped += 1
    return skipped


# ---- A job's own model (Redde's Run On, 2026-11-03) ------------------------------------------------
#
# A job can run on a model of its own (Hermes keeps `model` and `provider` on the job; the scheduler
# runs it on them, else on cron.model, else the main model). The Dashboard's job update sets them
# directly; the Hermes API's PATCH api/jobs takes neither, so the app adds
# ` [redde-model:<model>|<provider>]` to the job's name instead (` [redde-model:|]`: back to the
# main model). Every half minute, phone paired or not, each marked job is given that model and
# provider and the mark is taken off. Over the Dashboard: `/redde-push job-model <profile> <job>
# <model|-> <provider|->`.

MODEL = re.compile(r"\s*\[redde-model:([^\]|]*)\|([^\]]*)\]")


def unmodeled(name: str) -> str:
    return MODEL.sub("", name or "").rstrip()


def unmarked(name: str) -> str:
    """A job's name less every mark the app adds (a skip, a model)."""
    return unskipped(unmodeled(name))


def model_marked(name: str) -> tuple[str, str] | None:
    """The (model, provider) a job's name asks for; ("", "") for the main model."""
    match = MODEL.search(name or "")
    return (match.group(1).strip(), match.group(2).strip()) if match else None


def set_model(home: Path, job: dict, model: str, provider: str, cron=None, rename: bool = True) -> str:
    """Gives `job` its own model and provider ("" for both: the main model again), and takes a model
    mark off its name: "set" or "failed". `cron` is Hermes's `cron.jobs` (a stand-in in tests)."""
    if cron is None:
        try:
            from cron import jobs as cron
        except Exception:
            return "failed"
    name, job_id = str(job.get("name") or ""), str(job.get("id") or "")
    if not job_id:
        return "failed"
    updates = {"model": model or None, "provider": (provider or None) if model else None}
    if rename and model_marked(name) is not None:
        updates["name"] = unmodeled(name)
    try:
        with cron.use_cron_store(home):
            changed = cron.update_job(job_id, updates)
    except Exception:
        log.debug("redde-push: couldn't set the model of %s", job_id, exc_info=True)
        return "failed"
    return "set" if changed else "failed"


def models_due(stores: "Stores", cron=None) -> int:
    """Every store's jobs with a model mark, each given its model; how many were."""
    done = 0
    for profile, home in stores.homes():
        for job in stores.jobs(home):
            asked = model_marked(str(job.get("name") or ""))
            if asked is not None and job.get("id") and set_model(home, job, *asked, cron=cron) == "set":
                done += 1
    return done


class Routines:
    """Reads the stores and sends a note for each run of a bot's schedule: `look` once, `start` for good."""

    def __init__(self, store: core.Store, send, stores: Stores, every: float = EVERY):
        self.store = store
        self.send = send   # (devices, note) -> how many it reached
        self.stores = stores
        self.every = every
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()

    def start(self) -> None:
        with self._lock:
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="redde-push-routines", daemon=True)
                self._thread.start()

    def _run(self) -> None:
        while True:
            try:
                # Runs the app asked to skip, phone paired or not (only one process at a time).
                with self.store.rooms_lock("skips") as mine:
                    if mine:
                        models_due(self.stores)   # (a job's own model, Run On)
                        skip_due(self.stores)
            except Exception:
                log.debug("redde-push: skipping runs failed", exc_info=True)
            try:
                if self.store.devices:
                    self.look()
            except Exception:
                log.debug("redde-push: reading the schedules failed", exc_info=True)
            try:
                # Email (mail.py, 1.16.0): each account looked at when due, its rules run.
                with self.store.rooms_lock("mail") as mine:
                    if mine:
                        from . import mail
                        mail.sync_due(self.stores.root, mail.Inbox(self.stores.root, notify=self._mail_said, idea=self._mail_idea))
            except Exception:
                log.debug("redde-push: syncing email failed", exc_info=True)
            try:
                # Leave-By Alerts' traffic re-checks whose time has come (leave.py).
                leave.send_due(self.store, self.send)
            except Exception:
                log.debug("redde-push: sending the traffic re-checks failed", exc_info=True)
            time.sleep(self.every)

    def _mail_idea(self, title: str, why: str, request: str) -> bool:
        """Suggested email rules as one Morning Ideas card (at most weekly; mail.py says when), only
        when Morning Ideas is on in the main profile."""
        from . import ideas
        try:
            jobs = self.stores.jobs(self.stores.root)
        except Exception:
            return False
        if not any(str(j.get("name") or "").startswith(ideas.JOBS[0]) and j.get("enabled", True) is not False for j in jobs):
            return False
        answer = ideas.offer(self.store, self.stores.root, "default", "Redde", [{"title": title, "why": why, "request": request}])
        return "sent" in answer

    def _mail_said(self, title: str, body: str, entry: str) -> None:
        """One of the person's email rules said to tell them: to every paired phone."""
        devices = self.store.devices
        if devices:
            self.send(devices, core.mail_note(title, body, entry))

    def look(self) -> int:
        """Reads every store once; a note for each schedule that ran since. How many went."""
        outgoing: list[tuple[str, dict]] = []
        with self.store.rooms_lock("routines") as mine:
            if not mine:
                return 0
            from . import ideas, remind   # (here: both reach back to this module)
            seen, now = self.store.routine_runs(), {}
            clock = time.time()
            for profile, home in self.stores.homes():
                for job in self.stores.jobs(home):
                    # (as named less a skip the app asked for, which is taken off within half a minute)
                    name = unmarked(str(job.get("name") or ""))
                    job = {**job, "name": name}
                    watching = watches.is_watch(job)
                    told = name.startswith(NOTIFY)
                    offering = name in ideas.JOBS
                    aiming = goals.is_goal(job)
                    if not (watching or told or offering or aiming or str(job.get("deliver") or "").startswith("bot-chat")) or not job.get("id"):
                        continue
                    key, last = f"{profile}|{job['id']}", str(job.get("last_run_at") or "")
                    now[key] = last
                    # First seen, or never run: nothing to say yet.
                    if key not in seen or not last or seen[key] == last:
                        continue
                    # A reminder told as its run started (remind.py, 1.14.6): said already.
                    if told and remind.what(job) and remind.told_lately(self.store, key, clock):
                        continue
                    failed = job.get("last_status") == "error"
                    words = (f"It didn't finish: {job.get('last_error') or 'an error'}" if failed
                             else self.stores.output(home, str(job["id"])))
                    # A run Hermes recorded as saying nothing (a quiet record, an empty answer) sends
                    # nothing (issue 55).
                    if not failed and self.stores.said_nothing(home, str(job["id"])):
                        continue
                    if not failed and not watching:
                        words, silent, failed = settle(words)
                        if silent:
                            continue
                    if watching:
                        # A watch says something only when there is something to say.
                        if not failed and (not words or watches.quiet(words)):
                            continue
                        # A watch on email where the agent can't read any (Redde 2.4's templates):
                        # said once, as such, and the watch paused until there is a way.
                        blind = not failed and watches.no_email(words)
                        if blind:
                            watches.pause(home, str(job["id"]))
                        outgoing.append((profile, core.watch_note(profile, self.stores.name(home, profile), watches.title(name),
                                                                  watches.NO_EMAIL_SAID if blind else words,
                                                                  watches.watch_id(name) or "", failed=failed,
                                                                  why="noemail" if blind else "")))
                        continue
                    if aiming:
                        # A goal's check-in: its progress kept, and a briefing with the goal's id and progress.
                        found, rest = goals.progress(words) if not failed else (None, words)
                        goal = goals.goal_id(name) or ""
                        if found:
                            goals.remember(home, goal, found)
                        body = rest if failed or not found else "\n".join(
                            line for line in ([found["headline"], f"Next: {found['next']}" if found["next"] else ""] + [rest]) if line)
                        if not body and not found:
                            continue
                        outgoing.append((profile, core.routine_note(profile, self.stores.name(home, profile), goals.title(name), body,
                                                                    failed=failed, brief=str(job["id"]), goal=goal,
                                                                    progress=f"{found['done']}/{found['total']}" if found else "")))
                        continue
                    if offering:
                        # The tool used during the run: the cards are on the phone already.
                        if not failed and ideas.sent_lately(self.stores.root, profile, time.time()):
                            continue
                        written = [] if failed else ideas.from_answer(words)
                        if written:
                            outgoing.append((profile, core.ideas_note(profile, self.stores.name(home, profile), written,
                                                                      uuid.uuid4().hex[:16])))
                            ideas.remember(self.stores.root, profile, time.time())
                        elif failed or (words and not watches.quiet(words)):
                            # Neither: what it said, so the person sees the run wasn't for nothing.
                            outgoing.append((profile, core.routine_note(profile, self.stores.name(home, profile),
                                                                        untagged(str(job.get("name") or "")).removeprefix("[redde] ").capitalize(),
                                                                        words, failed=failed, brief=str(job["id"]))))
                        continue
                    from . import headsup   # (here: headsup's own imports reach back to this module)
                    event = headsup.recall(home, str(job.get("name") or "")) if told else {}
                    outgoing.append((profile, core.routine_note(profile, self.stores.name(home, profile), untagged(str(job.get("name") or "")),
                                                                words, failed=failed, brief=str(job["id"]) if told else "",
                                                                starts=str(event.get("starts") or ""), where=str(event.get("where") or ""))))
            self.store.set_routine_runs(now)
        sent = 0
        for profile, made in outgoing:
            targets = self.store.unmuted(self.store.devices, "b:" + profile)
            if made.get("i") and made.get("x") == "brief":
                # A job the phone hides (Redde's Don't Show, 2026-11-05): nothing sent for it.
                targets = self.store.unmuted(targets, job_mute(profile, made["i"]))
            if targets:
                sent += self.send(targets, made)
        return sent

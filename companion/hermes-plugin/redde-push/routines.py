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
"""

from __future__ import annotations

import json
import logging
import threading
import time
from pathlib import Path

from . import core

log = logging.getLogger("redde_push")

#: How often the stores are read, in seconds.
EVERY = 30.0


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
        """The latest run's answer: what follows its "## Response", or the whole of it."""
        folder = home / "cron" / "output" / job_id
        try:
            latest = max(folder.glob("*.md"), key=lambda p: p.stat().st_mtime)
            text = latest.read_text()
        except (OSError, ValueError):
            return ""
        return text.rpartition("## Response")[2].strip() if "## Response" in text else text.strip()

    def name(self, home: Path, profile: str) -> str:
        """What the bot is called (its Bot Mode title), or its profile's name."""
        try:
            import yaml
            meta = (yaml.safe_load((home / "profile.yaml").read_text()) or {}).get("ui_meta") or {}
            title = ((meta.get("hermes-bots") or {}).get("title") or "").strip()
            if title:
                return title
        except Exception:
            pass
        return "Hermes" if profile == "default" else profile


def untagged(name: str) -> str:
    """A job's name less Hermes Desktop's tag for a bot's ("[bot:scout] What to wear")."""
    return name.split("]", 1)[1].strip() if name.startswith("[bot:") and "]" in name else name


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
                if self.store.devices:
                    self.look()
            except Exception:
                log.debug("redde-push: reading the schedules failed", exc_info=True)
            time.sleep(self.every)

    def look(self) -> int:
        """Reads every store once; a note for each schedule that ran since. How many went."""
        outgoing: list[tuple[str, dict]] = []
        with self.store.rooms_lock("routines") as mine:
            if not mine:
                return 0
            seen, now = self.store.routine_runs(), {}
            for profile, home in self.stores.homes():
                for job in self.stores.jobs(home):
                    if not str(job.get("deliver") or "").startswith("bot-chat") or not job.get("id"):
                        continue
                    key, last = f"{profile}|{job['id']}", str(job.get("last_run_at") or "")
                    now[key] = last
                    # First seen, or never run: nothing to say yet.
                    if key not in seen or not last or seen[key] == last:
                        continue
                    failed = job.get("last_status") == "error"
                    words = (f"It didn't finish: {job.get('last_error') or 'an error'}" if failed
                             else self.stores.output(home, str(job["id"])))
                    outgoing.append((profile, core.routine_note(profile, self.stores.name(home, profile), untagged(str(job.get("name") or "")),
                                                                words, failed=failed)))
            self.store.set_routine_runs(now)
        sent = 0
        for profile, made in outgoing:
            targets = self.store.unmuted(self.store.devices, "b:" + profile)
            if targets:
                sent += self.send(targets, made)
        return sent

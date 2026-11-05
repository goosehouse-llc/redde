"""Goals and skipping a run (`goals.py`, `routines.skip`): python -m unittest discover -s companion/hermes-plugin/tests"""
import json
import types
import unittest
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone

from test_routines import RoutinesTests, plugin

core, routines, goals, watches = plugin.core, plugin.routines, plugin.goals, plugin.watches


class FakeBoard:
    """Hermes's Kanban, as `goals` uses it: create_task and list_tasks on a connection."""

    def __init__(self):
        self.tasks = []

    def create_task(self, conn, *, title, body=None, assignee=None, tenant=None, triage=False, idempotency_key=None, **_):
        for task in self.tasks:
            if task.idempotency_key == idempotency_key:
                return task.id
        task = types.SimpleNamespace(id=f"t{len(self.tasks) + 1}", title=title, assignee=assignee, tenant=tenant,
                                     status="triage" if triage else "ready", idempotency_key=idempotency_key)
        self.tasks.append(task)
        return task.id

    def list_tasks(self, conn, *, tenant=None, **_):
        return [t for t in self.tasks if t.tenant == tenant]

    @contextmanager
    def __call__(self):
        yield self, None


@contextmanager
def no_board():
    raise ImportError("no kanban here")
    yield


class FakeCron:
    """Hermes's cron.jobs, as `routines.skip` and `watches.pause` use it, over the test's jobs.json."""

    def __init__(self):
        self.home = None
        self.updates, self.paused = [], []

    @contextmanager
    def use_cron_store(self, home):
        self.home = home
        yield

    def compute_next_run(self, schedule, last_run_at=None):
        base = datetime.fromisoformat(last_run_at)
        return (base + timedelta(days=7 if schedule.get("expr") == goals.WEEKLY else 1)).isoformat()

    def update_job(self, job_id, updates):
        self.updates.append((job_id, dict(updates)))
        path = self.home / "cron" / "jobs.json"
        data = json.loads(path.read_text())
        for job in data["jobs"]:
            if job["id"] == job_id:
                job.update(updates)
                path.write_text(json.dumps(data))
                return job
        return None

    def pause_job(self, job_id, reason=None):
        self.paused.append(job_id)
        return {"id": job_id}


class GoalTests(RoutinesTests):
    def made(self):
        self.jobs = []

        def make(prompt, schedule, name=None, deliver=None, **_):
            self.jobs.append({"prompt": prompt, "schedule": schedule, "name": name, "deliver": deliver})
            # (in the store, as Hermes keeps it: a goal whose job is gone is ended)
            (self.root / "cron").mkdir(parents=True, exist_ok=True)
            stored = [{"id": f"job{i}", "name": j["name"], "schedule": {"kind": "cron", "expr": j["schedule"]}, "deliver": j["deliver"]}
                      for i, j in enumerate(self.jobs, 1)]
            (self.root / "cron" / "jobs.json").write_text(json.dumps({"jobs": stored}))
            return {"id": f"job{len(self.jobs)}"}
        return make

    def test_a_goal_whose_check_in_is_gone_is_ended(self):
        goal = goals.set_up(self.root, "default", "Run a 10K", make=self.made(), board=no_board)["set"]
        self.assertEqual(len(goals.status(self.root)["goals"]), 1)
        (self.root / "cron" / "jobs.json").write_text(json.dumps({"jobs": []}))   # (Redde's End Goal deleted it)
        self.assertEqual(goals.status(self.root)["goals"], [])
        self.assertEqual(goals.listing(routines.Stores(self.root)), [])
        self.assertTrue(goals.load(self.root)[0]["ended"])
        self.assertIsNone(goals.checkin_note(self.root, f"[redde-goal:{goal}] Check-in", "cron"))

    def test_an_unreadable_store_ends_nothing(self):
        goals.set_up(self.root, "default", "Run a 10K", make=self.made(), board=no_board)
        (self.root / "cron" / "jobs.json").write_text("{not json")
        self.assertEqual(len(goals.status(self.root)["goals"]), 1)

    def test_the_check_ins_job_is_the_truth_for_its_schedule(self):
        goals.set_up(self.root, "default", "Run a 10K", make=self.made(), board=no_board)
        data = json.loads((self.root / "cron" / "jobs.json").read_text())
        data["jobs"][0]["schedule"] = {"kind": "cron", "expr": "0 18 * * 3"}   # (Redde's picker edits the job alone)
        (self.root / "cron" / "jobs.json").write_text(json.dumps(data))
        self.assertEqual(goals.listing(routines.Stores(self.root))[0]["every"], "0 18 * * 3")
        self.assertEqual(goals.load(self.root)[0]["every"], "0 18 * * 3", "goals.json follows it")

    def test_the_app_ends_a_goal_over_the_dashboard(self):
        goal = goals.set_up(self.root, "default", "Run a 10K", make=self.made(), board=no_board)["set"]
        removed = []
        original = plugin._home
        plugin._home = lambda: self.root
        try:
            self.assertEqual(plugin._end_goal_slash(["default", goal], remove=removed.append), f"redde-push goals ended {goal}")
            self.assertEqual(plugin._end_goal_slash(["default", "nope"], remove=removed.append), "redde-push goals unknown")
            self.assertIn("for the Redde app", plugin._end_goal_slash(["../x", goal]))
        finally:
            plugin._home = original
        self.assertEqual(removed, ["job1"])
        self.assertEqual(goals.status(self.root)["goals"], [])

    def test_a_message_that_sounds_like_a_goal_and_no_other_gets_the_note(self):
        for asked in ("I want to run a 10K by March", "My goal is to read 20 books this year", "Help me save up for a trip to Japan",
                      "Can you help me get to 70 kg?", "I'd like to learn Portuguese within six months", "Keep me on track with Spanish",
                      "Set a goal for me: ship the app before December"):
            self.assertEqual(goals.turn_note(asked), goals.NOTE, asked)
        for asked in ("What's the weather?", "I want to watch a movie", "Turn off the lights by the door", "Run the backup",
                      "Score a goal in FIFA for me"):
            self.assertIsNone(goals.turn_note(asked), asked)
        self.assertIsNone(goals.turn_note("I want to run a 10K by March", platform="cron"))
        self.assertIn("redde_goal", goals.NOTE)
        self.assertIn("Not Hermes's /goal", goals.NOTE)
        self.assertLess(len(goals.NOTE), 450, "a turn's note: short")

    def test_check_ins_default_to_mondays_or_every_other_day_when_its_soon(self):
        today = date(2026, 11, 2)
        self.assertEqual(goals.schedule_for(None, today=today), goals.WEEKLY)
        self.assertEqual(goals.schedule_for("2026-12-31", today=today), goals.WEEKLY)
        self.assertEqual(goals.schedule_for("2026-11-10", today=today), goals.OTHER_DAY)
        self.assertEqual(goals.schedule_for("2026-12-31", "daily", today=today), goals.DAILY)
        self.assertEqual(goals.schedule_for(None, "30 18 * * 5", today=today), "30 18 * * 5")
        self.assertEqual(goals.schedule_for(None, "every so often", today=today), goals.WEEKLY)

    def test_setting_a_goal_makes_its_cards_in_triage_its_check_in_and_keeps_it(self):
        board = FakeBoard()
        said = goals.set_up(self.root, "default", "Run a 10K", "2027-03-01", ["Run 3K twice a week", "Run 5K", "Sign up for a race"],
                            make=self.made(), board=board, today=date(2026, 11, 2))
        goal = said["set"]
        self.assertIn("Kanban", said["said"])
        self.assertEqual(said["check_ins"], goals.WEEKLY)
        self.assertEqual([(t.status, t.tenant, t.assignee) for t in board.tasks], [("triage", f"redde-goal-{goal}", "default")] * 3)
        job = self.jobs[0]
        self.assertEqual((job["name"], job["schedule"], job["deliver"]), (f"[redde-goal:{goal}] Run a 10K", goals.WEEKLY, "local"))
        self.assertTrue(job["prompt"].startswith(f"[redde-goal:{goal}]"))
        kept = goals.load(self.root)[0]
        self.assertEqual((kept["title"], kept["by"], kept["job"]), ("Run a 10K", "2027-03-01", "job1"))
        self.assertEqual([s["card"] for s in kept["steps"]], ["t1", "t2", "t3"])

    def test_without_a_board_the_steps_are_kept_here(self):
        said = goals.set_up(self.root, "scout", "Read 20 books", None, ["Pick the list"], make=self.made(), board=no_board)
        self.assertNotIn("Kanban", said["said"])
        self.assertEqual(goals.load(self.root)[0]["steps"], [{"title": "Pick the list", "card": None, "done": False}])

    def test_odd_asks_are_refused(self):
        self.assertIn("error", goals.set_up(self.root, "default", "", make=self.made()))
        self.assertIn("error", goals.set_up(self.root, "default", "Run", "next March", make=self.made()))
        self.assertIn("error", goals.update(self.root, "nope", done=[1]))

    def test_steps_are_marked_done_and_added_after_the_others(self):
        board = FakeBoard()
        goal = goals.set_up(self.root, "default", "Run a 10K", None, ["Run 3K", "Run 5K"], make=self.made(), board=board)["set"]
        edits = []
        said = goals.update(self.root, goal, done=[1, 9, "x"], add=["Run 8K"], every="daily", board=board,
                            edit=lambda job, updates: edits.append((job, updates)))
        self.assertEqual(said["steps_done"], "1/3")
        self.assertEqual([t.idempotency_key for t in board.tasks][-1], f"redde-goal-{goal}-3", "its own card, not step 1's again")
        self.assertEqual(edits, [("job1", {"schedule": goals.DAILY})])
        listed = goals.status(self.root)["goals"][0]
        self.assertEqual(listed["steps"], ["1. Run 3K (done)", "2. Run 5K", "3. Run 8K"])

    def test_ending_a_goal_stops_its_check_ins(self):
        goal = goals.set_up(self.root, "default", "Run a 10K", make=self.made(), board=no_board)["set"]
        removed = []
        goals.end(self.root, goal, remove=removed.append)
        self.assertEqual(removed, ["job1"])
        self.assertEqual(goals.status(self.root)["goals"], [])

    def test_a_check_in_is_told_its_steps_and_how_to_answer(self):
        board = FakeBoard()
        goal = goals.set_up(self.root, "default", "Run a 10K", "2027-03-01", ["Run 3K", "Run 5K"], make=self.made(), board=board)["set"]
        board.tasks[0].status = "done"
        asked = self.jobs[0]["prompt"]
        note = goals.checkin_note(self.root, asked, "cron", board=board)
        self.assertIn("1. Run 3K (done); 2. Run 5K (triage)", note)
        self.assertIn("Target: 2027-03-01", note)
        self.assertIn("PROGRESS: <steps done>/<steps>", note)
        self.assertIn("suggest_to_user", note)
        self.assertIsNone(goals.checkin_note(self.root, "What's the weather?", "cron"))
        self.assertIsNone(goals.checkin_note(self.root, asked, "desktop"), "only the check-in's own turn")
        goals.remember(self.root, goal, {"done": 1, "total": 2, "headline": "Ran 3K", "next": "Run 5K"})
        self.assertIn('Last check-in: 1/2, "Ran 3K"', goals.checkin_note(self.root, asked, "cron", board=board))

    def test_a_check_ins_progress_line_is_read(self):
        found, rest = goals.progress("PROGRESS: 3/7 | Ran 5K on Saturday | Book the race\n\nGood week: two runs and a long one.")
        self.assertEqual(found, {"done": 3, "total": 7, "headline": "Ran 5K on Saturday", "next": "Book the race"})
        self.assertEqual(rest, "Good week: two runs and a long one.")
        self.assertEqual(goals.progress("**Progress: 2 / 5** | On track")[0]["headline"], "On track")
        self.assertEqual(goals.progress("Some words first.\nPROGRESS: 9/4 | Done | -")[0]["done"], 4)
        self.assertIsNone(goals.progress("No progress line here.")[0])

    def goal_job(self, last=None, goal="g1"):
        return self.job("default", last=last, deliver="local", name=f"[redde-goal:{goal}] Run a 10K")

    def test_a_check_in_is_a_briefing_with_its_goal_and_progress(self):
        goals.save(self.root, [{"id": "g1", "title": "Run a 10K", "steps": []}])
        home = self.goal_job(last="2026-11-02T09:00:00")
        self.watch.look()
        self.output(home, "## Response\n\nPROGRESS: 2/5 | Two runs this week | Run 5K Saturday\n\nThe knee is fine now.")
        self.goal_job(last="2026-11-09T09:00:00")
        self.assertEqual(self.watch.look(), 1)
        made = self.sent[0][1]
        self.assertEqual((made["k"], made["x"], made["i"], made["o"], made["q"], made["t"]),
                         ("routine", "brief", "job1", "g1", "2/5", "Run a 10K"))
        self.assertEqual(made["b"], "Two runs this week\nNext: Run 5K Saturday\nThe knee is fine now.")
        self.assertEqual(goals.load(self.root)[0]["progress"]["headline"], "Two runs this week")

    def test_a_check_in_without_a_progress_line_still_says_what_it_said(self):
        goals.save(self.root, [{"id": "g1", "title": "Run a 10K", "steps": []}])
        home = self.goal_job(last="2026-11-02T09:00:00")
        self.watch.look()
        self.output(home, "## Response\n\nTwo runs this week.")
        self.goal_job(last="2026-11-09T09:00:00")
        self.watch.look()
        made = self.sent[0][1]
        self.assertEqual((made["b"], made["o"]), ("Two runs this week.", "g1"))
        self.assertNotIn("q", made)

    def test_the_app_lists_every_agents_goals_with_progress_read_from_the_last_check_in(self):
        scout = self.root / "profiles" / "scout"
        goals.save(scout, [{"id": "g2", "title": "Ship the app", "steps": [{"title": "Beta", "card": "t9", "done": True}]},
                           {"id": "g3", "title": "Old one", "ended": 1}])
        home = self.job("scout", last="2026-11-09T09:00:00+00:00", deliver="local", name="[redde-goal:g2] Ship the app")
        self.output(home, "## Response\n\nPROGRESS: 1/3 | Beta is out | Fix the crash")
        listed = goals.listing(routines.Stores(self.root))
        self.assertEqual(len(listed), 1)
        self.assertEqual((listed[0]["id"], listed[0]["profile"], listed[0]["job"]), ("g2", "scout", "job1"))
        self.assertEqual(listed[0]["progress"]["next"], "Fix the crash", "read now: no phone paired to have kept it")
        self.assertEqual(listed[0]["steps"], [{"title": "Beta", "card": "t9", "done": True}])

    def test_the_tool_stays_small(self):
        made = {}
        ctx = types.SimpleNamespace(register_tool=lambda **kw: made.update(kw))
        goals.register(ctx, lambda: self.root)
        self.assertEqual((made["name"], made["toolset"]), ("redde_goal", "redde_ideas"))
        self.assertLess(len(json.dumps(made["schema"])), 1500)


class SkipTests(RoutinesTests):
    def marked(self, next_run, when, kind="cron", profile="default"):
        home = self.root if profile == "default" else self.root / "profiles" / profile
        (home / "cron").mkdir(parents=True, exist_ok=True)
        job = {"id": "job1", "name": f"[redde] Morning ideas [redde-skip:{when}]", "deliver": "local",
               "schedule": {"kind": kind, "expr": "0 9 * * *"}, "next_run_at": next_run}
        (home / "cron" / "jobs.json").write_text(json.dumps({"jobs": [job]}))
        return home

    def stored(self, home):
        return json.loads((home / "cron" / "jobs.json").read_text())["jobs"][0]

    def test_the_marked_run_is_moved_on_to_the_one_after_and_the_mark_taken_off(self):
        runs = datetime(2026, 11, 3, 9, tzinfo=timezone.utc)
        home = self.marked(runs.isoformat(), int(runs.timestamp()), profile="scout")
        cron = FakeCron()
        self.assertEqual(routines.skip_due(routines.Stores(self.root), cron), 1)
        job = self.stored(home)
        self.assertEqual(job["name"], "[redde] Morning ideas")
        self.assertEqual(datetime.fromisoformat(job["next_run_at"]), runs + timedelta(days=1))
        self.assertEqual(cron.home, home, "in that profile's own store")
        self.assertEqual(routines.skip_due(routines.Stores(self.root), cron), 0, "once")

    def test_a_run_already_past_or_a_one_off_only_loses_the_mark(self):
        runs = datetime(2026, 11, 3, 9, tzinfo=timezone.utc)
        for next_run, kind in (((runs + timedelta(days=1)).isoformat(), "cron"), (runs.isoformat(), "once")):
            home = self.marked(next_run, int(runs.timestamp()), kind=kind)
            routines.skip_due(routines.Stores(self.root), FakeCron())
            job = self.stored(home)
            self.assertEqual((job["name"], job["next_run_at"]), ("[redde] Morning ideas", next_run), kind)

    def test_a_skip_further_off_waits_for_its_run(self):
        runs = datetime(2026, 11, 3, 9, tzinfo=timezone.utc)
        home = self.marked(runs.isoformat(), int((runs + timedelta(days=1)).timestamp()))
        cron = FakeCron()
        routines.skip_due(routines.Stores(self.root), cron)
        self.assertEqual(cron.updates, [])
        self.assertIn("[redde-skip:", self.stored(home)["name"])

    def test_a_skipped_jobs_note_reads_as_its_name(self):
        self.assertEqual(routines.untagged("[redde-notify] Daily brief [redde-skip:1793000000]"), "Daily brief")

    def test_the_app_can_skip_at_once_over_the_dashboard(self):
        runs = datetime(2026, 11, 3, 9, tzinfo=timezone.utc)
        home = self.marked(runs.isoformat(), 0)
        job = self.stored(home)
        job["name"] = "[redde] Morning ideas"
        (home / "cron" / "jobs.json").write_text(json.dumps({"jobs": [job]}))
        original = plugin._home
        plugin._home = lambda: self.root
        try:
            said = plugin._skip_slash(["default", "job1", str(int(runs.timestamp()))], cron=FakeCron())
            self.assertTrue(said.startswith("redde-push skipped job1 2026-11-04T09:00"), said)
            self.assertEqual(plugin._skip_slash(["default", "nope", "1"], cron=FakeCron()), "redde-push skip unknown")
            self.assertIn("for the Redde app", plugin._skip_slash(["../x", "job1", "1"]))
        finally:
            plugin._home = original


class NoEmailTests(RoutinesTests):
    def test_a_watch_that_cant_read_email_says_so_once_and_is_paused(self):
        paused = []
        original = watches.pause
        watches.pause = lambda home, job: paused.append(job) or True
        try:
            home = self.job("default", last="2026-11-02T07:00:00", deliver="local", name="[redde-watch:t-urgentmail] Urgent email")
            self.watch.look()
            self.output(home, "## Response\n\nNO EMAIL ACCESS.")
            self.job("default", last="2026-11-02T07:15:00", deliver="local", name="[redde-watch:t-urgentmail] Urgent email")
            self.assertEqual(self.watch.look(), 1)
        finally:
            watches.pause = original
        made = self.sent[0][1]
        self.assertEqual((made["k"], made["w"], made["i"]), ("watch", "noemail", "t-urgentmail"))
        self.assertIn("email MCP", made["b"])
        self.assertEqual(paused, ["job1"])

    def test_no_email_answers(self):
        for answer in ("NO EMAIL ACCESS", "No email access.", "**NO EMAIL ACCESS**"):
            self.assertTrue(watches.no_email(answer), answer)
        self.assertFalse(watches.no_email("A new email from the school: pickup at 2."))
        self.assertTrue(watches.pause(self.root, "job1", cron=FakeCron()))


if __name__ == "__main__":
    unittest.main()

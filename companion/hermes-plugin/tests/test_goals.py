"""Goals and skipping a run (`goals.py`, `routines.skip`): python -m unittest discover -s companion/hermes-plugin/tests"""
import json
import time
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

    def archive_task(self, conn, task_id, **_):
        for task in self.tasks:
            if task.id == task_id:
                task.status = "archived"
        return True

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
        self.assertIn("whether they do it or you do", goals.NOTE)
        self.assertLess(len(goals.NOTE), 560, "a turn's note: short")

    def test_check_ins_default_to_mondays_or_every_other_day_when_its_soon(self):
        today = date(2026, 11, 2)
        self.assertEqual(goals.schedule_for(None, today=today), goals.WEEKLY)
        self.assertEqual(goals.schedule_for("2026-12-31", today=today), goals.WEEKLY)
        self.assertEqual(goals.schedule_for("2026-11-10", today=today), goals.OTHER_DAY)
        self.assertEqual(goals.schedule_for("2026-12-31", "daily", today=today), goals.DAILY)
        self.assertEqual(goals.schedule_for(None, "30 18 * * 5", today=today), "30 18 * * 5")
        self.assertEqual(goals.schedule_for(None, "every so often", today=today), goals.WEEKLY)

    def test_setting_a_goal_puts_only_the_agents_steps_on_the_board_ready_and_keeps_it(self):
        board = FakeBoard()
        said = goals.set_up(self.root, "default", "Run a 10K", "2027-03-01",
                            [{"title": "Run 3K twice a week", "who": "you"}, {"title": "Find a training plan", "who": "agent"},
                             "Sign up for a race"],
                            make=self.made(), board=board, today=date(2026, 11, 2))
        goal = said["set"]
        self.assertIn("Kanban", said["said"])
        self.assertIn("checklist", said["said"])
        self.assertEqual(said["check_ins"], goals.WEEKLY)
        # Agreeing in the chat was the approval: the agent's step starts at once; theirs aren't cards.
        self.assertEqual([(t.title, t.status, t.tenant, t.assignee) for t in board.tasks],
                         [("Find a training plan", "ready", f"redde-goal-{goal}", "default")])
        job = self.jobs[0]
        self.assertEqual((job["name"], job["schedule"], job["deliver"]), (f"[redde-goal:{goal}] Run a 10K", goals.WEEKLY, "local"))
        self.assertTrue(job["prompt"].startswith(f"[redde-goal:{goal}]"))
        kept = goals.load(self.root)[0]
        self.assertEqual((kept["title"], kept["by"], kept["job"]), ("Run a 10K", "2027-03-01", "job1"))
        self.assertEqual([(s["who"], s["card"]) for s in kept["steps"]], [("you", None), ("agent", "t1"), ("you", None)],
                         "a plain string is theirs: nothing starts on its own")

    def test_without_a_board_the_steps_are_kept_here(self):
        said = goals.set_up(self.root, "scout", "Read 20 books", None, ["Pick the list"], make=self.made(), board=no_board)
        self.assertNotIn("Kanban", said["said"])
        self.assertEqual(goals.load(self.root)[0]["steps"], [{"title": "Pick the list", "who": "you", "card": None, "done": False}])

    def test_odd_asks_are_refused(self):
        self.assertIn("error", goals.set_up(self.root, "default", "", make=self.made()))
        self.assertIn("error", goals.set_up(self.root, "default", "Run", "next March", make=self.made()))
        self.assertIn("error", goals.update(self.root, "nope", done=[1]))

    def test_steps_are_marked_done_and_added_after_the_others(self):
        board = FakeBoard()
        goal = goals.set_up(self.root, "default", "Run a 10K", None, [{"title": "Run 3K", "who": "agent"}, "Run 5K"],
                            make=self.made(), board=board)["set"]
        edits = []
        said = goals.update(self.root, goal, done=[1, 9, "x"], add=[{"title": "Run 8K", "who": "agent"}], every="daily", board=board,
                            edit=lambda job, updates: edits.append((job, updates)))
        self.assertEqual(said["steps_done"], "1/3")
        self.assertEqual([t.idempotency_key for t in board.tasks][-1], f"redde-goal-{goal}-3", "its own card, not step 1's again")
        self.assertEqual(edits, [("job1", {"schedule": goals.DAILY})])
        listed = goals.status(self.root)["goals"][0]
        self.assertEqual(listed["steps"], ["1. Run 3K (yours, done)", "2. Run 5K (theirs)", "3. Run 8K (yours)"])
        self.assertEqual(goals.update(self.root, goal, undone=[1])["steps_done"], "0/3", "a step not done after all")

    def test_ending_a_goal_stops_its_check_ins(self):
        goal = goals.set_up(self.root, "default", "Run a 10K", make=self.made(), board=no_board)["set"]
        removed = []
        goals.end(self.root, goal, remove=removed.append)
        self.assertEqual(removed, ["job1"])
        self.assertEqual(goals.status(self.root)["goals"], [])

    def test_a_check_in_is_told_its_steps_and_how_to_answer(self):
        board = FakeBoard()
        goal = goals.set_up(self.root, "default", "Run a 10K", "2027-03-01",
                            [{"title": "Find a plan", "who": "agent"}, {"title": "Run 5K", "who": "you"}], make=self.made(), board=board)["set"]
        board.tasks[0].status = "done"
        asked = self.jobs[0]["prompt"]
        note = goals.checkin_note(self.root, asked, "cron", board=board)
        self.assertIn("1. Find a plan (yours, done); 2. Run 5K (theirs, to do)", note)
        self.assertIn("never mark one done unless they told you", note, "theirs are asked about, not guessed")
        self.assertIn("Target: 2027-03-01", note)
        self.assertIn("PROGRESS: <steps done>/<steps>", note)
        self.assertIn("suggest_to_user", note)
        self.assertIn("never done because you set a reminder", note,
                      "a reminder set isn't the step done (2026-11-22: \"drink around Christmas\" struck through in November)")
        self.assertIn("even when you'll remind them of it", goals.NOTE, "real-life steps are planned as theirs")
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
        self.assertEqual(goals.load(self.root)[0]["progress"]["details"], "The knee is fine now.")

    def test_a_check_ins_report_keeps_its_lines(self):
        goals.save(self.root, [{"id": "g1", "title": "Run a 10K", "steps": []}])
        home = self.goal_job(last="2026-11-02T09:00:00")
        self.watch.look()
        report = "| Run | km |\n|---|---|\n| Tue | 4 |\n| Sun | 6 |\n\n- **Rest** tomorrow"
        self.output(home, "## Response\n\nPROGRESS: 2/5 | Two runs | Book the race\n\n" + report)
        self.goal_job(last="2026-11-09T09:00:00")
        self.watch.look()
        self.assertEqual(self.sent[0][1]["b"], "Two runs\nNext: Book the race\n" + report)
        self.assertEqual(goals.load(self.root)[0]["progress"]["details"], report)

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
        self.assertEqual(listed[0]["steps"], [{"title": "Beta", "card": "t9", "who": "you", "done": True}],
                         "kept before 1.35, its card not let go on the board: theirs")

    def test_the_person_ticks_their_step_from_the_phone(self):
        board = FakeBoard()
        goal = goals.set_up(self.root, "default", "Run a 10K", None, [{"title": "Run 5K", "who": "you"}, {"title": "Find a race", "who": "agent"}],
                            make=self.made(), board=board)["set"]
        self.assertTrue(goals.tick(self.root, goal, 1, True, board))
        self.assertTrue(goals.load(self.root)[0]["steps"][0]["done"])
        self.assertTrue(goals.tick(self.root, goal, 1, False, board))
        self.assertFalse(goals.load(self.root)[0]["steps"][0]["done"], "a tick taken back")
        self.assertFalse(goals.tick(self.root, goal, 3, True, board))
        self.assertFalse(goals.tick(self.root, "nope", 1, True, board))
        self.assertEqual(board.tasks[0].status, "ready", "the agent's card is left alone")

    def test_the_app_ticks_a_step_over_either_connection(self):
        goal = goals.set_up(self.root, "default", "Run a 10K", None, ["Run 5K"], make=self.made(), board=no_board)["set"]
        original = plugin._home
        plugin._home = lambda: self.root
        try:
            self.assertEqual(plugin._goal_step_slash(["default", goal, "1", "done"], board=no_board), f"redde-push goals step {goal} 1 done")
            self.assertTrue(goals.load(self.root)[0]["steps"][0]["done"])
            self.assertEqual(plugin._goal_step_slash(["default", goal, "1", "undo"], board=no_board), f"redde-push goals step {goal} 1 undone")
            self.assertEqual(plugin._goal_step_slash(["default", goal, "4", "done"], board=no_board), "redde-push goals unknown")
            self.assertIn("for the Redde app", plugin._goal_step_slash(["default", goal, "x", "done"]))
            self.assertIn("for the Redde app", plugin._goal_step_slash(["../x", goal, "1", "done"]))
        finally:
            plugin._home = original

    def test_a_step_kept_before_owners_is_theirs_while_its_card_waits_in_triage(self):
        board = FakeBoard()
        board.create_task(None, title="Run 5K", tenant="redde-goal-g1", triage=True, idempotency_key="k1")
        board.create_task(None, title="Find a race", tenant="redde-goal-g1", idempotency_key="k2")
        goals.save(self.root, [{"id": "g1", "title": "Run a 10K", "steps": [{"title": "Run 5K", "card": "t1", "done": False},
                                                                             {"title": "Find a race", "card": "t2", "done": False}]}])
        kept = goals.load(self.root)[0]["steps"]
        statuses = goals._card_statuses("g1", board)
        self.assertEqual([goals.owner(s, statuses) for s in kept], ["you", "agent"])
        self.assertTrue(goals.tick(self.root, "g1", 1, True, board))
        self.assertEqual(board.tasks[0].status, "archived", "ticked by the person: its waiting card leaves the board")
        self.assertEqual((goals.load(self.root)[0]["steps"][0]["who"], goals.load(self.root)[0]["steps"][0]["card"]), ("you", None))
        self.assertEqual(board.tasks[1].status, "ready")

    def _aged(self, goal, **fields):
        kept = goals.load(self.root)
        for g in kept:
            if g["id"] == goal:
                g.update(fields)
        goals.save(self.root, kept)
        return next(g for g in goals.load(self.root) if g["id"] == goal)

    def test_a_quiet_goal_is_asked_about_once_then_paused_never_ended(self):
        goal = goals.set_up(self.root, "default", "Run a 10K", None, [{"title": "Run 5K", "who": "you"}], make=self.made(), board=no_board)["set"]
        asked = self.jobs[0]["prompt"]
        self.assertTrue(goals.load(self.root)[0]["moved"], "a new goal has just moved")
        self.assertNotIn("Nothing has moved", goals.checkin_note(self.root, asked, "cron", board=no_board))
        now = time.time()
        self._aged(goal, moved=int(now - 15 * 86400))
        note = goals.checkin_note(self.root, asked, "cron", board=no_board)
        self.assertIn("Nothing has moved on this goal for 15 days: ask them, once", note)
        self.assertIn("Nothing has moved", goals.checkin_note(self.root, asked, "cron", board=no_board), "the same run hears it at each model call")
        self._aged(goal, asked=int(now - 8 * 3600))
        self.assertNotIn("Nothing has moved", goals.checkin_note(self.root, asked, "cron", board=no_board), "asked once, not at each check-in")
        self.assertFalse(goals.after_checkin(self.root, goal, pause=lambda job: None), "nothing to pause yet")
        self._aged(goal, asked=int(now - 8 * 86400))
        self.assertIn("you're pausing its check-ins", goals.checkin_note(self.root, asked, "cron", board=no_board))
        paused = []
        self.assertTrue(goals.after_checkin(self.root, goal, pause=paused.append))
        self.assertEqual(paused, ["job1"])
        kept = goals.load(self.root)[0]
        self.assertTrue(kept["faded"] and not kept.get("ended"), "paused, not ended")
        listed = goals.listing(routines.Stores(self.root))[0]
        self.assertTrue(listed["faded"] and listed["asked"] and listed["quiet"] >= 15)
        resumed = []
        self.assertTrue(goals.keep(self.root, goal, resume=resumed.append))
        self.assertEqual(resumed, ["job1"])
        kept = goals.load(self.root)[0]
        self.assertFalse(kept.get("asked") or kept.get("faded"))
        self.assertEqual(goals.listing(routines.Stores(self.root))[0]["quiet"], 0)

    def test_ticking_a_step_or_progress_moves_the_goal(self):
        goal = goals.set_up(self.root, "default", "Run a 10K", None, [{"title": "Run 5K", "who": "you"}, "Find a race"], make=self.made(), board=no_board)["set"]
        old = int(time.time() - 20 * 86400)
        self._aged(goal, moved=old, asked=old)
        goals.tick(self.root, goal, 1, True, no_board)
        self.assertGreater(goals.load(self.root)[0]["moved"], old)
        self.assertNotIn("asked", goals.load(self.root)[0], "a question answered by doing")
        self._aged(goal, moved=old)
        goals.remember(self.root, goal, {"done": 1, "total": 2, "headline": "h", "next": ""})
        self.assertEqual(goals.load(self.root)[0]["moved"], old, "the first progress isn't news")
        goals.remember(self.root, goal, {"done": 1, "total": 2, "headline": "h", "next": ""})
        self.assertEqual(goals.load(self.root)[0]["moved"], old, "the same count again isn't")
        goals.remember(self.root, goal, {"done": 2, "total": 2, "headline": "h", "next": ""})
        self.assertGreater(goals.load(self.root)[0]["moved"], old)

    def test_a_goal_kept_before_it_could_fade_starts_its_quiet_now(self):
        goal = goals.set_up(self.root, "default", "Run a 10K", make=self.made(), board=no_board)["set"]
        kept = goals.load(self.root)
        kept[0].pop("moved")
        goals.save(self.root, kept)
        self.assertNotIn("Nothing has moved", goals.checkin_note(self.root, self.jobs[0]["prompt"], "cron", board=no_board))
        self.assertTrue(goals.load(self.root)[0]["moved"])

    def test_the_app_keeps_a_quiet_goal_going(self):
        goal = goals.set_up(self.root, "default", "Run a 10K", make=self.made(), board=no_board)["set"]
        self._aged(goal, faded=1, asked=1)
        resumed = []
        original = plugin._home
        plugin._home = lambda: self.root
        try:
            self.assertEqual(plugin._keep_goal_slash(["default", goal], resume=resumed.append), f"redde-push goals kept {goal}")
            self.assertEqual(plugin._keep_goal_slash(["default", "nope"], resume=resumed.append), "redde-push goals unknown")
            self.assertIn("for the Redde app", plugin._keep_goal_slash(["../x", goal]))
        finally:
            plugin._home = original
        self.assertEqual(resumed, ["job1"])

    def test_a_check_ins_question_with_choices_is_read(self):
        asked, rest = goals.question("Good week.\n**ASK: Aim for an hour, or just finish? | Under an hour | Just finish**\nRest tomorrow.")
        self.assertEqual(asked, {"q": "Aim for an hour, or just finish?", "choices": ["Under an hour", "Just finish"]})
        self.assertEqual(rest, "Good week.\nRest tomorrow.")
        self.assertEqual(len(goals.question("ASK: Which? | a | b | c | d | e | f")[0]["choices"]), goals.CHOICES)
        self.assertIsNone(goals.question("ASK: Which one? | only this")[0], "a choice takes two")
        self.assertIsNone(goals.question("Nothing to ask.")[0])

    def test_a_check_in_is_kept_in_the_goals_log_with_its_question(self):
        goals.save(self.root, [{"id": "g1", "title": "Run a 10K", "steps": [], "question": {"q": "Old?", "choices": ["a", "b"]}}])
        home = self.goal_job(last="2026-11-02T09:00:00")
        self.watch.look()
        self.output(home, "## Response\n\nPROGRESS: 2/5 | Two runs | Book the race\n\nASK: Aim for an hour? | Under an hour | Just finish")
        self.goal_job(last="2026-11-09T09:00:00")
        self.watch.look()
        kept = goals.load(self.root)[0]
        self.assertEqual(kept["question"]["choices"], ["Under an hour", "Just finish"], "the new question, the old one over")
        self.assertEqual([(c["done"], c["headline"]) for c in kept["checkins"]], [(2, "Two runs")])
        self.assertTrue(self.sent[0][1]["b"].endswith("Aim for an hour?"), "the briefing still asks, in words")
        for n in range(goals.CHECKINS + 2):
            goals.remember(self.root, "g1", {"done": 2, "total": 5, "headline": f"Week {n}", "next": ""}, at=2_000_000_000 + n)
        kept = goals.load(self.root)[0]
        self.assertEqual(len(kept["checkins"]), goals.CHECKINS, "the last dozen")
        self.assertNotIn("question", kept, "a check-in that asks nothing ends the question")

    def test_what_they_tell_redde_goes_to_the_next_check_in(self):
        goal = goals.set_up(self.root, "default", "Run a 10K", None, [{"title": "Run 5K", "who": "you"}], make=self.made(), board=no_board)["set"]
        goals.remember(self.root, goal, {"done": 0, "total": 1, "headline": "Starting", "next": ""}, asked={"q": "Aim for an hour?", "choices": ["Yes", "No"]},
                       at=time.time() - 60)
        self.assertTrue(goals.tell(self.root, goal, "Ran 4 km, knee fine"))
        self.assertTrue(goals.tell(self.root, goal, "Yes", answering=True))
        self.assertFalse(goals.tell(self.root, goal, "   "))
        self.assertFalse(goals.tell(self.root, "nope", "Hello"))
        kept = goals.load(self.root)[0]
        self.assertNotIn("question", kept, "answered")
        self.assertEqual([(n.get("q"), n["text"]) for n in kept["notes"]], [(None, "Ran 4 km, knee fine"), ("Aim for an hour?", "Yes")])
        note = goals.checkin_note(self.root, self.jobs[0]["prompt"], "cron", board=no_board)
        self.assertIn('They told Redde: "Ran 4 km, knee fine".', note)
        self.assertIn('They answered your question "Aim for an hour?": "Yes".', note)
        self.assertIn("ASK: <question> | <choice> | <choice>", note)
        goals.remember(self.root, goal, {"done": 1, "total": 1, "headline": "Done", "next": ""}, at=time.time() + 5)
        self.assertNotIn("They told Redde", goals.checkin_note(self.root, self.jobs[0]["prompt"], "cron", board=no_board),
                         "heard by the check-in after them, not again")

    def test_a_step_done_keeps_when(self):
        goal = goals.set_up(self.root, "default", "Run a 10K", None, [{"title": "Run 5K", "who": "you"}, {"title": "Find a race", "who": "agent"}],
                            make=self.made(), board=no_board)["set"]
        goals.tick(self.root, goal, 1, True)
        goals.update(self.root, goal, done=[2], board=no_board)
        steps = goals.load(self.root)[0]["steps"]
        self.assertTrue(all(isinstance(s.get("at"), int) for s in steps))
        listed = goals.listing(routines.Stores(self.root))[0]
        self.assertEqual([("at" in s) for s in listed["steps"]], [True, True])
        self.assertEqual((listed["checkins"], listed["notes"], listed["question"]), ([], [], None))
        goals.tick(self.root, goal, 1, False)
        self.assertNotIn("at", goals.load(self.root)[0]["steps"][0], "a tick taken back")

    def test_the_app_tells_a_goal_over_the_dashboard(self):
        goal = goals.set_up(self.root, "default", "Run a 10K", make=self.made(), board=no_board)["set"]
        original = plugin._home
        plugin._home = lambda: self.root
        try:
            words = core.b64u("Ran 4 km".encode())
            self.assertEqual(plugin._tell_goal_slash("note", ["default", goal, words]), f"redde-push goals told {goal}")
            self.assertEqual(plugin._tell_goal_slash("answer", ["default", "nope", words]), "redde-push goals unknown")
            self.assertNotIn("told", plugin._tell_goal_slash("note", ["default", goal, "%%%"]), "nothing to say, nothing kept")
            self.assertIn("for the Redde app", plugin._tell_goal_slash("note", ["../x", goal, words]))
        finally:
            plugin._home = original
        self.assertEqual(goals.load(self.root)[0]["notes"][0]["text"], "Ran 4 km")

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

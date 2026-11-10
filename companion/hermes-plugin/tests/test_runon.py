"""A job's own model, Redde's Run On (`routines.set_model`, `models_due`, `/redde-push job-model`):
python -m unittest discover -s companion/hermes-plugin/tests"""
import json
import unittest
from datetime import datetime, timedelta, timezone

from test_goals import FakeCron
from test_routines import RoutinesTests, plugin

routines = plugin.routines


class RunOnTests(RoutinesTests):
    def marked(self, name, profile="default", **fields):
        home = self.root if profile == "default" else self.root / "profiles" / profile
        (home / "cron").mkdir(parents=True, exist_ok=True)
        job = {"id": "job1", "name": name, "deliver": "local", "schedule": {"kind": "cron", "expr": "0 21 * * *"},
               "next_run_at": "2026-11-03T21:00:00+00:00", **fields}
        (home / "cron" / "jobs.json").write_text(json.dumps({"jobs": [job]}))
        return home

    def stored(self, home):
        return json.loads((home / "cron" / "jobs.json").read_text())["jobs"][0]

    def test_a_marked_job_gets_its_model_and_the_mark_comes_off(self):
        home = self.marked("[redde] Evening wrap-up [redde-model:qwen3-4b|custom:local]", profile="scout")
        cron = FakeCron()
        self.assertEqual(routines.models_due(routines.Stores(self.root), cron), 1)
        job = self.stored(home)
        self.assertEqual((job["name"], job["model"], job["provider"]), ("[redde] Evening wrap-up", "qwen3-4b", "custom:local"))
        self.assertEqual(cron.home, home, "in that profile's own store")
        self.assertEqual(routines.models_due(routines.Stores(self.root), cron), 0, "once")

    def test_an_empty_mark_puts_the_job_back_on_the_main_model(self):
        home = self.marked("[redde] Week ahead [redde-model:|]", model="qwen3-4b", provider="custom:local")
        routines.models_due(routines.Stores(self.root), FakeCron())
        job = self.stored(home)
        self.assertEqual((job["name"], job["model"], job["provider"]), ("[redde] Week ahead", None, None))

    def test_a_model_and_a_skip_in_one_name_are_each_taken_up(self):
        runs = datetime(2026, 11, 3, 21, tzinfo=timezone.utc)
        home = self.marked(f"[redde] Evening wrap-up [redde-skip:{int(runs.timestamp())}] [redde-model:qwen3-4b|custom:local]",
                           next_run_at=runs.isoformat())
        cron = FakeCron()
        routines.models_due(routines.Stores(self.root), cron)
        self.assertEqual(self.stored(home)["name"], f"[redde] Evening wrap-up [redde-skip:{int(runs.timestamp())}]")
        routines.skip_due(routines.Stores(self.root), cron)
        job = self.stored(home)
        self.assertEqual((job["name"], job["model"]), ("[redde] Evening wrap-up", "qwen3-4b"))
        self.assertEqual(datetime.fromisoformat(job["next_run_at"]), runs + timedelta(days=1))

    def test_names_read_without_the_marks(self):
        self.assertEqual(routines.untagged("[redde-notify] Daily brief [redde-model:qwen3-4b|custom:local]"), "Daily brief")
        self.assertEqual(routines.unmarked("Wrap-up [redde-model:a|b] [redde-skip:1793000000]"), "Wrap-up")
        self.assertEqual(routines.model_marked("Wrap-up [redde-model:|]"), ("", ""))
        self.assertIsNone(routines.model_marked("Wrap-up"))

    def test_a_marked_daily_job_still_reaches_the_phone_as_itself(self):
        # (look() matches the plugin's daily jobs by their exact name: a mark mustn't hide them)
        from test_routines import plugin as p
        self.assertEqual(routines.unmarked(p.ideas.JOBS and next(iter(p.ideas.JOBS)) + " [redde-model:m|p]"),
                         next(iter(p.ideas.JOBS)))

    def test_the_app_can_set_a_model_at_once_over_the_dashboard(self):
        home = self.marked("[redde] Evening wrap-up")
        original = plugin._home
        plugin._home = lambda: self.root
        try:
            said = plugin._job_model_slash(["default", "job1", "qwen3-4b", "custom:local"], cron=FakeCron())
            self.assertEqual(said, "redde-push job-model set job1 qwen3-4b")
            self.assertEqual((self.stored(home)["model"], self.stored(home)["provider"]), ("qwen3-4b", "custom:local"))
            said = plugin._job_model_slash(["default", "job1", "-", "-"], cron=FakeCron())
            self.assertEqual(said, "redde-push job-model set job1 -")
            self.assertIsNone(self.stored(home)["model"])
            self.assertEqual(plugin._job_model_slash(["default", "nope", "m", "p"], cron=FakeCron()), "redde-push job-model unknown")
            self.assertIn("for the Redde app", plugin._job_model_slash(["../x", "job1", "m", "p"]))
            self.assertIn("for the Redde app", plugin._job_model_slash(["default", "job1", "m]", "p"]))
        finally:
            plugin._home = original


if __name__ == "__main__":
    unittest.main()

"""Reports of handed-off tasks kept for the chat (`tasks.py`): python -m unittest discover -s companion/hermes-plugin/tests"""
import json
import tempfile
import time
import unittest
from pathlib import Path

from test_routines import plugin

tasks = plugin.task_reports


class TaskReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def listed(self, session):
        said = tasks.slash(self.home, [session])
        self.assertTrue(said.startswith("redde-push tasks "))
        return json.loads(said.removeprefix("redde-push tasks "))["tasks"]

    def test_a_report_is_kept_for_its_session(self):
        now = time.time()
        tasks.keep(self.home, "s1", [("completed", "12 files.")], "12 files.", "", now=now)
        tasks.keep(self.home, "s2", [("completed", "Other."), ("failed", "")], "Other.", "2 tasks, 1 not completed", now=now)
        self.assertEqual([(r["summary"], r["at"]) for r in self.listed("s1")], [("12 files.", now)])
        [other] = self.listed("s2")
        self.assertEqual((other["tasks"], other["failed"], other["about"]), (2, 1, "2 tasks, 1 not completed"))
        self.assertEqual(self.listed("s3"), [])

    def test_old_reports_go_and_a_session_keeps_its_newest(self):
        tasks.keep(self.home, "s1", [("completed", "old")], "old", "", now=0)
        for n in range(tasks.PER_SESSION + 2):
            tasks.keep(self.home, "s1", [("completed", f"r{n}")], f"r{n}", "", now=tasks.KEPT_FOR - 100 + n)
        shown = [r["summary"] for r in tasks.of(self.home, "s1", now=tasks.KEPT_FOR + 1)]
        self.assertEqual(shown, [f"r{n}" for n in range(2, tasks.PER_SESSION + 2)])

    def test_the_command_takes_one_session(self):
        self.assertEqual(tasks.slash(self.home, []), "redde-push tasks: this command is for the Redde app.")
        self.assertEqual(tasks.slash(self.home, ["a b/c"]), "redde-push tasks: this command is for the Redde app.")
        self.assertIsNone(tasks.keep(self.home, "", [], "x", ""))

    def test_a_long_summary_is_cut(self):
        tasks.keep(self.home, "s1", [("completed", "x")], "x" * (tasks.LONGEST + 50), "", now=10)
        self.assertEqual(len(tasks.of(self.home, "s1", now=11)[0]["summary"]), tasks.LONGEST)

    def test_the_file_is_the_persons_alone(self):
        tasks.keep(self.home, "s1", [("completed", "x")], "x", "")
        self.assertEqual(tasks.path(self.home).stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()

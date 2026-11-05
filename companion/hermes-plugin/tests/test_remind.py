"""A reminder's run answered with no model (`remind.py`): python -m unittest discover -s companion/hermes-plugin/tests

2026-11-03: "Remind me to stretch at exactly 805" made the right job, but its run asked the model
again, which tried to set a phone alarm for 7:00, waited four minutes and said it couldn't."""
import importlib.util
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "redde-push"
if "redde_push" not in sys.modules:
    spec = importlib.util.spec_from_file_location("redde_push", HERE / "__init__.py", submodule_search_locations=[str(HERE)])
    plugin = importlib.util.module_from_spec(spec)
    sys.modules["redde_push"] = plugin
    spec.loader.exec_module(plugin)
plugin = sys.modules["redde_push"]
core, routines, remind = plugin.core, plugin.routines, plugin.remind

# The 8:05 job as it was on dchermes.
STRETCH = {"id": "a67adea58537", "name": "[redde-notify] Stretch", "prompt": "Tell the person in one line: stretch.",
           "schedule": {"kind": "once", "run_at": "2026-11-03T20:05:00-05:00"}, "repeat": {"times": 1, "completed": 0},
           "deliver": "local", "last_run_at": None}
HEADS_UP = {"id": "89037d641f8f", "name": "[redde-notify] Heads-up: BI Team Sync",
            "prompt": "Heads-up for the user: \"BI Team Sync\" starts at 17:00 today.", "last_run_at": None}
RUN = "cron_a67adea58537_20261103_200518"


class RemindTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.root = Path(self.home.name)
        self.store = core.Store(self.root)
        self.store.add({"id": "phone-1", "name": "Marta"})
        self.sent = []
        self.reach = 1
        self.jobs([STRETCH, HEADS_UP])
        self.reminders = remind.Reminders(lambda: self.root, lambda: self.store, self.send)

    def tearDown(self):
        self.home.cleanup()

    def jobs(self, jobs, profile="default"):
        home = self.root if profile == "default" else self.root / "profiles" / profile
        (home / "cron").mkdir(parents=True, exist_ok=True)
        (home / "cron" / "jobs.json").write_text(json.dumps({"jobs": jobs}))

    def send(self, profile, home, job, text):
        self.sent.append((profile, job["id"], text))
        return self.reach

    def model(self, request):
        self.asked.append(request)
        return "the model's answer"

    def turn(self, session, api_mode="chat_completions"):
        self.asked = []
        reply = self.reminders.turn({"messages": [{"role": "user", "content": "…"}]}, self.model, session_id=session, api_mode=api_mode)
        deadline = time.time() + 2
        while self.reach and not self.sent and time.time() < deadline and self.asked == []:
            time.sleep(0.01)   # the notification goes from a thread of its own
        return reply

    def test_a_reminder_is_known_by_its_tag_and_prompt(self):
        self.assertEqual(remind.what(STRETCH), "stretch")
        self.assertEqual(remind.what({**STRETCH, "prompt": "Tell the person in one line: “Call the dentist”"}), "Call the dentist")
        self.assertIsNone(remind.what(HEADS_UP))
        self.assertIsNone(remind.what({**STRETCH, "name": "Stretch"}), "no [redde-notify]: not Redde's")
        self.assertIsNone(remind.what({**STRETCH, "no_agent": True}), "a script's job runs no model anyway")
        self.assertEqual(remind.line("stretch"), "Reminder: stretch.")
        self.assertEqual(remind.line("Time to stretch!"), "Reminder: Time to stretch!")

    def test_its_run_is_answered_with_no_model_and_told_at_once(self):
        reply = self.turn(RUN)
        self.assertEqual(self.asked, [], "the model is never asked")
        self.assertEqual(reply.choices[0].message.content, "Reminder: stretch.")
        self.assertIsNone(reply.choices[0].message.tool_calls)
        self.assertEqual(reply.choices[0].finish_reason, "stop")
        self.assertEqual(self.sent, [("default", "a67adea58537", "Reminder: stretch.")])
        self.assertTrue(remind.told_lately(self.store, "default|a67adea58537", time.time()))
        # A second model call in the same run (a retry) gets the same answer, and no second notification.
        self.turn(RUN)
        self.assertEqual(len(self.sent), 1)

    def test_every_api_mode_gets_its_own_shape(self):
        anthropic = self.turn("cron_a67adea58537_20261103_200519", "anthropic_messages")
        self.assertEqual((anthropic.content[0].text, anthropic.stop_reason), ("Reminder: stretch.", "end_turn"))
        codex = self.turn("cron_a67adea58537_20261103_200520", "codex_responses")
        self.assertEqual(codex.output_text, "Reminder: stretch.")

    def test_everything_else_goes_to_its_model(self):
        for session in ("20261102_202749_3021cb", "cron_89037d641f8f_20261103_122153", "cron_ffffffffffff_20261103_200518", ""):
            self.assertEqual(self.turn(session), "the model's answer", session)
            self.assertEqual(len(self.asked), 1, session)
        self.assertEqual(self.sent, [])

    def test_a_bots_reminder_is_found_in_its_profile(self):
        self.jobs([{**STRETCH, "id": "b0b0b0b0b0b0"}], profile="ops")
        self.turn("cron_b0b0b0b0b0b0_20261103_200518")
        self.assertEqual(self.sent, [("ops", "b0b0b0b0b0b0", "Reminder: stretch.")])

    def test_reaching_no_phone_leaves_it_to_the_reader_of_the_schedules(self):
        self.reach = 0
        self.turn(RUN)
        deadline = time.time() + 2
        while remind.told_lately(self.store, "default|a67adea58537", time.time()) and time.time() < deadline:
            time.sleep(0.01)
        self.assertFalse(remind.told_lately(self.store, "default|a67adea58537", time.time()))


class ReaderTests(unittest.TestCase):
    """The half-minute reader of the schedules doesn't say a told reminder again."""

    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.root = Path(self.home.name)
        self.store = core.Store(self.root)
        self.store.add({"id": "phone-1", "name": "Marta"})
        self.sent = []
        self.watch = routines.Routines(self.store, lambda devices, made: self.sent.append(made) or len(devices), routines.Stores(self.root))

    def tearDown(self):
        self.home.cleanup()

    def ran(self, jobs):
        (self.root / "cron").mkdir(parents=True, exist_ok=True)
        (self.root / "cron" / "jobs.json").write_text(json.dumps({"jobs": jobs}))

    def output(self, job_id, text):
        folder = self.root / "cron" / "output" / job_id
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "2026-11-03_20-05-19.md").write_text(f"# Cron\n\n## Response\n\n{text}\n")

    def test_a_told_reminder_isnt_sent_again_but_an_untold_one_is(self):
        self.ran([STRETCH, {**STRETCH, "id": "c0c0c0c0c0c0"}])
        self.watch.look()   # first seen, not run
        self.output("a67adea58537", "Reminder: stretch.")
        self.output("c0c0c0c0c0c0", "Reminder: stretch.")
        self.store.tell_reminder("default|a67adea58537")
        self.ran([{**STRETCH, "last_run_at": "2026-11-03T20:05:19-05:00"},
                  {**STRETCH, "id": "c0c0c0c0c0c0", "last_run_at": "2026-11-03T20:05:19-05:00"}])
        self.watch.look()
        self.assertEqual([(m["t"], m["b"], m["i"]) for m in self.sent], [("Stretch", "Reminder: stretch.", "c0c0c0c0c0c0")])

    def test_marks_are_kept_a_day(self):
        self.store.tell_reminder("default|x")
        self.assertIn("default|x", self.store.reminders_told())
        self.store.untell_reminder("default|x")
        self.assertNotIn("default|x", self.store.reminders_told())


if __name__ == "__main__":
    unittest.main()

"""python -m unittest discover -s companion/hermes-plugin/tests

1.36.0's three for the day (2026-11-22): things to keep in mind (facts.py), the jobs that wait for
the person to go quiet (silence.py), and backing off what goes unanswered or finds nothing (ideas
left alone, idle watches)."""
import json
import tempfile
import time
import unittest
from pathlib import Path

from test_calls import plugin

core, facts, silence, ideas, watches, remind = plugin.core, plugin.facts, plugin.silence, plugin.ideas, plugin.watches, plugin.remind


class FactsTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())

    def test_facts_are_kept_once_listed_and_let_go(self):
        self.assertIn("kept", facts.add(self.root, "Driving into France I need 3-day car insurance"))
        self.assertIn("already", facts.add(self.root, "driving into france  I need 3-day car insurance.")["said"])
        facts.add(self.root, "Pickles needs his jab every March", by="scout")
        self.assertEqual(facts.change(self.root, {"action": "list"})["facts"],
                         ["1. Driving into France I need 3-day car insurance", "2. Pickles needs his jab every March"])
        self.assertIn("error", facts.add(self.root, "  "))
        self.assertEqual(facts.remove(self.root, "1")["removed"], 1)
        self.assertEqual(facts.texts(self.root), ["Pickles needs his jab every March"])
        self.assertIn("error", facts.change(self.root, {"action": "remove", "text": "nope"}))

    def test_a_run_that_plans_ahead_is_told_them_and_to_look_around_each_event(self):
        heads_up = "Heads-ups, 30 minutes before. Look at the user's calendar for the rest of today."
        self.assertIsNone(facts.run_note(self.root, heads_up, "cron"), "nothing kept, nothing said")
        facts.add(self.root, "Driving into France I need 3-day car insurance")
        note = facts.run_note(self.root, heads_up, "cron")
        self.assertIn('"Driving into France I need 3-day car insurance"', note)
        self.assertIn("three days before to three days after", note)
        self.assertIn("runs out before the event is over", note)
        self.assertIn("Check their mail", note)
        self.assertIsNotNone(facts.run_note(self.root, "Morning ideas. Look at the user's day", "cron"))
        self.assertIsNotNone(facts.run_note(self.root, "Week ahead for the user. Look at the coming week", "cron"))
        self.assertIsNone(facts.run_note(self.root, heads_up, "desktop"), "only the scheduled run")
        self.assertIsNone(facts.run_note(self.root, "Evening wrap-up for the user.", "cron"))

    def test_a_message_that_sounds_like_one_is_told_it_can_be_kept(self):
        self.assertIn(facts.TOOL, facts.turn_note("Whenever I drive to France I need the 3-day insurance", "desktop"))
        self.assertIn(facts.TOOL, facts.turn_note("Keep in mind I can't do calls before 9", "api_server"))
        self.assertIsNone(facts.turn_note("Book the vet", "desktop"))
        self.assertIsNone(facts.turn_note("Whenever I drive to France…", "cron"))

    def test_the_app_lists_adds_and_removes_them(self):
        original = plugin._home
        plugin._home = lambda: self.root
        try:
            line = core.b64u("I can't do calls before 9".encode())
            self.assertEqual(plugin._slash(f"facts add {line}"), "redde-push facts added")
            listed = plugin._slash("facts list").split()[-1]
            self.assertEqual(json.loads(core.unb64u(listed)), ["I can't do calls before 9"])
            self.assertEqual(plugin._slash(f"facts remove {line}"), "redde-push facts removed")
            self.assertTrue(plugin._slash(f"facts remove {line}").startswith("redde-push facts refused"))
            self.assertIn("for the Redde app", plugin._slash("facts burn it"))
        finally:
            plugin._home = original


class QuietWakeTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        (self.root / "cron").mkdir()
        self.job = {"id": "quiet1", "name": "[redde-notify] When you've gone quiet",
                    "prompt": "[redde-quiet:24h] The user hasn't written to you for a day.", "schedule": {"kind": "cron", "expr": "0 * * * *"}}
        (self.root / "cron" / "jobs.json").write_text(json.dumps({"jobs": [self.job]}))
        self.calls = []

    def model(self, request):
        self.calls.append(request)
        return "the model"

    def wake(self, middleware, session):
        return middleware.turn("req", self.model, session_id=session, api_mode="chat_completions")

    def test_the_mark_says_how_long(self):
        self.assertEqual(silence.hours(self.job), 24)
        self.assertEqual(silence.hours({"prompt": "[redde-quiet:1h] x"}), silence.SHORTEST)
        self.assertIsNone(silence.hours({"prompt": "Check the weather"}))

    def test_its_runs_are_answered_without_the_model_until_they_go_quiet_then_once(self):
        said = silence.Said(self.root)
        now = time.time()
        said.wrote(now - 3600)
        wakes = silence.QuietWakes(lambda: self.root)
        quiet = self.wake(wakes, "cron_quiet1_20261122_100000")
        self.assertEqual(quiet.choices[0].message.content, "[SILENT]")
        self.assertEqual(self.calls, [], "no model while they're about")
        said.wrote(now - 30 * 3600)   # (written down earlier: the clock moved back for the test)
        data = json.loads(said.file.read_text())
        data["at"] = int(now - 30 * 3600)
        said.file.write_text(json.dumps(data))
        self.assertEqual(self.wake(wakes, "cron_quiet1_20261122_110000"), "the model")
        self.assertEqual(self.wake(wakes, "cron_quiet1_20261122_110000"), "the model", "the same run's next call goes on too")
        self.assertEqual(self.wake(wakes, "cron_quiet1_20261122_120000").choices[0].message.content, "[SILENT]",
                         "once a quiet stretch")
        said.wrote(time.time() + 2)
        data = json.loads(said.file.read_text())
        self.assertGreater(data["at"], data["woke"]["default|quiet1"], "their message starts a new stretch")

    def test_other_runs_and_chats_go_on_to_the_model(self):
        wakes = silence.QuietWakes(lambda: self.root)
        self.assertEqual(self.wake(wakes, "20261122_100000_abc"), "the model")
        self.assertEqual(self.wake(wakes, "cron_other99_20261122_100000"), "the model")

    def test_only_the_persons_turns_count(self):
        self.assertTrue(silence.person("api_server", "hello"))
        self.assertFalse(silence.person("cron", "Heads-ups"))
        self.assertFalse(silence.person("bot_room", "hi"))
        self.assertFalse(silence.person("desktop", ""))

    def test_a_turn_is_written_down_at_most_once_a_minute(self):
        said = silence.Said(self.root)
        said.wrote(1000)
        said.wrote(1030)
        self.assertEqual(said.last(), 1000)
        said.wrote(1061)
        self.assertEqual(said.last(), 1061)


class BackingOffTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())

    def test_ideas_left_alone_come_quietly_until_one_is_touched(self):
        quiet = []
        for _ in range(ideas.IGNORED + 2):
            made = {"k": "ideas"}
            quiet.append(ideas.quiet_if_ignored(self.root, "default", made))
        self.assertEqual(quiet, [False] * ideas.IGNORED + [True, True])
        self.assertFalse(ideas.quiet_if_ignored(self.root, "ops", {}), "each agent's own")
        ideas.touched(self.root, "default")
        made = {"k": "ideas"}
        self.assertFalse(ideas.quiet_if_ignored(self.root, "default", made))
        self.assertNotIn("z", made)

    def test_the_app_says_when_one_was_touched(self):
        original = plugin._home
        plugin._home = lambda: self.root
        try:
            for _ in range(ideas.IGNORED):
                ideas.quiet_if_ignored(self.root, "scout", {})
            self.assertEqual(plugin._slash("ideas touched scout"), "redde-push ideas touched")
            self.assertEqual(ideas.untouched(self.root, "scout"), 0)
        finally:
            plugin._home = original

    def test_a_watch_that_keeps_finding_nothing_slows_then_pauses(self):
        start = 1_800_000_000
        steps = [watches.found_nothing(self.root, "w1", now=start + n * 3600) for n in range(watches.SLOW_AFTER)]
        self.assertEqual(set(steps), {""}, "eight in eight hours: too soon to slow")
        day = 86400
        steps = [watches.found_nothing(self.root, "w1", now=start + 3 * day + n) for n in range(4)]
        self.assertEqual(steps, ["", "skip", "", "skip"], "every other run skipped, after two days")
        for n in range(watches.PAUSE_AFTER):
            last = watches.found_nothing(self.root, "w1", now=start + 8 * day + n)
            if last == "pause":
                break
        self.assertEqual(last, "pause")
        self.assertEqual(watches.idle_days(self.root, "w1")[0], 0, "counted afresh after the pause")

    def test_finding_something_starts_the_count_again(self):
        for n in range(watches.SLOW_AFTER + 3):
            watches.found_nothing(self.root, "w2", now=1_800_000_000 + n * 86400)
        watches.found_something(self.root, "w2")
        self.assertEqual(watches.found_nothing(self.root, "w2", now=1_800_000_000 + 20 * 86400), "")
        self.assertEqual(watches.idle_days(self.root, "w2", now=1_800_000_000 + 20 * 86400), (1, 0))


if __name__ == "__main__":
    unittest.main()

"""Agents Bring Up (redde-push/proactive.py, 1.58.0): one dial for what every agent brings up on its
own. Off sends none of it but what asks to be heard and ends the suggestion-only runs with no model;
Less keeps what matters soon and one set of ideas a day; More lowers the bar."""
import json
import tempfile
import time
import unittest
from pathlib import Path

from test_calls import Relay, paired, plugin

core, ideas, proactive, silence, routines = plugin.core, plugin.ideas, plugin.proactive, plugin.silence, plugin.routines


class DialTests(unittest.TestCase):
    def setUp(self):
        self.relay = Relay()
        self.addCleanup(self.relay.close)
        self.main = Path(tempfile.mkdtemp())
        self.store = core.Store(self.main)

    def offer(self, at, level=""):
        return ideas.offer(self.store, self.main, "default", "Sol", [{"title": "Book the vet", "request": "Book the vet"}],
                           now=at, level=level)

    def test_kept_in_the_main_home_and_normal_until_set(self):
        self.assertEqual(proactive.level(self.main), "normal")
        self.assertEqual(proactive.slash(self.main, ["set", "less"]), "redde-push proactive less")
        self.assertEqual(proactive.slash(self.main, []), "redde-push proactive less")
        self.assertTrue(proactive.slash(self.main, ["set", "loud"]).startswith("redde-push refused"))
        self.assertEqual(proactive.level(self.main), "less")

    def test_off_sends_no_ideas_but_what_asks_to_be_heard(self):
        paired(self.store, self.relay.url, "dev-marta")
        proactive.set_level(self.main, "off")
        said = self.offer(1000)
        self.assertIn("give them in your reply", said["error"], "asked for in a chat: in words")
        self.assertEqual(self.relay.pushes, [])
        self.assertIn("sent", self.offer(1001, level="now"))

    def test_less_sends_one_set_a_day_from_each_agent(self):
        paired(self.store, self.relay.url, "dev-marta")
        proactive.set_level(self.main, "less")
        self.assertIn("sent", self.offer(1000))
        self.assertIn("tomorrow", self.offer(5000)["error"])
        self.assertIn("sent", ideas.offer(self.store, self.main, "ops", "Home", [{"title": "x", "request": "x"}], now=5000),
                      "another agent's")
        self.assertIn("sent", self.offer(1000 + ideas.DAY + 1), "a day on")
        proactive.set_level(self.main, "normal")
        for n in range(3):
            self.assertIn("sent", self.offer(ideas.DAY + 2000 + n), "as before")

    def test_redde_own_cards_by_kind_and_mark(self):
        allowed = proactive.card_allowed
        self.assertTrue(all(allowed(d, "followup") for d in ("normal", "more")))
        self.assertFalse(allowed("less", "followup"))
        self.assertTrue(allowed("less", "bill") and allowed("less", "trip") and allowed("less", "", "look"))
        self.assertFalse(allowed("less", "", ""), "what's new on Jellyfin, usual buys, Days Out")
        self.assertFalse(allowed("off", "bill"))
        self.assertTrue(allowed("off", "security", "now"))

    def test_follow_through_cards_held_back_count_as_said(self):
        paired(self.store, self.relay.url, "dev-marta")
        proactive.set_level(self.main, "less")
        reader = routines.Routines.__new__(routines.Routines)
        reader.store, reader.stores = self.store, routines.Stores(self.main)
        cards = [{"title": "Reply to Ana", "request": "Draft a reply to Ana", "kind": "followup"},
                 {"title": "Pay the gas bill", "request": "Pay the gas bill", "kind": "bill"}]
        self.assertTrue(reader._follow_offer(cards))
        self.assertEqual(len(self.relay.pushes), 1)
        self.assertTrue(reader._follow_offer([{"title": "New on Jellyfin", "request": "Plan a night"}]),
                        "held back, but said: it won't come in a heap later")
        self.assertEqual(len(self.relay.pushes), 1)

    def test_more_lets_more_sets_go_unanswered_before_they_go_quiet(self):
        self.assertEqual(proactive.ignored_before_quiet("more", ideas.IGNORED), 6)
        self.assertEqual(proactive.ignored_before_quiet("normal", ideas.IGNORED), ideas.IGNORED)

    def test_idea_runs_are_told_the_bar(self):
        run = "Morning ideas. Look at their day and offer ideas with suggest_to_user."
        self.assertIsNone(proactive.run_note(self.main, run, "cron"))
        proactive.set_level(self.main, "less")
        self.assertIn("two at most", proactive.run_note(self.main, run, "cron"))
        self.assertIsNone(proactive.run_note(self.main, run, "api_server"), "a chat: what they ask for")
        self.assertIsNone(proactive.run_note(self.main, "Check the weather", "cron"))
        proactive.set_level(self.main, "more")
        self.assertIn("Up to five", proactive.run_note(self.main, run, "cron"))


class StandDownTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        (self.root / "cron").mkdir()
        jobs = [{"id": "ideas1", "name": "[redde] Morning ideas", "prompt": "Morning ideas. …"},
                {"id": "quiet1", "name": "[redde-notify] When you've gone quiet", "prompt": "[redde-quiet:24h] …"},
                {"id": "heads1", "name": "[redde] Heads-ups", "prompt": "Heads-ups, 30 minutes before. …"},
                {"id": "brief1", "name": "[redde-notify] Evening wrap-up", "prompt": "Wrap up the day."}]
        (self.root / "cron" / "jobs.json").write_text(json.dumps({"jobs": jobs}))
        self.calls = []
        silence.Said(self.root).wrote(time.time() - 30 * 3600)

    def model(self, request):
        self.calls.append(request)
        return "the model"

    def ran(self, job):
        wakes = silence.QuietWakes(lambda: self.root)
        answer = wakes.turn("req", self.model, session_id=f"cron_{job}_20261127_070000", api_mode="chat_completions")
        return answer if answer == "the model" else answer.choices[0].message.content

    def test_off_ends_the_suggestion_runs_with_no_model_and_leaves_the_rest(self):
        proactive.set_level(self.root, "off")
        self.assertEqual(self.ran("ideas1"), "[SILENT]")
        self.assertEqual(self.ran("quiet1"), "[SILENT]")
        self.assertEqual(self.calls, [])
        self.assertEqual(self.ran("heads1"), "the model", "Heads-Ups are theirs to keep")
        self.assertEqual(self.ran("brief1"), "the model", "a briefing they asked for")

    def test_at_less_they_run(self):
        proactive.set_level(self.root, "less")
        self.assertEqual(self.ran("ideas1"), "the model")

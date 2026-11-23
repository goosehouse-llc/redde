"""python -m unittest discover -s companion/hermes-plugin/tests

Plan For It (1.41.0, asked 2026-11-23: "tell it 'I'm doing something' and have it act on anything
that may help me ... a few different actions it can take that are user selectable"): the 'plan'
card, the turn's note when they say what they're about to do, and a plan's later picks kept to
come back as cards at their time."""
import importlib
import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

from test_cards import cards, plugin

follow = importlib.import_module(plugin.__name__ + ".followthrough")

PLAN = {"type": "plan", "title": "Driving to Montreal · Friday", "actions": [
    {"title": "Check the border and car insurance", "why": "Crossing into Canada", "when": "now", "request": "Check what I need", "picked": True},
    {"title": "Weather for the drive", "when": "now", "request": "Look up the weather on the drive", "picked": True},
    {"title": "Leave-By alert", "when": "2026-11-27T07:00:00-05:00", "request": "Tell me when to leave"}]}


def at(text):
    return datetime.fromisoformat(text).timestamp()


class PlanCardTests(unittest.TestCase):
    def test_a_plan_is_shown_with_its_actions(self):
        shown, problems = cards.check({"cards": [PLAN]})
        self.assertEqual(problems, [])
        self.assertEqual(shown, ["plan: Driving to Montreal · Friday (3 actions, 1 for later; button Do These)"])

    def test_a_plan_needs_two_actions_each_with_a_request(self):
        _, problems = cards.check({"cards": [{**PLAN, "actions": PLAN["actions"][:1]}]})
        self.assertIn("a plan needs a 'title'", problems[0])
        _, problems = cards.check({"cards": [{**PLAN, "actions": [{"title": "A"}, {"title": "B", "request": "b"}]}]})
        self.assertIn("needs a 'request'", problems[0])

    def test_saying_what_theyre_about_to_do_brings_the_plan_note(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            for said in ("We're driving to Montreal Friday", "I'm hosting Thanksgiving this year, it's next Thursday",
                         "I'm flying to Lisbon on Dec 18", "We are moving next month"):
                self.assertEqual(cards.turn_note(home, said, "desktop"), cards.PLAN_NOTE, said)
            for said in ("I'm going to bed", "I'm going to send Ana the file tomorrow", "I'm driving",
                         "Make me a packing list, I'm camping this weekend"):
                self.assertNotEqual(cards.turn_note(home, said, "desktop"), cards.PLAN_NOTE, said)

    def test_the_later_picks_are_kept_and_come_back_at_their_time(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            bot = root / "profiles" / "scout"
            bot.mkdir(parents=True)
            picked = {"title": "Driving to Montreal · Friday", "now": [{"title": "Weather for the drive", "request": "Look up the weather"}],
                      "later": [{"title": "Leave-By alert", "request": "Tell me when to leave for Montreal", "at": "2026-11-27T07:00:00-05:00"}],
                      "left": ["Check the border"]}
            message = "Do these: Weather for the drive, Leave-By alert\n\n[Redde card k1a2: plan " + json.dumps(picked) + "]"
            self.assertEqual(cards.turn_note(bot, message, "desktop"), cards.PLAN_ANSWER_NOTE, "a bot's answer: kept in the main home")
            cards.turn_note(bot, message, "desktop")
            items = list(follow.load(root)["items"].values())
            self.assertEqual([(i["kind"], i["title"], i["what"]) for i in items],
                             [("planned", "Leave-By alert", "Driving to Montreal · Friday")], "once, read twice")
            sent = []
            follow.due(root, lambda c: sent.append(c) or True, now=at("2026-11-27T06:59:00-05:00"))
            self.assertEqual(sent, [], "not before its time")
            follow.due(root, lambda c: sent.append(c) or True, now=at("2026-11-27T07:01:00-05:00"))
            (card,) = sent[0]
            self.assertEqual(card, {"title": "Leave-By alert", "why": "You planned it for Driving to Montreal · Friday",
                                    "request": "Tell me when to leave for Montreal"})
            self.assertEqual(follow.listing(root)["items"], [], "said once")


if __name__ == "__main__":
    unittest.main()

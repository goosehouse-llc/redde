"""python -m unittest discover -s companion/hermes-plugin/tests

Outings (1.48.0, asked 2026-11-26 of "We're going mini golfing today", which nothing caught): a day
out today, said in passing, gets a note for the reply (holiday hours, the weather, somewhere near)
and afterwards one card from the plugin, the photos from it."""
import importlib
import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

from test_cards import cards, plugin

outings = importlib.import_module(plugin.__name__ + ".outings")
follow = importlib.import_module(plugin.__name__ + ".followthrough")
device = importlib.import_module(plugin.__name__ + ".device")

THURSDAY = datetime(2026, 11, 26, 11, 0)


def at(text: str) -> float:
    return datetime.fromisoformat(text).timestamp()


class OutingTests(unittest.TestCase):
    def test_a_day_out_today_is_found(self):
        for said, what, when in (("We're going mini golfing today", "mini golfing", "day"),
                                 ("We’re going mini golfing today", "mini golfing", "day"),
                                 ("Going to the beach this afternoon", "the beach", "day"),
                                 ("Taking the kids to the zoo today", "the zoo", "day"),
                                 ("I'm going bowling tonight with Robin", "bowling", "evening"),
                                 ("We're heading out to the Christmas lights tonight", "the Christmas lights", "evening"),
                                 ("Heads up, going ice skating in a bit", "ice skating", "day"),
                                 ("We're off to a concert tonight", "the concert", "evening"),
                                 ("Robin and I are going apple picking", "apple picking", "day"),
                                 ("We're going Black Friday shopping tonight", "black friday shopping", "evening"),
                                 ("We're going to the pumpkin patch Thursday", "the pumpkin patch", "day"),
                                 ("We're going to the museum this morning", "the museum", "morning")):
            found = outings.find(said, THURSDAY)
            self.assertIsNotNone(found, said)
            self.assertEqual((found["what"], found["when"]), (what, when), said)

    def test_errands_other_days_and_other_peoples_outings_are_not(self):
        for said in ("I’m going to the store today", "I’m going to sleep soon", "I’m going crazy today",
                     "I'm going to bring the pie today", "We're going bowling Saturday", "We're going to the beach tomorrow",
                     "The kids are going to the zoo today", "I'm going nothing today", "I’m taking a nap this afternoon",
                     "I'm going back home now", "We're going to the park next week", "I'm going through a lot today",
                     "I'm going camping today", "I'm going to the doctor today", "I’m going to Target today"):
            self.assertIsNone(outings.find(said, THURSDAY), said)

    def test_the_card_comes_when_theyre_likely_back(self):
        for said, when, comes in (("2026-11-26T11:20", "day", "2026-11-26T17:00"),
                                  ("2026-11-26T13:20", "day", "2026-11-26T18:00"),
                                  ("2026-11-26T14:20", "day", "2026-11-27T10:00"),
                                  ("2026-11-26T09:20", "morning", "2026-11-26T13:00"),
                                  ("2026-11-26T18:20", "evening", "2026-11-27T10:00"),
                                  ("2026-11-26T23:20", "day", "2026-11-27T10:00")):
            self.assertEqual(outings.offer_at(at(said), when), at(comes), said)

    def test_saying_it_brings_the_outing_note_and_keeps_it(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            note = cards.turn_note(home, "We're going mini golfing today", "desktop")
            self.assertIn("a day out", note)
            self.assertIn("holiday hours", note)
            self.assertIn("'weather' card", note)
            self.assertNotIn("photos", note, "no Photos tool: no card afterwards to mention")
            self.assertEqual([o["what"] for o in outings.load(home)], ["mini golfing"])
            cards.turn_note(home, "We're going mini golfing today", "desktop")
            self.assertEqual(len(outings.load(home)), 1, "said twice, kept once")
            device.Phone(home).set_areas(["photos"])
            self.assertIn("photos from it", cards.turn_note(home, "Going to the beach this afternoon", "desktop"))

    def test_a_plan_an_ask_or_a_question_is_not_an_outing(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            self.assertEqual(cards.turn_note(home, "We're going camping this weekend", "desktop"), cards.PLAN_NOTE)
            for said in ("We're going mini golfing today, can you find a course near us",
                         "We're going mini golfing today, is it going to rain?", "We're going mini golfing today"):
                note = cards.turn_note(home, said, "cron") or ""
                self.assertNotIn("a day out", note, said)
            for said in ("We're going mini golfing today, can you find a course near us",
                         "We're going mini golfing today, is it going to rain?"):
                self.assertNotIn("a day out", cards.turn_note(home, said, "desktop") or "", said)
            self.assertEqual(outings.load(home), [])

    def test_a_bots_outing_is_kept_in_the_main_home(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            bot = root / "profiles" / "scout"
            bot.mkdir(parents=True)
            cards.turn_note(bot, "We're going to the zoo today", "desktop")
            self.assertEqual([o["what"] for o in outings.load(root)], ["the zoo"])

    def test_the_photos_card_comes_once_at_its_time(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            outings.remember(root, {"what": "mini golfing", "kind": "activity", "when": "day"}, said=at("2026-11-26T13:05"))
            sent = []
            offer = lambda cards_: sent.append(cards_) or True   # noqa: E731
            self.assertEqual(outings.look(root, offer, now=at("2026-11-26T18:30")), 0, "no Photos tool on the phone")
            device.Phone(root).set_areas(["photos", "calendar"])
            self.assertEqual(outings.look(root, offer, now=at("2026-11-26T17:30")), 0, "before its time")
            self.assertEqual(outings.look(root, offer, now=at("2026-11-26T18:00")), 1)
            self.assertEqual(sent[0], [{
                "title": "Photos from mini golfing", "why": "Today · the best few, ready to share",
                "request": "Find the photos I took mini golfing today (between 12:35 PM and 6 PM) on my iPhone, and show me the "
                           "best few, ready to share."}])
            self.assertEqual(outings.look(root, offer, now=at("2026-11-26T18:30")), 0, "once")

    def test_an_evening_outings_card_comes_the_next_morning_and_the_switch_turns_it_off(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            device.Phone(root).set_areas(["photos"])
            outings.remember(root, {"what": "the Christmas lights", "kind": "place", "when": "evening"}, said=at("2026-11-26T18:10"))
            sent = []
            self.assertEqual(outings.look(root, lambda c: sent.append(c) or True, now=at("2026-11-26T22:00")), 0, "out of the day's hours")
            self.assertEqual(outings.look(root, lambda c: sent.append(c) or True, now=at("2026-11-27T10:00")), 1)
            self.assertEqual(sent[0][0]["title"], "Photos from the Christmas lights")
            self.assertEqual(sent[0][0]["why"], "Last night · the best few, ready to share")
            self.assertIn("at the Christmas lights last night", sent[0][0]["request"])

            outings.remember(root, {"what": "bowling", "kind": "activity", "when": "day"}, said=at("2026-11-27T11:00"))
            self.assertIn("redde-push follow", follow.slash(root, ["set", "outings", "off"]))
            self.assertEqual(outings.look(root, lambda c: True, now=at("2026-11-27T17:00")), 0, "switched off")
            follow.slash(root, ["set", "outings", "on"])
            self.assertEqual(outings.look(root, lambda c: True, now=at("2026-11-27T17:00")), 1)

    def test_a_card_that_couldnt_go_is_tried_again_then_let_go(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            device.Phone(root).set_areas(["photos"])
            outings.remember(root, {"what": "the beach", "kind": "place", "when": "day"}, said=at("2026-11-26T11:00"))
            self.assertEqual(outings.look(root, lambda c: False, now=at("2026-11-26T17:00")), 0)
            self.assertEqual(outings.look(root, lambda c: True, now=at("2026-11-26T18:00")), 1, "tried again")
            outings.remember(root, {"what": "the zoo", "kind": "place", "when": "day"}, said=at("2026-11-26T11:30"))
            self.assertEqual(outings.look(root, lambda c: True, now=at("2026-11-27T18:00")), 0, "a day late: let go")
            self.assertTrue(json.loads((root / "redde-push" / "outings.json").read_text()))


if __name__ == "__main__":
    unittest.main()

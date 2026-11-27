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
    def test_cards_written_out_as_text_are_read_or_said_to_be_broken(self):
        # Sol on the real server (2026-11-23): 'cards' as a JSON string with a stray brace. Hermes
        # passed it on as a list of that string, and the refusal said its type was wrong, though
        # it was 'plan': the model went looking through the schema, out loud, for two more tries.
        good = json.dumps([{"type": "plan", "title": "Driving · Friday", "actions": [
            {"title": "A", "when": "now", "request": "do a", "picked": True},
            {"title": "B", "when": "now", "request": "do b"}]}])
        for sent in (good, [good]):
            self.assertNotIn("error", json.loads(cards.handle({"cards": sent})), sent)
        broken = good.replace('"request": "do b"}', '"request": "do b"}, "picked": true}')
        for sent in (broken, [broken]):
            said = json.loads(cards.handle({"cards": sent}))["error"]
            self.assertIn("broken JSON", said)
            self.assertIn("at character", said)
            self.assertNotIn("'type' must be", said)
            self.assertIn("without mentioning this", said)

    def test_the_tool_says_what_an_action_is(self):
        # Declared as a bare object, Sol (DeepSeek v4 flash) sent `actions: []`, then `[{}]` twice,
        # and only the fourth call had them, on the real server (2026-11-23).
        action = cards.SCHEMA["parameters"]["properties"]["cards"]["items"]["properties"]["actions"]["items"]
        self.assertEqual(sorted(action["properties"]), ["picked", "request", "title", "when", "why"])
        self.assertEqual(action["required"], ["title", "request"])
        self.assertLess(len(json.dumps(cards.SCHEMA)), 6000)

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

    def test_only_something_that_takes_planning_brings_a_plan(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            for said in ("We’re driving to Montreal Friday", "I’m hosting Thanksgiving next week", "I’m flying to Lisbon on Dec 18",
                         "We’re moving next month", "I’m interviewing at Apple on Tuesday", "We’re going camping this weekend",
                         "We're having people over Saturday", "I'm running the Boston Marathon next month",
                         "We’re taking the kids to Disney next week", "I’m having surgery on Monday", "We're getting married in June",
                         "I'm starting a new job next week", "We're selling our house this spring",
                         "We're moving next month, help me plan it", "I’m visiting my parents this weekend",
                         "We’re throwing a party tomorrow", "I'm heading to the airport tomorrow"):
                self.assertEqual(cards.turn_note(home, said, "desktop"), cards.PLAN_NOTE, said)
            for said in ("I’m running late today", "I’m doing fine today", "I’m having pasta tonight", "We’re having a slow week this week",
                         "I’m off today", "I’m taking a nap this afternoon", "I’m leaving work soon", "I’m doing laundry tonight",
                         "I’m starting to feel better today", "I’m having a bad day today", "I’m going to sleep soon",
                         "I’m going crazy today", "We’re doing great this year", "I’m running out of patience today",
                         "I’m driving to work tomorrow", "I’m heading home soon", "I’m going to the store today",
                         "I’m going to Target today", "We’re having leftovers tonight", "I’m buying milk today",
                         "I’m moving slowly today", "I’m throwing up today", "I’m off to bed soon", "I’m painting my nails tonight",
                         "We’re driving to Montreal Friday, find me a hotel", "We’re flying to Lisbon on Dec 18, please check us in",
                         "Book a table, we’re hosting Ana on Friday"):
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
                                    "request": "Tell me when to leave for Montreal", "level": "now",
                                "kind": "planned"},
                         "a pick at the time they chose, heard (1.57.0); its kind for Agents Bring Up (1.58.0)")
            self.assertEqual(follow.listing(root)["items"], [], "said once")

    def test_a_later_pick_comes_back_on_a_day_of_many_suggestions(self):
        # Picked for its time by them: the day's limit (8) is for what the agent thinks of. On the
        # real server a pick for 3:23 PM hadn't come back by 3:25 (2026-11-23).
        with tempfile.TemporaryDirectory() as tmp:
            root, now = Path(tmp), at("2026-11-27T15:23:30-05:00")
            follow.planned(root, "k1", "Driving to Montreal", [{"title": "Leave-By alert", "request": "Tell me when to leave",
                                                                "at": at("2026-11-27T15:23:00-05:00")}])
            data = follow.load(root)
            data["offered"] = [now - 600] * follow.DAILY
            data["items"]["w1"] = {"id": "w1", "kind": "waiting", "state": "open", "due": now - 7200, "name": "Ana Ruiz",
                                   "who": "ana@example.com", "subject": "Lease"}
            follow.save(root, data)
            sent = []
            self.assertEqual(follow.due(root, lambda c: sent.append(c) or True, now=now), 1)
            self.assertEqual([c["title"] for c in sent[0]], ["Leave-By alert"], "the pick, and no more suggestions")
            self.assertEqual(len(follow.load(root)["offered"]), follow.DAILY, "and it doesn't use up the day's")

    def test_the_tool_says_what_a_compare_row_is(self):
        # A bare object: Sol's first compare card was refused for its rows, twice (2026-11-23).
        row = cards.SCHEMA["parameters"]["properties"]["cards"]["items"]["properties"]["rows"]["items"]
        self.assertEqual(sorted(row["properties"]), ["best", "criterion", "values"])
        self.assertEqual(row["properties"]["values"]["type"], "array")
        self.assertLess(len(json.dumps(cards.SCHEMA)), 6000)


if __name__ == "__main__":
    unittest.main()

"""The person's lists (`lists.py`): python -m unittest discover -s companion/hermes-plugin/tests"""
import base64
import json
import tempfile
import unittest
from pathlib import Path

from test_routines import plugin

lists = plugin.lists


def do(home, **args):
    return lists.change(home, args, by="default", now=1_000)


class ListsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_make_add_check_and_show(self):
        made = do(self.home, action="make", title="Groceries", items=["Milk", "Eggs"])
        self.assertIn("made", made)
        self.assertEqual(made["items"], ["1. [ ] Milk", "2. [ ] Eggs"])
        do(self.home, action="add", list="groceries", items=["Bread"])
        checked = do(self.home, action="check", list="Groceries", items=["2", "bread"])
        self.assertEqual(checked["checked"], ["Eggs", "Bread"])
        self.assertEqual(checked["open"], 1)
        self.assertEqual(checked["done"], 2)
        shown = do(self.home, action="show")
        self.assertEqual(shown["lists"][0]["items"], ["1. [ ] Milk", "2. [x] Eggs", "3. [x] Bread"])

    def test_one_list_needs_no_name_and_two_do(self):
        do(self.home, action="make", title="To Do")
        self.assertEqual(do(self.home, action="add", items=["Call the vet"])["added"], 1)
        do(self.home, action="make", title="Packing")
        missed = do(self.home, action="add", items=["Socks"])
        self.assertIn("error", missed)
        self.assertEqual(missed["lists"], ["To Do", "Packing"])

    def test_making_a_list_twice_keeps_one(self):
        do(self.home, action="make", title="Groceries", items=["Milk"])
        again = do(self.home, action="make", title="groceries", items=["Eggs"])
        self.assertIn("already_there", again)
        self.assertEqual(len(lists.load(self.home)), 1)
        self.assertEqual(again["items"], ["1. [ ] Milk", "2. [ ] Eggs"])

    def test_uncheck_remove_clear_rename_delete(self):
        do(self.home, action="make", title="Chores", items=["Dishes", "Laundry", "Trash"])
        do(self.home, action="check", list="Chores", items=["1", "3"])
        self.assertEqual(do(self.home, action="uncheck", list="Chores", items=["Trash"])["unchecked"], ["Trash"])
        self.assertEqual(do(self.home, action="remove", list="Chores", items=["laundry"])["removed"], ["Laundry"])
        self.assertEqual(do(self.home, action="clear_done", list="Chores")["cleared"], 1)
        self.assertEqual(do(self.home, action="rename", list="Chores", title="House")["items"], ["1. [ ] Trash"])
        self.assertEqual(do(self.home, action="delete", list="House")["deleted"], "House")
        self.assertEqual(lists.load(self.home), [])

    def test_unknown_items_and_actions_are_said(self):
        do(self.home, action="make", title="To Do", items=["A thing"])
        self.assertIn("error", do(self.home, action="check", list="To Do", items=["9"]))
        partly = do(self.home, action="check", list="To Do", items=["1", "nothing like it"])
        self.assertEqual(partly["not_found"], ["nothing like it"])
        self.assertIn("error", do(self.home, action="fly"))
        self.assertIn("error", do(self.home, action="make", title="  "))

    def test_items_are_trimmed_and_capped(self):
        do(self.home, action="make", title="x" * 100, items=["  lots   of   space  ", "", "y" * 500])
        kept = lists.load(self.home)[0]
        self.assertEqual(len(kept["title"]), lists.TITLE)
        self.assertEqual([i["text"] for i in kept["items"]][0], "lots of space")
        self.assertEqual(len(kept["items"]), 2)
        self.assertEqual(len(kept["items"][1]["text"]), lists.TEXT)

    def test_the_apps_command(self):
        listed = lists.slash(self.home, ["list"])
        self.assertTrue(listed.startswith("redde-push lists "))
        self.assertEqual(json.loads(listed.removeprefix("redde-push lists "))["lists"], [])
        do(self.home, action="make", title="Groceries", items=["Milk"])
        item = lists.listing(self.home)[0]["items"][0]
        change = base64.urlsafe_b64encode(json.dumps({"action": "check", "list": lists.listing(self.home)[0]["id"],
                                                       "items": [item["id"]]}).encode()).decode().rstrip("=")
        said = json.loads(lists.slash(self.home, ["do", change]).removeprefix("redde-push lists "))
        self.assertEqual(said["said"]["checked"], ["Milk"])
        self.assertTrue(said["lists"][0]["items"][0]["done"])
        self.assertIn("for the Redde app", lists.slash(self.home, ["do", "not base64!"]))
        self.assertIn("for the Redde app", lists.slash(self.home, ["eat"]))

    def test_the_turn_note(self):
        for said in ("Make me a to-do list", "add milk to my grocery list", "check off the eggs", "what's on my lists?",
                     "put batteries on the shopping list", "Start a packing list for Maine"):
            self.assertIsNotNone(lists.turn_note(said), said)
        for said in ("remind me to call mom", "what's the weather", "I listened to it"):
            self.assertIsNone(lists.turn_note(said), said)
        self.assertIsNone(lists.turn_note("make a to-do list", platform="cron"))

    def test_every_bot_shares_the_main_homes_lists(self):
        calls = []

        class Ctx:
            def register_tool(self, **kw):
                calls.append(kw)

        bot = self.home / "profiles" / "scout"
        bot.mkdir(parents=True)
        lists.register(Ctx(), lambda: bot)
        handle = calls[0]["handler"]
        json.loads(handle({"action": "make", "title": "To Do", "items": ["Fix the gate"]}))
        self.assertEqual(lists.load(self.home)[0]["by"], "scout")
        self.assertFalse(lists.path(bot).exists())


if __name__ == "__main__":
    unittest.main()

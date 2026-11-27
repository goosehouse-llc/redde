"""Forget a Topic (redde-push/forget.py, 1.58.0): every agent's memory entries and Things to Keep in
Mind about one topic, found by its words and let go exactly as ticked, under Hermes's memory lock."""
import importlib
import json
import tempfile
import unittest
from pathlib import Path

from test_calls import plugin

core, facts, ideas = plugin.core, plugin.facts, plugin.ideas
forget = importlib.import_module(plugin.__name__ + ".forget")


def b64(value) -> str:
    return core.b64u((value if isinstance(value, str) else json.dumps(value)).encode())


class ForgetTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        (self.root / "memories").mkdir()
        (self.root / "memories" / "USER.md").write_text(
            "Works as a nurse at the old job in Laval\n§\nHas a dog called Pickles\n§\nLeft the old jobs board in March")
        (self.root / "memories" / "MEMORY.md").write_text("Prefers short replies")
        bot = self.root / "profiles" / "media"
        (bot / "cron").mkdir(parents=True)
        (bot / "memories").mkdir()
        (bot / "memories" / "MEMORY.md").write_text("Their old job's shift ended at 7\n§\nLikes Jellyfin films in French")
        facts.add(self.root, "On Fridays I drive past the old job site")
        facts.add(self.root, "Pickles needs his jab in March")

    def test_found_by_its_words_for_every_agent(self):
        found = forget.find(self.root, "my old job")
        self.assertEqual([(a["profile"], a["user"], a["memory"]) for a in found["agents"]],
                         [("default", ["Works as a nurse at the old job in Laval", "Left the old jobs board in March"], []),
                          ("media", [], ["Their old job's shift ended at 7"])])
        self.assertEqual(found["facts"], ["On Fridays I drive past the old job site"])
        self.assertFalse(forget.matches("A jobless old man", "old job") and False)
        self.assertTrue(forget.matches("Asked about AI tools", "AI"), "a short topic: as a whole word")
        self.assertFalse(forget.matches("Said hi to Kai", "AI"))

    def test_only_what_stayed_ticked_goes_and_the_rest_of_the_file_stays(self):
        said = forget.forget(self.root, {"topic": "old job", "block": True,
                                         "agents": [{"profile": "default", "user": ["Works as a nurse at the old job in Laval"]},
                                                    {"profile": "media", "memory": ["Their old job's shift ended at 7"]}],
                                         "facts": ["On Fridays I drive past the old job site"]})
        self.assertEqual(said, {"removed": 3, "missed": 0, "blocked": True})
        self.assertEqual((self.root / "memories" / "USER.md").read_text(),
                         "Has a dog called Pickles\n§\nLeft the old jobs board in March", "unticked: kept")
        self.assertEqual(forget.entries(self.root / "profiles" / "media", "memory"), ["Likes Jellyfin films in French"])
        self.assertEqual(facts.texts(self.root), ["Pickles needs his jab in March"])
        self.assertIn("old job", ideas.blocked(self.root))
        self.assertTrue((self.root / "memories" / "USER.md.lock").exists(), "under Hermes's lock")

    def test_gone_already_is_counted_not_an_error(self):
        said = forget.forget(self.root, {"agents": [{"profile": "default", "user": ["Not there"]}, {"profile": "nobody", "memory": ["x"]}]})
        self.assertEqual(said, {"removed": 0, "missed": 2, "blocked": False})

    def test_the_commands_for_the_app(self):
        original = plugin._home
        plugin._home = lambda: str(self.root)
        try:
            found = plugin._slash(f"memory find {b64('old job')}")
            self.assertTrue(found.startswith("redde-push memory found {"))
            self.assertEqual(len(json.loads(found.split(" ", 3)[3])["agents"]), 2)
            gone = plugin._slash(f"memory forget {b64({'agents': [{'profile': 'default', 'user': ['Has a dog called Pickles']}]})}")
            self.assertEqual(json.loads(gone.split(" ", 3)[3])["removed"], 1)
            self.assertTrue(plugin._slash("memory find !!").startswith("redde-push refused"))
        finally:
            plugin._home = original

    def test_asked_in_a_chat(self):
        self.assertIn("memory remove", forget.turn_note("Please forget everything about my old job"))
        self.assertIn("memory remove", forget.turn_note("forget about Laval"))
        self.assertIsNone(forget.turn_note("Don't forget the milk"), "not a topic to forget")
        self.assertIsNone(forget.turn_note("don't forget about the dentist"), "a reminder")
        self.assertIsNone(forget.turn_note("I forget the name of that film"))
        self.assertIsNone(forget.turn_note("forget about it", "cron"))

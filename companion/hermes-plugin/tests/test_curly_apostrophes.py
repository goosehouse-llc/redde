"""An iPhone's keyboard and Mail write a curly apostrophe ("We’re", "I’ll"): what the plugin listens
for in English hears it as well as a straight one (found trying Plan For It, 2026-11-23)."""
import importlib
import unittest

from test_cards import cards, plugin

follow = importlib.import_module(plugin.__name__ + ".followthrough")
followups = importlib.import_module(plugin.__name__ + ".followups")
goals = importlib.import_module(plugin.__name__ + ".goals")
remember = importlib.import_module(plugin.__name__ + ".remember")


class CurlyApostropheTests(unittest.TestCase):
    def test_both_apostrophes_are_heard(self):
        for pattern, said in ((cards._DOING, "We're driving to Montreal Friday"),
                              (cards._DOING, "I'm flying to Lisbon on Dec 18"),
                              (follow._PROMISE, "I'll send you the signed copy by Friday"),
                              (followups._LOOSE_END, "Don't let me forget the rent"),
                              (goals._GOALISH, "I'm training for a marathon"),
                              (remember._REMEMBER, "Don't forget that I need the 3-day insurance")):
            with self.subTest(said):
                self.assertTrue(pattern.search(said), "straight")
                self.assertTrue(pattern.search(said.replace("'", "’")), "curly")


if __name__ == "__main__":
    unittest.main()

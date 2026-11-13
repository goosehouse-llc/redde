"""The app's answers (`wire.py`): python -m unittest discover -s companion/hermes-plugin/tests"""
import json
import unittest

from test_routines import plugin

wire = plugin.wire


class WireTests(unittest.TestCase):
    def test_an_answer_is_its_command_then_one_line_of_json(self):
        said = wire.reply("lists", {"lists": [{"title": "Épicerie\nà faire"}]})
        self.assertTrue(said.startswith("redde-push lists {"))
        self.assertNotIn("\n", said)
        self.assertIn("Épicerie", said)   # as it is, not escaped
        self.assertEqual(json.loads(said[len("redde-push lists "):]), {"lists": [{"title": "Épicerie\nà faire"}]})

    def test_compact_has_no_spaces_and_a_two_word_command_works(self):
        self.assertEqual(wire.reply("device cache", {"a": [1, 2]}, compact=True), 'redde-push device cache {"a":[1,2]}')


if __name__ == "__main__":
    unittest.main()

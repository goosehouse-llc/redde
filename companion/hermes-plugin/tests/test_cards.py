"""python -m unittest discover -s companion/hermes-plugin/tests

Cards (redde-push/cards.py): `redde_show` checks the cards the app will draw, leniently, and says
what each will show or why it can't; the phone turns them off and on."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "redde-push"
if "redde_push" in sys.modules:
    plugin = sys.modules["redde_push"]
else:
    spec = importlib.util.spec_from_file_location("redde_push", HERE / "__init__.py", submodule_search_locations=[str(HERE)])
    plugin = importlib.util.module_from_spec(spec)
    sys.modules["redde_push"] = plugin
    spec.loader.exec_module(plugin)
cards = plugin.cards

WALK = {"type": "map", "route": {"mode": "walking", "to": {"name": "Rossio Roasters", "address": "Rua das Portas de Santo Antão 136"}}}
PLACES = {"type": "places", "title": "Coffee", "places": [{"name": "Rossio Roasters", "rating": 4.7}, {"name": "Alfama Bean"}, "Tram 28 Café"]}
WEATHER = {"type": "weather", "place": "Lisbon", "units": "C", "now": {"temperature": "19°", "condition": "partly_cloudy"},
           "days": [{"date": "2026-10-23", "high": 21, "low": 15, "condition": "rain"}]}


class CardTests(unittest.TestCase):
    def test_each_kind_says_what_it_shows(self):
        answer = json.loads(cards.handle({"cards": [WALK, PLACES, WEATHER]}))
        self.assertEqual(answer["shown"], ["map: route to Rossio Roasters (walking)", "places: 3 (Rossio Roasters, Alfama Bean, Tram 28 Café)",
                                           "weather: Lisbon (now, 1 days)"])
        self.assertNotIn("not_shown", answer)
        self.assertIn("don't read out", answer["note"])

    def test_a_card_that_cant_be_drawn_is_named_and_the_rest_shown(self):
        answer = json.loads(cards.handle({"cards": [WALK, {"type": "weather", "place": "Lisbon"}, {"type": "chart"}]}))
        self.assertEqual(answer["shown"], ["map: route to Rossio Roasters (walking)"])
        self.assertEqual(len(answer["not_shown"]), 2)
        self.assertIn("card 2", answer["not_shown"][0])
        self.assertIn("map, places or weather", answer["not_shown"][1])

    def test_nothing_to_show_is_an_error(self):
        for args in ({}, {"cards": []}, {"cards": [{"type": "places", "places": []}]}, None):
            self.assertIn("error", json.loads(cards.handle(args)))

    def test_one_card_without_the_list_is_taken(self):
        self.assertEqual(json.loads(cards.handle(WEATHER))["shown"], ["weather: Lisbon (now, 1 days)"])

    def test_at_most_four(self):
        answer = json.loads(cards.handle({"cards": [PLACES] * 6}))
        self.assertEqual(len(answer["shown"]), 4)
        self.assertIn("first 4", answer["not_shown"][-1])

    def test_on_until_the_phone_says_off(self):
        with tempfile.TemporaryDirectory() as home:
            self.assertTrue(cards.offered(Path(home)))
            self.assertEqual(cards.slash(Path(home), ["off"]), "redde-push cards off")
            self.assertFalse(cards.offered(Path(home)))
            self.assertEqual(cards.slash(Path(home), []), "redde-push cards off")
            self.assertEqual(cards.slash(Path(home), ["on"]), "redde-push cards on")
            self.assertTrue(cards.offered(Path(home)))

    def test_turned_off_it_refuses_even_when_reached(self):
        with tempfile.TemporaryDirectory() as home:
            cards.set_on(Path(home), False)
            answer = json.loads(cards.handle({"cards": [WALK]}, home=lambda: Path(home)))
            self.assertIn("turned off", answer["error"])
            cards.set_on(Path(home), True)
            self.assertIn("shown", json.loads(cards.handle({"cards": [WALK]}, home=lambda: Path(home))))

    def test_the_schema_is_small_and_valid_json(self):
        text = json.dumps(cards.SCHEMA)
        self.assertLess(len(text), 6000, "its description rides on every prompt")
        self.assertEqual(cards.SCHEMA["name"], "redde_show")


if __name__ == "__main__":
    unittest.main()

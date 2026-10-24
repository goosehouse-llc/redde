"""python -m unittest discover -s companion/hermes-plugin/tests

Cards (redde-push/cards.py): `redde_show` checks the cards the app will draw, leniently, and says
what each will show or why it can't; weather and time cards are looked up (forecast.py, Open-Meteo,
faked here: no test reaches the network); the phone turns them off and on."""
import importlib.util
import json
import sys
import tempfile
import unittest
import urllib.parse
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


TIME = {"type": "time", "place": "Lisbon"}

PLACES_FOUND = {
    "Orlando": [{"name": "Orlando", "admin1": "Florida", "country": "United States", "country_code": "US",
                 "latitude": 28.53834, "longitude": -81.37924, "timezone": "America/New_York"},
                {"name": "Orlando", "admin1": "Oklahoma", "country": "United States", "country_code": "US",
                 "latitude": 36.14893, "longitude": -97.3781, "timezone": "America/Chicago"}],
    "Lisbon": [{"name": "Lisbon", "admin1": "Lisbon", "country": "Portugal", "country_code": "PT",
                "latitude": 38.71667, "longitude": -9.13333, "timezone": "Europe/Lisbon"}],
}


def forecast_answer(temperature=75.5, units="F"):
    """Open-Meteo's forecast as it answered for Orlando at 17:45 on 2026-10-23."""
    return {"timezone": "America/New_York", "utc_offset_seconds": -14400,
            "current": {"time": "2026-10-23T17:45", "temperature_2m": temperature, "apparent_temperature": 71.9,
                        "relative_humidity_2m": 49, "weather_code": 0, "wind_speed_10m": 12.3, "wind_direction_10m": 31, "is_day": 1},
            "hourly": {"time": [f"2026-10-23T{h:02d}:00" for h in range(17, 24)] + [f"2026-10-24T{h:02d}:00" for h in range(0, 5)],
                       "temperature_2m": [77.3, 74.9, 70.1, 68, 67, 66, 65, 64, 64, 63, 63, 62],
                       "weather_code": [0, 0, 1, 2, 2, 3, 3, 3, 61, 61, 3, 2],
                       "precipitation_probability": [0, 0, 0, 0, 5, 5, 10, 10, 40, 35, 10, 5],
                       "is_day": [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]},
            "daily": {"time": [f"2026-10-{d}" for d in range(23, 30)], "weather_code": [0, 2, 61, 3, 0, 0, 95],
                      "temperature_2m_max": [81.9, 80.6, 78, 79, 82, 83, 84], "temperature_2m_min": [64, 63, 62, 61, 62, 63, 66],
                      "precipitation_probability_max": [0, 10, 60, 20, 0, 0, 70]}}


class FakeOpenMeteo:
    def __init__(self, temperature=75.5, down=False):
        self.calls, self.temperature, self.down = [], temperature, down

    def __call__(self, url):
        self.calls.append(url)
        if self.down:
            raise OSError("offline")
        query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query))
        if "geocoding" in url:
            found = {k.lower(): v for k, v in PLACES_FOUND.items()}.get(query["name"].lower())   # as Open-Meteo, any case
            return {"results": found} if found else {"generationtime_ms": 0.1}
        return forecast_answer(self.temperature, "F" if query.get("temperature_unit") == "fahrenheit" else "C")


class CardTests(unittest.TestCase):
    def setUp(self):
        cards.forecast._kept.clear()
        self.open_meteo = FakeOpenMeteo()
        self.real_fetch = cards.forecast.fetch_json
        cards.forecast.fetch_json = self.open_meteo

    def tearDown(self):
        cards.forecast.fetch_json = self.real_fetch

    def test_each_kind_says_what_it_shows(self):
        answer = json.loads(cards.handle({"cards": [WALK, PLACES, WEATHER, TIME]}))
        self.assertEqual(answer["shown"], ["map: route to Rossio Roasters (walking)", "places: 3 (Rossio Roasters, Alfama Bean, Tram 28 Café)",
                                           "weather: Lisbon (now 75.5°C clear, 12 hours, 7 days)", "time: Lisbon"])
        self.assertNotIn("not_shown", answer)
        self.assertIn("don't read out", answer["note"])
        self.assertIn("'said'", answer["note"])
        self.assertTrue(answer["said"][0].startswith("weather: Lisbon: now 76°C clear; feels like 72°C; today high 82°C, low 64°C"))
        self.assertRegex(answer["said"][1], r"^time: Lisbon: \d\d:\d\d \(\d{1,2}:\d\d [AP]M\), \w+day \d{1,2} \w+ 20\d\d, WES?T \(UTC\+0[01]:00\)$")
        self.assertEqual(answer["cards"][:2], [WALK, PLACES], "maps and places go back as they came")
        weather = answer["cards"][2]
        self.assertEqual((weather["place"], weather["units"], weather["source"]), ("Lisbon", "C", "Open-Meteo.com"))
        self.assertEqual(len(weather["hours"]), 12)
        self.assertEqual(len(weather["days"]), 7)
        self.assertEqual(answer["cards"][3], {"type": "time", "place": "Lisbon", "timezone": "Europe/Lisbon"})

    def test_the_forecast_replaces_what_the_agent_wrote(self):
        # 2026-10-23: the agent sent 0 and "clear" for Orlando, and later 66°F from a search result, at 5 pm
        # while it was 75°F there.
        for now in ({"temperature": 0, "condition": "clear"}, {"temperature": 66, "condition": "Clear"}):
            answer = json.loads(cards.handle({"cards": [{"type": "weather", "place": "Orlando FL", "units": "F", "now": now}]}))
            card = answer["cards"][0]
            self.assertEqual(card["now"], {"temperature": 75.5, "condition": "clear", "night": False, "feels_like": 71.9, "humidity": 49,
                                           "wind": "12 mph NE", "high": 81.9, "low": 64, "precipitation": 0})
            self.assertEqual(card["hours"][2], {"time": "2026-10-23T19:00", "temperature": 70.1, "condition": "clear", "night": True, "precipitation": 0})
            self.assertEqual(card["days"][2], {"date": "2026-10-25", "high": 78, "low": 62, "condition": "rain", "precipitation": 60})
            self.assertIn("now 76°F clear; feels like 72°F; today high 82°F, low 64°F; rain chance 0% this hour; humidity 49%; "
                          "wind 12 mph NE; tomorrow 81°F/63°F partly cloudy, rain 10%", answer["said"][0])
            self.assertNotIn("not_shown", answer)

    def test_a_place_is_found_as_agents_write_it(self):
        for written in ("Orlando FL", "Orlando, FL", "Orlando, Florida", "orlando  fl"):
            cards.forecast._kept.clear()
            self.assertEqual(cards.forecast.find(written)["admin1"], "Florida", written)
        self.assertEqual(cards.forecast.find("Orlando, OK")["admin1"], "Oklahoma")
        self.assertEqual(cards.forecast.find("Lisbon")["country_code"], "PT")
        self.assertIsNone(cards.forecast.find("Atlantis"))
        self.assertEqual(cards.forecast.label(cards.forecast.find("Orlando FL")), "Orlando, Florida")
        self.assertEqual(cards.forecast.label(cards.forecast.find("Lisbon")), "Lisbon, Portugal")

    def test_asked_twice_it_looks_up_once(self):
        cards.handle({"cards": [{"type": "weather", "place": "Orlando FL"}]})
        calls = len(self.open_meteo.calls)
        cards.handle({"cards": [{"type": "weather", "place": "Orlando FL"}]})
        self.assertEqual(len(self.open_meteo.calls), calls)

    def test_units_follow_the_agent_then_the_phone_then_the_country(self):
        unit = lambda card, home=None: json.loads(cards.handle({"cards": [card]}, home=home))["cards"][0]["units"]
        self.assertEqual(unit({"type": "weather", "place": "Orlando FL"}), "F")
        self.assertEqual(unit({"type": "weather", "place": "Lisbon"}), "C")
        self.assertEqual(unit({"type": "weather", "place": "Lisbon", "units": "F"}), "F")
        self.assertIn("temperature_unit=fahrenheit", self.open_meteo.calls[-1])
        with tempfile.TemporaryDirectory() as home:
            cards.slash(Path(home), ["on", "tz=America/New_York", "units=F"])
            self.assertEqual(unit({"type": "weather", "place": "Lisbon"}, home=lambda: Path(home)), "F")

    def test_the_time_here_is_the_phones(self):
        with tempfile.TemporaryDirectory() as home:
            answer = json.loads(cards.handle({"cards": [{"type": "time"}]}, home=lambda: Path(home)))
            self.assertEqual(answer["cards"][0], {"type": "time"}, "not knowing the phone's zone, the card shows the phone's own time")
            self.assertIn("this server's own clock", answer["said"][0])
            self.assertEqual(cards.slash(Path(home), ["on", "tz=America/New_York"]), "redde-push cards on")
            self.assertEqual(cards.slash(Path(home), ["on", "tz=Not/AZone", "units=K"]), "redde-push cards on")
            self.assertEqual(cards.preferences(Path(home)), {"tz": "America/New_York"})
            answer = json.loads(cards.handle({"cards": [{"type": "time"}]}, home=lambda: Path(home)))
            self.assertEqual(answer["cards"][0], {"type": "time", "timezone": "America/New_York"})
            self.assertRegex(answer["said"][0], r"^time: The person’s time: .*, E[DS]T \(UTC-0[45]:00\)$")
            self.assertEqual(answer["shown"], ["time: the person’s own"])
        self.assertEqual(json.loads(cards.handle({"cards": [{"type": "time", "timezone": "Asia/Tokyo"}]}))["cards"][0]["timezone"], "Asia/Tokyo")
        self.assertEqual(self.open_meteo.calls, [], "a zone given needs no search")

    def test_the_time_is_said_plainly(self):
        from datetime import datetime, timezone
        at = datetime(2026, 10, 23, 21, 36, tzinfo=timezone.utc)
        self.assertEqual(cards.forecast.time_said("Orlando, FL", cards.forecast.zone("America/New_York"), at),
                         "Orlando, FL: 17:36 (5:36 PM), Friday 23 October 2026, EDT (UTC-04:00)")

    def test_weather_codes(self):
        c = cards.forecast.condition
        self.assertEqual([c(0), c(1), c(2), c(3), c(45), c(53), c(56), c(63), c(65), c(82), c(75), c(95), c(99), c(None)],
                         ["clear", "clear", "partly_cloudy", "cloudy", "fog", "drizzle", "sleet", "rain", "heavy_rain", "heavy_rain",
                          "snow", "thunderstorm", "thunderstorm", "cloudy"])

    def test_offline_the_agent_hears_it_and_its_own_numbers_stand(self):
        self.open_meteo.down = True
        answer = json.loads(cards.handle({"cards": [WEATHER]}))
        self.assertEqual(answer["shown"], ["weather: Lisbon (now 19°C partly_cloudy, 1 days)"])
        self.assertIn("couldn't be looked up", answer["not_shown"][0])
        self.assertEqual(answer["cards"], [WEATHER])
        # Seen 2026-10-23: a placeholder 0 is still sent back when there is nothing to replace it with.
        answer = json.loads(cards.handle({"cards": [{"place": "Orlando FL", "now": {"temperature": 0, "condition": "clear"}, "type": "weather", "units": "F"}]}))
        self.assertIn("error", answer)
        self.assertIn("placeholder", answer["error"])
        self.assertIn("say so rather than guess", answer["error"])

    def test_a_place_not_found_is_named(self):
        answer = json.loads(cards.handle({"cards": [WALK, {"type": "weather", "place": "Atlantis"}, {"type": "time", "place": "Atlantis"}]}))
        self.assertEqual(answer["shown"], ["map: route to Rossio Roasters (walking)", "time: Atlantis"])
        self.assertIn("'Atlantis' wasn't found for the weather", answer["not_shown"][0])
        self.assertIn("'Atlantis' wasn't found for the time", answer["not_shown"][1])

    def test_a_card_that_cant_be_drawn_is_named_and_the_rest_shown(self):
        answer = json.loads(cards.handle({"cards": [WALK, {"type": "weather"}, {"type": "chart"}]}))
        self.assertEqual(answer["shown"], ["map: route to Rossio Roasters (walking)"])
        self.assertEqual(len(answer["not_shown"]), 2)
        self.assertIn("card 2", answer["not_shown"][0])
        self.assertIn("map, places, weather or time", answer["not_shown"][1])

    def test_the_description_says_to_answer_from_the_lookup(self):
        self.assertIn("look themselves up", cards.SCHEMA["description"])
        self.assertIn("never from memory or a guess", cards.SCHEMA["description"])

    def test_nothing_to_show_is_an_error(self):
        for args in ({}, {"cards": []}, {"cards": [{"type": "places", "places": []}]}, None):
            self.assertIn("error", json.loads(cards.handle(args)))

    def test_one_card_without_the_list_is_taken(self):
        self.assertEqual(json.loads(cards.handle(PLACES))["shown"], ["places: 3 (Rossio Roasters, Alfama Bean, Tram 28 Café)"])

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

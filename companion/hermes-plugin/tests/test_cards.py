"""python -m unittest discover -s companion/hermes-plugin/tests

Cards (redde-push/cards.py): `redde_show` checks the cards the app will draw, leniently, and says
what each will show or why it can't; weather and time cards are looked up (forecast.py, Open-Meteo,
faked here: no test reaches the network); the phone turns them off and on."""
import importlib.util
import json
import socket
import sys
import tempfile
import time
import unittest
import urllib.parse
from datetime import datetime, timezone
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
                       "is_day": [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                       "wind_gusts_10m": [18.6, 17.2, 14.1, 12, 11, 10, 10, 9, 15, 16, 12, 10]},
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
            self.assertEqual(card["hours"][2], {"time": "2026-10-23T19:00", "temperature": 70.1, "condition": "clear", "night": True,
                                                "precipitation": 0, "gusts": 14})
            self.assertEqual(card["updated"], "2026-10-23T17:45:00-04:00", "when it was read, with the place's offset")
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

    def test_asked_the_time_the_turn_says_whose_time_and_to_show_it(self):
        from datetime import datetime, timezone
        at = datetime(2026, 10, 24, 0, 5, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            note = cards.turn_note(home, "What time is it", "desktop", at)
            self.assertIn("Call redde_show first (a 'time' card", note)
            self.assertIn("Don't guess the time", note, "the phone hasn't said its zone yet")
            cards.slash(home, ["on", "tz=America/New_York"])
            note = cards.turn_note(home, "What time is it", "desktop", at)
            self.assertIn("it is now 20:05 (8:05 PM), Friday 23 October 2026, EDT (UTC-04:00) (America/New_York)", note,
                          "Sol guessed: 12:05 AM Thursday, at 9:09 PM on Friday")
            self.assertIn("'weather' card", cards.turn_note(home, "Will it rain tomorrow?", "api_server", at))
            self.assertIn("a 'time' and a 'weather' card", cards.turn_note(home, [{"type": "text", "text": "time in Tokyo and the weather there"}], "tui", at))
            for other in ("Tell me a 30 word short story.", "Set the alarm to away."):
                self.assertIsNone(cards.turn_note(home, other, "desktop", at), other)
            self.assertIn("'home' card", cards.turn_note(home, "Turn off the lights in the office.", "desktop", at), "from 1.12.0 a home card, no time")
            self.assertIsNone(cards.turn_note(home, "What time is it", "telegram", at), "cards are drawn only in Redde")
            cards.slash(home, ["off"])
            self.assertIsNone(cards.turn_note(home, "What time is it", "desktop", at), "cards off: nothing to show")
            plugin_home = plugin._home
            plugin._home = lambda: home
            try:
                cards.slash(home, ["on"])
                self.assertIn("'time' card", plugin._on_turn(session_id="s", platform="desktop", turn_id="t", user_message="what's the time")["context"])
                self.assertIsNone(plugin._on_turn(session_id="s", platform="desktop", turn_id="t", user_message="hello"))
            finally:
                plugin._home = plugin_home

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

    def test_rain_coming_is_said_as_the_card_calls_it_out(self):
        # The weather card's callout (asked 2026-10-30): the first run of hours at 50 % or more.
        answer = forecast_answer()
        answer["hourly"]["precipitation_probability"] = [0, 10, 55, 80, 70, 20, 10, 5, 0, 0, 0, 0]
        answer["hourly"]["weather_code"] = [0, 2, 61, 95, 95, 3, 3, 3, 3, 3, 3, 3]
        answer["hourly"]["wind_gusts_10m"] = [10, 12, 24, 34.6, 30, 15, 10, 9, 9, 9, 9, 9]
        card = cards.forecast.card_from(answer, "Orlando FL", "F")
        self.assertEqual(cards.forecast.spell(card), {"kind": "storms", "from": "2026-10-23T19:00", "to": "2026-10-23T21:00",
                                                      "peak": "2026-10-23T20:00", "chance": 80, "gusts": 35})
        self.assertIn("storms likely 19:00–22:00, likeliest 80% at 20:00, gusts to 35 mph", cards.forecast.said(card))
        answer["hourly"]["precipitation_probability"] = [0] * 10 + [60, 65]
        answer["hourly"]["weather_code"] = [0] * 12
        late = cards.forecast.card_from(answer, "Orlando FL", "F")
        self.assertIn("rain likely from 03:00", cards.forecast.said(late), "it runs past the last hour: no end is made up")
        self.assertIsNone(cards.forecast.spell(cards.forecast.card_from(forecast_answer(), "Orlando FL", "F")), "40 % isn't likely")

    def test_a_list_of_places_says_what_the_card_shows_of_each(self):
        listed = cards.SCHEMA["parameters"]["properties"]["cards"]["items"]["properties"]["places"]["items"]["properties"]
        self.assertTrue({"price", "hours", "pick", "rating"} <= set(listed))
        route = cards.SCHEMA["parameters"]["properties"]["cards"]["items"]["properties"]["route"]["properties"]["to"]["properties"]
        self.assertNotIn("pick", route, "a route's ends show only a name")
        found = {"type": "places", "places": [{"name": "Rossio Roasters", "price": "$$", "rating": 4.7, "hours": "Open until 9 PM", "pick": True},
                                               {"name": "Tram 28 Café", "price_level": 1, "closes": "5 PM"}]}
        answer = json.loads(cards.handle({"cards": [found]}))
        self.assertEqual(answer["shown"], ["places: 2 (Rossio Roasters, Tram 28 Café)"])
        self.assertEqual(answer["cards"], [found], "passed on as given: the app reads them")

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
        self.assertIn("map, places, weather, time", answer["not_shown"][1])

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


class AnnounceTests(unittest.TestCase):
    """GitHub issue 35: on Hermes 0.22 the Dashboard tells a client of redde_show's calls live."""

    def test_redde_show_joins_the_tools_the_dashboard_always_tells_of(self):
        import types
        server = types.ModuleType("tui_gateway.server")
        server._TOOL_LIFECYCLE_UI_TOOLS = frozenset({"clarify", "write_file"})
        before = sys.modules.get("tui_gateway.server")
        sys.modules["tui_gateway.server"] = server
        try:
            self.assertTrue(plugin.cards.announce())
            self.assertIn("redde_show", server._TOOL_LIFECYCLE_UI_TOOLS)
            self.assertIn("clarify", server._TOOL_LIFECYCLE_UI_TOOLS)
            self.assertTrue(plugin.cards.announce(), "again: nothing more to do")
        finally:
            if before is None:
                sys.modules.pop("tui_gateway.server", None)
            else:
                sys.modules["tui_gateway.server"] = before

    def test_without_the_list_nothing_is_changed(self):
        import types
        before = sys.modules.get("tui_gateway.server")
        sys.modules["tui_gateway.server"] = types.ModuleType("tui_gateway.server")
        try:
            self.assertFalse(plugin.cards.announce())
        finally:
            if before is None:
                sys.modules.pop("tui_gateway.server", None)
            else:
                sys.modules["tui_gateway.server"] = before


class AnswerCardTests(unittest.TestCase):
    """Cards the person answers with a tap (1.9.0, asked 2026-10-28)."""

    def test_a_review_is_shown_and_the_agent_is_told_to_wait(self):
        said = json.loads(cards.handle({"cards": [{"type": "review", "title": "Email to Ana", "action": "Send",
                                                    "fields": [{"label": "To", "value": "ana@example.com"},
                                                               {"label": "Message", "value": "See you at 3."}]}]}))
        self.assertIn("review: Email to Ana", said["shown"][0])
        self.assertIn("wait", said["note"])
        self.assertIn("until they tap", said["note"])

    def test_cards_that_cant_be_answered_say_why(self):
        said = json.loads(cards.handle({"cards": [{"type": "choice", "options": [{"title": "Only one"}]}]}))
        self.assertIn("at least two", said["error"])
        said = json.loads(cards.handle({"cards": [{"type": "review", "title": "x"}]}))
        self.assertIn("'fields'", said["error"])

    def test_a_choice_a_checklist_and_a_form(self):
        said = json.loads(cards.handle({"cards": [
            {"type": "choice", "title": "Where to eat?", "options": [{"title": "Lupa"}, {"title": "Sushi Ko"}]},
            {"type": "checklist", "title": "Packing", "items": [{"text": "Passport"}, "Charger"]},
            {"type": "form", "title": "Dinner booking", "fields": [{"label": "Date", "kind": "date"}, {"label": "People", "kind": "number"}]}]}))
        self.assertEqual(len(said["shown"]), 3)
        self.assertIn("Lupa", said["shown"][0])
        self.assertIn("2 items", said["shown"][1])
        self.assertIn("Dinner booking", said["shown"][2])

    def test_the_description_stays_short(self):
        self.assertLess(len(cards.SCHEMA["description"]), 1700, "it is in every prompt")

    def test_a_review_says_what_it_is_and_a_checklist_its_groups(self):
        """2026-10-30: drawn as the thing itself, an email as an email; a list in its groups, a word by an item."""
        said = json.loads(cards.handle({"cards": [
            {"type": "review", "kind": "Email", "title": "Email to send", "subtitle": "From your Gmail · as you", "action": "Send",
             "fields": [{"label": "To", "value": "Ana Okafor"}, {"label": "Subject", "value": "Late"}, {"label": "Body", "value": "Hi Ana"}]},
            {"type": "review", "kind": "a fax", "title": "Table at Lupa", "action": "Book", "fields": [{"label": "When", "value": "Sat 7:30"}]},
            {"type": "checklist", "title": "Beach", "subtitle": "Nov 7 – 8", "verb": "packed",
             "groups": [{"name": "Clothes", "items": [{"text": "Swimsuits", "note": "×2"}, "Sandals"]}, {"name": "Beach", "items": ["Towels"]}]},
            {"type": "checklist", "title": "Shop", "items": [{"text": "Eggs", "group": "Dairy"}, {"text": "Milk", "group": "Dairy"}]}]}))
        self.assertNotIn("error", said)
        self.assertIn("as an email", said["shown"][0])
        self.assertNotIn(" as ", said["shown"][1], "a kind it doesn't know is left out, not an error")
        self.assertIn("3 items in 2 groups", said["shown"][2], "groups each with their items count")
        self.assertIn("(2 items)", said["shown"][3], "one group is just the list")
        props = cards.SCHEMA["parameters"]["properties"]["cards"]["items"]["properties"]
        self.assertEqual(props["kind"]["enum"], list(cards.REVIEW_KINDS + cards.REMINDER_KINDS), "a review's kinds, and from 1.12.0 a reminder's")
        self.assertIn("subtitle", props)
        self.assertIn("verb", props)
        self.assertIn("note", props["items"]["items"]["properties"])


class ReviewNoteTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())

    def test_asked_to_act_the_agent_is_told_to_show_a_review_first(self):
        note = cards.turn_note(self.home, "Email Ana that I'll be late", platform="desktop")
        self.assertIn("'review'", note)
        self.assertIsNone(cards.turn_note(self.home, "What's the capital of France?", platform="desktop"))
        self.assertIsNone(cards.turn_note(self.home, "Send: Email to Ana\n\n[Redde card k1: the user tapped \"Send\"]", platform="desktop"),
                          "the answer to a review is the go-ahead")


class CardAloneTests(unittest.TestCase):
    """2026-11-01: "Home card" got a long write-up of every light, then the card. Asked for by name,
    the card is the whole answer."""
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())

    def test_a_card_asked_for_by_name_is_the_whole_answer(self):
        for asked in ("Home card", "home card.", "Show me the home card", "house status card", "Can I see the score card?",
                      "Home card [Redde: the person is on CarPlay]"):
            note = cards.turn_note(self.home, asked, platform="desktop") or ""
            self.assertIn("card is the whole answer", note, asked)
            self.assertIn("Write nothing else", note, asked)
        self.assertIn("'home' card", cards.turn_note(self.home, "Home card", platform="desktop"))
        self.assertIn("'score' card", cards.turn_note(self.home, "score card", platform="desktop"))
        for other in ("Turn off the lights in the office.", "What's on my home screen card game list", "Make me a birthday card",
                      "Home card [Redde card review] yes"):
            self.assertNotIn("card is the whole answer", cards.turn_note(self.home, other, platform="desktop") or "", other)
        self.assertIsNone(cards.turn_note(self.home, "Home card", platform="telegram"), "cards are drawn only in Redde")


class ListNoteTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())

    def test_asked_for_a_list_the_agent_is_told_to_show_a_checklist(self):
        for asked in ("Make me a packing list for the cabin", "Can you give me a shopping list for tacos?",
                      "what should we bring to the lake"):
            self.assertIn("'checklist'", cards.turn_note(self.home, asked, platform="desktop") or "", asked)
        self.assertNotIn("'checklist'", cards.turn_note(self.home, "Email Ana the list", platform="desktop") or "")

    def test_a_sectioned_checklist_is_shown(self):
        said = json.loads(cards.handle({"cards": [{"type": "checklist", "title": "Cabin", "emoji": "🏕️",
                                                    "items": [{"text": "Swimsuits", "section": "Clothing"}, {"text": "Sunscreen", "section": "Toiletries"}]}]}))
        self.assertIn("2 items", said["shown"][0])


class AutonomyTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        (self.root / "profiles" / "ops").mkdir(parents=True)

    def test_each_agent_has_its_level_and_the_nudge_follows_it(self):
        self.assertEqual(cards.autonomy(self.root), "ask")
        said = cards.autonomy_slash(self.root, ["default=routine", "ops=act", "bad=whatever"])
        self.assertEqual(said, "redde-push autonomy default=routine ops=act")
        self.assertEqual(cards.autonomy(self.root), "routine")
        self.assertEqual(cards.autonomy(self.root / "profiles" / "ops"), "act")
        self.assertIn("easy to undo", cards.turn_note(self.root, "Text Ana I'm late", platform="desktop"))
        self.assertIn("act on their behalf", cards.turn_note(self.root / "profiles" / "ops", "Book the table", platform="desktop"))
        self.assertIn("review", cards.turn_note(Path(tempfile.mkdtemp()), "Book the table", platform="desktop"), "ask first by default")


class GatedTests(unittest.TestCase):
    """A coding bot whose writes Hermes already asks about gets no review card first (2026-10-29:
    the person was asked twice for each change)."""
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        (self.root / "profiles" / "claude").mkdir(parents=True)
        self.coder = self.root / "profiles" / "claude"

    def test_a_gated_agent_gets_no_review_note_and_the_others_still_do(self):
        asked = "Fix the error message in the POST handler"
        self.assertIn("'review'", cards.turn_note(self.coder, asked, platform="desktop"))
        self.assertEqual(cards.gated_slash(self.root, ["claude", "on"]), "redde-push gated claude")
        self.assertIsNone(cards.turn_note(self.coder, asked, platform="desktop"))
        self.assertIn("'review'", cards.turn_note(self.root, "Email Ana that I'll be late", platform="desktop"), "Sol still asks first")
        self.assertIn("'checklist'", cards.turn_note(self.coder, "Make me a packing list", platform="desktop") or "", "other notes stay")

    def test_the_list_is_set_on_the_server_and_survives_the_apps_levels(self):
        cards.gated_slash(self.root, ["claude", "on"])
        cards.autonomy_slash(self.root, ["claude=ask"])
        self.assertTrue(cards.gated(self.coder))
        self.assertEqual(cards.gated_slash(self.root, ["claude", "off"]), "redde-push gated none")
        self.assertFalse(cards.gated(self.coder))
        self.assertTrue(cards.gated_slash(self.root, ["../x", "on"]).endswith("not a profile name"))


class AgendaTests(unittest.TestCase):
    """What's on the calendar as an 'agenda' card (asked 2026-10-29)."""
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())

    def test_an_agenda_is_checked_leniently_and_an_empty_day_still_shows(self):
        shown, problems = cards.check({"cards": [{"type": "agenda", "title": "Tomorrow", "date": "2026-10-30", "events": [
            {"title": "Standup", "start": "2026-10-30T09:30:00-04:00", "end": "2026-10-30T09:45:00-04:00", "calendar": "Work"},
            {"summary": "Day off", "start": "2026-10-30"}, {"title": "no start"}]}]})
        self.assertEqual(problems, [])
        self.assertIn("2 events", shown[0])
        self.assertIn("1 left out", shown[0])
        shown, problems = cards.check({"cards": [{"type": "agenda", "date": "2026-10-31", "events": []}]})
        self.assertIn("nothing on the calendar", shown[0])
        shown, problems = cards.check({"cards": [{"type": "agenda"}]})
        self.assertEqual(shown, [])
        self.assertIn("needs 'events'", problems[0])

    def test_the_card_is_passed_on_as_given(self):
        said = json.loads(cards.handle({"cards": [{"type": "agenda", "date": "2026-10-30",
                                                    "events": [{"title": "Standup", "start": "2026-10-30T09:30:00-04:00"}]}]}))
        self.assertEqual(said["cards"][0]["events"][0]["title"], "Standup")

    def test_asked_what_is_on_the_calendar_the_agent_is_told_to_show_an_agenda(self):
        for asked in ("What's on my calendar tomorrow?", "what's on my calendar", "What do I have today?", "Am I free Friday afternoon?",
                      "Any meetings this week?", "What's my schedule tomorrow", "when is my next meeting", "what's on tomorrow",
                      "what time is my dentist appointment tomorrow?"):
            self.assertIn("'agenda'", cards.turn_note(self.home, asked, platform="desktop") or "", asked)
        for not_asked in ("Add dentist to my calendar Friday at 3", "Put lunch with Dana on my calendar", "Schedule a call with Ana tomorrow",
                          "what's the weather tomorrow", "what's for dinner tonight?", "what time is it in Tokyo", "Remind me to call the vet"):
            self.assertNotIn("'agenda'", cards.turn_note(self.home, not_asked, platform="desktop") or "", not_asked)

    def test_the_person_s_time_comes_with_it_and_cards_off_or_a_gated_agent_get_none(self):
        cards.slash(self.home, ["on", "tz=America/New_York"])
        self.assertIn("America/New_York", cards.turn_note(self.home, "What's on my calendar tomorrow?", platform="desktop"))
        cards.slash(self.home, ["off"])
        self.assertIsNone(cards.turn_note(self.home, "What's on my calendar tomorrow?", platform="desktop"))
        root = Path(tempfile.mkdtemp())
        (root / "profiles" / "claude").mkdir(parents=True)
        cards.gated_slash(root, ["claude", "on"])
        self.assertIsNone(cards.turn_note(root / "profiles" / "claude", "What's on my calendar tomorrow?", platform="desktop"))


class MoreCardsTests(unittest.TestCase):
    """From 1.12.0 (asked 2026-10-30): purchase, home, reminder, compare and score cards, checked
    leniently, each one's shape in a turn note only when asked for that kind of thing, and in the
    tool's error; the schema stays small."""
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())

    def note(self, text):
        return cards.turn_note(self.home, text, platform="desktop") or ""

    def test_more_ways_of_asking_what_to_buy(self):
        for asked in ("Give me recommendations to buy", "I'm looking to buy a smart plug", "I want to get a new kettle",
                      "I'm shopping for a stroller", "What headphones to buy?", "Any recommendations for a TV to buy?",
                      # 2026-11-01, asked of Sol, and no purchase card came:
                      "Give me a few buying options for 5090 graphics cards. Look for low price iptions",
                      "Where to buy a 5090?", "Find the best deals on a robot vacuum", "Lowest price for AirPods Pro?"):
            self.assertIn("asked what to buy", self.note(asked), asked)
        for errand in ("Buy it", "Order the Wyze plug for me", "Add it to my cart", "What are the price options for the hotel?",
                       "Find the cheapest flight to Lisbon"):
            self.assertNotIn("asked what to buy", self.note(errand), errand)

    def test_asked_what_to_buy_a_review_card_is_sent_back(self):
        # 2026-10-31: "I'm looking to buy a smart plug … recommend a couple", and Home drew a
        # review card twice. The turn is remembered by its session; the card tool holds it to it.
        asked = "I’m looking to buy a smart plug for some Christmas lights. Look at my setup and recommend a couple"
        self.assertIn("asked what to buy", cards.turn_note(self.home, asked, platform="desktop", session="s1"))
        review = {"type": "review", "kind": "purchase", "title": "Wyze Plug Outdoor",
                  "fields": [{"label": "Product", "value": "Wyze Outdoor Smart Plug"}]}
        refused = json.loads(cards.handle({"cards": [review]}, session_id="s1"))
        self.assertIn("'purchase' card, not a 'review'", refused.get("error", ""))
        self.assertIn("items", refused["error"], "the error carries the shape")
        product = {"type": "purchase", "title": "Smart plugs", "items": [{"name": "Plug A", "price": 15}, {"name": "Plug B", "price": 12}]}
        self.assertIn("shown", json.loads(cards.handle({"cards": [product]}, session_id="s1")))
        self.assertIn("shown", json.loads(cards.handle({"cards": [review]}, session_id="s2")), "another chat is its own")
        cards.turn_note(self.home, "Order the Wyze plug for me", platform="desktop", session="s1")
        self.assertIn("shown", json.loads(cards.handle({"cards": [review]}, session_id="s1")), "an order to place is a review again")

    def test_the_schema_stays_small_with_five_more_cards(self):
        self.assertLess(len(json.dumps(cards.SCHEMA)), 6000)
        self.assertLess(len(cards.SCHEMA["description"]), 1700)
        props = cards.SCHEMA["parameters"]["properties"]["cards"]["items"]["properties"]
        self.assertTrue(set(cards.MORE) <= set(props["type"]["enum"]))
        self.assertNotIn("description", props["devices"], "a card's fields are in its note, not in every prompt")

    def test_a_purchase_is_checked_and_its_pick_named(self):
        shown, problems = cards.check({"cards": [{"type": "purchase", "title": "Headphones", "items": [
            {"name": "Aurora Q5", "price": 279, "pick": True}, {"name": "Tidal Air", "badge": "Best value"}, {"price": 9}, "Plain"]}]})
        self.assertEqual(problems, [])
        self.assertIn("purchase: 3 (Aurora Q5 (pick), Tidal Air, Plain)", shown[0])
        self.assertIn("1 left out", shown[0])
        shown, _ = cards.check({"cards": [{"type": "purchase", "items": [{"name": "A"}, {"name": "B", "badge": "Top pick"}]}]})
        self.assertIn("B (pick)", shown[0], "a badge can name the pick")
        self.assertIn("no pick", cards.check({"cards": [{"type": "purchase", "items": ["A", "B"]}]})[0][0])
        self.assertIn("first 6", cards.check({"cards": [{"type": "purchase", "items": [f"P{i}" for i in range(8)]}]})[0][0])
        shown, problems = cards.check({"cards": [{"type": "purchase", "items": [{"price": 3}]}]})
        self.assertEqual(shown, [])
        self.assertIn("'items' (up to 6, your pick first), each {name, brand, price", problems[0], "the error gives the whole shape")

    def test_home_reminder_compare_and_score_are_checked(self):
        shown, problems = cards.check({"cards": [
            {"type": "home", "devices": [{"name": "Kitchen lights", "kind": "light", "state": "on", "entity": "light.kitchen"}, {"name": "Porch"}, {"area": "x"}]},
            {"type": "reminder", "kind": "timer", "title": "Pasta", "duration": "20 min"},
            {"type": "compare", "options": ["Python", {"title": "JavaScript"}], "rows": [{"criterion": "Setup", "values": ["One install", "None"], "best": 1}], "pick": 0},
            {"type": "score", "games": [{"status": "final", "home": {"name": "Orlando Magic", "score": 112}, "away": {"name": "Boston Celtics", "score": 104}}]}]})
        self.assertEqual(problems, [])
        self.assertIn("home: 2 devices (Kitchen lights on, Porch)", shown[0])
        self.assertIn("1 without an 'entity'", shown[0])
        self.assertEqual(shown[1], "reminder: timer 'Pasta'")
        self.assertEqual(shown[2], "compare: Python vs JavaScript (1 criteria; pick Python)")
        self.assertEqual(shown[3], "score: Boston Celtics 104 at Orlando Magic 112 (final)")
        shown, _ = cards.check({"cards": [{"type": "reminder", "title": "Call the vet", "at": "tomorrow at 10"}]})
        self.assertIn("isn't an ISO time", shown[0])
        for card, words in (({"type": "home", "devices": []}, "'devices', each {name, area, kind"),
                            ({"type": "reminder", "at": "2026-10-30T15:45:00-04:00"}, "'title' (what), 'kind'"),
                            ({"type": "compare", "options": ["Only one"], "rows": [{"criterion": "x", "values": ["a"]}]}, "'options' (2 to 4"),
                            ({"type": "compare", "options": ["A", "B"], "rows": ["not a row"]}, "'rows' (the criteria"),
                            ({"type": "score", "games": [{"home": "Magic"}]}, "'games' (one or a few), each {league, home, away")):
            shown, problems = cards.check({"cards": [card]})
            self.assertEqual(shown, [], card)
            self.assertIn(words, problems[0], card)

    def test_each_card_is_asked_for_by_what_the_person_says(self):
        asks = {
            "'purchase' card": ("Which noise-cancelling headphones should I buy?", "What's the best laptop under $1000?",
                                "Can you recommend a good stand mixer?", "I'm looking for a new running watch", "Gift ideas for my dad?",
                                "Is the Kindle or the Kobo better for the price?", "Where can I buy the new Murakami book?",
                                "What vacuum should I get?", "best robot vacuum for $300"),
            "'home' card": ("Turn off the kitchen lights", "Is the garage closed?", "Set the house to 70", "Lock the front door",
                            "Did I leave the porch light on?", "dim the living room lamps", "set the living room lights to 40%"),
            "'reminder' card": ("Remind me to call the vet tomorrow at 10", "Set a timer for 20 minutes", "Wake me up at 6:30",
                                "Every Monday, send me the weekly numbers", "set an alarm for 7 o'clock"),
            "'compare' card": ("Which is better for a beginner, Python or JavaScript?", "Lisbon vs Porto for a week in March",
                               "Should I learn Spanish or French?", "Is Notion better than Obsidian for notes?"),
            "'score' card": ("Did the Magic win?", "When's the next Lightning game?", "What was the score last night?",
                             "How's the Heat game going?", "Is the Heat game on tonight?"),
        }
        for card, messages in asks.items():
            for asked in messages:
                self.assertIn(card, self.note(asked), asked)
        nots = {
            "'purchase' card": ("Buy it", "Order it from Amazon", "Add the blue one to my cart", "Recommend a restaurant near the office",
                                "Can you recommend a good book?", "What should I get for dinner?", "What's the best way to learn Go?"),
            "'home' card": ("Turn on notifications", "Is the store open?", "Close the deal with Ana", "Did the Heat win?",
                            "Lock the row before you update it"),
            "'reminder' card": ("What time is it?", "Set the alarm to away.", "What reminders do I have?"),
            "'compare' card": ("What's the weather?", "Which headphones should I buy, the Sony or the Bose?",
                               "Compare these two functions and tell me which is faster"),
            "'score' card": ("What's my credit score?", "Did you play the song?", "Who won the election?"),
        }
        for card, messages in nots.items():
            for asked in messages:
                self.assertNotIn(card, self.note(asked), asked)
        self.assertIn("never make up a price, a rating or a link", self.note("Which TV should I buy?"))
        self.assertIn("'review'", self.note("Buy it"), "an errand is the review note's")

    def test_the_person_s_time_comes_with_a_reminder_and_a_game_and_off_or_gated_none(self):
        cards.slash(self.home, ["on", "tz=America/New_York"])
        self.assertIn("(America/New_York).]", self.note("Remind me in 20 minutes to check the oven"))
        self.assertIn("(America/New_York).]", self.note("When do the Magic play next?"))
        self.assertTrue(self.note("Which TV should I buy?").endswith("]"))
        self.assertIsNone(cards.turn_note(self.home, "Did the Magic win?\n\n[Redde card k: the user tapped Refresh]", platform="desktop"),
                          "a card's answer is not a new ask")
        cards.slash(self.home, ["off"])
        self.assertIsNone(cards.turn_note(self.home, "Which TV should I buy?", platform="desktop"))
        root = Path(tempfile.mkdtemp())
        (root / "profiles" / "claude").mkdir(parents=True)
        cards.gated_slash(root, ["claude", "on"])
        self.assertIsNone(cards.turn_note(root / "profiles" / "claude", "Set a timer for 5 minutes", platform="desktop"))
        self.assertIsNone(cards.turn_note(self.home, "Which TV should I buy?", platform="telegram"))

    def test_they_are_passed_on_as_given(self):
        card = {"type": "home", "devices": [{"name": "Kitchen lights", "state": "on", "brightness": 80, "entity": "light.kitchen"}]}
        said = json.loads(cards.handle({"cards": [card]}))
        self.assertEqual(said["cards"], [card])
        self.assertNotIn("Stop here", said["note"], "not a card that waits for a tap")


class NewestCardsTests(unittest.TestCase):
    """From 1.13.0 (asked 2026-10-31): recipe, delivery, flight, show, conversion and stock cards,
    checked leniently, each one's shape in a turn note only when asked for that kind of thing (and
    never stealing the 1.12.0 cards' asks), and in the tool's error; the schema stays small."""
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())

    def note(self, text):
        return cards.turn_note(self.home, text, platform="desktop") or ""

    def test_the_schema_stays_small_with_six_more(self):
        self.assertLess(len(json.dumps(cards.SCHEMA)), 6000)
        self.assertLess(len(cards.SCHEMA["description"]), 1700)
        props = cards.SCHEMA["parameters"]["properties"]["cards"]["items"]["properties"]
        for kind in ("recipe", "delivery", "flight", "show", "conversion", "stock"):
            self.assertIn(kind, props["type"]["enum"])
            self.assertIn(kind, cards.MORE)
            self.assertIn(f"'{kind}'", cards.SCHEMA["description"])
        for field in ("ingredients", "legs", "symbol", "rate"):
            self.assertNotIn(field, props, "a card's fields are in its note, not in every prompt")

    def test_they_are_checked_and_said_back(self):
        shown, problems = cards.check({"cards": [
            {"type": "recipe", "title": "Tomato Spaghetti", "servings": 4, "ingredients": ["12 oz spaghetti", {"name": "basil", "amount": 1, "unit": "cup"}],
             "steps": ["Boil.", "Toss."]},
            {"type": "delivery", "title": "Headphones", "carrier": "UPS", "tracking": "1ZDEMO0000000001", "status": "In transit", "expected": "2026-11-05"},
            {"type": "flight", "legs": [{"airline": "Northwind Air", "number": "NW 238", "status": "Delayed",
                                         "from": {"code": "LIS", "time": "2026-11-05T10:35:00+00:00"}, "to": {"code": "JFK"}}]},
            {"type": "show", "items": [{"title": "The Quiet Floor", "pick": True}, "Paper Moons"]}]})
        self.assertEqual(problems, [])
        self.assertEqual(shown[0], "recipe: Tomato Spaghetti (2 ingredients, 2 steps, serves 4)")
        self.assertEqual(shown[1], "delivery: Headphones (In transit, expected 2026-11-05)")
        self.assertEqual(shown[2], "flight: Northwind Air NW 238 LIS→JFK (Delayed)")
        self.assertEqual(shown[3], "show: 2 (The Quiet Floor (pick), Paper Moons)")
        shown, problems = cards.check({"cards": [
            {"type": "conversion", "amount": 5, "from": "mi", "to": "km"},
            {"type": "conversion", "from": "100 USD", "to": "EUR", "rate": 0.9214, "as_of": "2026-10-31T09:00:00-04:00"},
            {"type": "stock", "symbol": "nwnd", "price": 191.2, "percent": "+1.2%", "as_of": "2026-10-31T16:00:00-04:00"},
            {"type": "stock", "items": [{"symbol": "KSTR", "price": "$64.18"}, {"name": "no symbol", "price": 3}]}]})
        self.assertEqual(problems, [])
        self.assertEqual(shown[0], "conversion: 5 mi to km")
        self.assertEqual(shown[1], "conversion: 100 USD to EUR at 0.9214")
        self.assertEqual(shown[2], "stock: NWND 191.2 (+1.2%)")
        self.assertIn("give each its 'as_of'", shown[3], "a price says when it is from")
        hints = cards.check({"cards": [{"type": "recipe", "title": "Bread", "ingredients": ["500 g flour"]},
                                       {"type": "flight", "from": "LIS", "to": "JFK"},
                                       {"type": "conversion", "amount": 100, "from": "USD", "to": "EUR", "rate": 0.92}]})[0]
        self.assertIn("no 'servings'", hints[0])
        self.assertIn("each end's 'time' as ISO", hints[1], "a flight given flat is read as one leg")
        self.assertIn("give 'as_of'", hints[2])

    def test_a_card_without_its_fields_gets_its_shape(self):
        for card, words in (({"type": "recipe", "title": "Bread"}, "'ingredients' (lines with the amount first"),
                            ({"type": "delivery", "title": "A box"}, "'status' (the carrier's words"),
                            ({"type": "flight", "legs": [{"from": "LIS"}]}, "'legs' (one per flight, in order)"),
                            ({"type": "show", "items": [{"year": 2022}]}, "'items' (1 to 6, your pick first)"),
                            ({"type": "conversion", "amount": 100, "from": "USD", "to": "EUR"}, "a currency needs the 'rate' you found"),
                            ({"type": "conversion", "amount": 5}, "'amount'; 'from' and 'to'"),
                            ({"type": "stock", "items": [{"symbol": "X"}]}, "'items' (1 to 4), each {symbol, name")):
            shown, problems = cards.check({"cards": [card]})
            self.assertEqual(shown, [], card)
            self.assertIn(words, problems[0], card)

    def test_each_card_is_asked_for_by_what_the_person_says(self):
        asks = {
            "'recipe' card": ("Can you find me a recipe for banana bread?", "How do I make chicken stock?", "How do you roast a whole chicken?",
                              "What can I make for dinner with chicken and rice?", "What should I cook tonight?", "how to bake sourdough"),
            "'delivery' card": ("Where's my package?", "Track my order from Northwind", "When will my package arrive?",
                                "Has my order shipped yet?", "Is my parcel out for delivery?", "What's the status of 1Z999AA10123456784?"),
            "'flight' card": ("Is my flight tomorrow on time?", "What gate is NW 238 leaving from?", "When does my flight land?",
                              "Is TP 238 delayed?", "Did our connection in Newark get cancelled?"),
            "'show' card": ("What should I watch tonight?", "Recommend a good movie for a rainy day", "Shows like Severance?",
                            "Where can I stream The Bear?", "Is Dune a good movie?", "any good documentaries about space?"),
            "'conversion' card": ("How far is 5 miles in km?", "What's $100 in euros?", "Convert 350°F to Celsius", "2 cups to grams",
                                  "how many ounces in a pound", "What's the exchange rate for yen?", "100 usd to eur"),
            "'stock' card": ("How's Apple stock doing?", "What's the share price of Nvidia?", "How did the market do today?",
                             "Is the S&P 500 up?", "Did Nvidia beat earnings?", "What's $TSLA at?"),
        }
        for card, messages in asks.items():
            for asked in messages:
                self.assertIn(card, self.note(asked), asked)
        nots = {
            "'recipe' card": ("Update the Nix recipe for the build", "That's a recipe for disaster", "How do I make a pull request?",
                              "What can I make with this API?"),
            "'delivery' card": ("Sort the orders by date", "Put these in order of size", "Order it from Amazon"),
            "'flight' card": ("Book a flight to Lisbon", "Find me the cheapest flights to Denver in March", "Turn on flight mode"),
            "'show' card": ("Show me the logs", "Plot this time series", "Watch out for the step", "Which Apple Watch should I buy?",
                            "The log shows a new error"),
            "'conversion' card": ("Convert this file to PDF", "Convert the JSON to a list", "Bake it for 30 minutes in the oven",
                                  "I have 3 kids in school"),
            "'stock' card": ("Is the blue one in stock?", "Make a chicken stock", "Stock up on rice", "Find a stock photo of a beach"),
        }
        for card, messages in nots.items():
            for asked in messages:
                self.assertNotIn(card, self.note(asked), asked)
        # The 1.12.0 cards keep their asks.
        for asked, card in (("Did the Magic win?", "'score' card"), ("Which noise-cancelling headphones should I buy?", "'purchase' card"),
                            ("Set a timer for 20 minutes", "'reminder' card"), ("Turn off the kitchen lights", "'home' card"),
                            ("Which is better for a beginner, Python or JavaScript?", "'compare' card"),
                            ("Remind me when my package arrives", "'reminder' card")):
            self.assertIn(card, self.note(asked), asked)

    def test_the_notes_say_to_look_things_up_and_never_make_them_up(self):
        for note in (cards.RECIPE_NOTE, cards.DELIVERY_NOTE, cards.FLIGHT_NOTE, cards.SHOW_NOTE, cards.STOCK_NOTE, cards.CONVERSION_NOTE):
            self.assertIn("look", note.lower())
            self.assertIn("never make up a price, a time, a status, a rating or a link", note)
        self.assertIn("Never buy or sell", cards.STOCK_NOTE)
        cards.slash(self.home, ["on", "tz=America/New_York"])
        self.assertIn("(America/New_York).]", self.note("Is my flight tomorrow on time?"))
        self.assertIn("(America/New_York).]", self.note("Where's my package?"))
        self.assertTrue(self.note("How's Apple stock doing?").endswith("]"))
        cards.slash(self.home, ["off"])
        self.assertIsNone(cards.turn_note(self.home, "What should I watch tonight?", platform="desktop"))


# ---- 1.14.0: a purchase card's products checked against their own pages (products.py)

products = plugin.products

PRODUCT_PAGE = """<!doctype html><html><head><title>Kasa Smart Plug Mini EP10 | Example Store</title>
<meta property="og:image" content="https://cdn.example.com/og/ep10.jpg">
<script type="application/ld+json">{"@context": "https://schema.org", "@type": "Product", "name": "Kasa Smart Plug Mini 15A",
 "brand": {"@type": "Brand", "name": "Kasa Smart"}, "image": ["https://cdn.example.com/ep10-front.jpg"],
 "aggregateRating": {"@type": "AggregateRating", "ratingValue": "4.6", "reviewCount": "51234"},
 "offers": {"@type": "Offer", "price": "24.99", "priceCurrency": "USD", "availability": "https://schema.org/InStock"}}</script>
</head><body>Kasa</body></html>"""

GRAPH_PAGE = """<html><head><title>Wyze Plug Outdoor</title><script type="application/ld+json">
{"@context": "https://schema.org", "@graph": [{"@type": "WebSite", "name": "Example"}, {"@type": "BreadcrumbList"},
 {"@type": ["Product"], "name": "Wyze Plug Outdoor", "image": {"@type": "ImageObject", "url": "/img/wyze-outdoor.png"},
  "offers": [{"@type": "AggregateOffer", "lowPrice": 32.98, "highPrice": 40, "priceCurrency": "usd",
              "availability": "http://schema.org/OutOfStock"}]}]}</script></head><body></body></html>"""

META_PAGE = """<html><head><title>Govee Smart Plug 4-pack</title>
<meta name="twitter:image" content="https://cdn.example.com/tw/govee.jpg">
<meta property="og:image" content="https://cdn.example.com/og/govee.jpg">
<meta property="product:price:amount" content="1.299,00"><meta property="product:price:currency" content="EUR">
<meta property="product:availability" content="instock"></head><body></body></html>"""

ROBOT_CHECK = """<html><head><title>Amazon.com</title></head><body><h4>Enter the characters you see below</h4>
<p>Sorry, we just need to make sure you're not a robot.</p><form action="/errors/validateCaptcha"></form></body></html>"""

HTML = {"content-type": "text/html; charset=utf-8"}


class FakeWeb:
    """The web for products.py, as pages by address ((status, headers, body), or an exception to
    raise) and hosts by name (their addresses, or an exception). No network."""
    def __init__(self):
        self.pages, self.hosts, self.delay = {}, {}, 0.0
        self.fetched = []

    def resolve(self, host):
        found = self.hosts.get(host, ["93.184.216.34"])
        if isinstance(found, Exception):
            raise found
        return found

    def fetch(self, url, addresses, deadline):
        self.fetched.append((url, tuple(addresses)))
        if self.delay:
            time.sleep(self.delay)
        page = self.pages.get(url, (404, HTML, b""))
        if isinstance(page, Exception):
            raise page
        status, headers, body = page
        return status, headers, body.encode() if isinstance(body, str) else body


def page(body, status=200, headers=HTML):
    return (status, headers, body)


class ProductCheckTests(unittest.TestCase):
    """From 1.14.0 (asked 2026-10-31: "this does not show pictures, and all of the links were dead.
    I want it to be current"): each product's page is read before the card shows; a dead link is
    taken off, a store that blocks programs is left alone, a page gives its price, stock, picture
    and rating; only public web addresses are ever read."""
    def setUp(self):
        products._kept.clear()
        self.web = FakeWeb()
        self.real = (products.resolve, products.fetch_once, products.STEP_TIMEOUT)
        products.resolve, products.fetch_once = self.web.resolve, self.web.fetch
        self.at = datetime(2026, 10, 31, 19, 42, tzinfo=timezone.utc)

    def tearDown(self):
        products.resolve, products.fetch_once, products.STEP_TIMEOUT = self.real
        products._kept.clear()

    def check(self, items, tz=None, **card):
        return products.check_card({"type": "purchase", "title": "Smart plugs", "items": items, **card},
                                   cards.forecast.zone(tz), now=self.at)

    def test_a_dead_link_is_taken_off_and_the_product_kept(self):
        self.web.pages = {"https://www.amazon.com/dp/B0FAKE1234": page("<title>Page Not Found</title>", 404),
                          "https://shop.example.com/gone": page("", 410),
                          "https://shop.example.com/soft": page("<html><head><title>Sorry, this page is no longer available</title></head></html>"),
                          "https://ok.example.com/ep10": page(PRODUCT_PAGE)}
        self.web.hosts = {"made-up-store.example": socket.gaierror(socket.EAI_NONAME, "nodename nor servname provided")}
        card, said = self.check([{"name": "Plug A", "url": "https://www.amazon.com/dp/B0FAKE1234", "price": 15},
                                 {"name": "Plug B", "link": "https://shop.example.com/gone"},
                                 {"name": "Plug C", "url": "https://made-up-store.example/plug"},
                                 {"name": "Plug D", "url": "https://shop.example.com/soft"},
                                 {"name": "Plug E", "url": "https://ok.example.com/ep10"}])
        self.assertEqual([i["name"] for i in card["items"]], ["Plug A", "Plug B", "Plug C", "Plug D", "Plug E"], "every product stays")
        for item in card["items"][:4]:
            self.assertNotIn("url", item)
            self.assertNotIn("link", item)
        self.assertEqual(card["items"][4]["url"], "https://ok.example.com/ep10")
        self.assertEqual(card["items"][0]["price"], 15, "a dead page changes nothing else")
        self.assertIn("links removed (dead): Plug A (the page isn't there (404))", said)
        self.assertIn("Plug C (the site isn't found)", said)
        self.assertIn("Plug D (the page says it isn't there)", said)

    def test_a_store_that_blocks_programs_is_left_unchecked_not_dead(self):
        self.web.pages = {"https://www.amazon.com/dp/B0A": page(ROBOT_CHECK),
                          "https://www.amazon.com/dp/B0B": page("To discuss automated access to Amazon data please contact us", 503),
                          "https://www.bestbuy.com/p/1": page("", 403), "https://www.walmart.com/ip/2": page("", 429),
                          "https://www.target.com/p/3": page("", 401)}
        items = [{"name": n, "url": u, "price": 20} for n, u in zip("ABCDE", self.web.pages)]
        card, said = self.check(items, note="Prices as I found them")
        self.assertEqual(card["items"], items, "kept as the agent wrote them")
        self.assertEqual(card["note"], "Prices as I found them", "nothing was checked: the note isn't touched")
        self.assertIn("not checked: A (the store asks if it's a robot); B (the store doesn't show its page to a program (503))", said)
        self.assertNotIn("removed", said)
        self.assertIn("Don't present those prices as checked", said)

    def test_a_page_gives_its_price_stock_picture_and_rating(self):
        self.web.pages = {"https://ok.example.com/ep10": page(PRODUCT_PAGE)}
        card, said = self.check([{"name": "Kasa EP10", "url": "https://ok.example.com/ep10", "price": 12.99, "was_price": 19.99,
                                  "currency": "GBP"}], tz="America/New_York", note="Prices checked today")
        item = card["items"][0]
        self.assertEqual((item["price"], item["currency"]), (24.99, "USD"), "the page's price wins")
        self.assertNotIn("was_price", item, "a 'was' below the real price is no sale")
        self.assertEqual(item["availability"], "in_stock")
        self.assertEqual(item["image"], "https://cdn.example.com/ep10-front.jpg", "the product's own picture before og:image")
        self.assertEqual((item["rating"], item["reviews"], item["brand"]), (4.6, 51234, "Kasa Smart"))
        self.assertEqual(item["checked"], "2026-10-31T19:42:00+00:00")
        self.assertEqual(item["name"], "Kasa EP10", "the agent's name stays")
        self.assertEqual(card["note"], "Prices checked Oct 31, 3:42 PM", "the person's time; the agent's own claim replaced")
        self.assertIn("from their pages now: Kasa EP10 24.99 USD, in stock", said)
        # What the agent gave stays where the page only fills gaps.
        products._kept.clear()
        card, _ = self.check([{"name": "Kasa", "url": "https://ok.example.com/ep10", "rating": 4.2, "reviews": 900,
                               "image": "https://agent.example.com/k.jpg"}], note="Great for lights")
        item = card["items"][0]
        self.assertEqual((item["rating"], item["reviews"], item["image"]), (4.2, 900, "https://agent.example.com/k.jpg"))
        self.assertEqual(card["note"], "Prices checked Oct 31, 7:42 PM UTC. Great for lights", "no zone known: UTC, and the agent's note kept")

    def test_og_image_and_price_metas_when_there_is_no_product_data(self):
        self.web.pages = {"https://shop.example.de/govee": page(META_PAGE)}
        card, _ = self.check([{"name": "Govee", "url": "https://shop.example.de/govee", "image": "http://insecure.example.com/x.jpg"}])
        item = card["items"][0]
        self.assertEqual(item["image"], "https://cdn.example.com/og/govee.jpg", "og:image first; an http picture counts as none")
        self.assertEqual((item["price"], item["currency"], item["availability"]), (1299.0, "EUR", "in_stock"))

    def test_json_ld_inside_a_graph_and_lists(self):
        self.web.pages = {"https://shop.example.com/wyze": page(GRAPH_PAGE)}
        card, said = self.check([{"name": "Wyze Plug Outdoor", "url": "https://shop.example.com/wyze"}])
        item = card["items"][0]
        self.assertEqual((item["price"], item["currency"], item["availability"]), (32.98, "USD", "out_of_stock"))
        self.assertEqual(item["image"], "https://shop.example.com/img/wyze-outdoor.png", "a relative picture made whole")
        self.assertIn("out of stock", said)
        found = products.read_page('<script type="application/ld+json">[{"@type": "Organization"}, {"@type": "Product", "name": "X", '
                                   '"offers": {"@type": "Offer", "priceSpecification": {"price": "9.50", "priceCurrency": "CAD"}}}]</script>',
                                   "https://a.example.com/x")
        self.assertEqual((found["price"], found["currency"]), (9.5, "CAD"))

    def test_microdata_and_amazons_own_page(self):
        found = products.read_page('<div itemscope itemtype="https://schema.org/Product"><img itemprop="image" src="/p/x.jpg">'
                                   '<span itemprop="price" content="49.00">$49</span><meta itemprop="priceCurrency" content="USD">'
                                   '<link itemprop="availability" href="https://schema.org/OutOfStock"><span itemprop="ratingValue" '
                                   'content="4.4"></span><span itemprop="reviewCount" content="120"></span></div>', "https://shop.example.com/x")
        self.assertEqual(found, {"image": "https://shop.example.com/p/x.jpg", "price": 49.0, "currency": "USD", "availability": "out_of_stock",
                                 "rating": 4.4, "reviews": 120})
        # As Amazon's desktop page wrote it on 2026-10-31 (no schema.org data, no og:image).
        amazon = ('<title>Amazon.com : Kasa Smart Plug HS103P4</title><span id="acrPopover" class="x" title="4.6 out of 5 stars"></span>'
                  '<span id="acrCustomerReviewText" aria-label="150,794 Reviews" class="a-size-small">(150,794)</span>'
                  '<div id="availability" class="a-section">   <span class="a-size-medium a-color-success"> In Stock </span></div>'
                  '<img alt="Kasa" src="https://m.media-amazon.com/images/I/41JnNfpIRXL._SX342_.jpg" data-old-hires='
                  '"https://m.media-amazon.com/images/I/51zoLDBO0wL._SL1105_.jpg" id="landingImage" data-a-dynamic-image="{}">'
                  '<div class="aok-hidden twister-plus-buying-options-price-data">{"desktop_buybox_group_1":[{"displayPrice":"$29.99",'
                  '"priceAmount":29.99,"currencySymbol":"$"}]}</div>')
        self.assertEqual(products.read_page(amazon, "https://www.amazon.com/dp/B07RCNB2L3"),
                         {"price": 29.99, "currency": "USD", "availability": "in_stock", "rating": 4.6, "reviews": 150794,
                          "image": "https://m.media-amazon.com/images/I/51zoLDBO0wL._SL1105_.jpg"})
        self.assertNotIn("price", products.read_page(amazon, "https://shop.example.com/x"), "Amazon's markup is read only on Amazon")
        self.assertEqual(products.read_page('<meta property="og:image" content="https://cdn.shop.com/files/a.png?v=1&width=100">',
                                            "https://shop.example.com/x")["image"], "https://cdn.shop.com/files/a.png?v=1&width=600",
                         "a thumbnail asked for small is asked for large enough")

    def test_only_public_web_addresses_are_read(self):
        self.web.hosts = {"intranet.example.com": ["10.0.0.7"], "tail.example.com": ["100.101.102.103"],
                          "sneaky.example.com": ["93.184.216.34", "192.168.1.2"], "v6.example.com": ["::1"]}
        for url in ("http://127.0.0.1/admin", "http://10.1.2.3/", "https://192.168.1.10/", "http://100.64.0.1/", "http://100.127.255.254/",
                    "http://[::1]/", "http://[::ffff:10.0.0.1]/", "http://[fe80::1]/", "http://169.254.169.254/latest/meta-data/",
                    "http://224.0.0.1/", "http://0.0.0.0/", "http://240.0.0.1/", "https://intranet.example.com/p", "https://tail.example.com/p",
                    "https://sneaky.example.com/p", "https://v6.example.com/p", "http://localhost/", "http://printer.local/",
                    "file:///etc/passwd", "ftp://example.com/x", "https://example.com:8443/p", "http://example.com:22/",
                    "https://user:pass@example.com/p", "gopher://example.com/"):
            with self.assertRaises(products.Refused, msg=url):
                products.target(url)
            products._kept.clear()
            self.assertEqual(products.look(url)["state"], "refused", url)
        self.assertEqual(self.web.fetched, [], "nothing private was ever asked")
        self.assertEqual(products.target("https://example.com/p"), ["93.184.216.34"])
        self.assertEqual(products.target("http://example.com:80/p"), ["93.184.216.34"])
        self.assertTrue(products.public("8.8.8.8") and products.public("2606:4700:4700::1111"))
        self.assertFalse(products.public("::ffff:127.0.0.1") or products.public("64:ff9b::a00:1") or products.public("fc00::1"))
        # A refused link isn't dead: it stays, unread.
        card, said = self.check([{"name": "Router", "url": "http://192.168.1.1/"}])
        self.assertEqual(card["items"][0]["url"], "http://192.168.1.1/")
        self.assertIn("not checked: Router", said)
        self.web.hosts["gone.example.com"] = socket.gaierror(socket.EAI_NONAME, "no such name")
        with self.assertRaises(products.NotFound):
            products.target("https://gone.example.com/p")

    def test_redirects_are_followed_by_hand_and_checked_each_time(self):
        self.web.hosts = {"evil.example.com": ["10.0.0.5"]}
        self.web.pages = {"https://shop.example.com/a": page("", 302, {"location": "http://10.0.0.5/admin"}),
                          "https://shop.example.com/b": page("", 301, {"location": "https://evil.example.com/x"}),
                          "https://shop.example.com/c": page("", 301, {"location": "/products/c-2"}),
                          "https://shop.example.com/products/c-2": page(PRODUCT_PAGE),
                          "https://www.amazon.com/dp/B0OLD": page("", 301, {"location": "https://www.amazon.com/"}),
                          "https://www.amazon.com/dp/B0SRCH": page("", 302, {"location": "/s?k=smart+plug"}),
                          "https://loop.example.com/1": page("", 302, {"location": "/2"}), "https://loop.example.com/2": page("", 302, {"location": "/3"}),
                          "https://loop.example.com/3": page("", 302, {"location": "/4"}), "https://loop.example.com/4": page("", 302, {"location": "/5"}),
                          "https://loop.example.com/5": page(PRODUCT_PAGE)}
        self.assertEqual(products.look("https://shop.example.com/a")["state"], "refused")
        self.assertEqual(products.look("https://shop.example.com/b")["state"], "refused")
        fetched = [u for u, _ in self.web.fetched]
        self.assertNotIn("http://10.0.0.5/admin", fetched)
        self.assertNotIn("https://evil.example.com/x", fetched)
        followed = products.look("https://shop.example.com/c")
        self.assertEqual((followed["state"], followed["found"]["price"]), ("page", 24.99))
        self.assertEqual(self.web.fetched[-1][1], ("93.184.216.34",), "the visit goes to the address that was checked")
        self.assertEqual(products.look("https://www.amazon.com/dp/B0OLD")["state"], "dead", "sent to the home page")
        self.assertEqual(products.look("https://www.amazon.com/dp/B0SRCH")["state"], "dead", "sent to a search")
        self.assertEqual(products.look("https://loop.example.com/1"), {"state": "unchecked", "why": "too many redirects"})
        self.assertNotIn("https://loop.example.com/5", [u for u, _ in self.web.fetched], "three redirects at most")

    def test_a_page_too_slow_or_broken_leaves_the_product_as_it_was(self):
        self.web.pages = {"https://slow.example.com/p": TimeoutError("timed out"), "https://reset.example.com/p": ConnectionResetError(),
                          "https://pdf.example.com/p": page("%PDF", 200, {"content-type": "application/pdf"}),
                          "https://err.example.com/p": page("", 500), "https://ok.example.com/p": page(PRODUCT_PAGE)}
        items = [{"name": "Slow", "url": "https://slow.example.com/p", "price": 10}, {"name": "Reset", "url": "https://reset.example.com/p"},
                 {"name": "PDF", "url": "https://pdf.example.com/p"}, {"name": "Err", "url": "https://err.example.com/p"}]
        card, said = self.check(items + [{"name": "Fine", "url": "https://ok.example.com/p"}])
        self.assertEqual(card["items"][:4], items)
        self.assertIn("Slow (too slow)", said)
        self.assertNotIn("removed", said)
        self.assertNotIn("checked", card["items"][0])

    def test_the_whole_step_is_bounded(self):
        products.STEP_TIMEOUT = 0.3
        self.web.delay = 1.0
        self.web.pages = {f"https://s{n}.example.com/p": page(PRODUCT_PAGE) for n in range(5)}
        items = [{"name": f"P{n}", "url": f"https://s{n}.example.com/p", "price": 5} for n in range(5)]
        started = time.monotonic()
        card, said = self.check(items)
        self.assertLess(time.monotonic() - started, 0.8, "the card doesn't wait for slow stores")
        self.assertEqual(card["items"], items)
        self.assertIn("P0 (too slow)", said)

    def test_pages_are_read_in_parallel_once_and_kept_ten_minutes(self):
        self.web.delay = 0.3
        self.web.pages = {f"https://s{n}.example.com/p": page(PRODUCT_PAGE) for n in range(4)}
        items = [{"name": f"P{n}", "url": f"https://s{n}.example.com/p"} for n in range(4)] + [{"name": "Again", "url": "https://s0.example.com/p"}]
        started = time.monotonic()
        card, _ = self.check(items)
        self.assertLess(time.monotonic() - started, 0.9, "in parallel")
        self.assertEqual(len(self.web.fetched), 4, "one read for a page named twice")
        self.assertTrue(all(i["price"] == 24.99 for i in card["items"]))
        self.check(items)
        self.assertEqual(len(self.web.fetched), 4, "kept")
        products._kept["https://s0.example.com/p"] = (time.time() - products.KEEP - 1, products._kept["https://s0.example.com/p"][1])
        self.check(items[:1])
        self.assertEqual(len(self.web.fetched), 5, "read again after ten minutes")

    def test_with_every_store_unreachable_this_server_is_offline_and_nothing_is_dropped(self):
        self.web.hosts = {"a.example.com": socket.gaierror(socket.EAI_NONAME, "x"), "b.example.com": socket.gaierror(socket.EAI_NONAME, "x")}
        items = [{"name": "A", "url": "https://a.example.com/p"}, {"name": "B", "url": "https://b.example.com/p"}]
        card, said = self.check(items)
        self.assertEqual(card["items"], items)
        self.assertIn("couldn't be reached from here", said)

    def test_through_redde_show_only_purchase_cards_are_read(self):
        self.web.pages = {"https://ok.example.com/ep10": page(PRODUCT_PAGE), "https://www.amazon.com/dp/B0FAKE": page("", 404)}
        purchase = {"type": "purchase", "title": "Smart plugs", "items": [
            {"name": "Kasa EP10", "url": "https://ok.example.com/ep10", "price": 9, "pick": True},
            {"name": "Made up", "url": "https://www.amazon.com/dp/B0FAKE", "price": 11}]}
        answer = json.loads(cards.handle({"cards": [purchase, PLACES]}))
        drawn = answer["cards"][0]["items"]
        self.assertEqual((drawn[0]["price"], drawn[0]["availability"]), (24.99, "in_stock"))
        self.assertNotIn("url", drawn[1])
        self.assertTrue(any("links removed (dead): Made up" in line for line in answer["said"]))
        self.assertIn("Prices checked", answer["cards"][0]["note"])
        self.assertEqual(answer["cards"][1], PLACES)
        self.assertEqual(len(self.web.fetched), 2, "the places card's pages aren't read")
        self.assertEqual(purchase["items"][1]["url"], "https://www.amazon.com/dp/B0FAKE", "the agent's own card isn't changed")
        self.web.fetched.clear()
        json.loads(cards.handle({"cards": [{"type": "purchase", "items": [{"name": "No link", "pick": True}]}]}))
        self.assertEqual(self.web.fetched, [], "no links, nothing read")
        self.assertLess(len(json.dumps(cards.SCHEMA)), 6000)

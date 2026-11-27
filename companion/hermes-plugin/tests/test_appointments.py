"""python -m unittest discover -s companion/hermes-plugin/tests

Appointments that come round again (1.54.0, asked 2026-11-26 "do 4"): the phone sends what it
found of a few kinds of appointment on its calendar; the usual gap is learned here, and a card
offered when one is due with nothing booked, or the day of a doctor's visit."""
import base64
import importlib
import json
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

from test_cards import plugin

appointments = importlib.import_module(plugin.__name__ + ".appointments")
follow = importlib.import_module(plugin.__name__ + ".followthrough")


def at(text: str) -> float:
    return datetime.fromisoformat(text).timestamp()


def iso(text: str) -> str:
    """A local time as the phone sends it, with its offset."""
    return datetime.fromisoformat(text).astimezone().isoformat(timespec="minutes")


def haircuts(last: str, every_days: int = 35, count: int = 5) -> list[str]:
    end = datetime.fromisoformat(last)
    return [iso((end - timedelta(days=every_days * n)).isoformat()) for n in reversed(range(count))]


class AppointmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.offered = []

    def tearDown(self):
        self.tmp.cleanup()

    def offer(self, cards):
        self.offered.append(cards)
        return True

    def send(self, found, device="phone-1", now=None):
        return appointments.take(self.home, device, found, now=now or at("2026-11-26T12:00"))

    def test_a_usual_gap_is_steady_visits(self):
        day = appointments.DAY
        self.assertEqual(appointments.gap([0, 35 * day, 70 * day, 104 * day]), 35 * day)
        self.assertIsNone(appointments.gap([0, 35 * day]), "two visits aren't a habit yet")
        self.assertIsNone(appointments.gap([0, 3 * day, 6 * day, 9 * day]), "too close together to be appointments")
        self.assertIsNone(appointments.gap([0, 20 * day, 150 * day, 160 * day, 300 * day]), "no steady gap")
        self.assertEqual(appointments.every(35 * day), "5 weeks")
        self.assertEqual(appointments.every(182 * day), "6 months")
        self.assertEqual(appointments.every(365 * day), "year")

    def test_a_haircut_due_with_nothing_booked_is_offered_once(self):
        self.send([{"kind": "haircut", "visits": haircuts("2026-10-20T10:00"), "where": "Main Street Barbers"}])
        (card,) = appointments.due(self.home, at("2026-11-26T12:00"))
        self.assertEqual(card["title"], "Time for a haircut?")
        self.assertEqual(card["why"], "You go about every 5 weeks; the last was October 20 at Main Street Barbers")
        self.assertIn("offer me two or three times that fit", card["request"])
        self.assertEqual(appointments.look(self.home, self.offer, now=at("2026-11-26T12:00")), 1)
        self.assertEqual(self.offered[0][0]["title"], "Time for a haircut?")
        self.assertNotIn("_key", self.offered[0][0])
        later = at("2026-11-27T12:00")
        self.assertEqual(appointments.due(self.home, later), [], "once per visit")
        # A new haircut, then due again a gap later.
        self.send([{"kind": "haircut", "visits": haircuts("2026-11-28T10:00")}], now=at("2026-11-28T12:00"))
        self.assertEqual(appointments.due(self.home, at("2026-12-10T12:00")), [], "not yet")
        self.send([{"kind": "haircut", "visits": haircuts("2026-11-28T10:00")}], now=at("2027-01-01T11:00"))   # (as the app does, every few hours)
        self.assertEqual(len(appointments.due(self.home, at("2027-01-01T12:00"))), 1)

    def test_not_yet_due_or_already_booked_isnt_offered(self):
        self.send([{"kind": "haircut", "visits": haircuts("2026-11-10T10:00")}])
        self.assertEqual(appointments.due(self.home, at("2026-11-26T12:00")), [], "16 days of 35")
        self.send([{"kind": "haircut", "visits": haircuts("2026-10-20T10:00"), "next": iso("2026-12-02T09:00")}])
        self.assertEqual(appointments.due(self.home, at("2026-11-26T12:00")), [], "one's booked")

    def test_two_devices_finds_are_put_together(self):
        # The iPad's calendar may be behind the phone's: the newest visit and the soonest booking count.
        self.send([{"kind": "haircut", "visits": haircuts("2026-09-15T10:00")}], device="ipad")
        self.send([{"kind": "haircut", "visits": haircuts("2026-10-20T10:00")}], device="phone")
        (card,) = appointments.due(self.home, at("2026-11-26T12:00"))
        self.assertIn("October 20", card["why"])
        self.send([{"kind": "haircut", "visits": haircuts("2026-09-15T10:00"), "next": iso("2026-12-01T09:00")}], device="ipad")
        self.assertEqual(appointments.due(self.home, at("2026-11-26T12:00")), [], "the iPad has one booked")

    def test_after_a_doctors_visit_its_follow_up_is_asked_the_same_day(self):
        visit = "2026-11-26T09:30"
        self.send([{"kind": "dentist", "visits": [iso(visit)], "ended": iso("2026-11-26T10:15"), "where": "Bright Smiles"}])
        self.assertEqual(appointments.due(self.home, at("2026-11-26T11:00")), [], "not straight after")
        (card,) = appointments.due(self.home, at("2026-11-26T14:00"))
        self.assertEqual(card["title"], "How did the dentist go?")
        self.assertEqual(card["why"], "You were there today at 9:30 AM at Bright Smiles")
        self.assertIn("a next visit to book, a prescription to pick up", card["request"])
        appointments.look(self.home, self.offer, now=at("2026-11-26T14:00"))
        self.assertEqual(appointments.due(self.home, at("2026-11-27T10:00")), [], "once")

    def test_the_morning_after_says_yesterday_and_a_haircut_isnt_asked_after(self):
        self.send([{"kind": "doctor", "visits": [iso("2026-11-25T16:00")], "ended": iso("2026-11-25T16:30")},
                   {"kind": "haircut", "visits": [iso("2026-11-25T17:00")]}], now=at("2026-11-26T09:00"))
        (card,) = appointments.due(self.home, at("2026-11-26T09:30"))
        self.assertEqual(card["title"], "How did the doctor's visit go?")
        self.assertTrue(card["why"].startswith("You were there yesterday at 4:00 PM"))
        self.assertEqual(appointments.due(self.home, at("2026-11-27T09:30")), [], "past a day, let go")

    def test_the_switch_the_days_hours_and_how_often_it_looks(self):
        self.send([{"kind": "haircut", "visits": haircuts("2026-10-20T10:00")}])
        self.assertEqual(appointments.look(self.home, self.offer, now=at("2026-11-26T21:00")), 0, "evening")
        with follow._locked(self.home):
            data = follow.load(self.home)
            data["switches"]["appointments"] = False
            follow.save(self.home, data)
        self.assertEqual(appointments.look(self.home, self.offer, now=at("2026-11-26T12:00")), 0, "switched off")
        self.assertEqual(self.offered, [])

    def test_unknown_kinds_and_bad_times_are_left_out(self):
        kept = self.send([{"kind": "book club", "visits": [iso("2026-11-01T19:00")]},
                          {"kind": "haircut", "visits": ["last Tuesday", "2026-11-01T10:00"]},
                          {"kind": "dentist", "visits": [iso("2026-11-01T10:00")], "where": "  Bright\n Smiles "}, "junk"])
        self.assertEqual(kept, 1)
        (dentist,) = appointments.load(self.home)["devices"]["phone-1"]["kinds"]
        self.assertEqual((dentist["kind"], dentist["where"]), ("dentist", "Bright Smiles"))

    def test_the_apps_command(self):
        found = [{"kind": "haircut", "visits": haircuts("2026-10-20T10:00")}]
        raw = base64.urlsafe_b64encode(json.dumps(found).encode()).decode().rstrip("=")
        answer = follow.slash(self.home, ["appts", "a1b2-c3", raw])
        self.assertEqual(json.loads(answer.split(" ", 2)[2]), {"appointments": {"kinds": 1}})
        self.assertIn("a1b2-c3", appointments.load(self.home)["devices"])
        self.assertIn('"error"', follow.slash(self.home, ["appts", "a1b2-c3", "!!!"]))
        self.assertIn("appointments", follow.listing(self.home)["switches"])
        # Switched off: nothing kept, and what was is forgotten.
        follow.slash(self.home, ["set", "appointments", "off"])
        answer = follow.slash(self.home, ["appts", "a1b2-c3", raw])
        self.assertEqual(json.loads(answer.split(" ", 2)[2]), {"appointments": {"kinds": 0, "off": True}})
        self.assertEqual(appointments.load(self.home)["devices"], {})

    def test_a_device_not_heard_from_in_a_month_is_let_go(self):
        self.send([{"kind": "haircut", "visits": haircuts("2026-10-20T10:00")}], device="old", now=at("2026-10-21T12:00"))
        self.send([{"kind": "dentist", "visits": [iso("2026-11-01T10:00")]}], device="new", now=at("2026-11-26T12:00"))
        self.assertEqual(set(appointments.load(self.home)["devices"]), {"new"})


if __name__ == "__main__":
    unittest.main()

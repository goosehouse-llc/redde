"""python -m unittest discover -s companion/hermes-plugin/tests

Deadlines as they really fall (1.56.0, 2026-11-27 "build 4 too"): bills by banking days, with
the US bank holidays when Hermes's zone is in the US, and renewals and bills written in another
time zone at their time here. Run in New York time, whatever the machine's."""
import importlib
import os
import tempfile
import time
import unittest
from datetime import date, datetime
from pathlib import Path

from test_calls import plugin

follow = importlib.import_module(plugin.__name__ + ".followthrough")
deadlines = importlib.import_module(plugin.__name__ + ".deadlines")

ME = "me@example.com"
ALL = {"mail": True, "orders": True, "trips": True}
_TZ = None


def setUpModule():
    global _TZ
    _TZ = os.environ.get("TZ")
    os.environ["TZ"] = "America/New_York"
    time.tzset()
    deadlines.COUNTRY = "US"


def tearDownModule():
    if _TZ is None:
        os.environ.pop("TZ", None)
    else:
        os.environ["TZ"] = _TZ
    time.tzset()
    deadlines.COUNTRY = None


def at(text: str) -> float:
    return datetime.fromisoformat(text).timestamp()


def mail(sender, subject, when, name=""):
    return {"address": sender, "from": name or sender, "subject": subject, "date": when, "to": [ME], "bucket": "fyi"}


class Cards:
    def __init__(self):
        self.sent = []

    def __call__(self, cards):
        self.sent.append(cards)
        return True


class BankDayTests(unittest.TestCase):
    def test_the_federal_reserve_holidays(self):
        days = deadlines.us_holidays(2026)
        self.assertEqual(days[date(2026, 11, 26)], "Thanksgiving")
        self.assertEqual(days[date(2026, 1, 19)], "Martin Luther King Jr. Day")
        self.assertEqual(days[date(2026, 5, 25)], "Memorial Day")
        self.assertNotIn(date(2026, 7, 4), days, "a Saturday's isn't moved: the banks are open the Friday")
        self.assertNotIn(date(2026, 7, 3), days)
        self.assertEqual(deadlines.us_holidays(2027)[date(2027, 7, 5)], "Independence Day", "a Sunday's is the Monday")
        self.assertEqual(len(days), 10)

    def test_a_bill_due_on_thanksgiving(self):
        days = deadlines.bill_days(date(2026, 11, 26), 3, 2)
        self.assertEqual((days["pay_by"], days["remind"], days["verify"]),
                         (date(2026, 11, 25), date(2026, 11, 22), date(2026, 11, 30)))
        self.assertEqual(days["closed"], {"day": "2026-11-26", "name": "Thanksgiving"})

    def test_a_holiday_between_reminds_a_day_sooner(self):
        days = deadlines.bill_days(date(2026, 11, 27), 3, 2)
        self.assertEqual((days["pay_by"], days["remind"]), (date(2026, 11, 27), date(2026, 11, 23)))
        self.assertEqual(deadlines.closed_said(days["closed"], lambda d: "thursday"), "Thursday is Thanksgiving: banks are closed")

    def test_a_weekend_and_elsewhere(self):
        days = deadlines.bill_days(date(2026, 12, 6), 3, 2)
        self.assertEqual(days["pay_by"], date(2026, 12, 4))
        self.assertEqual(deadlines.closed_said(days["closed"], str), "It's due on a Sunday, when banks are closed")
        deadlines.COUNTRY = "GB"
        try:
            self.assertEqual(deadlines.bill_days(date(2026, 11, 26), 3, 2)["pay_by"], date(2026, 11, 26),
                             "not a US Hermes: only weekends")
        finally:
            deadlines.COUNTRY = "US"


class ZoneTests(unittest.TestCase):
    def test_a_time_and_a_day_in_another_zone(self):
        ref = date(2026, 11, 20)
        found = deadlines.zoned("Your membership renews on December 1, 2026 at 00:00 UTC.", follow._TRIAL, date(2026, 12, 1), ref)
        self.assertEqual(datetime.fromtimestamp(found["at"]), datetime(2026, 11, 30, 19, 0))
        self.assertEqual(found["said"], "midnight UTC")
        found = deadlines.zoned("Your plan renews on December 1, 2026 (UTC).", follow._TRIAL, date(2026, 12, 1), ref)
        self.assertEqual((datetime.fromtimestamp(found["at"]).hour, found["said"]), (19, "December 1 in UTC"))
        found = deadlines.zoned("Payment is due by 5 PM PT on December 4.", follow._DUE, date(2026, 12, 4), ref)
        self.assertEqual((datetime.fromtimestamp(found["at"]).hour, found["said"]), (20, "5 PM PT"))
        self.assertIsNone(deadlines.zoned("Payment is due by 5 PM ET on December 4.", follow._DUE, date(2026, 12, 4), ref),
                          "their own zone: nothing to move")
        self.assertIsNone(deadlines.zoned("Your plan renews on December 1.", follow._TRIAL, date(2026, 12, 1), ref))


class CardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.data = follow.load(self.home)

    def tearDown(self):
        self.tmp.cleanup()

    def due(self, when):
        follow.save(self.home, self.data)
        cards = Cards()
        follow.due(self.home, cards, now=at(when))
        self.data = follow.load(self.home)
        return [c for batch in cards.sent for c in batch]

    def test_a_renewal_at_midnight_utc_is_the_evening_before(self):
        when = at("2026-11-20T09:00")
        follow.from_order(self.data, mail("billing@clear.example", "Your CLEAR+ membership", when, name="CLEAR"),
                          "Your membership will renew on December 1, 2026 at 12:00 AM UTC for $209.", when)
        (item,) = self.data["items"].values()
        self.assertEqual((item["kind"], item["day"], item["zone_said"]), ("trial", "2026-11-30", "12:00 AM UTC"))
        self.assertEqual(self.due("2026-11-26T10:30"), [])
        (card,) = self.due("2026-11-27T10:30")
        self.assertEqual(card["title"], "CLEAR renews Monday")
        self.assertEqual(card["why"], "At 7 PM Monday your time (12:00 AM UTC), then $209")

    def test_a_bill_due_on_thanksgiving_says_so(self):
        when = at("2026-11-16T08:00")
        follow.from_kept_mail(self.data, mail("billing@cityelectric.com", "Your November bill is ready", when, name="City Electric"),
                              "Amount due: $84.20. Payment due date: November 26, 2026.", ME, when, ALL)
        (item,) = self.data["items"].values()
        self.assertEqual(item["pay_by"], "2026-11-25")
        self.assertEqual(self.due("2026-11-21T10:30"), [])
        (card,) = self.due("2026-11-22T10:30")
        self.assertEqual(card["title"], "Pay City Electric $84.20 by Wednesday")
        self.assertEqual(card["why"], "Thursday is Thanksgiving: banks are closed")
        self.assertIn("so by 2026-11-25", card["request"])
        (check,) = self.due("2026-11-30T10:30")
        self.assertEqual(check["title"], "Did the City Electric bill get paid?")

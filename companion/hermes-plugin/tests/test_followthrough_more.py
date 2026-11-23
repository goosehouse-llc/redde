"""python -m unittest discover -s companion/hermes-plugin/tests

Follow-through, the larger proactive update (1.40.0, 2026-11-23: "1, 2 and 4" and "and 7"):
bills and renewals (mail and Paperless), trips, meeting prep, and usual buys."""
import importlib
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

from test_calls import plugin

follow = importlib.import_module(plugin.__name__ + ".followthrough")
paper = importlib.import_module(plugin.__name__ + ".paper")
habits = importlib.import_module(plugin.__name__ + ".habits")
dates = importlib.import_module(plugin.__name__ + ".dates")
lists = plugin.lists


def at(text: str) -> float:
    return datetime.fromisoformat(text).timestamp()


TUESDAY = at("2026-11-24T11:00")
ME = "me@example.com"
ALL = {"mail": True, "orders": True, "trips": True}


def mail(sender, subject, when=TUESDAY, name="", to=(ME,)):
    return {"address": sender, "from": name or sender, "subject": subject, "date": when, "to": list(to), "bucket": "fyi"}


class Cards:
    def __init__(self):
        self.sent = []

    def __call__(self, cards):
        self.sent.append(cards)
        return True


class Base(unittest.TestCase):
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

    def read(self, message, text):
        return follow.from_kept_mail(self.data, message, text, ME, float(message["date"]), ALL)


class BillTests(Base):
    def test_reminded_before_and_checked_after(self):
        self.read(mail("billing@cityelectric.com", "Your November bill is ready", name="City Electric"),
                  "Amount due: $84.20. Payment due date: December 4, 2026.")
        (item,) = self.data["items"].values()
        self.assertEqual((item["kind"], item["shop"], item["amount"], item["day"]), ("bill", "City Electric", "$84.20", "2026-12-04"))
        self.assertEqual(self.due("2026-11-30T12:00"), [])
        (remind,) = self.due("2026-12-01T10:30")
        self.assertEqual(remind["title"], "Pay City Electric $84.20 by Friday")
        (check,) = self.due("2026-12-06T10:30")
        self.assertEqual(check["title"], "Did the City Electric bill get paid?")
        self.assertEqual(self.due("2026-12-07T10:30"), [], "both steps said")

    def test_a_payment_confirmation_settles_it_and_autopay_is_only_checked(self):
        self.read(mail("billing@cityelectric.com", "Your bill", name="City Electric"),
                  "Amount due $84.20, due on Dec 4, 2026. It will be paid automatically from your account.")
        (item,) = self.data["items"].values()
        self.assertTrue(item["autopay"])
        self.assertEqual([s["step"] for s in item["steps"]], ["verify"])
        self.read(mail("billing@cityelectric.com", "Thank you for your payment", when=at("2026-12-03T08:00")),
                  "Thank you for your payment of $84.20.")
        self.assertEqual(self.due("2026-12-06T10:30"), [])
        self.assertEqual(item["id"] in self.data["items"] and self.data["items"][item["id"]]["how"], "paid")

    def test_a_package_due_to_arrive_is_no_bill(self):
        self.read(mail("ship@shop.com", "Your order statement"), "Your package is due to arrive Thursday.")
        self.assertEqual([i["kind"] for i in self.data["items"].values()], [])


class ExpiryTests(Base):
    def test_a_policy_a_month_ahead_a_passport_three(self):
        self.read(mail("service@carinsure.com", "Your car insurance policy documents"),
                  "Your policy expires on January 15, 2027. Renew online.")
        self.read(mail("passports@gov.example", "Your passport renewal reminder"),
                  "Your passport expires on March 1, 2027.")
        kinds = {i["thing"]: i for i in self.data["items"].values()}
        self.assertEqual(sorted(kinds), ["insurance", "passport"])
        (passport,) = self.due("2026-12-01T10:30")
        self.assertEqual(passport["title"], "Passport expires March 1")
        (policy,) = self.due("2026-12-16T10:30")
        self.assertEqual(policy["title"], "Insurance expires January 15")

    def test_a_cards_expiry_month_is_not_one(self):
        self.read(mail("billing@streamco.com", "Your membership receipt"), "Visa card ending 4242, expires 12/27.")
        self.assertEqual(list(self.data["items"]), [])


class TripTests(Base):
    TEXT = ("Your flight to Lisbon is booked. Confirmation code: QX7LMB. Flight TP 202. "
            "Departure: Friday, December 18, 2026 7:05 PM from Boston. Return: Sunday, December 27, 2026.")

    def test_pack_check_in_and_receipts(self):
        self.read(mail("noreply@flytap.com", "Your trip to Lisbon: booking confirmed", name="TAP Air Portugal"), self.TEXT)
        (trip,) = self.data["items"].values()
        self.assertEqual((trip["place"], trip["flight"], trip["ref"], trip["day"], trip["back"]),
                         ("Lisbon", "TP202", "QX7LMB", "2026-12-18", "2026-12-27"))
        (pack,) = self.due("2026-12-15T10:30")
        self.assertEqual(pack["title"], "Pack for Lisbon")
        self.assertIn("packing list in Redde", pack["request"])
        self.assertIn("Leave-By", pack["request"])
        (checkin,) = self.due("2026-12-17T10:30")
        self.assertEqual(checkin["title"], "Check in for TP202")
        self.assertIn("QX7LMB", checkin["request"])
        (home,) = self.due("2026-12-28T10:30")
        self.assertEqual(home["title"], "File the receipts from Lisbon?")

    def test_a_second_mail_fills_in_the_first(self):
        self.read(mail("noreply@flytap.com", "Your booking", name="TAP"), "Flight TP 202. Departure: December 18, 2026.")
        self.read(mail("noreply@flytap.com", "Your itinerary to Lisbon"), "Flight TP202. Departure December 18, 2026. Return December 27, 2026.")
        (trip,) = self.data["items"].values()
        self.assertEqual((trip["back"], trip["place"]), ("2026-12-27", "Lisbon"))
        self.assertEqual([s["step"] for s in trip["steps"]], ["pack", "checkin", "home"])

    def test_a_hotel_stay(self):
        self.read(mail("res@hotel.com", "Your stay in Porto is confirmed"),
                  "Check-in: Dec 20, 2026 from 3pm. Check-out: Dec 22, 2026 by 11am.")
        (trip,) = self.data["items"].values()
        self.assertEqual((trip["place"], trip["flight"], trip["back"]), ("Porto", None, "2026-12-22"))
        self.assertEqual([s["step"] for s in trip["steps"]], ["pack", "home"])


class MeetingTests(Base):
    def test_prep_an_hour_before_with_what_is_open(self):
        follow.from_sent(self.data, {"to": ["ana@example.com"], "subject": "Lease", "date": TUESDAY,
                                     "_text": "I'll send the signed copy by Friday."}, ME, TUESDAY)
        self.read(mail("ana@example.com", "Invitation: Lease review @ Wed Nov 25, 2026 10am - 11am (EST) (me@example.com)",
                       name="Ana Ruiz"), "")
        meeting = next(i for i in self.data["items"].values() if i["kind"] == "meeting")
        self.assertEqual((meeting["title"], meeting["people"]), ("Lease review", ["ana@example.com"]))
        self.assertEqual(self.due("2026-11-25T08:30"), [])
        (card,) = self.due("2026-11-25T09:05")
        self.assertEqual(card["title"], "Before Lease review at 10 AM")
        self.assertIn("you promised Ana", card["why"])
        self.assertIn("brief me", card["request"])

    def test_nothing_open_nothing_said_and_a_cancellation_drops_it(self):
        self.read(mail("bo@example.com", "Invitation: Coffee @ Thu Nov 26, 2026 8am - 9am (EST)"), "")
        self.assertEqual(self.due("2026-11-26T07:10"), [])
        self.read(mail("cy@example.com", "Invitation: Sync @ Fri Nov 27, 2026 2pm - 3pm"), "")
        self.read(mail("cy@example.com", "Canceled event: Sync @ Fri Nov 27, 2026 2pm - 3pm"), "")
        self.assertEqual({i["title"]: i["state"] for i in self.data["items"].values() if i["kind"] == "meeting"},
                         {"Coffee": "offered", "Sync": "dropped"})

    def test_an_outlook_when_line(self):
        self.read(mail("dee@example.com", "Invitation: Budget"), "When: Thursday, December 3, 2026 2:30 PM-3:30 PM (UTC-05:00)")
        meeting = next(i for i in self.data["items"].values() if i["kind"] == "meeting")
        self.assertEqual(datetime.fromtimestamp(meeting["start"]).strftime("%Y-%m-%d %H:%M"), "2026-12-03 14:30")

    def test_heads_ups_are_told_whats_open(self):
        follow.from_sent(self.data, {"to": ["ana@example.com"], "subject": "Lease", "date": TUESDAY,
                                     "_text": "Could you confirm the dates?"}, ME, TUESDAY)
        follow.save(self.home, self.data)
        note = follow.run_note(self.home, "Heads-ups, 60 minutes before. Look at the calendar", "cron")
        self.assertIn("waiting on Ana (ana@example.com)", note)
        self.assertIsNone(follow.run_note(self.home, "Heads-ups, 60 minutes before.", "telegram"))


class PaperlessTests(Base):
    def test_new_documents_read_for_bills_and_expiries(self):
        (self.home / ".env").write_text("PAPERLESS_URL=http://100.101.12.34:8000/api/\nPAPERLESS_WATCHER_TOKEN=t0k\n")
        docs = [{"id": 5, "title": "Old", "content": "", "correspondent": None}]

        def fetch(url, headers):
            self.assertEqual(headers["Authorization"], "Token t0k")
            if "/correspondents/" in url:
                return {"results": [{"id": 3, "name": "Water Board"}]}
            return {"results": docs}
        paper.FETCH = fetch
        try:
            self.assertEqual(paper.status(self.home), {"found": True, "profile": "default"})
            self.assertEqual(paper.look(self.home, now=at("2026-11-24T10:00")), 0, "the first look only remembers")
            docs = [{"id": 6, "title": "Water bill November", "correspondent": 3,
                     "content": "Amount due: $41.00. Please pay by December 10, 2026."},
                    {"id": 7, "title": "Home insurance policy", "correspondent": None,
                     "content": "Coverage period ends February 2, 2027."}] + docs
            self.assertEqual(paper.look(self.home, now=at("2026-11-24T13:00")), 2)
        finally:
            paper.FETCH = None
        items = {i["kind"]: i for i in follow.load(self.home)["items"].values()}
        self.assertEqual((items["bill"]["shop"], items["bill"]["day"]), ("Water Board", "2026-12-10"))
        self.assertEqual(items["expiry"]["day"], "2027-02-02")


class HabitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        lists.BACKGROUND = False
        lists.change(self.home, {"action": "make", "title": "Groceries", "items": []})

    def tearDown(self):
        lists.BACKGROUND = True
        self.tmp.cleanup()

    def buy(self, text, when):
        lists.change(self.home, {"action": "add", "list": "Groceries", "items": [text]}, now=at(when))
        lists.change(self.home, {"action": "check", "list": "Groceries", "items": [text]}, now=at(when))
        lists.change(self.home, {"action": "clear_done", "list": "Groceries"}, now=at(when))

    def test_milk_every_six_days(self):
        for day in ("2026-11-01", "2026-11-07", "2026-11-13", "2026-11-19"):
            self.buy("Milk", day + "T18:00")
        self.buy("Saffron", "2026-11-02T18:00")
        cards = Cards()
        self.assertEqual(habits.look(self.home, cards, now=at("2026-11-23T10:00")), 0, "not yet")
        habits.save(self.home, {**habits.load(self.home), "at": 0})
        (card,) = habits.due(self.home, at("2026-11-26T10:00"))
        self.assertEqual(card["title"], "Milk again?")
        self.assertIn("about every 6 days", card["why"])
        self.assertEqual(card["request"], "Add Milk to my Groceries list.")
        habits.look(self.home, cards, now=at("2026-11-26T10:00"))
        self.assertEqual(len(cards.sent), 1)
        self.assertEqual(habits.due(self.home, at("2026-11-27T10:00")), [], "once per gap")

    def test_not_while_its_on_a_list_and_not_from_unsteady_buys(self):
        for day in ("2026-11-01", "2026-11-07", "2026-11-13"):
            self.buy("Eggs", day + "T18:00")
        lists.change(self.home, {"action": "add", "list": "Groceries", "items": ["eggs"]}, now=at("2026-11-20T09:00"))
        self.assertEqual(habits.due(self.home, at("2026-11-21T10:00")), [])
        for day in ("2026-11-01", "2026-11-03", "2026-11-20"):
            self.buy("Bread", day + "T18:00")
        self.assertEqual(habits.gap(habits.load(self.home)["items"]["bread"]["times"]), None)


if __name__ == "__main__":
    unittest.main()

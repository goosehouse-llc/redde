"""python -m unittest discover -s companion/hermes-plugin/tests

Follow-through and arrivals (1.39.0, 2026-11-23: "What are some other proactive actions we can
incorporate?", then "All 3"): promises and questions in mail, replies owed, deliveries, return
windows and trials, Jellyfin arrivals and new seasons."""
import importlib
import json
import tempfile
import unittest
from datetime import date, datetime
from pathlib import Path

from test_calls import plugin

dates = importlib.import_module(plugin.__name__ + ".dates")
follow = importlib.import_module(plugin.__name__ + ".followthrough")
arrivals = importlib.import_module(plugin.__name__ + ".arrivals")
lists = plugin.lists


def at(text: str) -> float:
    return datetime.fromisoformat(text).timestamp()


TUESDAY = at("2026-11-24T11:00")
ME = "me@example.com"


def sent(to, text, subject="Lease renewal", when=TUESDAY):
    return {"to": [to], "subject": subject, "date": when, "_text": text}


def came(sender, subject, when, bucket="fyi", name="", mid="a:INBOX:1"):
    return {"id": mid, "address": sender, "from": name or sender, "subject": subject, "date": when, "bucket": bucket}


class Cards:
    def __init__(self, take=True):
        self.sent, self.take = [], take

    def __call__(self, cards):
        self.sent.append(cards)
        return self.take


class DatesTests(unittest.TestCase):
    def test_days_as_people_write_them(self):
        ref = date(2026, 11, 24)    # a Tuesday
        for text, want in [("by Friday", date(2026, 11, 27)), ("tomorrow", date(2026, 11, 25)),
                           ("next week", date(2026, 11, 30)), ("end of the week", date(2026, 11, 27)),
                           ("on Dec 3", date(2026, 12, 3)), ("December 15th, 2026", date(2026, 12, 15)),
                           ("3 January", date(2027, 1, 3)), ("on 12/1", date(2026, 12, 1)),
                           ("2026-12-09", date(2026, 12, 9)), ("Thursday, November 26", date(2026, 11, 26)),
                           ("next Tuesday", date(2026, 12, 1))]:
            self.assertEqual(dates.first(text, ref), want, text)
        self.assertIsNone(dates.first("in a while", ref))


class MailTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.data = follow.load(self.home)

    def tearDown(self):
        self.tmp.cleanup()

    def due(self, when, mailbox=None, take=True):
        follow.save(self.home, self.data)
        cards = Cards(take)
        follow.due(self.home, cards, mailbox, now=at(when))
        self.data = follow.load(self.home)
        return [c for batch in cards.sent for c in batch]

    def test_a_promise_comes_back_on_its_day_unless_something_went(self):
        made = follow.from_sent(self.data, sent("ana.lopez@example.com", "Hi Ana,\nI'll send you the signed copy by Friday.\n\n"
                                                "On Mon, Ana wrote:\n> Any news?"), ME, TUESDAY)
        item = self.data["items"][made[0]]
        self.assertEqual((item["kind"], item["day"], item["name"]), ("promise", "2026-11-27", "Ana Lopez"))
        self.assertEqual(self.due("2026-11-27T10:00"), [], "not before the afternoon")
        (card,) = self.due("2026-11-27T16:30")
        self.assertEqual(card["title"], "Send Ana what you promised")
        self.assertIn("I'll send you the signed copy by Friday.", card["request"])
        self.assertIn("look over before anything is sent", card["request"])
        self.assertEqual(self.due("2026-11-27T18:30"), [], "once")

    def test_a_promise_kept_is_settled_by_the_next_mail_to_them(self):
        follow.from_sent(self.data, sent("ana@example.com", "I'll send it tomorrow."), ME, TUESDAY)
        follow.from_sent(self.data, sent("ana@example.com", "Here it is.", when=at("2026-11-25T09:00")), ME, at("2026-11-25T09:00"))
        self.assertEqual(self.due("2026-11-25T16:30"), [])
        self.assertEqual([i["how"] for i in self.data["items"].values() if i["kind"] == "promise"], ["sent"])

    def test_a_question_waits_four_days_for_an_answer(self):
        follow.from_sent(self.data, sent("bo@example.com", "Could you confirm the dates?"), ME, TUESDAY)
        self.assertEqual(self.due("2026-11-27T10:00"), [])
        self.assertEqual(self.due("2026-11-28T10:00"), [], "four whole days")
        (card,) = self.due("2026-11-28T11:30")
        self.assertEqual(card["title"], "No answer from Bo yet")
        self.assertIn("nudge", card["request"])

    def test_an_answer_settles_it(self):
        follow.from_sent(self.data, sent("bo@example.com", "Could you confirm the dates?"), ME, TUESDAY)
        follow.from_inbox(self.data, came("bo@example.com", "Re: Lease renewal", at("2026-11-25T08:00")), at("2026-11-25T08:00"))
        self.assertEqual(self.due("2026-11-29T10:00"), [])

    def test_no_promise_or_question_to_a_shop_or_a_crowd(self):
        self.assertEqual(follow.from_sent(self.data, sent("no-reply@shop.com", "Can you refund it?"), ME, TUESDAY), [])
        many = {"to": ["a@x.com", "b@x.com", "c@x.com", "d@x.com"], "subject": "Party", "date": TUESDAY, "_text": "Can you come?"}
        self.assertEqual(follow.from_sent(self.data, many, ME, TUESDAY), [])
        self.assertEqual(follow.from_sent(self.data, sent("ana@example.com", "Thanks, see you then."), ME, TUESDAY), [])

    def test_a_reply_owed_once_if_still_in_the_inbox(self):
        follow.from_inbox(self.data, came("cy@example.com", "Dinner?", TUESDAY, bucket="needs_reply", name="Cy Park", mid="a:INBOX:7"), TUESDAY)
        follow.from_inbox(self.data, came("dee@example.com", "Lunch?", TUESDAY, bucket="needs_reply", mid="a:INBOX:8"), TUESDAY)
        cards = self.due("2026-11-27T12:00", mailbox=lambda: {"a:INBOX:7"})
        self.assertEqual([c["title"] for c in cards], ["Reply to Cy"], "the archived one was dealt with")

    def test_cards_come_in_the_day_an_hour_apart_and_not_when_switched_off(self):
        for n in range(7):
            follow.from_sent(self.data, sent(f"p{n}@example.com", "Could you send it?", subject=f"S{n}"), ME, TUESDAY)
        self.assertEqual(self.due("2026-11-29T07:00"), [], "not at night")
        self.assertEqual(len(self.due("2026-11-29T10:00")), 5)
        self.assertEqual(self.due("2026-11-29T10:30"), [], "an hour apart")
        self.assertEqual(len(self.due("2026-11-29T11:05")), 2)
        follow.from_sent(self.data, sent("q@example.com", "Can you?", subject="Q"), ME, TUESDAY)
        self.data["switches"]["mail"] = False
        self.assertEqual(self.due("2026-11-29T13:00"), [])

    def test_a_card_not_taken_is_offered_again(self):
        follow.from_sent(self.data, sent("bo@example.com", "Could you confirm?"), ME, TUESDAY)
        self.assertEqual(len(self.due("2026-11-28T12:00", take=False)), 1)
        self.assertEqual(len(self.due("2026-11-28T12:05")), 1)


class OrderTests(unittest.TestCase):
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

    def shipped(self, text, subject='Shipped: "Lego Botanical Bouquet"', when=TUESDAY):
        message = {"address": "shipment-tracking@amazon.com", "from": "Amazon.com", "subject": subject, "date": when,
                   "bucket": "receipts"}
        self.assertTrue(follow.orderish(message))
        return follow.from_order(self.data, message, text, when)

    def test_a_delivery_today_then_late(self):
        made, _ = self.shipped("Arriving Thursday, November 26. Order #112-3345566-7788990. Track package. "
                               "Ordered Shipped Out for delivery Delivered")
        item = self.data["items"][made[0]]
        self.assertEqual((item["what"], item["shop"], item["order"], item["day"]),
                         ("Lego Botanical Bouquet", "Amazon", "112-3345566-7788990", "2026-11-26"))
        (today,) = self.due("2026-11-26T09:30")
        self.assertEqual(today["title"], "Arriving today: Lego Botanical Bouquet")
        self.assertEqual(self.due("2026-11-27T10:00"), [])
        (late,) = self.due("2026-11-28T10:30")
        self.assertEqual(late["title"], "Still no sign of Lego Botanical Bouquet")
        self.assertIn("112-3345566-7788990", late["request"])

    def test_delivered_settles_it_and_ticks_the_gift_off(self):
        lists.change(self.home, {"action": "make", "title": "Christmas Gifts", "items": ["Lego Botanical Bouquet for Mum"]})
        self.shipped("Arriving Thursday, November 26. Order #112-3345566-7788990.")
        follow.save(self.home, self.data)
        message = {"address": "shipment-tracking@amazon.com", "from": "Amazon.com", "bucket": "receipts", "id": "a:INBOX:9",
                   "subject": 'Delivered: "Lego Botanical Bouquet"', "date": at("2026-11-26T15:00")}
        inbox = type("I", (), {"root": self.home})()
        account = type("A", (), {"address": ME, "via": "imap", "id": "a"})()
        self.data["switches"]["mail"] = False
        follow.save(self.home, self.data)
        follow.after_sync(inbox, account, [message], {"a:INBOX:9": "Your package was delivered."}, at("2026-11-26T15:05"))
        self.data = follow.load(self.home)
        self.assertEqual([i.get("how") for i in self.data["items"].values()], ["delivered"])
        self.assertTrue(lists.load(self.home)[0]["items"][0]["done"])
        self.assertEqual(self.due("2026-11-28T10:30"), [])

    def test_a_tracker_that_says_delivered_is_still_on_its_way(self):
        made, came_ = self.shipped("Your package will be delivered Friday. Ordered > Shipped > Delivered",
                                   subject="Your order is on its way")
        self.assertEqual(came_, [])
        self.assertEqual(self.data["items"][made[0]]["day"], "2026-11-27")

    def test_a_return_window_and_a_trial(self):
        self.shipped("Thanks for your order. Return window closes on Dec 26, 2026.", subject="Your order of a lamp")
        message = {"address": "billing@streamco.com", "from": "StreamCo", "subject": "Welcome to your free trial",
                   "date": TUESDAY, "bucket": "notifications"}
        follow.from_order(self.data, message, "Your free trial ends on December 1, 2026. After that you'll be charged "
                                              "$14.99/month.", TUESDAY)
        (trial,) = self.due("2026-11-28T10:30")
        self.assertEqual(trial["title"], "StreamCo renews December 1")
        self.assertIn("$14.99/month", trial["why"])
        (back,) = self.due("2026-12-21T10:30")
        self.assertEqual(back["title"], "Return window closes December 26")
        self.assertIn("a lamp", back["why"])


class SlashTests(unittest.TestCase):
    def test_list_switch_and_drop(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            data = follow.load(home)
            follow.from_sent(data, sent("bo@example.com", "Could you confirm?"), ME, TUESDAY)
            follow.save(home, data)
            shown = json.loads(follow.slash(home, ["list"]).removeprefix("redde-push follow "))
            self.assertEqual(shown["switches"], {"mail": True, "orders": True, "arrivals": True})
            self.assertEqual(shown["jellyfin"], {"found": False})
            (item,) = shown["items"]
            self.assertEqual((item["kind"], item["who"], item["subject"]), ("waiting", "bo@example.com", "Lease renewal"))
            follow.slash(home, ["set", "orders", "off"])
            after = json.loads(follow.slash(home, ["drop", item["id"]]).removeprefix("redde-push follow "))
            self.assertEqual((after["items"], after["switches"]["orders"]), ([], False))
            self.assertIn("for the Redde app", follow.slash(home, ["eat"]))


class ArrivalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        (self.home / "profiles" / "media").mkdir(parents=True)
        (self.home / "profiles" / "media" / ".env").write_text("JELLYFIN_URL=100.101.12.34:8096\nJELLYFIN_API_KEY=k3y\n")
        self.library = [{"Id": "1", "Name": "Home Alone", "ProductionYear": 1990}]
        self.asked = []

        def fetch(url, headers):
            self.asked.append(url)
            if "/Users/" in url:
                return {"Items": [{"Name": "Severance"}]}
            if url.endswith("/Users"):
                return [{"Id": "u1", "Name": "sam"}]
            return {"Items": self.library}
        arrivals.FETCH = fetch
        self.web = {}
        self.saved_get = plugin.posters.GET
        plugin.posters.GET = lambda url, deadline: self.web.get(url, ("ok", 404, {}, b""))
        lists.BACKGROUND = False
        lists.change(self.home, {"action": "make", "title": "Movies", "kind": "watch", "items": ["Elf (2003)", "Heat"]})

    def tearDown(self):
        arrivals.FETCH = None
        plugin.posters.GET = self.saved_get
        lists.BACKGROUND = True
        self.tmp.cleanup()

    def look(self, when):
        cards = Cards()
        arrivals.look(self.home, cards, now=at(when))
        return [c for batch in cards.sent for c in batch]

    def seasons(self, *numbers_and_dates):
        show = {"name": "Severance", "_embedded": {"seasons": [{"number": n, "premiereDate": d} for n, d in numbers_and_dates]}}
        self.web["https://api.tvmaze.com/singlesearch/shows?q=Severance&embed=seasons"] = ("ok", 200, {}, json.dumps(show).encode())

    def test_found_in_a_bots_env_never_shown(self):
        found = arrivals.find(self.home)
        self.assertEqual((found["url"], found["profile"]), ("http://100.101.12.34:8096", "media"))
        self.assertEqual(arrivals.status(self.home), {"found": True, "profile": "media"})

    def test_a_watch_list_title_new_in_the_library(self):
        self.seasons((1, "2022-02-18"), (2, "2025-01-17"))
        self.assertEqual(self.look("2026-11-24T10:00"), [], "the first look remembers what's there")
        self.library = [{"Id": "2", "Name": "Elf", "ProductionYear": 2003}, {"Id": "3", "Name": "Heat", "ProductionYear": 2023}] + self.library
        self.assertEqual(self.look("2026-11-24T10:10"), [], "half an hour apart")
        cards = self.look("2026-11-24T10:40")
        self.assertEqual([c["title"] for c in cards], ["Elf is on Jellyfin now", "Heat is on Jellyfin now"])
        self.assertIn("plan a night", cards[0]["request"])

    def test_a_finished_series_new_season(self):
        self.seasons((1, "2022-02-18"), (2, "2025-01-17"))
        self.look("2026-11-24T10:00")
        self.seasons((1, "2022-02-18"), (2, "2025-01-17"), (3, "2026-12-12"))
        self.assertEqual(self.look("2026-11-24T12:00"), [], "a series once a day")
        (card,) = self.look("2026-11-25T12:00")
        self.assertEqual(card["title"], "Severance season 3 starts December 12")
        self.assertEqual(self.look("2026-11-26T12:00"), [], "once")

    def test_off_and_at_night(self):
        self.assertEqual(self.look("2026-11-24T22:00"), [])
        self.assertEqual(self.asked, [])
        follow.slash(self.home, ["set", "arrivals", "off"])
        self.assertEqual(self.look("2026-11-24T10:00"), [])
        self.assertEqual(self.asked, [])



class ThroughTheInboxTests(unittest.TestCase):
    """A look at the inbox reads the newest sent mail too, and hands both over."""
    def setUp(self):
        import os
        from unittest import mock
        from test_mail import FakeImap, FakeServer, FakeSmtp
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        (self.root / ".env").write_text("REDDE_MAIL_ADDRESS=alex@example.com\nREDDE_MAIL_PASSWORD='app-pass'\nREDDE_MAIL_PROVIDER=fastmail\n")
        self.server = FakeServer()
        plugin.mail._usable_cache.clear()
        self.env = mock.patch.dict(os.environ, {k: v for k, v in os.environ.items() if not k.startswith("REDDE_MAIL_")}, clear=True)
        self.env.start()
        self.inbox = plugin.mail.Inbox(self.root, imap_connect=lambda a: FakeImap(self.server),
                                       smtp_connect=lambda a: FakeSmtp(self.server), sort=lambda **_: "[]")

    def tearDown(self):
        self.env.stop()
        self.dir.cleanup()

    def put(self, folder, uid, sender, to, subject, body, when="Tue, 24 Nov 2026 11:%02d:00 -0500"):
        from email.message import EmailMessage
        msg = EmailMessage()
        msg["From"], msg["To"], msg["Subject"], msg["Date"] = sender, to, subject, when % uid
        msg["Message-ID"] = f"<{folder}{uid}@example.com>"
        msg.set_content(body)
        self.server.folders[folder][uid] = [msg.as_bytes(), set()]

    def test_a_promise_in_sent_mail_and_its_answer(self):
        self.put("Sent", 1, "Alex <alex@example.com>", "Ana Ruiz <ana@example.com>", "Lease", "I'll send the signed copy by Friday.")
        self.put("Sent", 2, "Alex <alex@example.com>", "Bo <bo@example.com>", "Dates", "Could you confirm the dates?")
        account = self.inbox.accounts()[0]
        now = datetime.fromisoformat("2026-11-24T18:00:00-05:00").timestamp()
        self.inbox.sync(account, now=now)
        kinds = sorted((i["kind"], i["who"]) for i in follow.load(self.root)["items"].values())
        self.assertEqual(kinds, [("promise", "ana@example.com"), ("waiting", "bo@example.com")])
        self.put("INBOX", 1, "Bo <bo@example.com>", "alex@example.com", "Re: Dates", "Yes, the 4th.",
                 when="Wed, 25 Nov 2026 09:%02d:00 -0500")
        self.inbox.sync(account, now=now + 86400)
        states = {i["who"]: i["state"] for i in follow.load(self.root)["items"].values()}
        self.assertEqual(states, {"ana@example.com": "open", "bo@example.com": "done"})


if __name__ == "__main__":
    unittest.main()

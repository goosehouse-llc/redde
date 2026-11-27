"""python -m unittest discover -s companion/hermes-plugin/tests

Security notices, bounces and follow-ups (1.55.0, 2026-11-27 "build 1-3", after a r/hermesagent
thread of other agents' nudges): "Was this you?" with "that was me" remembered, mail that
bounced and hasn't gone again, someone following up with a draft still waiting."""
import importlib
import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

from test_calls import plugin

follow = importlib.import_module(plugin.__name__ + ".followthrough")
watch = importlib.import_module(plugin.__name__ + ".mailwatch")


def at(text: str) -> float:
    return datetime.fromisoformat(text).timestamp()


ME = "me@example.com"
MORNING = at("2026-11-27T09:14")


def came(sender, subject, when=MORNING, name="", mid="a:INBOX:1", bucket="fyi", **kw):
    return {"id": mid, "address": sender, "from": name or sender, "subject": subject, "date": when, "bucket": bucket, **kw}


GOOGLE = ("New sign-in to your Google Account\nWe noticed a new sign-in to your Google Account on a Mac device, near "
          "Saint Paul, Minnesota. If this was you, you don't need to do anything." + " " * 500
          + "Get the Google app for iPhone and Android.")


class Cards:
    def __init__(self, take=True):
        self.sent, self.take = [], take

    def __call__(self, cards):
        self.sent.append(cards)
        return self.take


class Base(unittest.TestCase):
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


class SecurityTests(Base):
    def google(self, mid="a:INBOX:1", when=MORNING, text=GOOGLE):
        return watch.from_security(self.data, came("no-reply@accounts.google.com", "Security alert", when, name="Google",
                                                   mid=mid), text, when)

    def test_a_sign_in_is_asked_about_a_quarter_hour_on(self):
        (made,) = self.google()
        (notice,) = self.data["items"][made]["notices"]
        self.assertEqual((notice["service"], notice["what"], notice["device"], notice["place"]),
                         ("Google", "sign_in", "Mac", "Saint Paul, Minnesota"), "the footer's iPhone isn't the device")
        self.assertEqual(self.due("2026-11-27T09:20"), [], "the ones that come together go together")
        (card,) = self.due("2026-11-27T09:30")
        self.assertEqual(card["title"], "Was this you? Google sign-in")
        self.assertEqual(card["why"], "Google sign-in on Mac near Saint Paul, Minnesota at 9:14 AM")
        self.assertIn(f"(id {made}.1)", card["request"])
        self.assertIn("redde_mail was_me", card["request"])
        self.assertLessEqual(len(card["request"]), 300, "the phone keeps 300 characters")
        self.assertEqual(card["level"], "now", "a security notice asks to be heard (1.57.0)")
        self.assertEqual(self.due("2026-11-27T11:00"), [], "once")

    def test_notices_that_come_together_are_one_card_in_the_wider_day(self):
        self.google()
        for n, (sender, name, subject) in enumerate([("verify@x.com", "X", "New login to X from Chrome on Mac"),
                                                     ("noreply@messaging.squareup.com", "Square", "New sign-in to your Square account")], 2):
            watch.from_security(self.data, came(sender, subject, MORNING + 60 * n, name=name, mid=f"a:INBOX:{n}"),
                                "We noticed a new sign-in from Chrome on a Mac.", MORNING + 60 * n)
        self.assertEqual(len([i for i in self.data["items"].values() if i["kind"] == "security"]), 1)
        follow.from_sent(self.data, {"to": ["p@example.com"], "subject": "S", "date": MORNING, "_text": "Could you send it?"},
                         ME, MORNING)
        self.data["offered"] = [at("2026-11-27T19:40")]
        cards = self.due("2026-11-27T20:00")
        self.assertEqual([c["title"] for c in cards], ["Was this you? 3 security notices"],
                         "past 7 pm and within the hour: a security card still goes, the question waits")
        self.assertEqual(cards[0]["why"], "Google, X and Square, first at 9:14 AM")
        self.assertIn("2) X sign-in on Chrome on Mac", cards[0]["request"])
        self.assertLessEqual(len(cards[0]["request"]), 300)

    def test_that_was_me_keeps_that_device_quiet(self):
        (made,) = self.google()
        follow.save(self.home, self.data)
        said = watch.was_me(self.home, [f"{made}.1"])
        self.assertEqual(said["quiet"], ["Google on Mac"])
        self.data = follow.load(self.home)
        self.assertEqual(self.data["items"][made]["state"], "done")
        self.assertEqual(self.google(mid="a:INBOX:5", when=MORNING + 86400), [], "the same Mac again")
        windows = GOOGLE.replace("a Mac device", "a Windows device")
        self.assertEqual(len(self.google(mid="a:INBOX:6", when=MORNING + 86400, text=windows)), 1, "a Windows PC is asked about")
        self.assertEqual(watch.was_me(self.home, ["nothing.1"])["found"], 0)

    def test_through_the_mail_tool(self):
        (made,) = self.google()
        follow.save(self.home, self.data)
        inbox = plugin.mail.Inbox(self.home, imap_connect=None, smtp_connect=None, sort=lambda **_: "[]")
        said = json.loads(plugin.mail.handle(inbox, {"action": "was_me", "ids": [f"{made}.1"]}))
        self.assertEqual(said["found"], 1)

    def test_codes_newsletters_and_people_are_not_notices(self):
        for subject in ("Your Google verification code", "Reset your password", "Security tips for the holidays"):
            self.assertEqual(watch.from_security(self.data, came("no-reply@accounts.google.com", subject), "A new sign-in.", MORNING), [])
        promo = came("news@shop.com", "New sign-in perks", bucket="promotions")
        self.assertEqual(watch.from_security(self.data, promo, "new sign-in", MORNING), [])
        self.data["people"] = {"ana@example.com": {"name": "Ana", "way": "out", "date": MORNING - 86400}}
        self.assertEqual(watch.from_security(self.data, came("ana@example.com", "Was this you in the photo?"), "", MORNING), [])
        old = came("no-reply@accounts.google.com", "Security alert", MORNING - 5 * 86400)
        self.assertEqual(watch.from_security(self.data, old, GOOGLE, MORNING), [], "a first look's old mail isn't news")

    def test_a_bank_profile_change_from_its_text(self):
        message = came("alerts@bank.example", "Zelle® profile update", name="Big Bank")
        (made,) = watch.from_security(self.data, message, "The phone number ending 1234 was removed from your Zelle profile "
                                                          "today. If you sign in to review it, use our app.", MORNING)
        notice = self.data["items"][made]["notices"][0]
        self.assertEqual((notice["service"], notice["what"]), ("Big Bank", "contact"))
        (card,) = self.due("2026-11-27T10:00")
        self.assertEqual(card["title"], "Was this you? Big Bank account change")

    def test_switched_off(self):
        self.google()
        self.data["switches"]["security"] = False
        self.assertEqual(self.due("2026-11-27T10:00"), [])

    def test_listed_for_the_app(self):
        self.google()
        follow.save(self.home, self.data)
        (item,) = follow.listing(self.home)["items"]
        self.assertEqual((item["kind"], item["shop"], item["count"]), ("security", "Google", 1))
        self.assertIn("security", follow.listing(self.home)["switches"])


GMAIL_BOUNCE = ("Address not found\nYour message wasn't delivered to bids@acme-cleaning.example because the address couldn't "
                "be found, or is unable to receive mail.\nThe response from the remote server was:\n550 5.1.1 The email "
                "account that you tried to reach does not exist.")


class BounceTests(Base):
    def bounce(self, text=GMAIL_BOUNCE, subject="Delivery Status Notification (Failure)", mid="a:INBOX:3", when=MORNING):
        return watch.from_bounce(self.data, came("mailer-daemon@googlemail.com", subject, when, name="Mail Delivery Subsystem",
                                                 mid=mid), text, ME, when)

    def wrote(self, subject="RFP for the office cleaning"):
        follow.from_sent(self.data, {"to": ["bids@acme-cleaning.example"], "to_names": {"bids@acme-cleaning.example": "Acme Bids"},
                                     "subject": subject, "date": MORNING - 120, "_text": "Please find the RFP attached."},
                         ME, MORNING - 120)

    def test_a_bounce_comes_back_two_hours_on(self):
        self.wrote()
        (made,) = self.bounce()
        item = self.data["items"][made]
        self.assertEqual((item["who"], item["reason"]), ("bids@acme-cleaning.example", "no_address"))
        self.assertEqual(self.due("2026-11-27T10:30"), [])
        (card,) = self.due("2026-11-27T11:20")
        self.assertEqual(card["title"], "Your email to Bids bounced")
        self.assertEqual(card["why"], "\"RFP for the office cleaning\": the address doesn't exist")
        self.assertIn("Find their right address", card["request"])
        self.assertLessEqual(len(card["request"]), 300)

    def test_sent_again_settles_it(self):
        self.wrote()
        self.bounce()
        follow.from_sent(self.data, {"to": ["office@acme-cleaning.example"], "subject": "Re: RFP for the office cleaning",
                                     "date": MORNING + 1800, "_text": "Resending."}, ME, MORNING + 1800)
        self.assertEqual(self.due("2026-11-27T12:00"), [])

    def test_outlook_and_postfix_and_a_full_mailbox(self):
        outlook = ("Your message to ana@example.org couldn't be delivered.\nana wasn't found at example.org.")
        made = watch.from_bounce(self.data, came("postmaster@example.org", "Undeliverable: Lease renewal", mid="a:INBOX:4"),
                                 outlook, ME, MORNING)
        self.assertEqual((self.data["items"][made[0]]["who"], self.data["items"][made[0]]["subject"]),
                         ("ana@example.org", "Lease renewal"))
        postfix = ("This is the mail system at host mx.example.net.\n\n<bo@example.net>: host mx said: 552 5.2.2 Mailbox full"
                   "\n\nSubject: Dates for the trip")
        made = watch.from_bounce(self.data, came("MAILER-DAEMON@mx.example.net", "Undelivered Mail Returned to Sender",
                                                 mid="a:INBOX:5"), postfix, ME, MORNING)
        item = self.data["items"][made[0]]
        self.assertEqual((item["who"], item["subject"], item["reason"]), ("bo@example.net", "Dates for the trip", "full"))

    def test_a_delay_or_spam_in_their_name_is_not_one(self):
        self.assertEqual(self.bounce(subject="Delivery Status Notification (Delay)"), [])
        self.bounce()
        self.assertEqual(self.due("2026-11-27T12:00"), [], "never written to: backscatter")


class FollowUpTests(Base):
    def test_someone_following_up_with_a_draft_waiting(self):
        follow.from_inbox(self.data, came("dana@acme.example", "Bid for the two offices", MORNING - 3 * 86400, name="Dana Ruiz",
                                          bucket="needs_reply", mid="a:INBOX:7"), MORNING - 3 * 86400)
        before = dict(self.data["people"]["dana@acme.example"])
        message = came("dana@acme.example", "Re: Bid for the two offices", name="Dana Ruiz", mid="a:INBOX:8")
        follow.from_inbox(self.data, message, MORNING)
        (made,) = watch.from_followup(self.data, message, "Hi, just following up to see where things stand.\n\nOn Mon, "
                                      "Dana wrote:\n> the bid", before, MORNING, lambda who: "mailbox")
        kinds = sorted((i["kind"], i["state"]) for i in self.data["items"].values())
        self.assertEqual(kinds, [("followup", "open"), ("owed", "done")], "it takes the reply owed's place")
        (card,) = self.due("2026-11-27T10:00", mailbox=lambda: {"a:INBOX:8"})
        self.assertEqual(card["title"], "Dana is following up")
        self.assertEqual(card["why"], "On \"Bid for the two offices\": your draft to them hasn't gone")
        self.assertIn("I have a draft to them in my Drafts", card["request"])

    def test_a_reply_settles_it_and_their_answer_is_not_a_nudge(self):
        message = came("dana@acme.example", "Any update on the bid?", name="Dana Ruiz", mid="a:INBOX:8")
        watch.from_followup(self.data, message, "Any update?", None, MORNING)
        follow.from_sent(self.data, {"to": ["dana@acme.example"], "subject": "Re: Any update on the bid?",
                                     "date": MORNING + 600, "_text": "Yes: Friday."}, ME, MORNING + 600)
        self.assertEqual(self.due("2026-11-27T11:00"), [])
        they_wrote_last = {"name": "Bo", "way": "out", "date": MORNING - 3600}
        self.assertEqual(watch.from_followup(self.data, came("bo@example.com", "Re: Dates", mid="a:INBOX:9"),
                                             "Following up on your question: the 4th.", they_wrote_last, MORNING), [])
        self.assertEqual(watch.from_followup(self.data, came("news@shop.com", "Just checking in!", mid="a:INBOX:10",
                                                             bulk=True), "Any news?", None, MORNING), [])


class ThroughTheInboxTests(unittest.TestCase):
    """A look at the inbox: a bounce of what they sent, a follow-up with a draft in Drafts."""
    def setUp(self):
        import os
        from unittest import mock
        from test_mail import FakeImap, FakeServer, FakeSmtp
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        (self.root / ".env").write_text("REDDE_MAIL_ADDRESS=alex@example.com\nREDDE_MAIL_PASSWORD='app-pass'\nREDDE_MAIL_PROVIDER=fastmail\n")
        self.server = FakeServer()
        self.server.folders["Drafts"] = {}
        plugin.mail._usable_cache.clear()
        self.env = mock.patch.dict(os.environ, {k: v for k, v in os.environ.items() if not k.startswith("REDDE_MAIL_")}, clear=True)
        self.env.start()
        self.inbox = plugin.mail.Inbox(self.root, imap_connect=lambda a: FakeImap(self.server),
                                       smtp_connect=lambda a: FakeSmtp(self.server), sort=lambda **_: "[]")

    def tearDown(self):
        self.env.stop()
        self.dir.cleanup()

    def put(self, folder, uid, sender, to, subject, body, when="Fri, 27 Nov 2026 09:%02d:00 -0500"):
        from email.message import EmailMessage
        msg = EmailMessage()
        msg["From"], msg["To"], msg["Subject"], msg["Date"] = sender, to, subject, when % uid
        msg["Message-ID"] = f"<{folder}{uid}@example.com>"
        msg.set_content(body)
        self.server.folders[folder][uid] = [msg.as_bytes(), set()]

    def test_a_bounce_and_a_follow_up(self):
        self.put("Sent", 1, "Alex <alex@example.com>", "Bids <bids@acme.example>", "RFP", "Please find the RFP attached.",
                 when="Fri, 27 Nov 2026 08:%02d:00 -0500")
        self.put("INBOX", 1, "Mail Delivery Subsystem <mailer-daemon@example.com>", "alex@example.com",
                 "Delivery Status Notification (Failure)", GMAIL_BOUNCE.replace("bids@acme-cleaning.example", "bids@acme.example"))
        self.put("INBOX", 2, "Dana Ruiz <dana@acme.example>", "alex@example.com", "Re: Bid", "Just following up on the bid.")
        self.put("Drafts", 1, "Alex <alex@example.com>", "Dana Ruiz <dana@acme.example>", "Re: Bid", "Thanks Dana, ")
        account = self.inbox.accounts()[0]
        now = datetime.fromisoformat("2026-11-27T09:30:00-05:00").timestamp()
        self.inbox.sync(account, now=now)
        items = {i["kind"]: i for i in follow.load(self.root)["items"].values()}
        self.assertEqual(items["bounce"]["who"], "bids@acme.example")
        self.assertEqual(items["followup"]["draft"], "mailbox")


if __name__ == "__main__":
    unittest.main()

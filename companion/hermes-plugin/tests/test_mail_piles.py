"""More piles (`mail.py`, 1.31.0, asked 2026-11-14: "more categories as the 4 we have do not catch
everything"): receipts, notifications and promotions of their own, the person's own piles sorted
by the model, older apps shown the four they know, and rules that put mail in a pile."""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_mail import FakeImap, FakeServer, FakeSmtp, mail


class PileTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        (self.root / ".env").write_text("REDDE_MAIL_ADDRESS=alex@example.com\nREDDE_MAIL_PASSWORD='app-pass'\nREDDE_MAIL_PROVIDER=fastmail\n")
        self.server = FakeServer()
        self.prompts = []
        self.answer = {}
        mail._usable_cache.clear()
        self.env = mock.patch.dict(os.environ, {k: v for k, v in os.environ.items() if not k.startswith("REDDE_MAIL_")}, clear=True)
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.dir.cleanup()

    def sort(self, task=None, messages=None, **_):
        self.prompts.append(messages[0]["content"])
        rows = []
        for line in messages[1]["content"].splitlines():
            row = json.loads(line)
            rows.append({"id": row["id"], "bucket": self.answer.get(row["subject"], "fyi"), "summary": "s"})
        return json.dumps(rows)

    def inbox(self):
        return mail.Inbox(self.root, imap_connect=lambda a: FakeImap(self.server), smtp_connect=lambda a: FakeSmtp(self.server),
                          sort=self.sort, notify=lambda *a: None)

    def test_the_headers_sort_into_the_new_piles(self):
        cases = [({"subject": "Your order #4 has shipped", "address": "shop@x.com"}, ("receipts", True)),
                 ({"subject": "Your verification code", "address": "noreply@bank.com"}, ("notifications", False)),
                 ({"subject": "Ana mentioned you", "address": "hi@social.com", "bulk": True}, ("notifications", False)),
                 ({"subject": "New activity", "address": "notifications@github.com", "bulk": True}, ("notifications", False)),
                 ({"subject": "30% off everything", "address": "hi@shop.com", "bulk": True}, ("promotions", False)),
                 ({"subject": "Weekend reads", "address": "hi@paper.com", "bulk": True}, ("newsletters", False)),
                 ({"subject": "Hello", "address": "x@y.com", "labels": ["CATEGORY_PROMOTIONS"]}, ("promotions", False)),
                 ({"subject": "Hello", "address": "x@y.com", "labels": ["CATEGORY_SOCIAL"]}, ("notifications", False)),
                 ({"subject": "Your statement is ready", "address": "updates@bank.com"}, ("notifications", False)),
                 ({"subject": "Lunch?", "address": "ana@example.com"}, (None, False))]
        for meta, want in cases:
            self.assertEqual(mail.rule_bucket(meta), want, meta["subject"])

    def test_an_older_app_sees_its_four(self):
        self.server.add(1, sender="Shop <orders@shop.com>", subject="Your order #123 receipt")
        self.server.add(2, sender="Bank <security@bank.com>", subject="New sign-in to your account")
        box = self.inbox()
        box.sync(box.account())
        old = {r["subject"]: r["bucket"] for r in box.listing("all")["threads"]}
        self.assertEqual(old, {"Your order #123 receipt": "newsletters", "New sign-in to your account": "fyi"})
        self.assertEqual([r["subject"] for r in box.listing("newsletters")["threads"]], ["Your order #123 receipt"])
        new = {r["subject"]: r["bucket"] for r in box.listing("all", piles=True)["threads"]}
        self.assertEqual(new, {"Your order #123 receipt": "receipts", "New sign-in to your account": "notifications"})
        row = box.status()["accounts"][0]
        self.assertEqual((row["buckets"]["newsletters"], row["buckets"]["fyi"]), (1, 1))
        self.assertNotIn("receipts", row["buckets"])
        self.assertEqual((row["piles"]["receipts"], row["piles"]["notifications"]), (1, 1))
        self.assertEqual([p["id"] for p in box.status()["piles"]][:7], list(mail.BUCKETS))
        # The app's command: "piles" after the account asks for the new ones.
        self.assertIn("Your order #123 receipt", mail.slash(box, ["list", "receipts", "0", "main", "piles"]))
        self.assertIn('"threads":[]', mail.slash(box, ["list", "receipts", "0", "main"]), "without asking, receipts are in newsletters")

    def test_own_piles_are_kept_named_and_sorted_into(self):
        box = self.inbox()
        said = box.set_piles([{"name": "School", "about": "the kids' school, teachers and class news"}, {"name": "Travel"}])
        own = [p for p in said["piles"] if p["own"]]
        self.assertEqual([(p["id"], p["name"]) for p in own], [("p-school", "School"), ("p-travel", "Travel")])
        with self.assertRaises(mail.MailError):
            box.set_piles([{"name": "Receipts"}])
        with self.assertRaises(mail.MailError):
            box.set_piles([{"name": "a/b"}])
        # Renamed, it keeps its id (and its mail).
        box.set_piles([{"id": "p-school", "name": "Kids' School", "about": "school"}])
        self.assertEqual(box.state.piles(), [{"id": "p-school", "name": "Kids' School", "about": "school"}])

        self.server.add(1, subject="Field trip on Friday", sender="Ms. Park <park@school.org>")
        self.server.add(2, subject="PTA newsletter", sender="PTA <news@school.org>", headers={"List-Unsubscribe": "<https://school.org/u>"})
        self.server.add(3, subject="Your order #9 has shipped", sender="Shop <orders@shop.com>")
        self.answer = {"Field trip on Friday": "p-school", "PTA newsletter": "p-school", "Your order #9 has shipped": "p-school"}
        box.sync(box.account())
        rows = {r["subject"]: r["bucket"] for r in box.listing("all", piles=True)["threads"]}
        self.assertEqual(rows["Field trip on Friday"], "p-school")
        self.assertEqual(rows["PTA newsletter"], "p-school", "mail sorted by its headers can still go to their own pile")
        self.assertEqual(rows["Your order #9 has shipped"], "receipts", "receipts stay receipts")
        self.assertIn("p-school: the person's own pile \"Kids' School\", school", self.prompts[0])
        self.assertEqual({r["bucket"] for r in box.listing("fyi")["threads"]}, {"fyi"}, "an older app sees their piles as FYI")

        # A pile taken away: its mail is sorted again.
        box.set_piles([])
        rows = {r["subject"]: r["bucket"] for r in box.listing("all", piles=True)["threads"]}
        self.assertEqual(rows["PTA newsletter"], "newsletters")
        self.assertEqual(rows["Field trip on Friday"], "unsorted")

    def test_a_rule_puts_mail_in_a_pile(self):
        box = self.inbox()
        box.set_piles([{"name": "Travel", "about": "trips"}])
        with self.assertRaises(mail.MailError):
            mail.set_rules(box.state, [{"when": {"from": "airline.com"}, "do": "group", "arg": "p-nope"}])
        mail.set_rules(box.state, [{"when": {"from": "airline.com"}, "do": "group", "arg": "p-travel"}])
        self.server.add(1, subject="Your flight tomorrow", sender="Air <hello@airline.com>")
        box.sync(box.account())
        row = box.listing("all", piles=True)["threads"][0]
        self.assertEqual(row["bucket"], "p-travel")
        self.assertEqual(box.state.account("main")["messages"][row["id"]]["grouped"], "rule")

    def test_kept_mail_is_sorted_again_once(self):
        box = self.inbox()
        kept = {"messages": {
            "main:INBOX:1": {"id": "main:INBOX:1", "bucket": "newsletters", "receipt": True, "subject": "Invoice", "address": "a@b.com"},
            "main:INBOX:2": {"id": "main:INBOX:2", "bucket": "fyi", "subject": "Your one-time code", "address": "no-reply@bank.com"},
            "main:INBOX:3": {"id": "main:INBOX:3", "bucket": "newsletters", "subject": "Big sale", "address": "a@shop.com",
                             "bulk": True, "grouped": "you"},
            "main:INBOX:4": {"id": "main:INBOX:4", "bucket": "fyi", "subject": "Notes from Ana", "address": "ana@x.com"}}}
        mail.Inbox.repile(kept)
        got = {k: m["bucket"] for k, m in kept["messages"].items()}
        self.assertEqual(got, {"main:INBOX:1": "receipts", "main:INBOX:2": "notifications", "main:INBOX:3": "newsletters",
                               "main:INBOX:4": "fyi"})
        kept["messages"]["main:INBOX:2"]["bucket"] = "fyi"
        mail.Inbox.repile(kept)
        self.assertEqual(kept["messages"]["main:INBOX:2"]["bucket"], "fyi", "only once")

    def test_the_agent_groups_and_makes_piles(self):
        box = self.inbox()
        said = json.loads(mail.handle(box, {"action": "piles", "piles": [{"name": "Health", "about": "doctors"}]}))
        self.assertIn("p-health", [p["id"] for p in said["piles"]])
        self.server.add(1)
        box.sync(box.account())
        mid = box.listing("all")["threads"][0]["id"]
        said = json.loads(mail.handle(box, {"action": "group", "ids": [mid], "bucket": "p-health"}))
        self.assertEqual(said["done"], [mid])
        listed = json.loads(mail.handle(box, {"action": "list", "bucket": "p-health"}))
        self.assertEqual(len(listed["threads"]), 1)


if __name__ == "__main__":
    unittest.main()

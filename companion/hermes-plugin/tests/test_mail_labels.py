"""Sorting shown in Gmail and tagging rules (`mail.py`, 1.16.0, asked 2026-11-03): Redde/… labels,
the Paperless rule, custom rules, backfill and undo. Gmail is a stand-in (IMAP with X-GM-LABELS, and
the Gmail API): no network."""
import json
import re
import time
import os
import tempfile
import unittest
import unittest.mock
from email.message import EmailMessage
from pathlib import Path

from test_mail import FakeImap, FakeServer, mail

ALL = "[Gmail]/All Mail"


def gmail_raw(uid, sender="Ana Ruiz <ana@example.com>", subject="Lunch Thursday?", body="Are you free for lunch on Thursday?",
              pdf=False, image=False, cc=None, date=None):
    msg = EmailMessage()
    msg["From"], msg["To"], msg["Subject"] = sender, "sam@example.com", subject
    if cc:
        msg["Cc"] = cc
    msg["Date"] = date or time.strftime("%a, %d %b %Y %H:%M:%S -0000", time.gmtime(time.time() - 3600))
    msg["Message-ID"] = f"<g{uid}@example.com>"
    msg.set_content(body)
    if pdf:
        msg.add_attachment(b"%PDF-1.4", maintype="application", subtype="pdf", filename="receipt.pdf")
    if image:
        msg.add_attachment(b"\x89PNG", maintype="image", subtype="png", filename="photo.png")
    return msg.as_bytes()


class GmailImap(FakeImap):
    """Gmail over IMAP: one message in INBOX and All Mail at once (the same entry), labels on it."""

    def list(self):
        out = []
        for name in self.server.folders:
            flags = {ALL: "\\HasNoChildren \\All", "[Gmail]/Trash": "\\HasNoChildren \\Trash"}.get(name, "\\HasNoChildren")
            out.append(f'({flags}) "/" "{name}"'.encode())
        return "OK", out

    def uid(self, command, *args):
        box = self.server.folders[self.folder]
        command = command.upper()
        if command == "SEARCH" and args[-1].startswith("X-GM-LABELS"):
            want = args[-1].split(" ", 1)[1].strip('"')
            return "OK", [" ".join(str(u) for u, e in sorted(box.items()) if want in e[2]).encode()]
        if command == "SEARCH" and args[-1].startswith("SINCE"):
            return "OK", [" ".join(map(str, sorted(box))).encode()]
        if command == "STORE" and "X-GM-LABELS" in args[1]:
            names = re.findall(r'"((?:[^"\\]|\\.)*)"', args[2])
            for u in self._set(args[0]):
                if args[1].startswith("+"):
                    box[u][2].update(names)
                else:
                    box[u][2].difference_update(names)
            self.server.stores.append((self.folder, args[1], tuple(names), tuple(self._set(args[0]))))
            return "OK", []
        if command == "SEARCH" and args[-1].startswith("HEADER Message-ID"):
            want = args[-1].split(" ", 2)[2].strip('"').encode()
            return "OK", [" ".join(str(u) for u, e in sorted(box.items()) if want in e[0]).encode()]
        if command == "FETCH" and args[1] == "(UID FLAGS)":
            return "OK", [f"{u} (UID {u} FLAGS ({' '.join(sorted(box[u][1]))}))".encode() for u in self._set(args[0])]
        if command == "FETCH" and "HEADER.FIELDS (MESSAGE-ID)" in args[1]:
            out = []
            for u in self._set(args[0]):
                mid = re.search(rb"Message-ID: (<[^>]+>)", box[u][0]).group(1)
                out.append(((f"{u} (UID {u} BODY[HEADER.FIELDS (MESSAGE-ID)] {{40}}").encode(), b"Message-ID: " + mid + b"\r\n\r\n"))
                out.append(b")")
            return "OK", out
        if command == "FETCH" and "X-GM-LABELS" in args[1]:
            out = []
            for u in self._set(args[0]):
                message, flags, labels = box[u][0], box[u][1], box[u][2]
                kinds = ""
                if b"application/pdf" in message:
                    kinds += ' ("application" "pdf" ("name" "receipt.pdf") NIL NIL "base64" 8)'
                if b"image/png" in message:
                    kinds += ' ("image" "png" ("name" "photo.png") NIL NIL "base64" 4)'
                head = (f"{u} (UID {u} FLAGS ({' '.join(sorted(flags))}) X-GM-LABELS ({' '.join(chr(34) + l + chr(34) for l in sorted(labels))})"
                        f" BODYSTRUCTURE (({kinds}) \"mixed\")")
                header, _, body = message.partition(b"\n\n")
                out.append(((head + " BODY[HEADER.FIELDS (FROM)] {%d}" % len(header)).encode(), header + b"\r\n\r\n"))
                out.append((b" BODY[TEXT]<0> {%d}" % len(body[:1500]), body[:1500]))
                out.append(b")")
            return "OK", out
        if command == "MOVE" and self.folder == "INBOX":          # archiving: out of INBOX, still in All Mail
            for u in self._set(args[0]):
                del box[u]
            return "OK", []
        if command == "MOVE" and args[1].strip('"') == "INBOX":   # back to the inbox
            for u in self._set(args[0]):
                self.server.folders["INBOX"][u] = box[u]
            return "OK", []
        return super().uid(command, *args)


class GmailServer(FakeServer):
    def __init__(self):
        super().__init__(capabilities=("IMAP4REV1", "MOVE", "UIDPLUS", "X-GM-EXT-1"))
        self.folders = {"INBOX": {}, ALL: {}, "[Gmail]/Trash": {}, "Sent": {}}
        self.stores = []

    def add(self, uid, labels=(), inbox=True, **kw):
        entry = [gmail_raw(uid, **kw), set(), set(labels)]
        self.folders[ALL][uid] = entry
        if inbox:
            self.folders["INBOX"][uid] = entry

    def labels(self, uid):
        return self.folders[ALL][uid][2]


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.notes = []
        mail._usable_cache.clear()
        self.env = unittest.mock.patch.dict(os.environ, {k: v for k, v in os.environ.items() if not k.startswith("REDDE_MAIL_")}, clear=True)
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.dir.cleanup()

    def sort(self, task=None, messages=None, **_):
        rows = [{"id": json.loads(line)["id"], "bucket": "needs_reply", "summary": "asks"} for line in messages[1]["content"].splitlines()]
        return json.dumps(rows)


class GmailLabelTests(Base):
    def setUp(self):
        super().setUp()
        (self.root / ".env").write_text("OTHER=1\nREDDE_MAIL_ADDRESS=alex@example.com\nREDDE_MAIL_PASSWORD='app-pass'\nREDDE_MAIL_PROVIDER=gmail\n")
        self.server = GmailServer()

    def inbox(self, sort=None):
        return mail.Inbox(self.root, imap_connect=lambda a: GmailImap(self.server), sort=sort or self.sort,
                          notify=lambda t, b, i: self.notes.append((t, b, i)))

    def rules(self, box, rules):
        return mail.set_rules(box.state, rules)

    # conditions
    def test_conditions_case_domain_attachments_any_and_age(self):
        meta = {"from": "Ana Ruiz", "address": "ana@mail.shop.example.com", "subject": "Your ORDER #12", "to": ["sam@example.com"],
                "cc": ["lea@example.com"], "attachment_kinds": ["pdf"], "has_attachments": True, "date": time.time(), "account": "main",
                "bucket": "newsletters", "receipt": True, "snippet": ""}
        m = mail.Inbox.matches
        self.assertTrue(m({"when": {"domain": "shop.example.com"}}, meta))
        self.assertTrue(m({"when": {"domain": "@example.com"}}, meta))
        self.assertFalse(m({"when": {"domain": "ample.com"}}, meta), "a domain is whole labels, not any ending")
        self.assertTrue(m({"when": {"from": "ANA@MAIL"}}, meta))
        self.assertTrue(m({"when": {"subject": "your order"}}, meta))
        self.assertTrue(m({"when": {"cc": "lea@"}}, meta))
        self.assertTrue(m({"when": {"attachment": "pdf"}}, meta))
        self.assertFalse(m({"when": {"attachment": "image"}}, meta))
        self.assertTrue(m({"when": {"body": "total due"}}, meta, "Thanks. Total due: $12"))
        self.assertFalse(m({"when": {"subject": "invoice", "from": "ana"}}, meta))
        self.assertTrue(m({"match": "any", "when": {"subject": "invoice", "from": "ana"}}, meta))
        self.assertFalse(m({"enabled": False, "when": {"from": "ana"}}, meta))
        self.assertFalse(m({"account": "work", "when": {"from": "ana"}}, meta))
        old = dict(meta, date=time.time() - 40 * 86400)
        self.assertFalse(m({"when": {"from": "ana"}}, old), "older than 30 days is passed over by default")
        self.assertTrue(m({"when": {"from": "ana", "newer_than_days": 0}}, old))

    def test_rules_validation_for_tagging(self):
        box = self.inbox()
        saved = self.rules(box, [{"when": {"domain": "shop.example.com", "attachment": "pdf"}, "do": "label", "arg": " Paperless ",
                                  "archive": True, "match": "any", "account": "main", "name": "Shop receipts"}])
        self.assertEqual(saved[0]["arg"], "Paperless")
        self.assertTrue(saved[0]["archive"])
        self.assertEqual(saved[0]["match"], "any")
        with self.assertRaises(mail.MailError):
            self.rules(box, [{"when": {"attachment": "zip"}, "do": "label", "arg": "X"}])
        with self.assertRaises(mail.MailError):
            self.rules(box, [{"when": {"from": "a"}, "do": "label", "arg": 'bad"name'}])
        archive_rule = self.rules(box, [{"when": {"from": "a"}, "do": "archive", "archive": True}])[0]
        self.assertFalse(archive_rule["archive"], "'also archive' only means something on a tagging rule")

    def test_the_paperless_rule_is_offered_first_and_off(self):
        box = self.inbox()
        rules = box.rules_with_counts()
        self.assertEqual(rules[0]["id"], "paperless")
        self.assertFalse(rules[0]["enabled"])
        self.assertEqual(rules[0]["arg"], "Paperless")

    # group labels
    def test_show_sorting_labels_each_group_and_regroups(self):
        self.server.add(1, sender="Shop <orders@shop.example.com>", subject="Your order #12 has shipped")
        self.server.add(2)
        box = self.inbox()
        box.sync(box.account())
        self.assertEqual(self.server.stores, [], "off until turned on: nothing labelled")
        box.state.save_settings({"labels": {"main": {"groups": True}}})
        box.sync(box.account())
        self.assertIn("Redde/Newsletters", self.server.labels(1))
        self.assertIn("Redde/Needs Reply", self.server.labels(2))
        kept = box.state.account("main")
        m2 = kept["messages"]["main:INBOX:2"]
        m2["bucket"] = "fyi"
        box.state.save_account("main", kept)
        box.sync(box.account())
        self.assertEqual(self.server.labels(2), {"Redde/FYI"}, "a message moved between groups loses the old label")

    def test_turning_off_takes_off_only_reddes_labels(self):
        self.server.add(1, labels={"Family"})
        self.server.add(2, labels={"Redde/Needs Reply"})        # the person had put it there
        box = self.inbox()
        box.state.save_settings({"labels": {"main": {"groups": True}}})
        box.sync(box.account())
        self.assertIn("Redde/Needs Reply", self.server.labels(1))
        box.state.save_settings({"labels": {"main": {"groups": False}}})
        box.label_job("main", "remove", "all")
        self.assertTrue(box.label_jobs(box.account()))
        self.assertEqual(self.server.labels(1), {"Family"})
        self.assertEqual(self.server.labels(2), {"Redde/Needs Reply"}, "never takes off a label the person put on")

    # tagging rules
    def test_paperless_rule_tags_receipts_with_attachments_only(self):
        self.server.add(1, sender="Shop <orders@shop.example.com>", subject="Your receipt", pdf=True)
        self.server.add(2, sender="Shop <orders@shop.example.com>", subject="Your receipt")
        box = self.inbox()
        rule = dict(mail.PAPERLESS_RULE, enabled=True)
        self.rules(box, [rule])
        box.sync(box.account())
        self.assertIn("Paperless", self.server.labels(1))
        self.assertNotIn("Paperless", self.server.labels(2), "the ready-made rule wants an attachment")
        self.assertIn(1, self.server.folders["INBOX"], "tagging never archives unless the rule says so")
        entry = box.state.log()[0]
        self.assertEqual(entry["action"], "tag")
        self.assertEqual(box.rules_with_counts()[0]["matches"], 1)

    def test_a_rule_can_also_archive_and_undo_puts_both_back(self):
        self.server.add(1, sender="News <news@paper.example.com>", subject="Morning edition")
        box = self.inbox()
        self.rules(box, [{"id": "r1", "when": {"domain": "paper.example.com"}, "do": "label", "arg": "Reading", "archive": True}])
        box.sync(box.account())
        self.assertIn("Reading", self.server.labels(1))
        self.assertNotIn(1, self.server.folders["INBOX"])
        entry = next(e for e in box.state.log() if e["action"] == "tag")
        box.act("undo", [entry["id"]])
        self.assertNotIn("Reading", self.server.labels(1))
        self.assertIn(1, self.server.folders["INBOX"])

    def test_undo_leaves_a_label_the_message_already_had(self):
        self.server.add(1, sender="Shop <orders@shop.example.com>", subject="Your receipt", pdf=True, labels={"Paperless"})
        box = self.inbox()
        self.rules(box, [dict(mail.PAPERLESS_RULE, enabled=True)])
        box.sync(box.account())
        entry = next(e for e in box.state.log() if e["action"] == "tag")
        box.act("undo", [entry["id"]])
        self.assertIn("Paperless", self.server.labels(1), "it was there before Redde: undo leaves it")

    def test_archive_and_notify_rules_still_run(self):
        self.server.add(1, sender="Ana <ana@example.com>", subject="Hi")
        box = self.inbox()
        self.rules(box, [{"when": {"from": "ana@"}, "do": "notify"}])
        box.sync(box.account())
        self.assertEqual(len(self.notes), 1)

    # backfill
    def test_backfill_is_bounded_and_steps(self):
        for uid in range(1, 6):
            self.server.add(uid, sender="Shop <orders@shop.example.com>", subject=f"Your receipt {uid}", pdf=True, inbox=False)
        box = self.inbox()
        self.rules(box, [dict(mail.PAPERLESS_RULE, enabled=True)])
        with unittest.mock.patch.object(mail, "BACKFILL_CHUNK", 2), unittest.mock.patch.object(mail, "BACKFILL_MAX", 4):
            box.label_job("main", "backfill")
            steps = 0
            while (box.state.account("main").get("labels_backfill") or {}).get("state") != "done" and steps < 10:
                box.label_jobs(box.account())
                steps += 1
        self.assertEqual(steps, 2)
        tagged = [u for u in range(1, 6) if "Paperless" in self.server.labels(u)]
        self.assertEqual(len(tagged), 4, "at most BACKFILL_MAX")
        self.assertEqual(box.state.account("main")["labels_backfill"]["total"], 4)

    def test_status_says_who_can_label(self):
        box = self.inbox()
        row = box.status()["accounts"][0]
        self.assertTrue(row["can_label"])
        self.assertEqual(row["labels"], {"groups": False, "suggest": False})


class SuggestionTests(Base):
    """Suggested rules: patterns found with no model, kept apart, never run until accepted."""

    def setUp(self):
        super().setUp()
        (self.root / ".env").write_text("REDDE_MAIL_ADDRESS=alex@example.com\nREDDE_MAIL_PASSWORD='app-pass'\nREDDE_MAIL_PROVIDER=gmail\n")
        self.server = GmailServer()
        self.box = mail.Inbox(self.root, imap_connect=lambda a: GmailImap(self.server), sort=self.sort,
                              notify=lambda t, b, i: self.notes.append((t, b, i)))
        self.now = time.time()

    def log(self, action, sender, n=1, by="you", **extra):
        for _ in range(n):
            mail.log_entry(self.box.state, by, action, "main", ["main:INBOX:1"], action, senders=[sender], extra=extra or None)

    def kept(self, messages):
        self.box.state.save_account("main", {"messages": {m["id"]: m for m in messages}})

    def found(self, can_label=True):
        return mail.find_suggestions(self.box.state.account("main"), self.box.state.log(), "main", can_label, self.now)

    def test_repeated_archives_and_deletes_by_sender(self):
        self.log("archive", "news@paper.example.com", 4)
        self.log("trash", "deals@shop.example.com", 3)
        self.log("archive", "once@example.com", 2)
        found = {f["rule"]["when"]["from"]: f for f in self.found()}
        self.assertEqual(found["news@paper.example.com"]["rule"]["do"], "archive")
        self.assertIn("archived 4 emails", found["news@paper.example.com"]["why"])
        self.assertEqual(found["deals@shop.example.com"]["rule"]["do"], "archive", "deleting suggests archiving: rules never delete")
        self.assertNotIn("once@example.com", found)

    def test_repeated_labels_suggest_the_same_label(self):
        self.log("label", "bills@power.example.com", 3, label="Bills")
        f = self.found()[0]
        self.assertEqual((f["rule"]["do"], f["rule"]["arg"]), ("label", "Bills"))
        self.assertEqual(self.found(can_label=False), [], "no label suggestions where there are no labels")

    def test_unread_newsletters_receipts_pdfs_and_replies(self):
        old = self.now - 20 * 86400
        ms = [{"id": f"main:INBOX:{i}", "address": "weekly@news.example.com", "bucket": "newsletters", "unread": True, "date": old} for i in range(3)]
        ms += [{"id": f"main:INBOX:r{i}", "address": "orders@shop.example.com", "receipt": True, "date": self.now} for i in range(3)]
        ms += [{"id": f"main:INBOX:p{i}", "address": "hr@work.example.com", "attachment_kinds": ["pdf"], "date": self.now} for i in range(3)]
        self.kept(ms)
        self.log("send", "ana@example.com", 3)
        kinds = {f["kind"]: f for f in self.found()}
        self.assertEqual(kinds["unread"]["rule"], {"when": {"from": "weekly@news.example.com", "bucket": "newsletters"}, "do": "archive", "account": "main"})
        self.assertEqual(kinds["receipts"]["rule"]["arg"], "Receipts")
        self.assertEqual(kinds["attachments"]["rule"]["when"]["attachment"], "pdf")
        self.assertEqual(kinds["replies"]["rule"]["do"], "notify")

    def test_nothing_happens_because_of_a_suggestion(self):
        self.box.state.save_settings({"labels": {"main": {"suggest": True}}})
        self.log("archive", "news@paper.example.com", 4)
        fresh = self.box.refresh_suggestions(self.box.account(), self.now)
        self.assertEqual(len(fresh), 1)
        self.assertEqual(self.box.state.rules(), [], "suggestions are kept apart from the rules")
        self.server.add(9, sender="Paper <news@paper.example.com>", subject="Today")
        self.box.sync(self.box.account())
        self.assertIn(9, self.server.folders["INBOX"], "not archived: the suggestion isn't a rule")
        self.assertEqual(self.server.stores, [], "nothing labelled either")
        self.assertFalse(any(e.get("by") == "rule" for e in self.box.state.log()))

    def test_accept_makes_a_rule_and_dismiss_is_remembered(self):
        self.box.state.save_settings({"labels": {"main": {"suggest": True}}})
        self.log("archive", "news@paper.example.com", 4)
        self.log("archive", "deals@shop.example.com", 3)
        opened = self.box.refresh_suggestions(self.box.account(), self.now)
        a, b = opened[0], opened[1]
        made = self.box.accept_suggestion("main", a["id"])["rule"]
        self.assertEqual(made["do"], "archive")
        self.assertEqual(self.box.state.rules()[0]["when"]["from"], a["rule"]["when"]["from"])
        self.box.dismiss_suggestion("main", b["id"])
        again = self.box.refresh_suggestions(self.box.account(), self.now + 2 * 86400)
        self.assertEqual(again, [], "a dismissed or accepted pattern isn't suggested again")
        self.server.add(9, sender=f"Paper <{a['rule']['when']['from']}>", subject="Today")
        self.box.sync(self.box.account())
        self.assertNotIn(9, self.server.folders["INBOX"], "once accepted, the rule runs")

    def test_accept_as_edited(self):
        self.box.state.save_settings({"labels": {"main": {"suggest": True}}})
        self.log("archive", "news@paper.example.com", 4)
        sug = self.box.refresh_suggestions(self.box.account(), self.now)[0]
        made = self.box.accept_suggestion("main", sug["id"], {"when": {"domain": "paper.example.com"}, "do": "label", "arg": "Reading"})["rule"]
        self.assertEqual((made["do"], made["arg"], made["when"]), ("label", "Reading", {"domain": "paper.example.com"}))

    def test_at_most_daily_and_five_open(self):
        self.box.state.save_settings({"labels": {"main": {"suggest": True}}})
        for i in range(7):
            self.log("archive", f"s{i}@example.com", 3)
        self.assertEqual(len(self.box.refresh_suggestions(self.box.account(), self.now)), 5)
        self.assertEqual(self.box.refresh_suggestions(self.box.account(), self.now + 3600), [], "not again within a day")
        self.assertEqual(len(self.box.state.suggestions("main")["open"]), 5)

    def test_off_means_none(self):
        self.log("archive", "news@paper.example.com", 4)
        self.assertEqual(self.box.refresh_suggestions(self.box.account(), self.now), [])

    def test_every_account_gets_suggestions_but_only_labels_where_gmail(self):
        (self.root / ".env").write_text("REDDE_MAIL_ADDRESS=sam@icloud.com\nREDDE_MAIL_PASSWORD='app-pass'\nREDDE_MAIL_PROVIDER=icloud\n")
        mail._usable_cache.clear()
        self.box.state.save_settings({"labels": {"main": {"suggest": True}}})
        self.log("archive", "news@paper.example.com", 4)
        self.log("label", "bills@power.example.com", 3, label="Bills")
        self.kept([{"id": f"main:INBOX:r{i}", "address": "orders@shop.example.com", "receipt": True, "date": self.now} for i in range(3)])
        self.log("send", "ana@example.com", 3)
        fresh = self.box.refresh_suggestions(self.box.account(), self.now)
        self.assertEqual(sorted(f["rule"]["do"] for f in fresh), ["archive", "notify"], "no label suggestions off Gmail")
        self.assertFalse(self.box.status()["accounts"][0]["can_label"])
        self.assertTrue(self.box.status()["accounts"][0]["suggest"])

    def test_commands(self):
        self.box.state.save_settings({"labels": {"main": {"suggest": True}}})
        self.log("archive", "news@paper.example.com", 4)
        said = mail.slash(self.box, ["suggest", "refresh", "main"])
        got = json.loads(said.split(" ", 2)[2])
        self.assertEqual(len(got["suggestions"]), 1)
        sid = got["suggestions"][0]["id"]
        said = mail.slash(self.box, ["suggest", "dismiss", "main", sid])
        self.assertEqual(json.loads(said.split(" ", 2)[2])["suggestions"], [])


class GmailApiLabelTests(Base):
    def test_gmail_api_labels_and_unlabels_by_id(self):
        (self.root / ".env").write_text("")
        (self.root / "google_token.json").write_text(json.dumps({"refresh_token": "r", "scopes": "https://www.googleapis.com/auth/gmail.modify"}))
        labels = {"g1": ["INBOX", "CATEGORY_PROMOTIONS"], "g2": ["INBOX", "Label_9"]}
        made = {"Family": "Label_9"}
        calls = []

        def fetch(method, url, body=None):
            calls.append((method, url, body))
            if url.startswith("messages?q=in:inbox"):
                return {"messages": [{"id": g} for g in labels]}
            if url == "profile":
                return {"historyId": "100"}
            if url.startswith("messages/") and "format=metadata" in url:
                gid = url.split("/")[1].split("?")[0]
                return {"id": gid, "threadId": "t" + gid, "labelIds": list(labels[gid]), "snippet": "Hi", "internalDate": str(int(time.time() * 1000)),
                        "payload": {"mimeType": "multipart/mixed", "headers": [{"name": "From", "value": "Ana <ana@example.com>"},
                                                                              {"name": "Subject", "value": "Hi " + gid}]}}
            if url.startswith("messages/") and "format=full" in url:
                return {"payload": {"mimeType": "multipart/mixed", "parts": [{"mimeType": "application/pdf", "filename": "r.pdf"}]}}
            if url == "labels" and method == "GET":
                return {"labels": [{"name": n, "id": i, "type": "user"} for n, i in made.items()]}
            if url == "labels" and method == "POST":
                made[body["name"]] = f"Label_{len(made) + 10}"
                return {"id": made[body["name"]]}
            if url == "messages/batchModify":
                for gid in body["ids"]:
                    labels[gid] = [l for l in labels[gid] if l not in body["removeLabelIds"]] + body["addLabelIds"]
                return {}
            raise AssertionError(url)
        box = mail.Inbox(self.root, gmail_fetch=fetch, sort=self.sort)
        box.state.save_settings({"labels": {"google": {"groups": True}}})
        mail.set_rules(box.state, [{"when": {"attachment": "pdf"}, "do": "label", "arg": "Family"}])
        box.sync(box.account())
        self.assertIn(made["Redde/Newsletters"], labels["g1"])
        self.assertIn("Label_9", labels["g1"], "the PDF rule tagged g1")
        box.label_job("google", "remove", "all")
        box.label_jobs(box.account())
        self.assertNotIn(made["Redde/Newsletters"], labels["g1"])
        self.assertNotIn("Label_9", labels["g1"])
        self.assertIn("Label_9", labels["g2"], "g2 had Family already: Redde never took it off")


if __name__ == "__main__":
    unittest.main()

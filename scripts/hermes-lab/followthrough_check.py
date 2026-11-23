"""Follow-Through with bills, trips, meetings and usual buys (lab.sh followthrough, plugin 1.40.0),
inside a real Hermes, as a person would meet it:

  mail      a bill, a passport reminder, a flight, a calendar invitation and a sent promise go
            through the plugin's own mail sync (`Inbox.sync`, an IMAP stand-in with real messages)
            into this Hermes's home; `/redde-push follow list` (the app's screen) lists them
  cards     the Hermes's own background loop, once a phone is paired, sends the ones that have
            come due as one set of idea cards to that phone: pay the bill, the passport, packing,
            the meeting with what's open with that person; and a usual buy (milk every 6 days)
  paperless PAPERLESS_URL and a PAPERLESS_…TOKEN in the home's .env: the loop finds Paperless and
            asks it with the token; a new document that's a bill becomes a bill to follow
  paid      a payment confirmation from the same sender settles the bill
  switches  `follow set trips off` / on, `follow drop <id>`, as the app's switches and swipe

Nothing reaches a real mail server, Paperless or model: the stand-ins are in this process.

usage: followthrough_check.py <hermes executable>   (a lab up with the push scenario)
"""
import asyncio
import importlib
import json
import math
import os
import sys
import threading
import time
from datetime import datetime, timedelta
from email.message import EmailMessage
from email.utils import format_datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import check
from check import Dashboard, report
from push_check import Phone, pair

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "companion" / "hermes-plugin" / "tests"))
from test_mail import FakeImap, FakeServer, mail  # noqa: E402  (the plugin as the tests load it)

plugin = sys.modules[mail.__name__.rsplit(".", 1)[0]]
follow = importlib.import_module(plugin.__name__ + ".followthrough")
habits = importlib.import_module(plugin.__name__ + ".habits")
paper = importlib.import_module(plugin.__name__ + ".paper")

HOME = Path(os.environ["HERMES_HOME"])
ME = "alex@example.com"
PAPER_PORT, PAPER_TOKEN = 18991, "lab-paper-token-0001"


def message(sender, subject, body, to=ME, when=None):
    m = EmailMessage()
    m["From"], m["To"], m["Subject"] = sender, to, subject
    m["Date"] = format_datetime((when or datetime.now()).astimezone())
    m["Message-ID"] = f"<{abs(hash((sender, subject, body)))}@lab.example>"
    m.set_content(body)
    return m.as_bytes()


def day(d):
    return f"{d:%B} {d.day}, {d.year}"


class Paperless:
    """Enough of Paperless-ngx's REST API: documents newest first, correspondents, the token checked."""
    docs = [{"id": 5, "title": "Old scan", "content": "Nothing to see.", "correspondent": None, "created": "2026-10-01"}]
    asked = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            Paperless.asked.append((self.path, self.headers.get("Authorization")))
            if self.headers.get("Authorization") != f"Token {PAPER_TOKEN}":
                self.send_response(401), self.end_headers()
                return
            if self.path.startswith("/api/documents/"):
                body = {"count": len(Paperless.docs), "results": sorted(Paperless.docs, key=lambda d: -d["id"])}
            elif self.path.startswith("/api/correspondents/"):
                body = {"count": 1, "results": [{"id": 3, "name": "City Water"}]}
            else:
                self.send_response(404), self.end_headers()
                return
            text = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(text)


async def say(dash, arg):
    return (await dash.call("command.dispatch", {"name": "redde-push", "arg": arg})).get("output", "")


def parsed(output):
    return json.loads(output.removeprefix("redde-push follow ")) if output.startswith("redde-push follow {") else None


async def main():
    now = datetime.now()
    if not 9 <= now.hour < 19:
        print("  SKIP  cards only go 9 am to 7 pm: run this in the day")
        return
    server = ThreadingHTTPServer(("127.0.0.1", PAPER_PORT), Paperless.Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with open(HOME / ".env", "a") as env:
        env.write(f"\nPAPERLESS_URL=127.0.0.1:{PAPER_PORT}\nPAPERLESS_API_TOKEN={PAPER_TOKEN}\n")

    # Mail, through the plugin's own sync.
    bill_day, trip_day, passport_day = now + timedelta(days=2), now + timedelta(days=2), now + timedelta(days=60)
    start = (now + timedelta(hours=1)).replace(minute=0, second=0, microsecond=0)
    hour = f"{(start.hour - 1) % 12 + 1}{'am' if start.hour < 12 else 'pm'}"
    end = start + timedelta(hours=1)
    end_hour = f"{(end.hour - 1) % 12 + 1}{'am' if end.hour < 12 else 'pm'}"
    imap = FakeServer()
    inbox_mail = [
        ("City Electric <billing@cityelectric.example>", "Your November bill is ready",
         f"Amount due: $84.20. Payment due date: {day(bill_day)}."),
        ("Passport Office <passports@gov.example>", "Your passport renewal reminder",
         f"Your passport expires on {day(passport_day)}. Renew in time for travel."),
        ("TAP Air Portugal <noreply@flytap.example>", "Your trip to Lisbon: booking confirmed",
         f"Your flight to Lisbon is booked. Confirmation code: QX7LMB. Flight TP 202. Departure: {trip_day:%A}, "
         f"{day(trip_day)} 7:05 PM from Boston. Return: {day(trip_day + timedelta(days=7))}."),
        ("Ana Ruiz <ana@example.com>", f"Invitation: Lease review @ {start:%a %b} {start.day}, {start.year} {hour} - {end_hour} (EST) ({ME})",
         "You have been invited to the following event."),
    ]
    for uid, (sender, subject, body) in enumerate(inbox_mail, 1):
        imap.folders["INBOX"][uid] = [message(sender, subject, body), set()]
    imap.folders["Sent"][1] = [message(ME, "Lease", "Thanks Ana. I'll send the signed copy by Friday.", to="Ana Ruiz <ana@example.com>",
                                       when=now - timedelta(hours=2)), {"\\Seen"}]
    account = mail.Account(id="lab", name="Lab", address=ME, provider="fastmail", user=ME, password="app-pass",
                           imap_host="imap.invalid")
    inbox = mail.Inbox(HOME, imap_connect=lambda a: FakeImap(imap), sort=lambda **_: "[]")
    inbox.sync(account)

    # Usual buys: milk ticked off a shopping list three times, six days apart.
    for days_ago in (18, 12, 6.05):
        habits.note(HOME, "Milk", "lab-groceries", "Groceries", time.time() - days_ago * 86400)

    dash = await Dashboard.connect()
    listed = parsed(await say(dash, "follow list")) or {}
    kinds = sorted(i["kind"] for i in listed.get("items") or [])
    report(kinds == ["bill", "expiry", "meeting", "promise", "trip"],
           "a bill, the passport, a flight, an invitation and a sent promise are followed", listed)
    by_kind = {i["kind"]: i for i in listed.get("items") or []}
    report(by_kind.get("bill", {}).get("shop") == "City Electric" and by_kind["bill"].get("amount") == "$84.20",
           "the bill: City Electric, $84.20", by_kind.get("bill"))
    report(by_kind.get("trip", {}).get("place") == "Lisbon" and by_kind["trip"].get("flight") == "TP202",
           "the trip: Lisbon, TP202", by_kind.get("trip"))
    report(by_kind.get("meeting", {}).get("title") == "Lease review" and by_kind["meeting"].get("start") == int(start.timestamp()),
           "the meeting: Lease review at the hour", by_kind.get("meeting"))
    report(sorted(listed.get("switches") or {}) == ["arrivals", "habits", "mail", "orders", "trips"],
           "five switches, all on", listed.get("switches"))
    report(listed.get("paperless", {}).get("found") is True, "Paperless found from the .env", listed.get("paperless"))

    # The loop runs once a phone is paired.
    phone = Phone()
    print("  ...  pairing a stand-in phone")
    await asyncio.to_thread(pair, phone)
    report(bool(phone.key), "a phone paired")
    deadline, ideas = time.time() + 120, []
    while time.time() < deadline and len(ideas) < 2:
        await asyncio.sleep(3)
        ideas = [n for n in phone.notes() if n.get("k") == "ideas"]
    titles = [c.get("t") for n in ideas for c in n.get("y") or []]
    print("       cards:", titles)
    want = [f"Pay City Electric $84.20 by {bill_day:%A}", f"Passport expires {passport_day:%B} {passport_day.day}",
            "Get ready for Lisbon", f"Before Lease review at"]
    for w in want:
        report(any(t and t.startswith(w) for t in titles), f"the loop sent “{w}…”", titles)
    meeting = next((c for n in ideas for c in n.get("y") or [] if str(c.get("t", "")).startswith("Before Lease")), {})
    report("signed copy" in meeting.get("w", "") or "promised" in meeting.get("w", "").lower(),
           "the meeting card says what was promised Ana", meeting)
    report("Milk again?" in titles, "a usual buy: “Milk again?”", titles)
    milk = next((c for n in ideas for c in n.get("y") or [] if c.get("t") == "Milk again?"), {})
    report("every 6 days" in milk.get("w", ""), "…about every 6 days", milk)

    # Paperless: the loop asked it with the token; a new bill in it becomes one to follow.
    report(any(p.startswith("/api/documents/") and a == f"Token {PAPER_TOKEN}" for p, a in Paperless.asked),
           "the loop asked Paperless for new documents with its token", Paperless.asked[:3])
    Paperless.docs.append({"id": 6, "title": "Water bill November", "correspondent": 3, "created": now.strftime("%Y-%m-%d"),
                           "content": f"City Water. Amount due: $41.10. Payment due date: {day(now + timedelta(days=16))}."})
    paper.look(HOME, time.time() + paper.EVERY + 60)
    listed = parsed(await say(dash, "follow list")) or {}
    water = [i for i in listed.get("items") or [] if i["kind"] == "bill" and i.get("shop") == "City Water"]
    report(len(water) == 1 and water[0].get("amount") == "$41.10", "a new Paperless document became a bill: City Water, $41.10", listed)

    # Paid: a payment confirmation from City Electric settles that bill.
    imap.folders["INBOX"][9] = [message("City Electric <billing@cityelectric.example>", "Thank you for your payment",
                                        "Thank you for your payment of $84.20."), set()]
    inbox.sync(account)
    listed = parsed(await say(dash, "follow list")) or {}
    report(not [i for i in listed.get("items") or [] if i.get("shop") == "City Electric"],
           "a payment confirmation settled the City Electric bill", listed)

    # The app's switch and swipe.
    off = parsed(await say(dash, "follow set trips off")) or {}
    report((off.get("switches") or {}).get("trips") is False, "`follow set trips off`", off.get("switches"))
    on = parsed(await say(dash, "follow set trips on")) or {}
    report((on.get("switches") or {}).get("trips") is True, "and on again", on.get("switches"))
    promise = next((i for i in on.get("items") or [] if i["kind"] == "promise"), None)
    if promise:
        gone = parsed(await say(dash, f"follow drop {promise['id']}")) or {}
        report(promise["id"] not in [i["id"] for i in gone.get("items") or []], "`follow drop` takes the promise off", gone)
    else:
        report(False, "the promise is still followed after its meeting card", on)
    server.shutdown()
    await dash.ws.close()


asyncio.run(main())
raise SystemExit(1 if check.failures else 0)

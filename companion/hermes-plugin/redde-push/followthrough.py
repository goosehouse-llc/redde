"""Follow-through (1.39.0, asked 2026-11-23: after plans that happen, "What are some other proactive
actions we can incorporate?", then "All 3"): what the person's mail says will happen is kept, and
checked when it should have, with no model. Only what didn't happen comes back, as an idea card
(`ideas.offer`) whose request their main agent carries out if they take it.

Mail they write and get (`mail.Inbox.sync` hands over each look's new messages, and a few of
their newest sent ones):
- promises: "I'll send you the figures by Friday" in mail they sent. On the day, in the afternoon,
  if nothing has gone to that person since: "You said you'd … by Friday", offering a draft.
- waiting on: a question they sent ("Could you confirm the dates?"). An answer from that person
  settles it; four days without one: "No answer from Ana yet", offering a nudge.
- replies owed: mail sorted Needs Reply, still in the inbox and unanswered after three days, once.
Orders, from receipts and shipping mail:
- deliveries: "Arriving Thursday" is kept with its order; "Delivered" settles it, and ticks off a
  gift on a gifts list (`lists.py`) whose name the order holds. Two days late: a card offering a
  note to the shop. The morning it's due: "Arriving today", quietly.
- return windows: "Return by December 15": five days before, unless it's gone back.
- free trials and renewals: "Your trial ends December 1… then $14.99/month": three days before.

English only; nothing here reads a whole mailbox, only what each look brings. Each is one item in
followthrough.json (main home), settled, offered or dropped once; the app lists them and can drop
one, and switches each kind off (`/redde-push follow …`). Jellyfin's arrivals are `arrivals.py`'s.
"""
from __future__ import annotations

import contextlib
import hashlib
import json
import logging
import os
import re
import time
from datetime import date, datetime, timedelta
from pathlib import Path

from . import dates, wire

log = logging.getLogger("redde_push.followthrough")

FILE = "followthrough.json"
SWITCHES = ("mail", "orders", "trips", "arrivals", "habits")
#: Which switch each kind of item is under.
GROUPS = {"promise": "mail", "waiting": "mail", "owed": "mail", "meeting": "mail", "delivery": "orders",
          "return": "orders", "trial": "orders", "bill": "orders", "expiry": "orders", "trip": "trips",
          "planned": "plans"}   # (no switch of its own: they picked it)
#: Days before a card: a question unanswered, a reply owed, a late delivery; a return window and a
#: trial ahead.
WAITING, OWED, LATE, RETURN_AHEAD, TRIAL_AHEAD = 4, 3, 2, 5, 3
#: Cards only in the day (the server's time): at most this many at once, a set an hour, so many a day.
DAY_FROM, DAY_TO, AT_ONCE, GAP, DAILY = 9, 19, 5, 3600, 8
#: A meeting's card is an hour before it, wider in the day and not kept to the hour's gap.
MEETING_FROM, MEETING_TO, MEETING_BEFORE = 7, 21, 3600
#: A bill: reminded this many days before it's due, checked as paid this many after. An expiry:
#: told this many days ahead (a passport, longer).
BILL_AHEAD, BILL_AFTER, EXPIRY_AHEAD, PASSPORT_AHEAD = 3, 2, 30, 90
#: Kept at most this many, and settled ones this long.
MOST, KEEP_DONE = 300, 30 * 86400
SENT_EVERY = 10 * 60
SENT_FIRST_DAYS = 3

_PROMISE = re.compile(
    r"\b(?:i'?ll|i will|i'm going to|i am going to|i'?m gonna|let me|we'?ll|we will|i can)\s+(?:\w+\s+){0,3}?"
    r"(?P<what>send|get|have|share|forward|finish|follow up|circle back|look|review|call|write|email|reply|check|"
    r"put together|draft|confirm|update|sign|pay|submit|book|order|bring|return)\b", re.IGNORECASE)
_ASK = re.compile(r"\?\s*$|\b(?:let me know|could you|can you|would you|will you|please (?:send|confirm|let|advise|share)|"
                  r"are you able|do you know|any update)\b", re.IGNORECASE)
_NOT_A_PERSON = re.compile(r"(?:^|[._+-])(?:no-?reply|do-?not-?reply|notifications?|mailer-daemon|bounce|support|"
                           r"info|news|alerts?|billing|orders?|receipts?|service)(?:[._+-]|@)", re.IGNORECASE)
_QUOTED = re.compile(r"^(?:>|On .{5,120} wrote:\s*$|-{2,}\s*Original Message|From:\s|Sent from my )", re.IGNORECASE | re.MULTILINE)

_ARRIVING = re.compile(r"\b(?:arriving|arrives|arrive|estimated delivery(?: date)?|expected delivery(?: date)?|delivery date|"
                       r"expected (?:by|on)|get it by|will be delivered(?: on| by)?|delivery by|out for delivery|"
                       r"delivering|scheduled delivery)\b", re.IGNORECASE)
#: "Delivered" in a subject; in the text only as a sentence says it (a shipping mail's tracker has the
#: word "Delivered" as its last step, still to come).
_DELIVERED_SUBJECT = re.compile(r"\bdelivered\b", re.IGNORECASE)
_NOT_YET = re.compile(r"\b(?:will be|to be|being|get it|once|when|until)\s+delivered\b", re.IGNORECASE)
_DELIVERED_TEXT = re.compile(r"\b(?:has been delivered|was delivered|were delivered|have been delivered)\b", re.IGNORECASE)
_RETURN = re.compile(r"\b(?:return (?:by|before|until|through|window closes(?: on)?|deadline(?: is)?)|returnable (?:until|through|by)|"
                     r"eligible for (?:a )?return (?:until|through|by)|return it by|returns? accepted (?:until|through))\b", re.IGNORECASE)
_TRIAL = re.compile(r"\b(?:trial (?:ends|expires|will end|period ends)(?: on)?|free trial (?:until|through|ends)|"
                    r"(?:will )?renews? (?:automatically )?on|will be (?:charged|billed) on|next (?:billing|payment|charge) (?:date|on)(?: is)?|"
                    r"subscription (?:renews|will renew)(?: on)?|first (?:payment|charge) (?:on|date))\b", re.IGNORECASE)
_PRICE = re.compile(r"(?:[$€£]\s?\d{1,4}(?:[.,]\d{2})?|\d{1,4}(?:[.,]\d{2})?\s?(?:USD|EUR|GBP))(?:\s?(?:/|per|a)\s?(?:mo(?:nth)?|yr|year|week))?", re.IGNORECASE)
_ORDER_NO = re.compile(r"\border\s*(?:#|no\.?|number)?\s*:?\s*#?([A-Z0-9][A-Z0-9-]{4,24})\b", re.IGNORECASE)
_SUBJECT_NOISE = re.compile(r"^(?:re|fwd?|shipped|ordered|delivered|arriving[^:]*|your order(?: of)?|order confirmation|"
                            r"out for delivery|a shipment from your order)[:\s-]*", re.IGNORECASE)
_ORDERISH = re.compile(r"\b(?:order|shipped|shipping|delivery|delivered|arriving|package|parcel|tracking|return|refund|"
                       r"trial|subscription|renew|receipt|invoice|membership|bill|statement|payment|due|premium|"
                       r"expir\w*|passport|licen[cs]e|registration|insurance|policy|warranty|flight|itinerary|booking|"
                       r"reservation|trip|e-?ticket|boarding|check-?in|hotel|stay|invitation|invite)\b", re.IGNORECASE)

# bills (1.40.0)
_BILLISH = re.compile(r"\b(?:bill|statement|invoice|payment due|amount due|balance due|due date|autopay|premium)\b", re.IGNORECASE)
_DUE = re.compile(r"\b(?:payment due(?: date)?|due date|(?:is |are )?due (?:on|by)|amount due by|please pay by|pay by|"
                  r"minimum payment due(?: by| date)?)\b", re.IGNORECASE)
_AMOUNT = re.compile(r"(?i:amount due|total due|balance due|minimum (?:payment )?due|new balance|statement balance|"
                     r"total amount|amount)\s*:?\s*([$€£]\s?\d[\d,]*(?:\.\d{2})?)")
_AUTOPAY = re.compile(r"\b(?:autopay|auto-pay|automatic payment|will be automatically (?:paid|debited|charged|drafted)|"
                      r"scheduled payment|will be paid automatically)\b", re.IGNORECASE)
_PAID = re.compile(r"\b(?:payment (?:received|confirmation|confirmed|processed|posted|successful|was successful)|"
                   r"thank you for your payment|thanks for your payment|we(?:'ve| have) received your payment|"
                   r"your payment of .{0,30}(?:has been|was|is) (?:received|processed|posted))\b", re.IGNORECASE)
# expiries
_EXPIRY_THING = re.compile(r"\b(?:passport|driver'?s? licen[cs]e|licen[cs]e|registration|insurance|policy|warranty|"
                           r"membership|permit|visa|certificate|id card|inspection|domain)\b", re.IGNORECASE)
_EXPIRES = re.compile(r"\b(?:expires?(?: on)?|expiration(?: date)?|expiry(?: date)?|valid (?:until|through|thru)|"
                      r"renew(?:al)? (?:by|before|date|due)|(?:coverage|policy) (?:ends|period ends)|"
                      r"warranty (?:ends|expires|until|through|valid until))\b", re.IGNORECASE)
_CARD_EXPIRY = re.compile(r"\b(?:card (?:ending|number)|credit card|debit card|exp(?:iration)?\.? date\s*:?\s*\d\d/\d\d)\b",
                          re.IGNORECASE)
# trips
_TRIPISH = re.compile(r"\b(?:flight|itinerary|booking|reservation|trip|e-?ticket|boarding pass|check-?in|hotel|stay)\b",
                      re.IGNORECASE)
_FLIGHT = re.compile(r"\b[Ff](?:light|LIGHT)\s*(?:[Nn]umber|[Nn]o\.?|#)?\s*:?\s*([A-Z][A-Z0-9]|[0-9][A-Z])\s?(\d{1,4})\b")
_DEPART = re.compile(r"\b(?:depart(?:s|ure|ing)?(?: date)?|outbound|leaves|flight date|travel date|check-?in(?: date)?)\b",
                     re.IGNORECASE)
_BACK = re.compile(r"\b(?:return(?:ing)?(?: flight| date)?|inbound|check-?out(?: date)?)\b", re.IGNORECASE)
_STAY = re.compile(r"\bcheck-?in\b[\s\S]{0,400}\bcheck-?out\b", re.IGNORECASE)
_PLACE = re.compile(r"\b(?:to|in|for)\s+([A-Z][\w'.-]+(?:\s+[A-Z][\w'.-]+){0,2})")
_REF = re.compile(r"(?i:\b(?:confirmation|booking|record locator|reservation|reference|pnr)(?:\s+(?:code|number|no\.?|#))?)"
                  r"\s*:?\s*#?([A-Z0-9]{5,8})\b")
# meetings
_INVITE = re.compile(r"^(?:updated )?invitation(?: from [^:]+)?:\s*(?P<title>.+?)(?:\s+@\s+(?P<when>.+?))?\s*(?:\(|$)", re.IGNORECASE)
_CANCELED = re.compile(r"^(?:canceled|cancelled)(?: event| invitation)?:\s*(?P<title>.+?)(?:\s+@\s+.*)?$", re.IGNORECASE)
_WHEN_LINE = re.compile(r"\bWhen\s*:\s*(.{5,140})", re.IGNORECASE)
_ROBOTS = re.compile(r"^(?:calendar-notification|calendar|noreply|no-reply)@", re.IGNORECASE)


# ---- what's kept ----------------------------------------------------------------------------------

def _path(home: Path) -> Path:
    return Path(home) / "redde-push" / FILE


@contextlib.contextmanager
def _locked(home: Path):
    folder = Path(home) / "redde-push"
    folder.mkdir(parents=True, exist_ok=True)
    handle = open(os.open(folder / "followthrough.lock", os.O_WRONLY | os.O_CREAT, 0o600), "w")
    try:
        try:
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX)
        except (ImportError, OSError):
            pass
        yield
    finally:
        handle.close()


def load(home: Path) -> dict:
    try:
        data = json.loads(_path(home).read_text())
    except (OSError, ValueError):
        data = {}
    data = data if isinstance(data, dict) else {}
    data["items"] = {k: v for k, v in (data.get("items") or {}).items() if isinstance(v, dict)}
    data["switches"] = {k: bool((data.get("switches") or {}).get(k, True)) for k in SWITCHES}
    data.setdefault("sent", {})
    return data


def save(home: Path, data: dict) -> None:
    now = time.time()
    items = data.get("items") or {}
    # settled ones go after a month; the oldest go first past MOST
    items = {k: v for k, v in items.items() if v.get("state") == "open" or now - float(v.get("settled") or v.get("made") or now) < KEEP_DONE}
    if len(items) > MOST:
        items = dict(sorted(items.items(), key=lambda kv: kv[1].get("made") or 0)[-MOST:])
    data["items"] = items
    path = _path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    os.chmod(temp, 0o600)
    temp.replace(path)


def on(home: Path, switch: str) -> bool:
    return load(home)["switches"].get(switch, True)


def _id(*parts) -> str:
    return hashlib.sha1("\x1f".join(str(p).lower() for p in parts).encode()).hexdigest()[:12]


def _day(ts: float) -> date:
    return datetime.fromtimestamp(ts).date()


def _at(day: date, hour: int) -> float:
    return datetime(day.year, day.month, day.day, hour).timestamp()


def _keep(data: dict, item: dict) -> bool:
    """Adds an item unless it's known (by its id); an open one may move its date. Whether new."""
    known = data["items"].get(item["id"])
    if known is None:
        data["items"][item["id"]] = {**item, "state": "open"}
        return True
    if known.get("state") == "open" and item.get("due") and item["due"] != known.get("due"):
        known["due"] = item["due"]
        known.pop("today_said", None)
    return False


def _settle(item: dict, how: str, now: float) -> None:
    item.update(state="done", settled=now, how=how)


# ---- reading mail -------------------------------------------------------------------------------

def own_words(text: str) -> str:
    """What they wrote, not what they quoted."""
    cut = _QUOTED.search(text or "")
    return (text[: cut.start()] if cut else text or "").strip()


def _sentences(text: str) -> list[str]:
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+|\n+", text) if s.strip()]


def is_person(address: str) -> bool:
    return bool(address) and "@" in address and not _NOT_A_PERSON.search(address.split("@")[0] + "@")


def _subject(subject: str) -> str:
    subject = re.sub(r"^(?:(?:re|fwd?|aw|sv)\s*:\s*)+", "", subject or "", flags=re.IGNORECASE).strip()
    return subject[:80] or "(no subject)"


def promise_in(text: str, ref: date) -> tuple[str, date] | None:
    """The sentence of a promise with a day, and the day."""
    for sentence in _sentences(own_words(text))[:40]:
        if not _PROMISE.search(sentence):
            continue
        found = dates.PHRASE.search(sentence[_PROMISE.search(sentence).end():])
        if found:
            when = dates.read(found, ref)
            if when and ref <= when <= ref + timedelta(days=60):
                return sentence[:160], when
    return None


def asks(text: str) -> bool:
    return any(_ASK.search(s) for s in _sentences(own_words(text))[:40])


def from_sent(data: dict, message: dict, me: str, now: float) -> list[str]:
    """A message they sent: what it settles, what it promises, what it asks. What's new."""
    to = [a.lower() for a in (message.get("to") or []) + (message.get("cc") or []) if a and a.lower() != me]
    people = [a for a in to if is_person(a)]
    when = float(message.get("date") or now)
    for item in data["items"].values():
        if item.get("state") != "open" or float(item.get("made") or 0) >= when:
            continue
        if item["kind"] in ("promise", "owed") and item.get("who") in to:
            _settle(item, "sent", now)
    for person in people[:3]:
        _remember_person(data, person, "", _subject(message.get("subject")), when, "out")
    if not people or len(people) > 3 or message.get("bulk"):
        return []
    text, subject, made = message.get("_text") or "", _subject(message.get("subject")), []
    name = (message.get("to_names") or {}).get(people[0]) or people[0].split("@")[0].replace(".", " ").title()
    promised = promise_in(text, _day(when))
    if promised:
        said, day = promised
        due = _at(day, 16) if _at(day, 16) > when else _at(day + timedelta(days=1), 9)
        item = {"id": _id("promise", people[0], subject, day), "kind": "promise", "who": people[0], "name": name,
                "subject": subject, "said": said, "day": day.isoformat(), "made": when, "due": due}
        if _keep(data, item):
            made.append(item["id"])
    elif asks(text):
        item = {"id": _id("waiting", people[0], subject), "kind": "waiting", "who": people[0], "name": name,
                "subject": subject, "made": when, "due": when + WAITING * 86400}
        if _keep(data, item):
            made.append(item["id"])
    return made


def from_inbox(data: dict, message: dict, now: float) -> list[str]:
    """A message that came: an answer settles waiting on its sender; needs-reply mail is kept."""
    who, when = (message.get("address") or "").lower(), float(message.get("date") or now)
    if is_person(who) and not message.get("bulk"):
        _remember_person(data, who, message.get("from") or who, _subject(message.get("subject")), when, "in")
    for item in data["items"].values():
        if item.get("state") == "open" and item["kind"] == "waiting" and item.get("who") == who and when > float(item.get("made") or 0):
            _settle(item, "answered", now)
    if message.get("bucket") == "needs_reply" and not message.get("bulk") and is_person(who):
        item = {"id": _id("owed", message.get("id")), "kind": "owed", "who": who, "name": message.get("from") or who,
                "subject": _subject(message.get("subject")), "message": message.get("id"), "made": when,
                "due": when + OWED * 86400}
        if _keep(data, item):
            return [item["id"]]
    return []


def _what(subject: str, text: str) -> str:
    quoted = re.search(r"[\"“]([^\"”]{3,80})[\"”]", subject or "")
    if quoted:
        return quoted.group(1).strip()
    cleaned = _SUBJECT_NOISE.sub("", subject or "").strip(" -:#")
    cleaned = re.sub(r"\s*(?:has shipped|is on its way|was delivered|has been delivered|is out for delivery)\.?$", "", cleaned, flags=re.IGNORECASE)
    return (cleaned or "your order")[:70]


def _shop(message: dict) -> str:
    name = (message.get("from") or "").strip()
    address = (message.get("address") or "")
    if not name or "@" in name:
        name = address.split("@")[-1].split(".")[-2].title() if "." in address else address
    return re.sub(r"\s*(?:\.com|orders?|shipping|customer service|support|notifications?)$", "", name, flags=re.IGNORECASE)[:40] or "the shop"


def _domain(address: str) -> str:
    host = (address or "").lower().split("@")[-1]
    parts = host.split(".")
    return ".".join(parts[-2:]) if len(parts) >= 2 else host


def orderish(message: dict) -> bool:
    return message.get("bucket") in ("receipts", "notifications") or bool(message.get("receipt")) \
        or bool(_ORDERISH.search(message.get("subject") or ""))


def from_order(data: dict, message: dict, text: str, now: float) -> tuple[list[str], list[dict]]:
    """Receipt or shipping mail: what it starts and what it settles. New ids, and the deliveries
    that came (for the gifts list)."""
    subject, when = message.get("subject") or "", float(message.get("date") or now)
    ref, shop, domain = _day(when), _shop(message), _domain(message.get("address"))
    body = f"{subject}\n{text}"
    order = _ORDER_NO.search(body)
    order = order.group(1) if order else None
    what, made, came = _what(subject, text), [], []

    if (_DELIVERED_SUBJECT.search(subject) and not _NOT_YET.search(subject)) \
            or (_DELIVERED_TEXT.search(text[:800]) and not _ARRIVING.search(subject) and not _NOT_YET.search(text[:800])):
        for item in data["items"].values():
            if item.get("state") == "open" and item["kind"] == "delivery" and item.get("domain") == domain \
                    and (not order or not item.get("order") or item["order"] == order):
                _settle(item, "delivered", now)
                came.append(item)
        if not came:
            came.append({"what": what, "shop": shop})
        return made, came

    arriving = dates.after(body, _ARRIVING, ref)
    if arriving and ref <= arriving <= ref + timedelta(days=45):
        item = {"id": _id("delivery", domain, order or what), "kind": "delivery", "shop": shop, "domain": domain,
                "what": what, "order": order, "day": arriving.isoformat(), "made": when,
                "due": _at(arriving + timedelta(days=LATE), 10), "today": _at(arriving, 8)}
        if _keep(data, item):
            made.append(item["id"])
        else:
            known = data["items"][item["id"]]
            if known.get("state") == "open" and known.get("day") != item["day"]:
                known.update(day=item["day"], due=item["due"], today=item["today"])
                known.pop("today_said", None)

    back = dates.after(body, _RETURN, ref)
    if back and ref < back <= ref + timedelta(days=120):
        item = {"id": _id("return", domain, order or what), "kind": "return", "shop": shop, "domain": domain,
                "what": what, "order": order, "day": back.isoformat(), "made": when,
                "due": _at(back - timedelta(days=RETURN_AHEAD), 10)}
        if _keep(data, item):
            made.append(item["id"])

    ends = dates.after(body, _TRIAL, ref)
    if ends and ref < ends <= ref + timedelta(days=400):
        price = _PRICE.search(body)
        service = shop if shop != "the shop" else what
        item = {"id": _id("trial", domain, ends), "kind": "trial", "shop": service, "domain": domain,
                "what": what, "day": ends.isoformat(), "price": price.group(0).strip() if price else None,
                "made": when, "due": _at(ends - timedelta(days=TRIAL_AHEAD), 10)}
        if _keep(data, item):
            made.append(item["id"])
    return made, came


# ---- bills, expiries, trips, meetings (1.40.0) ---------------------------------------------------

def _steps(item: dict, steps: list[tuple[str, float]], now: float) -> dict:
    """An item whose cards come at several times: the ones still to come, the first as `due`."""
    item["steps"] = [{"step": name, "at": at} for name, at in sorted(steps, key=lambda s: s[1]) if at > now - 86400]
    item["due"] = item["steps"][0]["at"] if item["steps"] else 0
    return item


def _payee(message: dict) -> str:
    return _shop(message)


def from_bill(data: dict, message: dict, text: str, now: float, shop: str | None = None, domain: str | None = None) -> list[str]:
    """A bill with its day due: reminded three days before (not when it's paid automatically),
    checked two days after for a payment confirmation."""
    subject, when = message.get("subject") or "", float(message.get("date") or now)
    body, ref = f"{subject}\n{text}", _day(when)
    shop, domain = shop or _payee(message), domain if domain is not None else _domain(message.get("address"))
    if _PAID.search(body):
        for item in data["items"].values():
            if item.get("state") == "open" and item["kind"] == "bill" and float(item.get("made") or 0) <= when \
                    and ((domain and item.get("domain") == domain) or _same_payee(item.get("shop"), shop)):
                _settle(item, "paid", now)
        return []
    if not _BILLISH.search(body):
        return []
    day = dates.after(body, _DUE, ref, numeric=True)
    if not day or not (ref - timedelta(days=1) <= day <= ref + timedelta(days=60)):
        return []
    amount = _AMOUNT.search(body) or _PRICE.search(body)
    auto = bool(_AUTOPAY.search(body))
    item = {"id": _id("bill", domain or shop, day), "kind": "bill", "shop": shop, "domain": domain,
            "what": _subject(subject) if subject else shop, "amount": (amount.group(1) if amount and amount.lastindex else
                                                                       amount.group(0) if amount else None),
            "autopay": auto, "day": day.isoformat(), "made": when}
    steps = [("verify", _at(day + timedelta(days=BILL_AFTER), 10))]
    if not auto and now < _at(day, 19):
        # (a bill that comes in less than three days before its day is reminded now, not never)
        steps.append(("remind", max(_at(day - timedelta(days=BILL_AHEAD), 10), now)))
    if data["items"].get(item["id"]):
        return []
    _keep(data, _steps(item, steps, now))
    return [item["id"]]


def _same_payee(a, b) -> bool:
    first = lambda x: (re.findall(r"[a-z0-9]{3,}", str(x or "").lower()) or [""])[0]
    return bool(first(a)) and first(a) == first(b)


def from_expiry(data: dict, what: str, body: str, ref: date, when: float, now: float, gate: str) -> list[str]:
    """Something that runs out (a passport, a policy, a warranty): told a month ahead, three for a
    passport. Only for what `gate` (a subject, a document's title) says it is."""
    thing = _EXPIRY_THING.search(gate or "")
    if not thing:
        return []
    for hit in _EXPIRES.finditer(body):
        if _CARD_EXPIRY.search(body[max(0, hit.start() - 60): hit.end() + 30]):
            continue
        day = dates.after(body[hit.start():], _EXPIRES, ref, numeric=False)
        if day and ref + timedelta(days=14) <= day <= ref + timedelta(days=3 * 366):
            ahead = PASSPORT_AHEAD if thing.group(0).lower() == "passport" else EXPIRY_AHEAD
            item = {"id": _id("expiry", what, day), "kind": "expiry", "what": what[:70], "thing": thing.group(0).lower(),
                    "day": day.isoformat(), "made": when}
            _steps(item, [("remind", max(_at(day - timedelta(days=ahead), 10), now))], now - 86400)
            return [item["id"]] if _keep(data, item) else []
    return []


def from_trip(data: dict, message: dict, text: str, now: float) -> list[str]:
    """A flight or a stay: a packing card three days before, check-in the day before a flight, and
    the trip's receipts the day after it's over."""
    subject, when = message.get("subject") or "", float(message.get("date") or now)
    body, ref = f"{subject}\n{text}", _day(when)
    if not _TRIPISH.search(subject):
        return []
    flight = _FLIGHT.search(body)
    stay = bool(_STAY.search(body))
    if not (flight or stay):
        return []
    leave = dates.after(body, _DEPART, ref, within=80)
    if not leave or not (ref <= leave <= ref + timedelta(days=330)):
        return []
    back = dates.after(body, _BACK, ref, within=80)
    if back and not (leave <= back <= leave + timedelta(days=60)):
        back = None
    place = _PLACE.search(subject)
    place = place.group(1).strip(" .") if place else None
    ref_code = _REF.search(body)
    flight_no = f"{flight.group(1)}{flight.group(2)}" if flight else None
    # one trip per departure day: a second mail about it fills in what the first didn't say
    for item in data["items"].values():
        if item["kind"] == "trip" and item.get("state") == "open" and abs((date.fromisoformat(item["day"]) - leave).days) <= 1:
            changed = False
            for key, value in (("flight", flight_no), ("back", back.isoformat() if back else None), ("place", place),
                               ("ref", ref_code.group(1) if ref_code else None)):
                if value and not item.get(key):
                    item[key], changed = value, True
            if changed:
                _trip_steps(item, now)
            return []
    item = {"id": _id("trip", leave, ref_code.group(1) if ref_code else flight_no or _domain(message.get("address"))),
            "kind": "trip", "place": place, "flight": flight_no, "ref": ref_code.group(1) if ref_code else None,
            "shop": _shop(message), "day": leave.isoformat(), "back": back.isoformat() if back else None, "made": when}
    _keep(data, _trip_steps(item, now))
    return [item["id"]]


def _trip_steps(item: dict, now: float) -> dict:
    leave = date.fromisoformat(item["day"])
    done = {s["step"] for s in item.get("done_steps") or []}
    # A trip booked less than three days ahead is packed for now; a day ahead, only checked in for.
    steps = []
    if now < _at(leave - timedelta(days=1), 10):
        steps.append(("pack", max(_at(leave - timedelta(days=3), 10), now)))
    if item.get("flight") and now < _at(leave, 12):
        steps.append(("checkin", max(_at(leave - timedelta(days=1), 10), now)))
    if item.get("back"):
        steps.append(("home", _at(date.fromisoformat(item["back"]) + timedelta(days=1), 10)))
    return _steps(item, [s for s in steps if s[0] not in done and s[1] > now - 86400], now)


def from_invite(data: dict, message: dict, text: str, me: str, now: float) -> list[str]:
    """A calendar invitation with other people in it: a card an hour before, with what's open with
    them, when there's something to say. A cancellation drops it."""
    subject, when = (message.get("subject") or "").strip(), float(message.get("date") or now)
    gone = _CANCELED.match(subject)
    if gone:
        for item in data["items"].values():
            if item["kind"] == "meeting" and item.get("state") == "open" and item.get("title", "").lower() == gone.group("title").strip().lower():
                item.update(state="dropped", settled=now)
        return []
    invite = _INVITE.match(subject)
    if not invite:
        return []
    said = invite.group("when") or (_WHEN_LINE.search(text or "") or [None, ""])[1]
    ref = _day(when)
    day, clock = dates.first(said or "", ref), dates.time_in(said or "")
    if not day or not clock:
        return []
    start = datetime(day.year, day.month, day.day, *clock).timestamp()
    if start <= now:
        return []
    who = [message.get("address") or ""] + list(message.get("to") or []) + list(message.get("cc") or [])
    people = list(dict.fromkeys(a.lower() for a in who if a and a.lower() != me and not _ROBOTS.match(a) and is_person(a)))
    if not people:
        return []
    title = invite.group("title").strip()[:80]
    item = {"id": _id("meeting", title, start), "kind": "meeting", "title": title, "start": start, "people": people[:8],
            "names": {message.get("address", "").lower(): message.get("from")} if message.get("from") else {},
            "day": day.isoformat(), "made": when}
    _steps(item, [("prep", start - MEETING_BEFORE)], now)
    return [item["id"]] if _keep(data, item) else []


def _name_of(address: str) -> str:
    return address.split("@")[0].replace(".", " ").replace("_", " ").title()


def _remember_person(data: dict, address: str, name: str, subject: str, when: float, way: str) -> None:
    people = data.setdefault("people", {})
    known = people.get(address)
    if name and "@" not in name and known and "@" not in str(known.get("name")) and float(known.get("date") or 0) >= when:
        return
    real = name if name and "@" not in name else (known or {}).get("name")
    if known and float(known.get("date") or 0) >= when:
        known["name"] = real or known.get("name")
        return
    people[address] = {"name": real or _name_of(address), "subject": subject, "date": when, "way": way}
    if len(people) > 500:
        for old in sorted(people, key=lambda a: people[a].get("date") or 0)[: len(people) - 500]:
            people.pop(old)


def from_paper(data: dict, doc: dict, now: float) -> list[str]:
    """A document new in Paperless: a bill's day due, or something that runs out."""
    title = str(doc.get("title") or "")[:80]
    text = str(doc.get("content") or "")[:6000]
    message = {"subject": title, "date": now, "address": "", "from": str(doc.get("correspondent_name") or title)}
    made = from_bill(data, message, text, now, shop=message["from"], domain="")
    made += from_expiry(data, title, f"{title}\n{text}", _day(now), now, now, f"{title}\n{text[:400]}")
    return made


def from_kept_mail(data: dict, message: dict, text: str, me: str, now: float, switches: dict) -> list[str]:
    """Every reader that keeps something from one message, as switched on."""
    made = []
    if switches.get("orders"):
        made += from_bill(data, message, text, now)
        made += from_expiry(data, _subject(message.get("subject")), f"{message.get('subject') or ''}\n{text}",
                            _day(float(message.get("date") or now)), float(message.get("date") or now), now,
                            message.get("subject") or "")
    if switches.get("trips"):
        made += from_trip(data, message, text, now)
    if switches.get("mail"):
        made += from_invite(data, message, text, me, now)
    return made


def run_note(home: Path, message, platform: str = "") -> str | None:
    """For `pre_llm_call`: a run that plans ahead (Heads-Ups, Morning Ideas, the Week Ahead) is told
    what's open with people, so a meeting with one of them says so."""
    from . import facts
    if platform != "cron" or not facts.PLANNING.match(facts._text(message)):
        return None
    data = load(home)
    if not data["switches"]["mail"]:
        return None
    lines = []
    for item in sorted(data["items"].values(), key=lambda i: i.get("made") or 0, reverse=True):
        if item.get("state") != "open":
            continue
        who = f"{item.get('name') or item.get('who')} ({item.get('who')})"
        if item["kind"] == "promise":
            lines.append(f"they promised {who} \"{item.get('said')}\"")
        elif item["kind"] == "waiting":
            lines.append(f"they're waiting on {who} about \"{item.get('subject')}\"")
        elif item["kind"] == "owed":
            lines.append(f"they owe {who} a reply to \"{item.get('subject')}\"")
        if len(lines) >= 8:
            break
    if not lines:
        return None
    return ("[Redde: open with people, from their mail: " + "; ".join(lines) + ". If an event you look at is with one "
            "of them, say it in that event's heads-up in a few words. Say nothing of the others.]")


# ---- the inbox's hook ----------------------------------------------------------------------------

def sent_imap(box, account, kept: dict, now: float) -> list[dict]:
    """Their newest sent mail on IMAP since the last look (the first look: the last few days)."""
    folder = box.folders().get("sent")
    if not folder:
        return []
    info = box.select(folder, readonly=True)
    if info.get("uidvalidity") and kept.get("uidvalidity") != info["uidvalidity"]:
        kept.clear()
        kept["uidvalidity"] = info["uidvalidity"]
    last = int(kept.get("last_uid") or 0)
    if last and info.get("uidnext") and info["uidnext"] <= last + 1:
        return []
    uids = box.uids(f"UID {last + 1}:*") if last else box.uids("ALL")[-20:]
    uids = [u for u in uids if u > last][-30:]
    if uids:
        kept["last_uid"] = max([last] + uids)
    found = box.headers(uids)
    return [m for m in found if last or now - float(m.get("date") or 0) < SENT_FIRST_DAYS * 86400]


def sent_gmail(api, kept: dict, now: float, body_of, plain) -> list[dict]:
    seen = list(kept.get("seen") or [])
    listed = api.fetch("GET", f"messages?q=in:sent newer_than:{SENT_FIRST_DAYS}d&maxResults=20")
    out = []
    for m in listed.get("messages") or []:
        if m["id"] in seen:
            continue
        seen.append(m["id"])
        try:
            meta = api.meta(m["id"])
            import base64
            import email
            import email.policy
            raw = api.fetch("GET", f"messages/{m['id']}?format=raw")
            msg = email.message_from_bytes(base64.urlsafe_b64decode(raw.get("raw", "") + "=="), policy=email.policy.default)
            meta["_text"] = plain(body_of(msg)[0], 1500)
            out.append(meta)
        except Exception:
            continue
    kept["seen"] = seen[-200:]
    return out


def after_sync(inbox, account, new: list[dict], texts: dict, now: float | None = None) -> None:
    """Called by `Inbox.sync` with what a look found: settles and keeps."""
    now = now or time.time()
    home = inbox.root
    with _locked(home):
        data = load(home)
        switches = data["switches"]
        if not (switches["mail"] or switches["orders"] or switches["trips"]):
            return
        me = (account.address or "").lower()
        for message in new:
            if message.get("address") == me:
                continue
            text = texts.get(message.get("id")) or message.get("_text") or ""
            if switches["mail"]:
                from_inbox(data, message, now)
            if (switches["orders"] or switches["trips"] or switches["mail"]) and orderish(message):
                if not text and account.via == "gmail_api":
                    text = _gmail_text(inbox, account, message)
                if switches["orders"]:
                    _, came = from_order(data, message, text, now)
                    for delivery in came:
                        _gifts_came(home, delivery)
                from_kept_mail(data, message, text, me, now, switches)
        if switches["mail"]:
            kept = data["sent"].setdefault(account.id, {})
            if now - float(kept.get("at") or 0) >= SENT_EVERY:
                kept["at"] = now
                try:
                    for message in _sent(inbox, account, kept, now):
                        from_sent(data, message, me, now)
                except Exception:
                    log.debug("redde-push: reading sent mail failed", exc_info=True)
        save(home, data)


def _sent(inbox, account, kept: dict, now: float) -> list[dict]:
    from . import mail
    if account.via == "gmail_api":
        return sent_gmail(inbox._gmail(account), kept, now, mail.body_of, mail.plain)
    with inbox._imap(account) as box:
        return sent_imap(box, account, kept, now)


def _gmail_text(inbox, account, message: dict) -> str:
    try:
        from . import mail
        import base64
        import email
        import email.policy
        gid = str(message.get("id") or "").split(":", 2)[-1]
        raw = inbox._gmail(account).fetch("GET", f"messages/{gid}?format=raw")
        msg = email.message_from_bytes(base64.urlsafe_b64decode(raw.get("raw", "") + "=="), policy=email.policy.default)
        return mail.plain(mail.body_of(msg)[0], 3000)
    except Exception:
        return ""


def _gifts_came(home: Path, delivery: dict) -> None:
    """A delivery that came ticks off a gift its order names, on a gifts list."""
    try:
        from . import lists
        said = f"{delivery.get('what') or ''}".casefold()
        if len(said) < 3:
            return
        for kept in lists.load(home):
            if lists.look(kept)["kind"] != "gifts":
                continue
            for item in kept.get("items") or []:
                name = str(item.get("text") or "").casefold()
                words = [w for w in re.findall(r"[\w']{4,}", name)]
                if not item.get("done") and words and all(w in said for w in words[:3]):
                    lists.change(home, {"action": "check", "list": kept["id"], "items": [item["id"]]}, by="redde")
                    return
    except Exception:
        log.debug("redde-push: ticking a gift off failed", exc_info=True)


# ---- what comes due -----------------------------------------------------------------------------

#: The moment cards are being made for (`due` sets it), so "Friday" is said from then.
_SAYING_AT: list[float] = []


def _when(day_text: str) -> str:
    try:
        day = date.fromisoformat(day_text)
    except (TypeError, ValueError):
        return ""
    today = _day(_SAYING_AT[-1]) if _SAYING_AT else date.today()
    if day == today:
        return "today"
    if day == today + timedelta(days=1):
        return "tomorrow"
    return day.strftime("%A" if 0 < (day - today).days < 7 else "%B %-d").replace(" 0", " ")


def planned(home: Path, key: str, plan: str, actions: list[dict]) -> list[str]:
    """A plan card's picks for later (Plan For It, 1.41.0): each comes back as a card at its time,
    in the day or not (they picked the time). The same answer read again adds nothing."""
    made = []
    with _locked(home):
        data = load(home)
        for action in actions[:8]:
            title, request, at = str(action.get("title") or "").strip(), str(action.get("request") or "").strip(), action.get("at")
            if not title or not request or not isinstance(at, (int, float)):
                continue
            item = {"id": _id("planned", key, title), "kind": "planned", "title": title[:80], "what": plan[:80],
                    "request": request[:600], "due": float(at), "day": _day(float(at)).isoformat(), "made": time.time()}
            if _keep(data, item):
                made.append(item["id"])
        save(home, data)
    return made


def card(item: dict, mailbox: dict | None = None) -> dict | None:
    """The idea card for an item come due, or None once it no longer needs one."""
    kind, name, subject = item["kind"], item.get("name") or item.get("who"), item.get("subject")
    if kind == "planned":
        return {"title": item.get("title", "")[:60], "why": (f"You planned it for {item['what']}" if item.get("what") else "You planned it")[:140],
                "request": item.get("request") or item.get("title", "")}
    if kind == "promise":
        return {"title": f"Send {name.split()[0]} what you promised"[:60],
                "why": f"You wrote \"{item.get('said')}\" in \"{subject}\""[:140],
                "request": f"In my email \"{subject}\" to {name} ({item['who']}) I wrote: \"{item.get('said')}\". Help me do "
                           "it, and draft the email for me to look over before anything is sent."}
    if kind == "waiting":
        return {"title": f"No answer from {name.split()[0]} yet"[:60],
                "why": f"You asked about \"{subject}\" {WAITING} days ago",
                "request": f"Draft a short, friendly nudge to {name} ({item['who']}) about my email \"{subject}\", for me "
                           "to look over before it's sent."}
    if kind == "owed":
        if mailbox is not None and item.get("message") not in mailbox:
            return None              # archived or deleted: dealt with
        return {"title": f"Reply to {name.split()[0]}"[:60],
                "why": f"\"{subject}\" has waited {OWED} days",
                "request": f"Read {name}'s email \"{subject}\" and draft a reply for me to look over before it's sent."}
    if kind == "delivery":
        order = f" (order {item['order']})" if item.get("order") else ""
        return {"title": f"Still no sign of {item.get('what')}"[:60],
                "why": f"{item.get('shop')} said it would arrive {_when(item.get('day'))}"[:140],
                "request": f"My {item.get('shop')} order{order}, {item.get('what')}, was due {item.get('day')} and hasn't "
                           "arrived. Find its tracking in my email and draft a note to them asking where it is, for me "
                           "to look over."}
    if kind == "return":
        order = f" (order {item['order']})" if item.get("order") else ""
        return {"title": f"Return window closes {_when(item.get('day'))}"[:60],
                "why": f"{item.get('what')}, from {item.get('shop')}"[:140],
                "request": f"Help me return {item.get('what')} to {item.get('shop')}{order} before {item.get('day')}: find "
                           "how in my email."}
    if kind == "trial":
        then = f", then {item['price']}" if item.get("price") else ""
        return {"title": f"{item.get('shop')} renews {_when(item.get('day'))}"[:60],
                "why": f"Your trial or plan ends {item.get('day')}{then}"[:140],
                "request": f"My {item.get('shop')} trial or subscription renews on {item.get('day')}{then}. Find how to "
                           "cancel it in my email, and tell me what it costs if I keep it."}
    return None


def today_card(item: dict) -> dict:
    return {"title": f"Arriving today: {item.get('what')}"[:60], "why": f"From {item.get('shop')}",
            "request": f"Find the tracking for my {item.get('shop')} order of {item.get('what')} in my email."}


def _clock(ts: float) -> str:
    return datetime.fromtimestamp(ts).strftime("%-I:%M %p").replace(":00 ", " ")


def step_card(item: dict, step: str, data: dict) -> dict | None:
    """The card for one of an item's steps, or None when there's nothing to say."""
    kind = item["kind"]
    if kind == "bill":
        amount = f" {item['amount']}" if item.get("amount") else ""
        if step == "remind":
            return {"title": f"Pay {item.get('shop')}{amount} by {_when(item.get('day'))}"[:60],
                    "why": f"{item.get('what')}"[:140],
                    "request": f"Help me pay my {item.get('shop')} bill{amount}, due {item.get('day')}: find it in my email "
                               "or my documents and tell me how to pay it."}
        return {"title": f"Did the {item.get('shop')} bill get paid?"[:60],
                "why": ("It's on autopay, but no confirmation came" if item.get("autopay") else
                        f"It was due {item.get('day')}, and no payment confirmation came")[:140],
                "request": f"Check whether my {item.get('shop')} bill{amount}, due {item.get('day')}, was paid: look for a "
                           "confirmation in my email, and tell me what to do if it wasn't."}
    if kind == "expiry":
        thing = (item.get("thing") or "it").capitalize()
        return {"title": f"{thing} expires {_when(item.get('day'))}"[:60], "why": f"{item.get('what')}"[:140],
                "request": f"My {item.get('what')} expires on {item.get('day')}. Find what I need to renew it, in my email "
                           "and documents, and the steps."}
    if kind == "trip":
        place = item.get("place") or "your trip"
        to = f" to {item['place']}" if item.get("place") else ""
        span = f"{item.get('day')}" + (f" to {item['back']}" if item.get("back") else "")
        if step == "pack":
            # (1.41.0: one plan for the trip, what to do picked by them, not a packing list alone)
            return {"title": f"Get ready for {place}"[:60],
                    "why": (f"You leave {_when(item.get('day'))}" + (f", flight {item['flight']}" if item.get("flight") else ""))[:140],
                    "request": f"I'm going on my trip{to}, {span}" + (f", flight {item['flight']}" if item.get("flight") else "")
                               + ". Show me a 'plan' card of what you could do for it: a packing list in Redde from the weather "
                               "there and what my email says, the trip on my calendar so Leave-By can time it, checking in the "
                               "day before, and anything else that would help."}
        if step == "checkin":
            ref = f" ({item['ref']})" if item.get("ref") else ""
            return {"title": f"Check in for {item.get('flight')}"[:60], "why": f"You fly {_when(item.get('day'))}",
                    "request": f"Find my {item.get('flight')} booking{ref} in my email and help me check in."}
        if step == "home":
            return {"title": f"File the receipts from {place}?"[:60], "why": f"Back since {_when(item.get('back'))}",
                    "request": f"Gather the receipts from my trip{to}, {span}, from my email into one list for expenses."}
    if kind == "meeting":
        return meeting_card(item, data)
    return None


def meeting_card(item: dict, data: dict) -> dict | None:
    """What's open with the meeting's people, and their last email; None when there's nothing."""
    people, known = item.get("people") or [], data.get("people") or {}
    said, names = [], []
    for address in people:
        name = (item.get("names") or {}).get(address) or (known.get(address) or {}).get("name") or _name_of(address)
        name = name if "@" not in str(name) else _name_of(address)
        first = str(name).split()[0] if name else address
        names.append(str(name))
        for open_ in data["items"].values():
            if open_.get("state") != "open" or open_.get("who") != address:
                continue
            if open_["kind"] == "promise":
                said.append(f"you promised {first} \"{open_.get('said')}\"")
            elif open_["kind"] == "waiting":
                said.append(f"waiting on {first} about \"{open_.get('subject')}\"")
            elif open_["kind"] == "owed":
                said.append(f"{first}'s \"{open_.get('subject')}\" needs a reply")
        last = known.get(address)
        if last and float(item.get("start") or 0) - float(last.get("date") or 0) < 30 * 86400:
            said.append(f"last email \"{last.get('subject')}\"")
    if not said:
        return None
    at, title = _clock(float(item["start"])), item.get("title")
    return {"title": f"Before {title} at {at}"[:60], "why": "; ".join(dict.fromkeys(said))[:140],
            "request": f"Before my meeting \"{title}\" at {at} with {', '.join(names[:4])}, brief me: our recent emails, what "
                       "I promised them and what I'm waiting on from them."}


def due(home: Path, offer, mailbox=None, now: float | None = None) -> int:
    """Cards for what's come due; `offer(ideas) -> bool` sends them (`ideas.offer`). In the day, a set
    an hour, so many a day; a meeting's in a wider day and not kept to the hour. `mailbox() -> set`
    gives the inbox's message ids, for replies owed. How many went."""
    now = now or time.time()
    hour = datetime.fromtimestamp(now).hour
    if not MEETING_FROM <= hour < MEETING_TO:
        return 0
    day_time = DAY_FROM <= hour < DAY_TO
    _SAYING_AT[:] = [now]
    with _locked(home):
        data = load(home)
        sent = [t for t in data.get("offered") or [] if now - t < 86400]
        if len(sent) >= DAILY:
            return 0
        hourly = day_time and not (sent and now - max(sent) < GAP)
        room = min(AT_ONCE, DAILY - len(sent))
        switches, cards, picked = data["switches"], [], []
        ids = None
        for item in sorted(data["items"].values(), key=lambda i: i.get("due") or 0):
            if item.get("state") != "open" or len(cards) >= room:
                continue
            if not switches.get(GROUPS.get(item["kind"], "mail"), True):
                continue
            if item["kind"] not in ("meeting", "planned") and not hourly:
                continue
            if item["kind"] == "delivery" and not item.get("today_said") and item.get("today", 0) <= now < item.get("due", 0) \
                    and _day(now).isoformat() == item.get("day"):
                cards.append(today_card(item))
                picked.append((item, "today"))
                continue
            if float(item.get("due") or 0) > now:
                continue
            if item.get("steps") is not None:
                if not item["steps"]:
                    item.update(state="offered", settled=now)
                    continue
                step = item["steps"][0]["step"]
                if item["kind"] == "meeting" and now > float(item.get("start") or 0):
                    item.update(state="done", settled=now, how="over")
                    continue
                made = step_card(item, step, data)
                if made is None:
                    _advance(item, now)
                    continue
                cards.append(made)
                picked.append((item, "step"))
                continue
            if item["kind"] == "owed" and ids is None and mailbox is not None:
                try:
                    ids = set(mailbox())
                except Exception:
                    ids = None
            made = card(item, ids)
            if made is None:
                _settle(item, "dealt with", now)
                continue
            cards.append(made)
            picked.append((item, "due"))
        if cards and offer(cards):
            data["offered"] = sent + [now] * len(cards)
            for item, how in picked:
                if how == "today":
                    item["today_said"] = now
                elif how == "step":
                    _advance(item, now)
                else:
                    item.update(state="offered", settled=now)
        save(home, data)
        return len(cards) if cards else 0


def _advance(item: dict, now: float) -> None:
    """An item's step offered (or with nothing to say): on to its next, or done with."""
    step = item["steps"].pop(0)
    item.setdefault("done_steps", []).append({**step, "said": now})
    if item["steps"]:
        item["due"] = item["steps"][0]["at"]
    else:
        item.update(state="offered", settled=now)


# ---- the app's command --------------------------------------------------------------------------

def listing(home: Path) -> dict:
    data = load(home)
    items = sorted((i for i in data["items"].values() if i.get("state") == "open"), key=lambda i: i.get("due") or 0)
    shown = []
    for i in items[:100]:
        shown.append({k: i.get(k) for k in ("id", "kind", "name", "who", "subject", "said", "shop", "what", "order", "day",
                                             "price", "amount", "autopay", "thing", "place", "flight", "back", "title")
                       if i.get(k) is not None} | {"due": int(i.get("due") or 0)}
                     | ({"start": int(i["start"])} if i.get("start") else {}))
    return {"switches": data["switches"], "items": shown}


def slash(home: Path, words: list[str]) -> str:
    """`/redde-push follow list`, `follow set <switch> on|off`, `follow drop <id>`."""
    if words == ["list"]:
        from . import arrivals
        from . import paper
        return wire.reply("follow", {**listing(home), "jellyfin": arrivals.status(home), "paperless": paper.status(home)})
    if len(words) == 3 and words[0] == "set" and words[1] in SWITCHES and words[2] in ("on", "off"):
        with _locked(home):
            data = load(home)
            data["switches"][words[1]] = words[2] == "on"
            save(home, data)
        return wire.reply("follow", listing(home))
    if len(words) == 2 and words[0] == "drop":
        with _locked(home):
            data = load(home)
            item = data["items"].get(words[1])
            if item:
                item.update(state="dropped", settled=time.time())
            save(home, data)
        return wire.reply("follow", listing(home))
    return "redde-push follow: this command is for the Redde app."

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
SWITCHES = ("mail", "orders", "arrivals")
#: Days before a card: a question unanswered, a reply owed, a late delivery; a return window and a
#: trial ahead.
WAITING, OWED, LATE, RETURN_AHEAD, TRIAL_AHEAD = 4, 3, 2, 5, 3
#: Cards only in the day (the server's time): at most this many at once, a set an hour, so many a day.
DAY_FROM, DAY_TO, AT_ONCE, GAP, DAILY = 9, 19, 5, 3600, 8
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
                       r"trial|subscription|renew|receipt|invoice|membership)\b", re.IGNORECASE)


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
        if not (switches["mail"] or switches["orders"]):
            return
        me = (account.address or "").lower()
        for message in new:
            if message.get("address") == me:
                continue
            text = texts.get(message.get("id")) or message.get("_text") or ""
            if switches["mail"]:
                from_inbox(data, message, now)
            if switches["orders"] and orderish(message):
                if not text and account.via == "gmail_api":
                    text = _gmail_text(inbox, account, message)
                _, came = from_order(data, message, text, now)
                for delivery in came:
                    _gifts_came(home, delivery)
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

def _when(day_text: str) -> str:
    try:
        day = date.fromisoformat(day_text)
    except (TypeError, ValueError):
        return ""
    today = date.today()
    if day == today:
        return "today"
    if day == today + timedelta(days=1):
        return "tomorrow"
    return day.strftime("%A" if 0 < (day - today).days < 7 else "%B %-d").replace(" 0", " ")


def card(item: dict, mailbox: dict | None = None) -> dict | None:
    """The idea card for an item come due, or None once it no longer needs one."""
    kind, name, subject = item["kind"], item.get("name") or item.get("who"), item.get("subject")
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


def due(home: Path, offer, mailbox=None, now: float | None = None) -> int:
    """Cards for what's come due, in the day; `offer(ideas) -> bool` sends them (`ideas.offer`).
    `mailbox() -> set` gives the inbox's message ids, for replies owed. How many went."""
    now = now or time.time()
    hour = datetime.fromtimestamp(now).hour
    if not DAY_FROM <= hour < DAY_TO:
        return 0
    with _locked(home):
        data = load(home)
        sent = [t for t in data.get("offered") or [] if now - t < 86400]
        if sent and now - max(sent) < GAP or len(sent) >= DAILY:
            return 0
        room = min(AT_ONCE, DAILY - len(sent))
        switches, cards, picked = data["switches"], [], []
        ids = None
        for item in sorted(data["items"].values(), key=lambda i: i.get("due") or 0):
            if item.get("state") != "open" or len(cards) >= room:
                continue
            group = "mail" if item["kind"] in ("promise", "waiting", "owed") else "orders"
            if not switches[group]:
                continue
            if item["kind"] == "delivery" and not item.get("today_said") and item.get("today", 0) <= now < item.get("due", 0) \
                    and _day(now).isoformat() == item.get("day"):
                cards.append(today_card(item))
                picked.append((item, "today"))
                continue
            if float(item.get("due") or 0) > now:
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
                else:
                    item.update(state="offered", settled=now)
        save(home, data)
        return len(cards) if cards else 0


# ---- the app's command --------------------------------------------------------------------------

def listing(home: Path) -> dict:
    data = load(home)
    items = sorted((i for i in data["items"].values() if i.get("state") == "open"), key=lambda i: i.get("due") or 0)
    shown = []
    for i in items[:100]:
        shown.append({k: i.get(k) for k in ("id", "kind", "name", "who", "subject", "said", "shop", "what", "order", "day",
                                             "price") if i.get(k) is not None} | {"due": int(i.get("due") or 0)})
    return {"switches": data["switches"], "items": shown}


def slash(home: Path, words: list[str]) -> str:
    """`/redde-push follow list`, `follow set <switch> on|off`, `follow drop <id>`."""
    if words == ["list"]:
        from . import arrivals
        return wire.reply("follow", {**listing(home), "jellyfin": arrivals.status(home)})
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

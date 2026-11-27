"""Three more from the mail (1.55.0, asked 2026-11-27 "build 1-3", after a r/hermesagent thread of
other agents' nudges): what that thread's useful ones did that Follow-Through didn't yet.

- security notices ("Was this you?"): a new sign-in, a password or two-step change, a phone
  number or email changed on an account, a new payee. The ones that come together are one card, a
  quarter of an hour after the first, in the wider day (7 to 21) and not kept to the hour's gap.
  Taken, the agent asks which were them; "that was me" (`redde_mail` `was_me`) keeps that
  service's sign-ins on that device quiet for half a year. A code they asked for isn't a notice.
  Their own switch, "security".
- bounces: mail they sent that didn't arrive ("the address couldn't be found"), two hours on, if
  nothing with that subject (or to that address) has gone since. Only for someone they've written
  to or heard from, so not the backscatter of spam sent in their name; a delay isn't a bounce.
- follow-ups: someone writing again ("Just following up…", "any update?") when they wrote last,
  half an hour on, unless a reply has gone: the card says whether a draft to them is waiting (in
  the mailbox's Drafts, or one of Redde's) and offers to finish it. It takes the place of that
  person's reply owed.

Bounces and follow-ups are under the "mail" switch. English only, no model: all three are items
in Follow-Through's store, offered by `followthrough.due`, the agent running only for a card taken.
"""
from __future__ import annotations

import re
import time
import urllib.parse
from datetime import datetime

from . import followthrough as ft

KINDS = ("security", "bounce", "followup")
#: A security card this long after its first notice, so the ones that come together go together;
#: at most this many notices on one (the phone keeps a card's request to 300 characters). "That
#: was me" keeps a sign-in quiet this long.
SECURITY_WAIT, SECURITY_MOST, KNOWN_FOR = 15 * 60, 4, 182 * 86400
#: A bounce: this long to send it again. A follow-up: this long to answer it. Older mail than
#: OLD (a first look at an inbox) isn't news.
BOUNCE_WAIT, FOLLOWUP_WAIT, OLD = 2 * 3600, 30 * 60, 3 * 86400

# ---- security notices ---------------------------------------------------------------------------

_SECURITY = re.compile(
    r"\b(?:new sign[- ]?in|new log[- ]?in|signed in (?:to|on|from|with)|logged in (?:to|on|from|with)|"
    r"(?:sign[- ]?in|log[- ]?in) (?:attempt|alert|activity|notification|from|detected)|"
    r"new (?:device|browser|computer|phone)\b|unrecognized (?:device|sign[- ]?in|log[- ]?in)|"
    r"(?:unusual|suspicious) (?:sign[- ]?in|log[- ]?in|activity)|security (?:alert|notice|notification)|was this you|"
    r"password (?:was |has been |just )?(?:changed|updated|reset)\b|"
    r"(?:two[- ]step|2-step|two[- ]factor|2fa|multi[- ]factor|mfa)\b.{0,30}\b(?:turned off|disabled|changed|removed|updated|added)\b|"
    r"(?:phone number|mobile number|recovery (?:email|phone)|backup (?:email|phone)|email address)\b.{0,40}"
    r"\b(?:removed|changed|added|updated)\b|new (?:payee|recipient)\b)", re.IGNORECASE)
#: A subject that might be one, its text saying which (a bank's "Zelle profile update").
_ACCOUNTISH = re.compile(r"\b(?:profile|security|sign[- ]?in|log[- ]?in|password|two[- ]step|2-step|verification|"
                         r"account (?:update|change|activity|alert|notice))\b", re.IGNORECASE)
#: What they asked for, or what isn't news: codes, links, resets they started, newsletters.
_NOT_NOTICE = re.compile(r"\b(?:verification code|security code|one[- ]time (?:pass)?(?:code|password)|passcode|your code|"
                         r"(?:log[- ]?in|sign[- ]?in) (?:code|link)|code is|confirm your (?:email|account)|verify your (?:email|account)|"
                         r"reset your password|forgot (?:your )?password|magic link|webinar|newsletter|tips)\b", re.IGNORECASE)
_KIND_OF = (
    ("password", re.compile(r"\bpassword (?:was |has been |just )?(?:changed|updated|reset)\b", re.IGNORECASE)),
    ("two_step", re.compile(r"\b(?:two[- ]step|2-step|two[- ]factor|2fa|multi[- ]factor|mfa)\b.{0,30}"
                            r"\b(?:turned off|disabled|changed|removed|updated|added)\b", re.IGNORECASE)),
    ("contact", re.compile(r"\b(?:phone number|mobile number|recovery (?:email|phone)|backup (?:email|phone)|email address)\b"
                           r".{0,40}\b(?:removed|changed|added|updated)\b", re.IGNORECASE)),
    ("payee", re.compile(r"\bnew (?:payee|recipient)\b", re.IGNORECASE)),
    ("sign_in", re.compile(r"\b(?:sign[- ]?in|log[- ]?in|signed in|logged in|new (?:device|browser|computer|phone)|"
                           r"unrecognized device|was this you)\b", re.IGNORECASE)),
)
_OS = (("Mac", re.compile(r"\b(?:mac|macos|macbook\w*|os x|imac)\b", re.IGNORECASE)),
       ("iPhone", re.compile(r"\biphone\b", re.IGNORECASE)), ("iPad", re.compile(r"\bipad\b", re.IGNORECASE)),
       ("Windows", re.compile(r"\bwindows\b", re.IGNORECASE)), ("Android", re.compile(r"\bandroid\b", re.IGNORECASE)),
       ("Chromebook", re.compile(r"\b(?:chrome ?os|chromebook)\b", re.IGNORECASE)),
       ("Linux", re.compile(r"\b(?:linux|ubuntu)\b", re.IGNORECASE)))
_BROWSER = (("Chrome", re.compile(r"\bchrome\b(?! ?os)", re.IGNORECASE)), ("Safari", re.compile(r"\bsafari\b", re.IGNORECASE)),
            ("Firefox", re.compile(r"\bfirefox\b", re.IGNORECASE)), ("Edge", re.compile(r"\b(?:microsoft )?edge\b", re.IGNORECASE)))
_NEAR = re.compile(r"(?i:\bnear|approximate location:?|\blocation:)\s*([A-Z][\w.'’-]+(?:,? [A-Z][\w.'’-]+){0,3})")
#: How a notice is said: on a card's heading, and in its request.
_SHORT = {"sign_in": "sign-in", "password": "password change", "two_step": "two-step change", "contact": "account change",
          "payee": "new payee", "alert": "security alert"}


def _kind(text: str, sign_in: bool = True) -> str | None:
    for kind, pattern in _KIND_OF:
        if (sign_in or kind != "sign_in") and pattern.search(text or ""):
            return kind
    return None


def _service(message: dict) -> str:
    name = re.sub(r"[\"'®™]", "", message.get("from") or "").strip()
    address = (message.get("address") or "").lower()
    if not name or "@" in name:
        parts = address.split("@")[-1].split(".")
        name = parts[-2].title() if len(parts) >= 2 else address
    name = re.sub(r"\s*\b(?:accounts?|security|team|alerts?|notifications?|no-?reply|support|sign[- ]?in)\b.*$", "", name,
                  flags=re.IGNORECASE).strip(" -–,")
    return name[:30] or "An account"


def _device(text: str) -> str:
    """"Chrome on Mac", "iPhone", "Firefox"; "" when it doesn't say."""
    system = next((name for name, pattern in _OS if pattern.search(text)), "")
    browser = next((name for name, pattern in _BROWSER if pattern.search(text)), "")
    return f"{browser} on {system}" if browser and system else system or browser


def _place(text: str) -> str | None:
    """"Saint Paul, Minnesota" of "near Saint Paul, Minnesota. If this was you…"; "St. Paul" kept whole."""
    found = _NEAR.search(text or "")
    if not found:
        return None
    words = []
    for word in found.group(1).split(" "):
        words.append(word)
        if word.endswith(".") and len(word.rstrip(".,")) > 3:
            break
    return " ".join(words).rstrip(".,")[:40] or None


def noticeish(message: dict) -> bool:
    """Whether a message might be a security notice, before its text is read."""
    subject = message.get("subject") or ""
    return bool((_SECURITY.search(subject) or _ACCOUNTISH.search(subject)) and not _NOT_NOTICE.search(subject))


def _key(notice: dict) -> str:
    return f"{notice['service']}|{notice['what']}|{notice.get('device') or ''}".lower()


def from_security(data: dict, message: dict, text: str, now: float) -> list[str]:
    """A security notice is kept, with the ones near it, as one item; a sign-in they said was
    them, on that device, isn't. What's new."""
    subject, when = message.get("subject") or "", float(message.get("date") or now)
    who = (message.get("address") or "").lower()
    if not noticeish(message) or now - when > OLD or message.get("bucket") in ("promotions", "newsletters", "needs_reply"):
        return []
    if ((data.get("people") or {}).get(who) or {}).get("way") == "out":
        return []                     # someone they write to: not a robot's notice
    body = (text or "")[:2000]
    named = bool(_SECURITY.search(subject))
    what = _kind(subject) or _kind(body, sign_in=named)
    if not named and not what:
        return []
    what = what or "alert"
    # Which device and where: from near the sign-in's words, not a footer's "Get the app for iPhone".
    found = _KIND_OF[-1][1].search(body)
    near = body[found.start(): found.start() + 400] if found else body[:400]
    notice = {"id": message.get("id"), "service": _service(message), "what": what,
              "device": _device(f"{subject} {near}") or None, "place": _place(near),
              "at": when, "subject": ft._subject(subject)[:80]}
    if what == "sign_in" and notice["device"] and now - float((data.get("known") or {}).get(_key(notice)) or 0) < KNOWN_FOR:
        return []
    for item in data["items"].values():
        if item.get("kind") != "security" or item.get("state") != "open":
            continue
        if any(_key(n) == _key(notice) and abs(float(n["at"]) - when) < 1800 for n in item["notices"]):
            return []                 # the same sign-in told twice (Google's alert and its notice)
        if len(item["notices"]) < SECURITY_MOST:
            item["notices"].append(notice)
            return []
    item = {"id": ft._id("security", message.get("id"), when), "kind": "security", "notices": [notice], "made": when,
            "due": when + SECURITY_WAIT}
    return [item["id"]] if ft._keep(data, item) else []


def was_me(home, refs: list[str], now: float | None = None) -> dict:
    """`redde_mail` `was_me`: the notices they said were them (`<item>.<n>`, as a card's request
    gives them, or the email's id). A sign-in on a known device is quiet for half a year after."""
    now = time.time() if now is None else now
    refs = {str(r).strip() for r in refs if str(r).strip()}
    found, quiet = 0, []
    with ft._locked(home):
        data = ft.load(home)
        known = data.setdefault("known", {})
        for item in data["items"].values():
            if item.get("kind") != "security":
                continue
            for n, notice in enumerate(item.get("notices") or [], 1):
                if f"{item['id']}.{n}" not in refs and item["id"] not in refs and notice.get("id") not in refs:
                    continue
                found += 1
                notice["me"] = True
                if notice["what"] == "sign_in" and notice.get("device"):
                    known[_key(notice)] = now
                    quiet.append(f"{notice['service']} on {notice['device']}")
            if item.get("state") != "done" and item.get("notices") and all(n.get("me") for n in item["notices"]):
                ft._settle(item, "was me", now)
        if len(known) > 200:
            data["known"] = dict(sorted(known.items(), key=lambda kv: kv[1])[-200:])
        ft.save(home, data)
    if not found:
        return {"found": 0, "note": "None of those is a security notice Redde showed them."}
    quiet = list(dict.fromkeys(quiet))
    return {"found": found, "quiet": quiet,
            "note": ("Redde won't ask about sign-ins at " + ", ".join(quiet) + " for six months." if quiet else
                     "Marked as theirs.")}


# ---- bounces ------------------------------------------------------------------------------------

_BOUNCER = re.compile(r"^(?:mailer-?daemon|postmaster|mail-daemon)@", re.IGNORECASE)
_BOUNCE_SUBJECT = re.compile(
    r"^(?:undeliverable|undelivered mail|delivery status notification \(failure\)|mail delivery (?:failed|failure|system)|"
    r"returned mail|delivery failure|failure notice|message not delivered|delivery has failed|non-?delivery|"
    r"could not deliver|message delivery failure|address not found|delivery to the following recipients? failed)", re.IGNORECASE)
_DELAY = re.compile(r"\(delay\)|\bdelayed\b|\bwarning:|will (?:retry|keep trying|try again)|still trying|"
                    r"not yet been delivered", re.IGNORECASE)
_ADDRESS = r"<?([\w.+'’-]+@[\w-]+(?:\.[\w-]+)+)>?"
_FAILED = (
    re.compile(r"(?:final|original)-recipient:\s*rfc822;\s*" + _ADDRESS, re.IGNORECASE),
    re.compile(r"(?:wasn['’]t|was not|couldn['’]t be|could not be|cannot be|can['’]t be) delivered to\s+" + _ADDRESS, re.IGNORECASE),
    re.compile(r"\b(?:message|email|mail) to\s+" + _ADDRESS + r"\s+(?:couldn['’]t|could not|can['’]t|cannot|wasn['’]t|was not) be",
               re.IGNORECASE),
    re.compile(r"delivery to the following recipients? failed[^\n]*\s+" + _ADDRESS, re.IGNORECASE),
    re.compile(r"^\s*<([\w.+'’-]+@[\w-]+(?:\.[\w-]+)+)>:?\s", re.MULTILINE),
    re.compile(r"\b(?:recipients?|address(?:es)?)(?: had permanent fatal errors| failed| rejected)?\s*:\s*" + _ADDRESS, re.IGNORECASE),
)
_ORIGINAL_SUBJECT = re.compile(r"^\s*Subject:\s*(.+)$", re.IGNORECASE | re.MULTILINE)
_GENERIC = re.compile(r"^(?:undeliverable|undelivered mail returned to sender|delivery status notification.*|mail delivery failed.*|"
                      r"returned mail.*|failure notice|delivery failure|message not delivered|mail delivery system)\s*:?\s*",
                      re.IGNORECASE)
_REASONS = (
    ("no_domain", re.compile(r"domain (?:name )?(?:not found|does not exist|couldn['’]t be found)|dns error|"
                             r"host (?:or domain name )?not found|nxdomain|5\.1\.2|5\.4\.4", re.IGNORECASE)),
    ("no_address", re.compile(r"doesn['’]t exist|does not exist|couldn['’]t be found|could not be found|address not found|"
                              r"no such (?:user|address|mailbox)|user unknown|unknown (?:user|recipient)|recipient (?:address )?rejected|"
                              r"invalid (?:recipient|address|mailbox)|mailbox (?:not found|unavailable)|not a valid|5\.1\.[01]",
                              re.IGNORECASE)),
    ("full", re.compile(r"mailbox (?:is )?full|over (?:its |the )?quota|quota exceeded|exceeded (?:the |their )?(?:storage|quota)|"
                        r"5\.2\.2", re.IGNORECASE)),
    ("blocked", re.compile(r"\bblocked\b|\bspam\b|blacklist|denylist|rejected (?:for|by|due to) policy|not authorized|5\.7\.\d",
                           re.IGNORECASE)),
)
#: What happened to it, as a card says it.
_CLAUSE = {"no_address": "the address doesn't exist", "no_domain": "their domain wasn't found",
           "full": "their mailbox is full", "blocked": "their server turned it away", "": "it couldn't be delivered"}


def bounceish(message: dict) -> bool:
    return bool(_BOUNCER.match(message.get("address") or "") or _BOUNCE_SUBJECT.match(message.get("subject") or ""))


def failed_address(text: str, me: str) -> str | None:
    def fine(address):
        address = address.strip(".,;:'’").lower()
        return None if address == me or _BOUNCER.match(address) else address
    for pattern in _FAILED:
        for found in pattern.finditer(text or ""):
            address = fine(found.group(1))
            if address:
                return address
    for found in re.finditer(r"[\w.+'’-]+@[\w-]+(?:\.[\w-]+)+", text or ""):
        address = fine(found.group(0))
        if address:
            return address
    return None


def from_bounce(data: dict, message: dict, text: str, me: str, now: float) -> list[str]:
    """A bounce of something they sent is kept, to come back if nothing goes again."""
    subject, when = message.get("subject") or "", float(message.get("date") or now)
    if not bounceish(message) or now - when > OLD or _DELAY.search(subject) or _DELAY.search((text or "")[:1500]):
        return []
    who = failed_address(text, (me or "").lower())
    if not who:
        return []
    original = _ORIGINAL_SUBJECT.search(text or "")
    said = original.group(1).strip() if original else _GENERIC.sub("", subject).strip()
    said = ft._subject(said) if said and not _GENERIC.fullmatch(said) else ""
    reason = next((name for name, pattern in _REASONS if pattern.search(text or "")), "")
    for item in data["items"].values():
        if item.get("kind") == "bounce" and item.get("state") == "open" and item.get("who") == who \
                and (item.get("subject") or "") == said:
            return []                 # the same bounce told twice
    known = (data.get("people") or {}).get(who) or {}
    said = said or (known.get("subject") if known.get("way") == "out" else "") or ""
    item = {"id": ft._id("bounce", message.get("id"), who), "kind": "bounce", "who": who,
            "name": known.get("name") or ft._name_of(who), "subject": said or None, "reason": reason, "made": when,
            "due": when + BOUNCE_WAIT}
    return [item["id"]] if ft._keep(data, item) else []


# ---- follow-ups ---------------------------------------------------------------------------------

_NUDGE = re.compile(
    r"\b(?:following up|follow(?:ing)?[- ]up on|checking in (?:on|about|to see|again)|just checking in|circling back|"
    r"bumping (?:this|up)|any (?:update|news|word)s?\b|where (?:things|we|this) stands?|where (?:do|are) (?:we|things) stand|"
    r"(?:did|have) you (?:get|had|have) a chance|gentle reminder|friendly reminder|haven['’]t heard (?:back|from you)|"
    r"wanted to check (?:in|back)|still waiting (?:on|for|to hear))", re.IGNORECASE)


def from_followup(data: dict, message: dict, text: str, before: dict | None, now: float, drafts=None) -> list[str]:
    """Someone writing again when they wrote last: kept, with whether a draft to them waits, in
    place of their reply owed. `before` is what was known of them before this message;
    `drafts(address) -> "mailbox" | "redde" | None`."""
    who, when = (message.get("address") or "").lower(), float(message.get("date") or now)
    if not ft.is_person(who) or message.get("bulk") or now - when > OLD \
            or message.get("bucket") in ("promotions", "newsletters", "notifications", "receipts"):
        return []
    if before and before.get("way") == "out" and float(before.get("date") or 0) < when:
        return []                     # they wrote last: this answers them
    if not (_NUDGE.search(ft.own_words(text or "")[:1500]) or _NUDGE.search(message.get("subject") or "")):
        return []
    draft = None
    if drafts is not None:
        try:
            draft = drafts(who)
        except Exception:
            draft = None
    for item in data["items"].values():
        if item.get("state") == "open" and item["kind"] in ("owed", "followup") and item.get("who") == who:
            ft._settle(item, "followed up", now)
    item = {"id": ft._id("followup", message.get("id")), "kind": "followup", "who": who, "name": message.get("from") or who,
            "subject": ft._subject(message.get("subject")), "message": message.get("id"), "draft": draft, "made": when,
            "due": when + FOLLOWUP_WAIT}
    return [item["id"]] if ft._keep(data, item) else []


def drafts_to(inbox, account):
    """`drafts(address)`: whether a draft to them waits, one of Redde's or in the mailbox's Drafts."""
    def drafts(who: str) -> str | None:
        for draft in inbox.state.drafts().values():
            if draft.get("account") == account.id and who in [str(a).lower() for a in draft.get("to") or []]:
                return "redde"
        if account.via == "gmail_api":
            found = inbox._gmail(account).fetch("GET", "messages?maxResults=1&q=" + urllib.parse.quote(f"in:drafts to:{who}"))
            return "mailbox" if found.get("messages") else None
        if account.via != "imap":
            return None
        from . import mail
        with inbox._imap(account) as box:
            folder = box.folders().get("drafts")
            if not folder:
                return None
            box.select(folder, readonly=True)
            return "mailbox" if box.uids(f"TO {mail._q(who)}") else None
    return drafts


# ---- cards --------------------------------------------------------------------------------------

def _first(name: str) -> str:
    name = str(name or "")
    return name.split("@")[0] if "@" in name else (name.split() or [name])[0]


def _when(at: float) -> str:
    """"at 9:14 AM", "yesterday at 11 PM", "on Nov 24 at 8 AM"."""
    now = ft._SAYING_AT[-1] if ft._SAYING_AT else time.time()
    day, today = datetime.fromtimestamp(at).date(), datetime.fromtimestamp(now).date()
    said = f"at {ft._clock(at)}"
    if day == today:
        return said
    return f"yesterday {said}" if (today - day).days == 1 else datetime.fromtimestamp(at).strftime("on %b %-d ") + said


def _notice(notice: dict, full: bool = False) -> str:
    said = f"{notice['service']} {_SHORT.get(notice['what'], 'notice')}"
    if notice.get("device"):
        said += f" on {notice['device']}"
    if full and notice.get("place"):
        said += f" near {notice['place']}"
    return said + (f" {_when(float(notice['at']))}" if full else "")


def card(item: dict, data: dict, mailbox: set | None = None) -> dict | None:
    """The idea card for one of these come due, or None once it no longer needs one."""
    kind = item["kind"]
    if kind == "security":
        notices = [n for n in item.get("notices") or [] if not n.get("me")]
        if not notices:
            return None
        secure = "help me secure that account in its own app, not via the email's links."
        if len(notices) == 1:
            notice = notices[0]
            ref = f"{item['id']}.{item['notices'].index(notice) + 1}"
            return {"title": f"Was this you? {notice['service']} {_SHORT.get(notice['what'], 'notice')}"[:60],
                    "why": (_notice(notice, full=True) if notice.get("device") or notice.get("place") else
                            f"\"{notice['subject']}\" {_when(float(notice['at']))}")[:140],
                    "request": f"A security notice in my email: {_notice(notice, full=True)} (id {ref}). Ask if it was me; "
                               f"if so, call redde_mail was_me with that id. If not, {secure}"}
        # (the asking first: a long list is what the phone's 300 characters cut)
        listed = "; ".join(f"{item['notices'].index(n) + 1}) {_notice(n)}" for n in notices)
        services = list(dict.fromkeys(n["service"] for n in notices))
        return {"title": f"Was this you? {len(notices)} security notices",
                "why": (", ".join(services[:-1]) + " and " + services[-1] if len(services) > 1 else services[0])
                       + f", first {_when(min(float(n['at']) for n in notices))}",
                "request": f"Ask which of these security notices were me; call redde_mail was_me with ids \"{item['id']}.N\" "
                           f"for those. For the rest, {secure} {listed}."}
    if kind == "bounce":
        people = data.get("people") or {}
        if item.get("who") not in people:
            return None               # never written to: spam sent in their name, bounced back
        subject = item.get("subject") or (people[item["who"]] or {}).get("subject")
        clause = _CLAUSE.get(item.get("reason") or "", _CLAUSE[""])
        mail = f"My email \"{subject}\"" if subject else "My email"
        if item.get("reason") == "full":
            request = (f"{mail} to {item['name']} ({item['who']}) bounced: their mailbox is full. Draft it again to send later, "
                       "and find another way to reach them in my email or contacts, for me to look over.")
        else:
            request = (f"{mail} to {item['name']} ({item['who']}) bounced: {clause}. Find their right address in my email, "
                       "contacts or their website and draft it again to it, for me to look over. No address: tell me "
                       "another way to reach them.")
        return {"title": f"Your email to {_first(item['name'])} bounced"[:60],
                "why": (f"\"{subject}\": {clause}" if subject else f"To {item['who']}: {clause}")[:140],
                "request": request}
    if kind == "followup":
        if mailbox is not None and item.get("message") not in mailbox:
            return None               # archived or deleted: dealt with
        name, subject, draft = item.get("name") or item["who"], item.get("subject"), item.get("draft")
        where = " in Redde" if draft == "redde" else " in my Drafts"
        return {"title": f"{_first(name)} is following up"[:60],
                "why": (f"On \"{subject}\": " + ("your draft to them hasn't gone" if draft else "no reply has gone yet"))[:140],
                "request": (f"{name} ({item['who']}) followed up on \"{subject}\" and I haven't replied. "
                            + (f"I have a draft to them{where}: read it and their emails and finish it" if draft else
                               "Read the thread and draft a reply saying where things stand")
                            + ", for me to look over before it's sent.")}
    return None


def listed(item: dict) -> dict:
    """What the app's list adds for one of these."""
    if item["kind"] == "security":
        notices = item.get("notices") or []
        return {"shop": ", ".join(dict.fromkeys(n["service"] for n in notices)), "count": len(notices)}
    return {}

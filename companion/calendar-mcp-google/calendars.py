"""Every Google calendar of every account signed in, as the tools see them: which may be shown,
which only read, which are "background" (sports, holidays, birthdays, subscriptions), and their
events in the shape the Mac server's CalendarService gives them.

Settings (`settings.json` in the server's folder, read on each use, so edits apply at once):

    { "hide_calendars": ["Team Schedule"],      background: out of the agenda and free time
      "never_show": ["Diary"],                   never seen or written, by title, id or account
      "read_only": ["Work"],                     seen, never added to
      "default_calendar": "Personal",            where create_event adds without a calendar_id
      "time_zone": "America/New_York" }          else the default calendar's own
"""

from __future__ import annotations

import html
import json
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timedelta, tzinfo
from zoneinfo import ZoneInfo

import dates
import google

MAX_RANGE_DAYS = 400
MAX_EVENTS = 500
MAX_NOTES = 1000
#: How long the list of calendars is kept before Google is asked again.
LIST_FOR = 300


class ToolError(Exception):
    pass


def settings() -> dict:
    try:
        data = json.loads((google.home() / "settings.json").read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def names(key: str, kept: dict | None = None) -> set[str]:
    found = (kept if kept is not None else settings()).get(key) or []
    return {str(n).strip().lower() for n in found if str(n).strip()} if isinstance(found, list) else set()


@dataclass
class Calendar:
    account: str
    gid: str
    title: str
    color: str
    access: str
    primary: bool
    zone: str | None

    @property
    def id(self) -> str:
        """Unique across accounts: "<account>/<Google's calendar id>"."""
        return f"{self.account}/{self.gid}"

    def matches(self, wanted: set[str]) -> bool:
        return bool(wanted) and any(n in wanted for n in (self.title.lower(), self.gid.lower(), self.id.lower(), self.account.lower()))

    @property
    def subscribed(self) -> bool:
        """Google's own public calendars (holidays, sports, birthdays from contacts, week numbers)
        and calendars added by URL."""
        return self.gid.endswith("@group.v.calendar.google.com") or self.gid.endswith("@import.calendar.google.com")

    def background(self, hidden: set[str]) -> bool:
        return self.subscribed or "holiday" in self.title.lower() or "birthday" in self.title.lower() or self.matches(hidden)

    def writable(self, read_only: set[str]) -> bool:
        return self.access in ("owner", "writer") and not self.subscribed and not self.matches(read_only)


class Calendars:
    def __init__(self, api: google.Google, allow_writes: bool = False, now=None):
        self.api = api
        self.allow_writes = allow_writes
        self._now = now
        self._listed: tuple[float, list[Calendar]] | None = None
        self._lock = threading.Lock()

    # ---- time

    @property
    def zone(self) -> tzinfo:
        wanted = settings().get("time_zone")
        if not wanted:
            default = self.default_calendar(quiet=True)
            wanted = default.zone if default else None
        try:
            return ZoneInfo(wanted) if wanted else datetime.now().astimezone().tzinfo
        except Exception:
            return datetime.now().astimezone().tzinfo

    @property
    def zone_name(self) -> str:
        z = self.zone
        return getattr(z, "key", None) or str(z)

    def now(self) -> datetime:
        return (self._now() if self._now else datetime.now(self.zone)).astimezone(self.zone)

    # ---- calendars

    def all(self) -> list[Calendar]:
        with self._lock:
            if self._listed and self._listed[0] > time.time() - LIST_FOR:
                return self._listed[1]
        accounts = google.accounts()
        if not accounts:
            raise ToolError("No Google account is signed in on this server. Run sign_in.py on the server.")
        found = []
        for account in accounts:
            for item in self.api.calendar_list(account):
                if item.get("deleted") or item.get("hidden"):
                    continue
                found.append(Calendar(account=account, gid=item["id"], title=item.get("summaryOverride") or item.get("summary") or item["id"],
                                      color=(item.get("backgroundColor") or "").upper(), access=item.get("accessRole") or "reader",
                                      primary=bool(item.get("primary")), zone=item.get("timeZone")))
        with self._lock:
            self._listed = (time.time(), found)
        return found

    def shown(self) -> list[Calendar]:
        never = names("never_show")
        return [c for c in self.all() if not c.matches(never)]

    def default_calendar(self, quiet: bool = False) -> Calendar | None:
        try:
            shown = self.shown()
        except (ToolError, google.GoogleError):
            if quiet:
                return None
            raise
        wanted = str(settings().get("default_calendar") or "").strip().lower()
        if wanted:
            for c in shown:
                if wanted in (c.title.lower(), c.gid.lower(), c.id.lower()):
                    return c
        return next((c for c in shown if c.primary), None)

    def listing(self) -> list[dict]:
        kept = settings()
        hidden, read_only = names("hide_calendars", kept), names("read_only", kept)
        default = self.default_calendar()
        return [{"id": c.id, "title": c.title, "account": c.account, "allows_changes": c.writable(read_only),
                 "subscribed": c.subscribed, "hidden_from_agenda": c.background(hidden),
                 "is_default": default is not None and c.id == default.id} for c in self.shown()]

    def resolve(self, ids) -> list[Calendar] | None:
        if not ids:
            return None
        wanted = {str(i) for i in ids}
        chosen = [c for c in self.shown() if c.id in wanted or c.gid in wanted or c.title in wanted]
        if not chosen:
            raise ToolError("None of those calendars exist. Use list_calendars for ids.")
        return chosen

    def is_background(self, calendar: Calendar) -> bool:
        return calendar.background(names("hide_calendars"))

    # ---- events

    def events(self, start: datetime, end: datetime, ids=None) -> list[dict]:
        if end <= start:
            raise ToolError("end must be after start")
        if end - start > timedelta(days=MAX_RANGE_DAYS):
            raise ToolError(f"The range can be at most {MAX_RANGE_DAYS} days.")
        calendars = self.resolve(ids) or self.shown()
        if not calendars:
            return []
        lo, hi = dates.string(start, self.zone), dates.string(end, self.zone)

        def one(c: Calendar):
            return [e for e in (self.normalize(item, c) for item in self.api.events(c.account, c.gid, lo, hi)) if e]

        with ThreadPoolExecutor(max_workers=min(8, len(calendars))) as pool:
            found = [e for batch in pool.map(one, calendars) for e in batch]
        # (Google's timeMin/timeMax already overlap the range; an all-day event read in another
        # zone can still poke out, so check again here.)
        return sorted([e for e in found if e["start"] < end and e["end"] > start], key=lambda e: (e["start"], e["title"]))

    def event(self, eid: str) -> dict:
        account, gid, event = split_id(eid)
        calendar = next((c for c in self.shown() if c.account == account and c.gid == gid), None)
        if calendar is None or not event:
            raise ToolError("No event with that id.")
        try:
            found = self.normalize(self.api.event(account, gid, event), calendar)
        except google.GoogleError:
            raise ToolError("No event with that id.")
        if not found:
            raise ToolError("No event with that id.")
        return found

    def normalize(self, item: dict, calendar: Calendar) -> dict | None:
        if item.get("status") == "cancelled":
            return None
        zone = self.zone
        s, e = item.get("start") or {}, item.get("end") or {}
        all_day = "date" in s and "dateTime" not in s
        try:
            if all_day:
                start = dates.midnight(datetime.fromisoformat(s["date"]).date(), zone)
                end = dates.midnight(datetime.fromisoformat(e.get("date") or s["date"]).date(), zone)
                if end <= start:
                    end = dates.add_days(start, 1, zone)
            else:
                start = datetime.fromisoformat(s["dateTime"].replace("Z", "+00:00")).astimezone(zone)
                end = datetime.fromisoformat((e.get("dateTime") or s["dateTime"]).replace("Z", "+00:00")).astimezone(zone)
        except (KeyError, ValueError):
            return None
        me = next((a for a in item.get("attendees") or [] if a.get("self")), None)
        availability = "free" if item.get("transparency") == "transparent" else \
            "tentative" if (me or {}).get("responseStatus") == "tentative" or item.get("status") == "tentative" else "busy"
        return {"id": f"{calendar.account}/{calendar.gid}/{item.get('id', '')}", "title": item.get("summary") or "",
                "start": start, "end": end, "all_day": all_day, "calendar": calendar,
                "location": item.get("location") or "", "notes": item.get("description") or "",
                "attendees": [a for a in item.get("attendees") or [] if not a.get("resource")],
                "organizer": item.get("organizer") or {}, "availability": availability,
                "recurring": bool(item.get("recurringEventId") or item.get("recurrence")),
                "url": item.get("hangoutLink") or ""}

    def create(self, title: str, start: datetime, end: datetime, all_day: bool, calendar_id: str | None,
               location: str | None, notes: str | None) -> tuple[dict, bool]:
        if not self.allow_writes:
            raise ToolError("This server is read-only.")
        shown = self.shown()
        if calendar_id:
            target = next((c for c in shown if calendar_id in (c.id, c.gid)), None) \
                or next((c for c in shown if c.title.lower() == calendar_id.lower()), None)
            if target is None:
                raise ToolError(f"No calendar called {calendar_id}. list_calendars shows the names.")
        else:
            target = self.default_calendar()
            if target is None:
                raise ToolError("No default calendar. Pass calendar_id; list_calendars shows the names.")
        if not target.writable(names("read_only")):
            raise ToolError(f"{target.title} is read-only: nothing can be added to it here. Ask which other calendar to use.")
        zone = self.zone
        near = self.events(start - timedelta(seconds=60), start + timedelta(seconds=60), [target.id])
        existing = next((e for e in near if abs((e["start"] - start).total_seconds()) < 60 and e["title"].lower() == title.lower()), None)
        if existing:
            return existing, True
        if all_day:
            when = {"start": {"date": start.astimezone(zone).date().isoformat()}, "end": {"date": end.astimezone(zone).date().isoformat()}}
        else:
            name = self.zone_name
            when = {"start": {"dateTime": dates.string(start, zone), "timeZone": name},
                    "end": {"dateTime": dates.string(end, zone), "timeZone": name}}
        body = {"summary": title, **when}
        if location:
            body["location"] = location
        if notes:
            body["description"] = notes
        made = self.normalize(self.api.insert(target.account, target.gid, body), target)
        if not made:
            raise ToolError("Google didn't return the new event.")
        return made, False


def split_id(eid: str) -> tuple[str, str, str]:
    parts = (eid or "").split("/", 2)
    return (parts + ["", "", ""])[:3] if len(parts) == 3 else ("", "", "")


# ---- the shapes the tools return (the Mac server's summarize and describe) ------------------------

def plain_text(text: str) -> str:
    """Invites often carry HTML notes. Keep the words and the link targets."""
    if "<" not in text and "&" not in text:
        return text.strip()
    s = re.sub(r"<a\s[^>]*href\s*=\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a>", r"\2 (\1)", text, flags=re.I | re.S)
    s = re.sub(r"<(br|/p|/div|/li|/tr|/h[1-6])\b[^>]*>", "\n", s, flags=re.I)
    s = re.sub(r"<li\b[^>]*>", "- ", s, flags=re.I)
    s = re.sub(r"<[^>]+>", "", s)
    s = html.unescape(s).replace("\xa0", " ")
    s = re.sub(r"(\S+) \(\1\)", r"\1", s)
    s = "\n".join(line.strip() for line in s.split("\n"))
    s = re.sub(r"\n{3,}", "\n\n", s)
    return s.strip()


def summarize(e: dict, zone) -> dict:
    out = {"id": e["id"], "title": e["title"], "start": dates.string(e["start"], zone), "end": dates.string(e["end"], zone),
           "calendar": e["calendar"].title, "color": e["calendar"].color}
    if e["all_day"]:
        out["all_day"] = True
    if e["location"]:
        out["location"] = e["location"][:120]
    if e["attendees"]:
        out["attendees"] = len(e["attendees"])
    if e["availability"] == "free":
        out["availability"] = "free"
    return out


_STATUS = {"accepted": "accepted", "declined": "declined", "tentative": "tentative", "needsAction": "pending"}


def describe(e: dict, zone) -> dict:
    out = {"id": e["id"], "title": e["title"], "start": dates.string(e["start"], zone), "end": dates.string(e["end"], zone),
           "all_day": e["all_day"], "calendar": e["calendar"].title, "color": e["calendar"].color,
           "calendar_id": e["calendar"].id, "recurring": e["recurring"]}
    if e["location"]:
        out["location"] = e["location"]
    if e["url"]:
        out["url"] = e["url"]
    notes = plain_text(e["notes"]) if e["notes"] else ""
    if notes:
        out["notes"] = notes[:MAX_NOTES] + "…" if len(notes) > MAX_NOTES else notes
    organizer = e["organizer"]
    if organizer and not organizer.get("self"):
        out["organizer"] = organizer.get("displayName") or organizer.get("email") or ""
    if e["attendees"]:
        out["attendees"] = [{"name": a.get("displayName") or "", **({"email": a["email"]} if "@" in (a.get("email") or "") else {}),
                             "status": _STATUS.get(a.get("responseStatus") or "", "unknown")} for a in e["attendees"]]
    out["availability"] = {"free": "free", "tentative": "tentative"}.get(e["availability"], "busy")
    return out

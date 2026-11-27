"""Deadlines as they really fall (1.56.0, asked 2026-11-27 "build 4 too", after a r/hermesagent
thread of other agents' nudges: "Thanksgiving moves the cutoff up a banking day", "its renewal
date uses UTC, which starts at 8 p.m. tonight in your current timezone").

- Bank days: a bill due on a day banks are shut (a weekend, a bank holiday) is to be paid by the
  banking day before, and its card says why ("Thursday is Thanksgiving: banks are closed"). Its
  reminder comes a day earlier for each bank holiday between, and its paid-check two banking days
  after its day, when a payment would have posted.
- Time zones: a renewal, trial end or bill whose mail gives a time in another zone ("renews at
  00:00 UTC", "due by 5 PM ET") or the day in one ("December 1 (UTC)": from its start) keeps that
  moment. Its day is the one it falls on here, and its card says the time here and as written.

"Here" is this Hermes's own time zone. Bank holidays are the US Federal Reserve's when that zone is
in the US (by the system's zone.tab); elsewhere only weekends count.
"""
from __future__ import annotations

import functools
import os
import re
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

#: Set by tests (or a lab): the country whose bank holidays count, instead of the zone's.
COUNTRY: str | None = None

_US_ZONES = ("America/New_York", "America/Chicago", "America/Denver", "America/Phoenix", "America/Los_Angeles",
             "America/Anchorage", "America/Detroit", "America/Boise", "America/Juneau", "Pacific/Honolulu")


# ---- bank days ----------------------------------------------------------------------------------

def _zone_name() -> str:
    named = os.environ.get("TZ", "").lstrip(":")
    if "/" in named and not named.startswith("/"):
        return named
    try:
        real = os.path.realpath("/etc/localtime")
        if "zoneinfo/" in real:
            return real.split("zoneinfo/", 1)[1]
    except OSError:
        pass
    try:
        return Path("/etc/timezone").read_text().strip()
    except OSError:
        return ""


@functools.lru_cache(maxsize=1)
def _country_here() -> str:
    name = _zone_name()
    if name.startswith("US/") or name in _US_ZONES or name.startswith(("America/Indiana/", "America/Kentucky/",
                                                                         "America/North_Dakota/")):
        return "US"
    for table in ("/usr/share/zoneinfo/zone1970.tab", "/usr/share/zoneinfo/zone.tab"):
        try:
            lines = Path(table).read_text().splitlines()
        except OSError:
            continue
        for line in lines:
            parts = line.split("\t")
            if len(parts) >= 3 and parts[2] == name:
                return parts[0].split(",")[0]
    return ""


def country() -> str:
    return COUNTRY if COUNTRY is not None else _country_here()


def _nth(year: int, month: int, weekday: int, n: int) -> date:
    """The nth `weekday` (Monday 0) of a month; n -1 is the last."""
    if n > 0:
        first = date(year, month, 1)
        return first + timedelta(days=(weekday - first.weekday()) % 7 + 7 * (n - 1))
    last = (date(year + 1, 1, 1) if month == 12 else date(year, month + 1, 1)) - timedelta(days=1)
    return last - timedelta(days=(last.weekday() - weekday) % 7)


@functools.lru_cache(maxsize=8)
def us_holidays(year: int) -> dict[date, str]:
    """The Federal Reserve's holidays: one on a Sunday is the Monday after; one on a Saturday isn't
    moved (the banks are open the Friday)."""
    days = {date(year, 1, 1): "New Year's Day", _nth(year, 1, 0, 3): "Martin Luther King Jr. Day",
            _nth(year, 2, 0, 3): "Presidents' Day", _nth(year, 5, 0, -1): "Memorial Day", date(year, 6, 19): "Juneteenth",
            date(year, 7, 4): "Independence Day", _nth(year, 9, 0, 1): "Labor Day", _nth(year, 10, 0, 2): "Columbus Day",
            date(year, 11, 11): "Veterans Day", _nth(year, 11, 3, 4): "Thanksgiving", date(year, 12, 25): "Christmas"}
    out = {}
    for day, name in days.items():
        if day.weekday() == 6:
            day += timedelta(days=1)
        elif day.weekday() == 5:
            continue
        out[day] = name
    return out


def holiday(day: date) -> str | None:
    return us_holidays(day.year).get(day) if country() == "US" else None


def closed(day: date) -> str | None:
    """Why banks are shut that day ("Thanksgiving", "Sunday"), or None."""
    if day.weekday() >= 5:
        return day.strftime("%A")
    return holiday(day)


def open_before(day: date) -> date:
    """`day` if banks are open, else the banking day before it."""
    while closed(day):
        day -= timedelta(days=1)
    return day


def banking_after(day: date, n: int) -> date:
    """The nth banking day after `day`."""
    while n > 0:
        day += timedelta(days=1)
        if not closed(day):
            n -= 1
    return day


def holidays_between(start: date, end: date) -> list[tuple[date, str]]:
    """Bank holidays from `start` to `end`, both counted."""
    out, day = [], start
    while day <= end:
        name = holiday(day)
        if name:
            out.append((day, name))
        day += timedelta(days=1)
    return out


def bill_days(due: date, ahead: int, after: int) -> dict:
    """A bill's days: when to pay by, when to remind (`ahead` days before that, a day earlier for
    each bank holiday between), when to check it was paid (`after` banking days after its day),
    and the closure to say."""
    pay_by = open_before(due)
    remind = pay_by - timedelta(days=ahead)
    between = holidays_between(remind, due)
    remind -= timedelta(days=len([d for d, _ in between if d < pay_by]))
    why = None
    if closed(due):
        why = {"day": due.isoformat(), "name": closed(due)}
    elif between:
        why = {"day": between[0][0].isoformat(), "name": between[0][1]}
    return {"pay_by": pay_by, "remind": remind, "verify": banking_after(due, after), "closed": why}


def closed_said(closed_: dict | None, when) -> str:
    """"Thursday is Thanksgiving: banks are closed", "It's due on a Sunday, when banks are closed".
    `when(iso) -> str` says a day ("Thursday", "tomorrow")."""
    if not closed_:
        return ""
    name = closed_["name"]
    if name in ("Saturday", "Sunday"):
        return f"It's due on a {name}, when banks are closed"
    return f"{when(closed_['day']).capitalize()} is {name}: banks are closed"


# ---- time zones ---------------------------------------------------------------------------------

_CLOCK = (r"(?:(?P<h>1[0-2]|0?[1-9])(?::(?P<m>[0-5]\d))?\s*(?P<ap>[aApP])\.?\s?[mM]\b\.?|(?P<h24>[01]?\d|2[0-3]):(?P<m24>[0-5]\d)"
          r"|(?P<word>(?i:midnight|noon)))")
_ZONE = (r"\(?(?P<zone>UTC|GMT|E[SD]?T|C[SD]?T|M[SD]?T|P[SD]?T|BST|CES?T|AE[SD]T|"
         r"(?i:eastern|central|mountain|pacific)(?:\s+(?i:standard|daylight))?\s+(?i:time))\)?")
_CLOCKED = re.compile(_CLOCK + r"\s*" + _ZONE)
_BARE = re.compile(r"^[\s,]*\(?(?P<zone>UTC|GMT)\b\)?")
_NAMED = {"UTC": "UTC", "GMT": "UTC", "ET": "America/New_York", "EST": "America/New_York", "EDT": "America/New_York",
          "CT": "America/Chicago", "CST": "America/Chicago", "CDT": "America/Chicago", "MT": "America/Denver",
          "MST": "America/Denver", "MDT": "America/Denver", "PT": "America/Los_Angeles", "PST": "America/Los_Angeles",
          "PDT": "America/Los_Angeles", "BST": "Europe/London", "CET": "Europe/Paris", "CEST": "Europe/Paris",
          "AEST": "Australia/Sydney", "AEDT": "Australia/Sydney", "EASTERN": "America/New_York",
          "CENTRAL": "America/Chicago", "MOUNTAIN": "America/Denver", "PACIFIC": "America/Los_Angeles"}


def _tz(zone: str):
    key = zone.upper().split()[0]
    name = _NAMED.get(key)
    if name == "UTC" or not name:
        return timezone.utc
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(name)
    except Exception:
        return None


def _short(zone: str) -> str:
    """How a zone is said back: "UTC", "PT", "Eastern Time"."""
    return "UTC" if zone.upper() == "GMT" else re.sub(r"\s+", " ", zone.strip())


def zoned(body: str, words: re.Pattern, day: date, ref: date) -> dict | None:
    """The moment of a deadline written in another zone, after one of `words` and the date it found
    ("renews on December 1 at 00:00 UTC", "December 1 (UTC)"): {"at", "said"}. None when it gives no
    zone, or the zone is this Hermes's own at that moment."""
    from . import dates
    for hit in words.finditer(body or ""):
        rest = body[hit.end(): hit.end() + 60]
        found = dates.PHRASE.search(rest)
        if not found or dates.read(found, ref) != day:
            continue
        span = body[hit.end(): hit.end() + found.end() + 50]
        clock = _CLOCKED.search(span)
        if clock:
            if clock.group("word"):
                hour, minute = (0, 0) if clock.group("word").lower() == "midnight" else (12, 0)
                written = clock.group("word").lower()
            elif clock.group("h24") is not None:
                hour, minute = int(clock.group("h24")), int(clock.group("m24"))
                written = "midnight" if (hour, minute) == (0, 0) else f"{hour:02d}:{minute:02d}"
            else:
                hour = int(clock.group("h")) % 12 + (12 if clock.group("ap").lower() == "p" else 0)
                minute = int(clock.group("m") or 0)
                written = f"{int(clock.group('h'))}{':' + clock.group('m') if clock.group('m') else ''} " \
                          f"{'PM' if clock.group('ap').lower() == 'p' else 'AM'}"
            zone = clock.group("zone")
        else:
            bare = _BARE.search(body[hit.end() + found.end(): hit.end() + found.end() + 12])
            if not bare:
                continue
            hour = minute = 0
            zone, written = bare.group("zone"), None
        tz = _tz(zone)
        if tz is None:
            return None
        moment = datetime(day.year, day.month, day.day, hour, minute, tzinfo=tz)
        if moment.utcoffset() == datetime.fromtimestamp(moment.timestamp()).astimezone().utcoffset():
            return None               # written in their own zone: nothing to move
        said = f"{written} {_short(zone)}" if written else f"{day.strftime('%B %-d')} in {_short(zone)}"
        return {"at": moment.timestamp(), "said": said, "from_start": written is None}
    return None


def at_said(at: float, when) -> str:
    """"7 PM tonight", "7 PM Monday": a moment as it falls here. `when(iso)` says its day."""
    moment = datetime.fromtimestamp(at)
    clock = moment.strftime("%-I:%M %p").replace(":00 ", " ")
    day = when(moment.date().isoformat())
    if day == "today":
        day = "tonight" if moment.hour >= 17 else "today"
    return f"{clock} {day}"

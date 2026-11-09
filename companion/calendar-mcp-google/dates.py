"""Dates in and out, the way the Mac calendar server reads and writes them (its Support.swift), so
an agent's calls work the same against either server.

In: "2026-09-15", "2026-09-15T14:30", "2026-09-15 14:30", "2026-09-15T14:30:00", with or without
seconds, fractions and an offset; no offset means the calendar's time zone. Day words: today,
tomorrow, yesterday, a weekday name (its next occurrence, today included), this/next/coming/last
<weekday>, this week / next week (their Monday), in N days.

Out: ISO 8601 with the offset, to the second ("2026-09-15T14:30:00-04:00").
"""

from __future__ import annotations

import re
from datetime import date, datetime, time, timedelta, tzinfo

WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
_SHAPE = re.compile(r"^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?$")


def midnight(day: date, zone: tzinfo) -> datetime:
    return datetime.combine(day, time(), zone)


def start_of(moment: datetime, zone: tzinfo) -> datetime:
    return midnight(moment.astimezone(zone).date(), zone)


def add_days(moment: datetime, days: int, zone: tzinfo) -> datetime:
    """Calendar days, kept at the same wall-clock time (a day over a clock change is 23 or 25 hours)."""
    local = moment.astimezone(zone)
    return datetime.combine(local.date() + timedelta(days=days), local.timetz().replace(tzinfo=None), zone)


def parse(text: str, zone: tzinfo) -> datetime | None:
    s = (text or "").strip()
    if not _SHAPE.match(s):
        return None
    try:
        found = datetime.fromisoformat(s.replace("Z", "+00:00") if s.endswith("Z") else s)
    except ValueError:
        return None
    if found.tzinfo is None:
        found = found.replace(tzinfo=zone)
    return found


def string(moment: datetime, zone: tzinfo) -> str:
    return moment.astimezone(zone).replace(microsecond=0).isoformat()


def is_date_only(text: str) -> bool:
    return len((text or "").strip()) == 10


def _sw(day: date) -> int:
    """Sunday 0 … Saturday 6, as the weekday names are listed."""
    return (day.weekday() + 1) % 7


def start_of_day(text: str, zone: tzinfo, now: datetime | None = None) -> datetime | None:
    now = (now or datetime.now(zone)).astimezone(zone)
    today = now.date()
    word = (text or "").strip().lower()
    if word == "today":
        return midnight(today, zone)
    if word == "tomorrow":
        return midnight(today + timedelta(days=1), zone)
    if word == "yesterday":
        return midnight(today - timedelta(days=1), zone)
    if word in WEEKDAYS:
        ahead = (WEEKDAYS.index(word) - _sw(today)) % 7
        return midnight(today + timedelta(days=ahead), zone)
    parts = word.split()
    # "this friday" is its next occurrence; "next friday" is the one after this week's.
    if len(parts) == 2 and parts[0] in ("this", "next", "coming", "last") and parts[1] in WEEKDAYS:
        ahead = (WEEKDAYS.index(parts[1]) - _sw(today)) % 7
        if parts[0] == "next":
            upcoming = today + timedelta(days=ahead or 7)
            # (Weeks start on Sunday, as the Mac's US calendar has them.)
            same_week = upcoming - timedelta(days=_sw(upcoming)) == today - timedelta(days=_sw(today))
            return midnight(upcoming + timedelta(days=7 if same_week else 0), zone)
        if parts[0] == "last":
            return midnight(today + timedelta(days=-7 if ahead == 0 else ahead - 7), zone)
        return midnight(today + timedelta(days=ahead), zone)
    if len(parts) == 2 and parts[0] in ("next", "this") and parts[1] == "week":
        monday = today - timedelta(days=today.weekday())
        return midnight(monday + timedelta(days=7 if parts[0] == "next" else 0), zone)
    if len(parts) == 3 and parts[0] == "in" and parts[2] in ("day", "days"):
        try:
            return midnight(today + timedelta(days=int(parts[1])), zone)
        except ValueError:
            return None
    found = parse(text, zone)
    return start_of(found, zone) if found else None


def is_day_word(text: str, zone: tzinfo) -> bool:
    word = (text or "").strip().lower()
    return (word in ("today", "tomorrow", "yesterday") or word in WEEKDAYS or is_date_only(text)
            or (not is_date_only(text) and parse(text, zone) is None and start_of_day(text, zone) is not None))


def moment(text: str, zone: tzinfo, now: datetime | None = None) -> datetime | None:
    """A full date-time, a day word, or a day word then a time ("tomorrow 14:00", "next friday 9:30")."""
    found = parse(text, zone) or start_of_day(text, zone, now)
    if found:
        return found
    words = (text or "").strip().split()
    if len(words) < 2:
        return None
    day = start_of_day(" ".join(words[:-1]), zone, now)
    clock = words[-1].split(":")
    if not day or len(clock) != 2 or not all(c.isdigit() for c in clock):
        return None
    hour, minute = int(clock[0]), int(clock[1])
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        return None
    return datetime.combine(day.date(), time(hour, minute), zone)


def day_string(moment: datetime, zone: tzinfo) -> str:
    return moment.astimezone(zone).strftime("%Y-%m-%d")


def weekday_name(moment: datetime, zone: tzinfo) -> str:
    return WEEKDAYS[_sw(moment.astimezone(zone).date())].capitalize()


def clock(moment: datetime, zone: tzinfo) -> str:
    return moment.astimezone(zone).strftime("%H:%M")

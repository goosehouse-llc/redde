"""Dates as people and shops write them, in English (1.39.0, for follow-through): "by Friday",
"tomorrow", "end of the week", "Arriving Thursday, November 26", "return by Dec 15, 2026",
"12/15", "2026-12-15". Read against the day the words were written, so "Friday" in Tuesday's mail
is that week's Friday. No model: what isn't plainly a date isn't one.
"""
from __future__ import annotations

import re
from datetime import date, timedelta

_DAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
_DAY = r"(?:mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\.?"
_MONTHS = ("january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
           "november", "december")
_MONTH = r"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?"

#: Every date phrase, longest first: one regex, so a finder can ask what follows a word.
PHRASE = re.compile(
    r"(?P<iso>\b20\d\d-[01]\d-[0-3]\d\b)"
    rf"|(?:{_DAY},?\s+)?(?P<md>\b{_MONTH}\s+[0-3]?\d(?:st|nd|rd|th)?\b(?:,?\s+20\d\d\b)?)"
    rf"|(?:{_DAY},?\s+)?(?P<dm>\b[0-3]?\d(?:st|nd|rd|th)?\s+(?:of\s+)?{_MONTH}(?:,?\s+20\d\d\b)?)"
    r"|(?P<num>\b[01]?\d/[0-3]?\d(?:/(?:20)?\d\d)?\b)"
    r"|(?P<rel>\b(?:today|tonight|tomorrow|end of (?:the )?day|eod|end of (?:the )?week|eow|this week|next week)\b)"
    rf"|(?P<day>\b(?:next\s+|this\s+)?{_DAY}(?:\s+(?:night|evening|morning|afternoon))?\b)",
    re.IGNORECASE)


def _month(word: str) -> int:
    word = word.lower().rstrip(".")[:3]
    return next(n for n, m in enumerate(_MONTHS, 1) if m.startswith(word))


def _weekday(word: str) -> int:
    word = word.lower().rstrip(".")[:3]
    return next(n for n, d in enumerate(_DAYS) if d.startswith(word))


def _year_for(month: int, day: int, ref: date) -> date | None:
    """A month and day with no year: this year's, or next year's once this year's is well past."""
    for year in (ref.year, ref.year + 1):
        try:
            found = date(year, month, day)
        except ValueError:
            return None
        if found >= ref - timedelta(days=30):
            return found
    return None


def read(match: re.Match, ref: date) -> date | None:
    """The date one PHRASE match names, written on `ref`."""
    text = match.group(0).strip().lower()
    if match.group("iso"):
        try:
            return date.fromisoformat(match.group("iso"))
        except ValueError:
            return None
    for key in ("md", "dm"):
        if match.group(key):
            words = re.findall(r"[a-z]+|\d+", match.group(key).lower())
            month = next(_month(w) for w in words if w.isalpha() and w not in ("of", "st", "nd", "rd", "th"))
            numbers = [int(w) for w in words if w.isdigit()]
            day, year = numbers[0], (numbers[1] if len(numbers) > 1 else None)
            if year:
                try:
                    return date(year, month, day)
                except ValueError:
                    return None
            return _year_for(month, day, ref)
    if match.group("num"):
        parts = [int(p) for p in match.group("num").split("/")]
        if len(parts) == 3:
            year = parts[2] + (2000 if parts[2] < 100 else 0)
            try:
                return date(year, parts[0], parts[1])
            except ValueError:
                return None
        return _year_for(parts[0], parts[1], ref) if 1 <= parts[0] <= 12 else None
    if match.group("rel"):
        if text in ("today", "tonight", "eod") or text.startswith("end of") and text.endswith("day"):
            return ref
        if text == "tomorrow":
            return ref + timedelta(days=1)
        if text in ("eow", "this week") or text.startswith("end of"):
            return ref + timedelta(days=(4 - ref.weekday()) % 7)        # Friday
        if text == "next week":
            return ref + timedelta(days=7 - ref.weekday())               # Monday
    if match.group("day"):
        words = text.split()
        ahead = (_weekday(words[-1] if words[-1] not in ("night", "evening", "morning", "afternoon") else words[-2])
                 - ref.weekday()) % 7
        if words[0] == "next" and ahead == 0:
            ahead = 7
        return ref + timedelta(days=ahead)
    return None


def after(text: str, words: re.Pattern, ref: date, within: int = 60, numeric: bool = True) -> date | None:
    """The first date written within `within` characters after one of `words` ("arriving", "return
    by"), or None. `numeric` False passes over "12/27" (a card's expiry month, read as a day)."""
    for hit in words.finditer(text):
        rest = text[hit.end(): hit.end() + within]
        found = PHRASE.search(rest)
        if found and not numeric and found.group("num"):
            continue
        if found and not re.search(r"[.;!?]\s", rest[: found.start()]):
            when = read(found, ref)
            if when:
                return when
    return None


def first(text: str, ref: date) -> date | None:
    found = PHRASE.search(text)
    return read(found, ref) if found else None


_TIME = re.compile(r"\b([01]?\d|2[0-3])(?::([0-5]\d))?\s*([ap])\.?\s?m\b\.?|\b([01]?\d|2[0-3]):([0-5]\d)\b", re.IGNORECASE)


def time_in(text: str) -> tuple[int, int] | None:
    """The first time of day written ("10am", "7:05 PM", "14:30"), as (hour, minute)."""
    found = _TIME.search(text or "")
    if not found:
        return None
    if found.group(1):
        hour, minute = int(found.group(1)) % 12, int(found.group(2) or 0)
        return (hour + (12 if found.group(3).lower() == "p" else 0), minute)
    return int(found.group(4)), int(found.group(5))

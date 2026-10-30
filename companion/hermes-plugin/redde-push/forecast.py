"""The weather and the time for a place, looked up for `redde_show` (cards.py).

Agents guessed the weather, or read it from a search result hours old (2026-10-23: 66°F said at
5 pm while Orlando was at 75°F), and their clocks can sit in another time zone. So a weather or a
time card names only the place, and this finds it: Open-Meteo's place search (coordinates, time
zone, country) and its forecast, free and without a key (open-meteo.com; data under CC BY 4.0,
credited on the card). What the agent says and what the card shows are then the same numbers.

The card it returns is in the app's format (Echo/Models/ReplyCards.swift in the Redde
repository). `fetch_json` is the one way out to the network, swapped in tests.
"""

from __future__ import annotations

import json
import math
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

SOURCE = "Open-Meteo.com"
GEOCODE = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST = "https://api.open-meteo.com/v1/forecast"
TIMEOUT = 6
HOURS = 12
DAYS = 7
KEEP = 600          # a place's forecast is kept ten minutes: an agent that calls twice gets the same numbers

# Countries that read temperatures in °F.
FAHRENHEIT = {"US", "LR", "MM", "BS", "BZ", "KY", "PW", "FM", "MH", "PR", "GU", "VI", "AS", "MP"}

US_STATES = {
    "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
    "CT": "Connecticut", "DE": "Delaware", "DC": "District of Columbia", "FL": "Florida", "GA": "Georgia",
    "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
    "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts",
    "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri", "MT": "Montana",
    "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico",
    "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
    "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota",
    "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington",
    "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
}

_kept: dict[tuple, tuple[float, object]] = {}


def fetch_json(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "redde-push (github.com/goosehouse-llc/redde)"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.loads(response.read().decode("utf-8"))


def _remembered(key, make):
    hit = _kept.get(key)
    if hit and time.time() - hit[0] < KEEP:
        return hit[1]
    value = make()
    _kept[key] = (time.time(), value)
    return value


# ---- where

def _search(name: str) -> list[dict]:
    query = urllib.parse.urlencode({"name": name, "count": 10, "language": "en", "format": "json"})
    return fetch_json(f"{GEOCODE}?{query}").get("results") or []


def _matches(result: dict, hint: str) -> bool:
    hint = hint.strip().lower()
    if not hint:
        return True
    names = {str(result.get(k) or "").lower() for k in ("admin1", "admin2", "country", "country_code")}
    state = US_STATES.get(hint.upper())
    return hint in names or (state is not None and state.lower() in names)


def find(place: str) -> dict | None:
    """The place as Open-Meteo knows it: name, admin1, country_code, latitude, longitude, timezone.
    "Orlando, FL", "Orlando FL", "Lisbon": the search takes a bare name, so a state or a country
    after it is matched against what comes back."""
    place = " ".join(place.split())
    if not place:
        return None

    def look():
        parts = [p.strip() for p in place.split(",") if p.strip()]
        tries = [(parts[0], parts[1:])] if len(parts) > 1 else []
        tries.append((place, []))
        words = parts[0].split() if parts else []
        for cut in range(len(words) - 1, 0, -1):    # "Orlando FL": "Orlando" and "FL"
            tries.append((" ".join(words[:cut]), [" ".join(words[cut:])] + parts[1:]))
        for name, hints in tries:
            for result in _search(name):
                if all(_matches(result, h) for h in hints):
                    return result
        return None

    return _remembered(("find", place.lower()), look)


def label(found: dict) -> str:
    """"Orlando, Florida", "Lisbon, Portugal"."""
    second = found.get("admin1") if found.get("country_code") == "US" else found.get("country")
    return ", ".join(p for p in (found.get("name"), second) if p)


def units_for(found: dict | None, given: str | None, preferred: str | None) -> str:
    for units in (given, preferred):
        if isinstance(units, str) and units.upper()[:1] in ("C", "F"):
            return units.upper()[:1]
    return "F" if found and found.get("country_code") in FAHRENHEIT else "C"


# ---- the weather

def condition(code) -> str:
    """WMO weather code → the card's condition."""
    code = int(code) if isinstance(code, (int, float)) else -1
    if code in (0, 1): return "clear"
    if code == 2: return "partly_cloudy"
    if code == 3: return "cloudy"
    if code in (45, 48): return "fog"
    if code in (51, 53, 55): return "drizzle"
    if code in (56, 57, 66, 67): return "sleet"
    if code in (61, 63, 80, 81): return "rain"
    if code in (65, 82): return "heavy_rain"
    if code in (71, 73, 75, 77, 85, 86): return "snow"
    if code in (95, 96, 99): return "thunderstorm"
    return "cloudy"


def _compass(degrees) -> str:
    if not isinstance(degrees, (int, float)):
        return ""
    return ("N", "NE", "E", "SE", "S", "SW", "W", "NW")[int((degrees % 360) / 45 + 0.5) % 8]


def _whole(value) -> int:
    """Rounded as the app rounds (half up: 74.5 is 75), so the agent says what the card shows."""
    return int(math.floor(value + 0.5))


def _at(values, i):
    return values[i] if isinstance(values, list) and i < len(values) else None


def weather_card(place: str, latitude: float, longitude: float, units: str) -> dict:
    """The card for a place: now, the next 12 hours and 7 days, in the app's format."""
    def look():
        query = urllib.parse.urlencode({
            "latitude": round(latitude, 3), "longitude": round(longitude, 3),
            "current": "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,is_day",
            "hourly": "temperature_2m,weather_code,precipitation_probability,is_day,wind_gusts_10m",
            "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
            "temperature_unit": "fahrenheit" if units == "F" else "celsius",
            "wind_speed_unit": "mph" if units == "F" else "kmh",
            "timezone": "auto", "forecast_days": DAYS, "forecast_hours": HOURS})
        return fetch_json(f"{FORECAST}?{query}")
    data = _remembered(("weather", round(latitude, 3), round(longitude, 3), units), look)
    return card_from(data, place, units)


def card_from(data: dict, place: str, units: str) -> dict:
    now, hourly, daily = data.get("current") or {}, data.get("hourly") or {}, data.get("daily") or {}
    if not isinstance(now.get("temperature_2m"), (int, float)):
        raise ValueError("the forecast had no reading")
    speed, wind = now.get("wind_speed_10m"), ""
    if isinstance(speed, (int, float)):
        wind = f"{_whole(speed)} {'mph' if units == 'F' else 'km/h'} {_compass(now.get('wind_direction_10m'))}".strip()
    reading = {"temperature": round(now["temperature_2m"], 1), "condition": condition(now.get("weather_code")),
               "night": now.get("is_day") == 0}
    if isinstance(now.get("apparent_temperature"), (int, float)):
        reading["feels_like"] = round(now["apparent_temperature"], 1)
    if isinstance(now.get("relative_humidity_2m"), (int, float)):
        reading["humidity"] = round(now["relative_humidity_2m"])
    if wind:
        reading["wind"] = wind
    if isinstance(_at(daily.get("temperature_2m_max"), 0), (int, float)):
        reading["high"] = round(daily["temperature_2m_max"][0], 1)
    if isinstance(_at(daily.get("temperature_2m_min"), 0), (int, float)):
        reading["low"] = round(daily["temperature_2m_min"][0], 1)
    if isinstance(_at(hourly.get("precipitation_probability"), 0), (int, float)):
        reading["precipitation"] = round(hourly["precipitation_probability"][0])
    hours = []
    for i, at in enumerate((hourly.get("time") or [])[:HOURS]):
        temperature = _at(hourly.get("temperature_2m"), i)
        if not isinstance(temperature, (int, float)):
            continue
        hour = {"time": at, "temperature": round(temperature, 1), "condition": condition(_at(hourly.get("weather_code"), i)),
                "night": _at(hourly.get("is_day"), i) == 0}
        chance = _at(hourly.get("precipitation_probability"), i)
        if isinstance(chance, (int, float)):
            hour["precipitation"] = round(chance)
        gusts = _at(hourly.get("wind_gusts_10m"), i)
        if isinstance(gusts, (int, float)):
            hour["gusts"] = round(gusts)
        hours.append(hour)
    days = []
    for i, date in enumerate((daily.get("time") or [])[:DAYS]):
        high, low = _at(daily.get("temperature_2m_max"), i), _at(daily.get("temperature_2m_min"), i)
        if not isinstance(high, (int, float)) or not isinstance(low, (int, float)):
            continue
        day = {"date": date, "high": round(high, 1), "low": round(low, 1), "condition": condition(_at(daily.get("weather_code"), i))}
        chance = _at(daily.get("precipitation_probability_max"), i)
        if isinstance(chance, (int, float)):
            day["precipitation"] = round(chance)
        days.append(day)
    card = {"type": "weather", "place": place, "units": units, "now": reading, "hours": hours, "days": days, "source": SOURCE}
    updated = _stamp(now.get("time"), data.get("utc_offset_seconds"))
    if updated:
        card["updated"] = updated
    return card


def _stamp(at, offset) -> str | None:
    """The reading's time ("2026-10-23T17:45", the place's) with its offset: "2026-10-23T17:45:00-04:00"."""
    if not isinstance(at, str) or len(at) != 16 or not isinstance(offset, (int, float)):
        return None
    minutes = int(offset) // 60
    sign = "-" if minutes < 0 else "+"
    return f"{at}:00{sign}{abs(minutes) // 60:02d}:{abs(minutes) % 60:02d}"


LIKELY = 50     # an hour's chance of rain that counts, as the app's callout counts it


def spell(card: dict) -> dict | None:
    """Rain (or storms, or snow) likely in the hours ahead, as the app's callout reads it
    (2026-10-30): the first run of hours at 50 % or more, and its likeliest hour."""
    hours = (card.get("hours") or [])[:HOURS]
    first = next((i for i, h in enumerate(hours) if (h.get("precipitation") or 0) >= LIKELY), None)
    if first is None:
        return None
    last = first
    while last + 1 < len(hours) and (hours[last + 1].get("precipitation") or 0) >= LIKELY:
        last += 1
    run = hours[first:last + 1]
    peak = max(run, key=lambda h: h.get("precipitation") or 0)
    kinds = {h.get("condition") for h in run}
    kind = "storms" if "thunderstorm" in kinds else "snow" if kinds & {"snow", "sleet", "hail"} else "rain"
    gusts = [h["gusts"] for h in run if isinstance(h.get("gusts"), (int, float))]
    return {"kind": kind, "from": run[0]["time"], "to": None if last == len(hours) - 1 else run[-1]["time"],
            "peak": peak["time"], "chance": peak.get("precipitation") or 0, "gusts": max(gusts) if gusts else None}


def said(card: dict) -> str:
    """The card in a line, for the agent to answer from."""
    u, now = card.get("units", ""), card.get("now") or {}

    def deg(v):
        return f"{_whole(v)}°{u}"
    bits = [f"now {deg(now['temperature'])} {now['condition'].replace('_', ' ')}{' (night)' if now.get('night') else ''}"]
    if "feels_like" in now:
        bits.append(f"feels like {deg(now['feels_like'])}")
    if "high" in now and "low" in now:
        bits.append(f"today high {deg(now['high'])}, low {deg(now['low'])}")
    if "precipitation" in now:
        bits.append(f"rain chance {now['precipitation']}% this hour")
    if "humidity" in now:
        bits.append(f"humidity {now['humidity']}%")
    if "wind" in now:
        bits.append(f"wind {now['wind']}")
    coming = spell(card)
    if coming:
        # Said as the card's callout says it, so the agent's words and the card agree.
        def clock(at, later=0):
            try:
                return f"{datetime.fromisoformat(at) + timedelta(hours=later):%H:%M}"
            except (TypeError, ValueError):
                return str(at)
        when = f"{clock(coming['from'])}–{clock(coming['to'], 1)}" if coming["to"] else f"from {clock(coming['from'])}"
        line = f"{coming['kind']} likely {when}, likeliest {coming['chance']}% at {clock(coming['peak'])}"
        if coming["gusts"] is not None:
            line += f", gusts to {_whole(coming['gusts'])} {'mph' if u == 'F' else 'km/h'}"
        bits.append(line)
    days = card.get("days") or []
    if len(days) > 1:
        tomorrow = days[1]
        bits.append(f"tomorrow {deg(tomorrow['high'])}/{deg(tomorrow['low'])} {tomorrow['condition'].replace('_', ' ')}"
                    + (f", rain {tomorrow['precipitation']}%" if tomorrow.get("precipitation") else ""))
    return f"{card['place']}: " + "; ".join(bits)


# ---- the time

def zone(name: str | None) -> ZoneInfo | None:
    try:
        return ZoneInfo(name) if isinstance(name, str) and name.strip() else None
    except Exception:
        return None


def time_said(place: str | None, tz: ZoneInfo, at: datetime | None = None) -> str:
    """"Lisbon, Portugal: 22:45 (10:45 PM), Thursday 23 October 2026, WEST (UTC+01:00)"."""
    local = (at or datetime.now(timezone.utc)).astimezone(tz)
    offset = local.strftime("%z")
    offset = f"UTC{offset[:3]}:{offset[3:]}" if offset else "UTC"
    clock = f"{local:%H:%M} ({local.strftime('%I:%M %p').lstrip('0')})"
    return f"{place or 'The person’s time'}: {clock}, {local:%A} {local.day} {local:%B %Y}, {local.tzname()} ({offset})"

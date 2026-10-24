"""Cards in Redde: a map, a list of places, the weather, the time, drawn by the app under the agent's reply.

The agent calls `redde_show` with the cards. Nothing travels to the phone: the app reads the call
from the conversation, live and when it is read back, on either connection, and draws the cards
itself (MapKit for maps and places, looked up on the phone when a place comes without
coordinates). This tool checks them, so the agent hears at once about a card that can't be drawn.

A weather or a time card names only its place: the forecast and the time zone are looked up here
(forecast.py, Open-Meteo), handed back to the agent to answer from, and returned as filled cards
(`cards` in the answer), which the app draws when it can read them (else it looks them up itself).

Offered unless the phone turned cards off (`/redde-push cards off`, Redde's Settings): its
description is in every prompt. The format must match what the app reads
(Echo/Models/ReplyCards.swift in the Redde repository).
"""

from __future__ import annotations

import json
import time
from datetime import datetime
from pathlib import Path

from . import forecast

TOOL = "redde_show"
TOOLSET = "redde_cards"
MAX_CARDS = 4
MAX_PLACES = 12
TYPES = ("map", "places", "weather", "time")
MODES = ("driving", "walking", "transit", "cycling")

_PLACE = {
    "type": "object",
    "properties": {
        "name": {"type": "string"},
        "address": {"type": "string"},
        "latitude": {"type": "number"},
        "longitude": {"type": "number"},
        "category": {"type": "string", "description": "e.g. Café"},
        "rating": {"type": "number", "description": "out of 5"},
        "note": {"type": "string", "description": "one line worth knowing"},
        "phone": {"type": "string"},
        "url": {"type": "string"},
    },
    "required": ["name"],
}

SCHEMA = {
    "name": TOOL,
    "description": (
        "Shows cards under your reply in the Redde app: a map (places as pins, or a route), a list of places, the "
        "weather, or the time. Use it when the person asks where something is, for directions, for places nearby, "
        "for the weather or what time it is. Weather and time look themselves up: give just the 'place' (a city, "
        "e.g. 'Orlando, FL'; for the time, leave it out to mean the person's own), call this before you answer, and "
        "answer from what it returns ('said'), never from memory or a guess: your own clock may be in another time "
        "zone. For a map or places, give what you found (from search or your other tools): coordinates when you "
        "have them, a name and street address otherwise, the phone looks them up. Up to 4 cards. Then answer in a "
        "sentence or two: the cards are on the person's screen, so don't read out everything in them."),
    "parameters": {
        "type": "object",
        "properties": {
            "cards": {
                "type": "array",
                "maxItems": MAX_CARDS,
                "items": {
                    "type": "object",
                    "properties": {
                        "type": {"type": "string", "enum": list(TYPES)},
                        "title": {"type": "string"},
                        "places": {"type": "array", "items": _PLACE, "description": "map: its pins; places: the list"},
                        "route": {
                            "type": "object",
                            "description": "map only: from a place (or omit 'from' for where the person is) to a place",
                            "properties": {"from": _PLACE, "to": _PLACE, "mode": {"type": "string", "enum": list(MODES)}},
                            "required": ["to"],
                        },
                        "place": {"type": "string", "description": "weather and time: where, e.g. Lisbon, or Orlando, FL"},
                        "timezone": {"type": "string", "description": "time: an IANA zone, e.g. Europe/Lisbon, if you know it"},
                        "units": {"type": "string", "enum": ["C", "F"], "description": "weather: if the person said"},
                    },
                    "required": ["type"],
                },
            },
        },
        "required": ["cards"],
    },
}


def _number(value) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip().rstrip("°%CFcf ").strip())
        except ValueError:
            return None
    return None


def _place(value) -> str | None:
    """A place's name, if the place can be drawn: a name, at least."""
    if isinstance(value, str) and value.strip():
        return value.strip()
    if isinstance(value, dict):
        name = value.get("name") or value.get("title")
        if isinstance(name, str) and name.strip():
            return name.strip()
    return None


def check(args) -> tuple[list[str], list[str]]:
    """What each card will show, in a few words, and what can't be drawn. Lenient as the app is."""
    cards = args.get("cards") if isinstance(args, dict) else None
    if isinstance(args, dict) and cards is None and args.get("type"):
        cards = [args]
    if not isinstance(cards, list) or not cards:
        return [], ["give 'cards': a list of one to four cards"]
    shown, problems = [], []
    for n, card in enumerate(cards[:MAX_CARDS], 1):
        kind = str(card.get("type") or "").lower() if isinstance(card, dict) else ""
        if kind not in TYPES:
            problems.append(f"card {n}: 'type' must be map, places, weather or time")
            continue
        if kind == "map":
            pins = [p for p in (_place(p) for p in card.get("places") or []) if p]
            route = card.get("route") if isinstance(card.get("route"), dict) else None
            to = _place(route.get("to")) if route else None
            if not pins and not to:
                problems.append(f"card {n}: a map needs 'places' with names, or a 'route' with 'to'")
                continue
            mode = str((route or {}).get("mode") or "driving").lower()
            shown.append(f"map: {('route to ' + to + ' (' + (mode if mode in MODES else 'driving') + ')') if to else ', '.join(pins[:4])}")
        elif kind == "places":
            names = [p for p in (_place(p) for p in (card.get("places") or [])[:MAX_PLACES]) if p]
            if not names:
                problems.append(f"card {n}: a places card needs 'places', each with a 'name'")
                continue
            shown.append(f"places: {len(names)} ({', '.join(names[:3])}{'…' if len(names) > 3 else ''})")
        elif kind == "time":
            place = card.get("place")
            shown.append(f"time: {place.strip() if isinstance(place, str) and place.strip() else 'the person’s own'}")
        else:
            place = card.get("place") or card.get("location")
            now = card.get("now") if isinstance(card.get("now"), dict) else None
            # A reading names its condition: a temperature with none (a 0 and "", 2026-10-23, where the
            # reply said 85°F and clear) is a placeholder, sent back to be filled in.
            def named(r): return bool(str(r.get("condition") or "").strip())
            has_now = now is not None and _number(now.get("temperature")) is not None and named(now)
            if now is not None and not has_now:
                problems.append(f"card {n}: 'now' needs the temperature and the condition you read from the forecast, "
                                "not a placeholder such as 0; it was left out")
            # Exactly 0 and nothing else read with it is a placeholder too (seen 2026-10-23: the agent sent
            # 0 and "clear" without looking the weather up, as if the card would). A forecast's real 0
            # comes with its other numbers.
            bare_zero = has_now and _number(now.get("temperature")) == 0 and not any(
                now.get(k) not in (None, "") for k in ("high", "low", "feels_like", "humidity", "wind", "precipitation", "summary"))
            if bare_zero and not card.get("hours") and not card.get("days"):
                has_now = False
                problems.append(f"card {n}: a temperature of exactly 0 with nothing else looks like a placeholder. This tool "
                                "shows the numbers you give it and looks nothing up: get the forecast first and send what it "
                                "says (a real 0 comes with its high and low, or feels_like)")
            hours = [h for h in card.get("hours") or [] if isinstance(h, dict) and _number(h.get("temperature")) is not None
                     and h.get("time") and named(h)]
            days = [d for d in card.get("days") or [] if isinstance(d, dict) and _number(d.get("high")) is not None
                    and _number(d.get("low")) is not None and (d.get("date") or d.get("day")) and named(d)]
            if not (isinstance(place, str) and place.strip()):
                problems.append(f"card {n}: the weather needs 'place'")
                continue
            if not (has_now or hours or days):
                problems.append(f"card {n}: no forecast for it, so no card")
                continue
            # The reading said back, so a wrong number can be seen and sent again.
            said_now = f"now {_number(now.get('temperature')):g}°{card.get('units') or ''} {now.get('condition')}" if has_now else ""
            parts = [p for p in (said_now, f"{len(hours)} hours" if hours else "", f"{len(days)} days" if days else "") if p]
            shown.append(f"weather: {place.strip()} ({', '.join(parts)})")
    if len(cards) > MAX_CARDS:
        problems.append(f"only the first {MAX_CARDS} cards are shown")
    return shown, problems


def _listed(args):
    cards = args.get("cards") if isinstance(args, dict) else None
    if isinstance(args, dict) and cards is None and args.get("type"):
        cards = [args]
    return cards


def look_up(card, prefs: dict) -> tuple[dict, str | None, str | None]:
    """A weather or a time card filled in from its place: the card, the line the agent answers
    from, and what went wrong. Any other card comes back as it was."""
    if not isinstance(card, dict):
        return card, None, None
    kind = str(card.get("type") or "").lower()
    place = card.get("place") or card.get("location")
    place = " ".join(place.split()) if isinstance(place, str) else ""
    if kind == "weather" and place:
        try:
            found = forecast.find(place)
            if not found:
                return card, None, f"'{place}' wasn't found for the weather: give a town or city, e.g. 'Orlando, FL'"
            units = forecast.units_for(found, card.get("units"), prefs.get("units"))
            filled = forecast.weather_card(place, found["latitude"], found["longitude"], units)
            return filled, "weather: " + forecast.said(filled), None
        except Exception as error:    # offline, or the service down: the agent hears it and answers in words
            return card, None, f"the forecast for {place} couldn't be looked up ({type(error).__name__}); say so rather than guess"
    if kind == "time":
        tz = forecast.zone(card.get("timezone"))
        try:
            if tz is None and place:
                found = forecast.find(place)
                if not found:
                    return card, None, f"'{place}' wasn't found for the time: give a town or city, or an IANA 'timezone'"
                tz = forecast.zone(found.get("timezone"))
        except Exception as error:
            return card, None, f"the time zone of {place} couldn't be looked up ({type(error).__name__})"
        if tz is None and not place:
            tz = forecast.zone(prefs.get("tz"))
        filled = {"type": "time", **({"place": place} if place else {}), **({"timezone": tz.key} if tz else {})}
        if tz is not None:
            return filled, "time: " + forecast.time_said(place or None, tz), None
        local = datetime.now().astimezone()
        return filled, (f"time: this server's own clock says {local:%H:%M}, {local:%A} {local.day} {local:%B} ({local.tzname()}); "
                        "the person's time zone isn't known here, so the card shows their phone's time"), None
    return card, None, None


def preferences(home) -> dict:
    """What the phone said of itself: its time zone and its temperature units."""
    try:
        data = json.loads(_file(home).read_text())
        return {k: data[k] for k in ("tz", "units") if isinstance(data.get(k), str)}
    except (OSError, ValueError, TypeError):
        return {}


def handle(args, home=None, **_) -> str:
    # Reached through `tool_call` even when not offered (Hermes 0.21.5): refused while off.
    if home is not None and not offered(home()):
        return json.dumps({"error": "Cards are turned off in Redde on the phone (Settings, Agent, Cards in replies). Answer in words."})
    args = args if isinstance(args, dict) else {}
    listed = _listed(args)
    said, missed = [], []
    if isinstance(listed, list):
        prefs = preferences(home()) if home is not None else {}
        filled = []
        for card in listed[:MAX_CARDS]:
            card, line, problem = look_up(card, prefs)
            filled.append(card)
            if line:
                said.append(line)
            if problem:
                missed.append(problem)
        args = {"cards": filled + listed[MAX_CARDS:]}
    shown, problems = check(args)
    problems = missed + problems
    if not shown:
        return json.dumps({"error": "Nothing could be shown: " + "; ".join(problems) + "."})
    answer = {"shown": shown, "note": "The cards are on the person's screen in Redde now. Answer in a sentence or two"
                                      + (" from what 'said' gives" if said else "") + "; don't read out what the cards already show."}
    if said:
        answer["said"] = said
    if problems:
        answer["not_shown"] = problems
    answer["cards"] = args["cards"][:MAX_CARDS]    # what the app draws, filled in
    return json.dumps(answer, ensure_ascii=False)


# ---- on or off, the phone's to say

def _file(home: Path) -> Path:
    return Path(home) / "redde-push" / "cards.json"


def offered(home: Path) -> bool:
    try:
        return bool(json.loads(_file(home).read_text()).get("on", True))
    except (OSError, ValueError):
        return True   # on until a phone turns them off


def _remember(home: Path, **values) -> None:
    path = _file(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        data = json.loads(path.read_text())
        data = data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        data = {}
    data.update(values, at=time.time())
    path.write_text(json.dumps(data))


def set_on(home: Path, on: bool) -> bool:
    _remember(home, on=on)
    return offered(home)


def slash(home: Path, words: list[str]) -> str:
    """`cards on`, `cards off`, `cards` (what it is now): "redde-push cards on|off". The phone adds
    its time zone and units, `cards on tz=America/New_York units=F`, for the time and the weather
    when the agent names no place or units."""
    if words[:1] in (["on"], ["off"]):
        set_on(home, words[0] == "on")
    said = dict(w.split("=", 1) for w in words[1:] if "=" in w)
    if forecast.zone(said.get("tz")):
        _remember(home, tz=said["tz"])
    if said.get("units", "").upper() in ("C", "F"):
        _remember(home, units=said["units"].upper())
    return f"redde-push cards {'on' if offered(home) else 'off'}"


def register(ctx, home) -> None:
    """Offers the tool while cards are on. `home` gives the Hermes home in use, asked at each
    check: a process can serve several profiles."""
    def check_fn() -> bool:
        try:
            return offered(home())
        except Exception:
            return True
    check_fn.__qualname__ = "redde_cards_offered"
    try:    # (a check that reads a file is quick and must not be remembered for half a minute)
        from tools.registry import no_cache_check_fn
        no_cache_check_fn(check_fn)
    except Exception:
        pass
    try:    # Shown outright, never behind tool search: a small local model doesn't search for it.
        import toolsets
        if TOOL not in toolsets._HERMES_CORE_TOOLS:
            toolsets._HERMES_CORE_TOOLS.append(TOOL)
    except Exception:
        pass
    ctx.register_tool(name=TOOL, toolset=TOOLSET, schema=SCHEMA, handler=lambda args, **kw: handle(args, home=home, **kw),
                      check_fn=check_fn, emoji="🗺️")

"""Cards in Redde: a map, a list of places, the weather, the time, drawn by the app under the agent's reply.

And, from 1.9.0, cards the person answers with a tap (asked 2026-10-28, after Meta's Muse): a
`review` of what the agent made ready to send, buy, book or change, its details editable, with
the button that lets it go ahead; a `choice` to pick from; a `checklist` to tick; a short `form`.
The app draws them; the answer comes back as the person's next message, with a note of exactly
what they picked or left in the fields ("[Redde card <key>: …]").

The agent calls `redde_show` with the cards. Nothing travels to the phone: the app reads the call
from the conversation, live and when it is read back, on either connection, and draws the cards
itself (MapKit for maps and places, looked up on the phone when a place comes without
coordinates). This tool checks them, so the agent hears at once about a card that can't be drawn.

An `agenda` (asked 2026-10-29: "when I ask what's on my calendar for tomorrow or what's on my
calendar in general, make it appear in a calendar card"): the events the agent read with its
calendar tool, drawn by day, or a day with nothing on it. The agent looks them up; this tool only
checks and passes them on, as for a map.

From 1.12.0 (asked 2026-10-30), five more: a `purchase` card (products to buy, the pick first), a
`home` card (the smart-home devices the agent touched or was asked about, with controls that ask
it back), a `reminder` card (a reminder, timer, alarm or scheduled message it set), a `compare`
card (two to four things side by side) and a `score` card (games). Their fields are not in the
schema, whose description is in every prompt: each card's shape is in a turn note added only when
the person's message asks for that kind of thing (`turn_note`), and in this tool's error when a
card comes without it (`_more`), so a wrong card is right on the first retry.

A weather or a time card names only its place: the forecast and the time zone are looked up here
(forecast.py, Open-Meteo), handed back to the agent to answer from, and returned as filled cards
(`cards` in the answer), which the app draws when it can read them (else it looks them up itself).

Offered unless the phone turned cards off (`/redde-push cards off`, Redde's Settings): its
description is in every prompt. The format must match what the app reads
(Echo/Models/ReplyCards.swift in the Redde repository).
"""

from __future__ import annotations

import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path

from . import forecast

TOOL = "redde_show"
TOOLSET = "redde_cards"
MAX_CARDS = 4
MAX_PLACES = 12
TYPES = ("map", "places", "weather", "time", "agenda", "review", "choice", "checklist", "form", "purchase", "home", "reminder", "compare", "score")
#: The cards from 1.12.0 whose shape is in their turn note and their error, not in the schema.
MORE = ("purchase", "home", "reminder", "compare", "score")
MAX_PRODUCTS = 6
MAX_DEVICES = 12
MAX_COMPARED = 4
MAX_GAMES = 6
DEVICE_KINDS = ("light", "switch", "climate", "cover", "lock", "sensor", "fan", "media")
REMINDER_KINDS = ("reminder", "timer", "alarm", "schedule")
GAME_STATUSES = ("final", "live", "upcoming")
MAX_EVENTS = 50
#: The cards the person answers.
ASKS = ("review", "choice", "checklist", "form")
FIELD_KINDS = ("text", "long", "number", "date", "time", "toggle", "choice")
#: What a review is, which the app draws it as (2026-10-30: an email as a sheet with who it's to,
#: its subject and its words). Optional: the app tells an email by its fields too.
REVIEW_KINDS = ("email", "message", "event", "purchase", "other")
MODES = ("driving", "walking", "transit", "cycling")

# A route's ends show a name: what finds them is all they need (2026-10-30, room for five more cards).
_END = {
    "type": "object",
    "properties": {"name": {"type": "string"}, "address": {"type": "string"}, "latitude": {"type": "number"}, "longitude": {"type": "number"}},
    "required": ["name"],
}

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

# A place in a list, with what the places card shows of it (its new look, asked 2026-10-30): the
# price, whether it is open, and the agent's pick, as found. Not on a route's ends, which show a name.
_LISTED = {**_PLACE, "properties": {
    **_PLACE["properties"],
    "price": {"type": "string", "description": "e.g. $$"},
    "hours": {"type": "string", "description": "e.g. Open until 9 PM, Closed"},
    "pick": {"type": "boolean", "description": "your pick of them"},
}}

SCHEMA = {
    "name": TOOL,
    "description": (
        "Shows cards under your reply in the Redde app: a map (pins or a route), places, the weather, the time. Use it "
        "for where something is, directions, places nearby, the weather or the time. Weather and time look themselves "
        "up: give just the 'place' (a city, e.g. 'Orlando, FL'; none for the time means the person's own), call this "
        "before you answer, and answer from what it returns ('said'), never from memory or a guess: your clock may be "
        "in another time zone. For a map or places, give what you found: coordinates, else a name and street address. "
        "Up to 4 cards. Then answer in a sentence or two; don't read the cards out. "
        "Cards they answer with a tap: before you send, buy, book or change anything for them, a 'review' ('fields' "
        "they can edit, 'action' the button, e.g. Send), then stop and act only on their answer; 'choice' ('options'), "
        "'checklist' ('items', each with a 'section' and a short 'note'; an 'emoji'), 'form' ('fields', each with a "
        "'kind'). Their answer is their next message. "
        "'agenda': calendar events by day ('events' as your calendar tool gave them: 'title', 'start' as ISO with its "
        "offset or a date for all day, 'end', 'location', 'calendar'; 'date' or 'dates' asked about, so a free day "
        "shows). Also 'purchase' (products to buy), 'home' (smart-home devices), 'reminder' (a reminder, timer, alarm "
        "or scheduled message you set), 'compare' (2-4 things side by side), 'score' (games): their fields are in the "
        "turn's note, or this tool's error. Look everything up first; never make anything up."),
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
                        "places": {"type": "array", "items": _LISTED, "description": "map: its pins; places: the list"},
                        "route": {
                            "type": "object",
                            "description": "map only: from a place (or omit 'from' for where the person is) to a place",
                            "properties": {"from": _END, "to": _END, "mode": {"type": "string", "enum": list(MODES)}},
                            "required": ["to"],
                        },
                        "place": {"type": "string", "description": "weather and time: where, e.g. Lisbon, or Orlando, FL"},
                        "timezone": {"type": "string", "description": "time: an IANA zone, e.g. Europe/Lisbon, if you know it"},
                        "units": {"type": "string", "enum": ["C", "F"], "description": "weather: if the person said"},
                        "action": {"type": "string"},
                        "kind": {"type": "string", "enum": list(REVIEW_KINDS + REMINDER_KINDS)},
                        "subtitle": {"type": "string", "description": "review, checklist: a line under the title"},
                        "verb": {"type": "string", "description": "checklist: an item done is, e.g. packed"},
                        "fields": {"type": "array", "items": {"type": "object", "properties": {
                            "label": {"type": "string"}, "value": {"type": "string"},
                            "kind": {"type": "string", "enum": list(FIELD_KINDS)}, "options": {"type": "array", "items": {"type": "string"}},
                            "required": {"type": "boolean"}}, "required": ["label"]}},
                        "options": {"type": "array", "items": {"type": "object", "properties": {
                            "title": {"type": "string"}, "detail": {"type": "string"}, "image": {"type": "string"}}, "required": ["title"]}},
                        "multiple": {"type": "boolean"},
                        "items": {"type": "array", "items": {"type": "object", "properties": {
                            "text": {"type": "string"}, "done": {"type": "boolean"}, "section": {"type": "string"},
                            "note": {"type": "string", "description": "e.g. ×2"}}}},
                        "emoji": {"type": "string"},
                        "events": {"type": "array", "description": "agenda: the events, from your calendar tool", "items": {
                            "type": "object", "properties": {
                                "title": {"type": "string"},
                                "start": {"type": "string", "description": "2026-10-30T09:30:00-04:00, or 2026-10-30 for all day"},
                                "end": {"type": "string"}, "all_day": {"type": "boolean"}, "location": {"type": "string"},
                                "calendar": {"type": "string"}, "notes": {"type": "string"}},
                            "required": ["title", "start"]}},
                        "date": {"type": "string", "description": "agenda: the day asked about, e.g. 2026-10-30"},
                        "dates": {"type": "array", "items": {"type": "string"}, "description": "agenda: the days asked about"},
                        "note": {"type": "string"},
                        "devices": {"type": "array", "items": {"type": "object"}},
                        "games": {"type": "array", "items": {"type": "object"}},
                        "rows": {"type": "array", "items": {"type": "object"}},
                        "at": {"type": "string"},
                        "repeat": {"type": "string"},
                        "where": {"type": "string"},
                        "id": {"type": "string"},
                        "verdict": {"type": "string"},
                        "pick": {"type": "integer"},
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
            problems.append(f"card {n}: 'type' must be one of {', '.join(TYPES)}")
            continue
        if kind in ASKS:
            said, problem = _ask(card, kind)
            if problem:
                problems.append(f"card {n}: {problem}")
            else:
                shown.append(said)
            continue
        if kind in MORE:
            said, problem = _more(card, kind)
            if problem:
                problems.append(f"card {n}: {problem}")
            else:
                shown.append(said)
            continue
        if kind == "agenda":
            said, problem = _agenda(card)
            if problem:
                problems.append(f"card {n}: {problem}")
            else:
                shown.append(said)
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


_DAY = re.compile(r"^\d{4}-\d{2}-\d{2}")


def _agenda(card: dict) -> tuple[str, str | None]:
    """What an agenda will show: its events (a title and a start that begins with a date), and the
    days asked about, which show even with nothing on them. Lenient as the app is."""
    events, dropped = [], 0
    for event in (card.get("events") or card.get("items") or [])[:MAX_EVENTS]:
        if not isinstance(event, dict):
            dropped += 1
            continue
        title = next((event[k].strip() for k in ("title", "summary", "name") if isinstance(event.get(k), str) and event[k].strip()), "")
        start = next((event[k].strip() for k in ("start", "starts", "start_time", "when", "date") if isinstance(event.get(k), str)), "")
        if title and _DAY.match(start):
            events.append((start, title))
        else:
            dropped += 1
    days = [d.strip() for d in ([card.get("date")] if isinstance(card.get("date"), str) else []) + list(card.get("dates") or [])
            if isinstance(d, str) and _DAY.match(d.strip())]
    title = card.get("title").strip() if isinstance(card.get("title"), str) else ""
    if not events and not days and not title:
        return "", ("an agenda needs 'events' (each a 'title' and a 'start' that begins with its date, 2026-10-30T09:30:00-04:00), "
                    "or the 'date' asked about when there is nothing on it")
    if not events:
        said = f"agenda: {title or ', '.join(days[:3])}, nothing on the calendar"
    else:
        events.sort()
        listed = ", ".join(f"{t} {s[11:16] if len(s) > 15 else '(all day)'}".strip() for s, t in events[:4])
        said = f"agenda: {title + ', ' if title else ''}{len(events)} event{'s' if len(events) != 1 else ''} ({listed}{'…' if len(events) > 4 else ''})"
    if dropped:
        said += f"; {dropped} left out (each needs a 'title' and a 'start' with its date)"
    return said, None


# What each of the newer cards needs, said again in the tool's error so a wrong card is right on
# the first retry: the same words as its turn note's.
SHAPES = {
    "purchase": ("'title'; 'items' (up to 6, your pick first), each {name, brand, price (a number), currency (ISO), was_price, "
                 "rating (out of 5), reviews (a count), retailer, url (the product's page), image (https), pick (true for one) "
                 "or badge (e.g. Best value), why (one line), pros, cons (a few words each), specs ({name: value}, a few)}; "
                 "'note' (e.g. when the prices were checked)"),
    "home": ("'title'; 'devices', each {name, area, kind (light, switch, climate, cover, lock, sensor, fan or media), "
             "state (as Home Assistant says it: on, off, open, closed, locked, heat...), brightness (0-100), temperature "
             "(now), target (a thermostat's setting), unit, entity (its entity id)}, as they are after what you did"),
    "reminder": ("'title' (what), 'kind' (reminder, timer, alarm or schedule), 'at' (when it goes off, ISO with its "
                 "offset, e.g. 2026-10-30T15:45:00-04:00), 'repeat' (in words, if it repeats), 'where' (where it lives: "
                 "Hermes, Reminders, an alarm on this iPhone), 'id' (what your tool returned for it), and for a timer "
                 "'duration' (e.g. 20 min)"),
    "compare": ("'title'; 'options' (2 to 4, each {title, pros, cons}); 'rows' (the criteria that matter, each "
                "{criterion, values: one short value per option in order, best: the better one's place from 0, where "
                "one is}); 'verdict' (one line, e.g. For you: B, mostly for battery); 'pick' (your pick's place)"),
    "score": ("'games' (one or a few), each {league, home, away (each {name, short (e.g. ORL), color (#hex), score, "
              "record}), status (final, live or upcoming), period and clock (live), start (ISO with its offset), venue, "
              "broadcast}; 'note'"),
}


def _name(row, *keys) -> str:
    if isinstance(row, str):
        return row.strip()
    if isinstance(row, dict):
        return next((row[k].strip() for k in keys if isinstance(row.get(k), str) and row[k].strip()), "")
    return ""


def _more(card: dict, kind: str) -> tuple[str, str | None]:
    """What a purchase, home, reminder, compare or score card will show, or why it can't be
    drawn, with the whole shape it takes. Lenient as the app is (Echo/Models/ReplyCards.swift)."""
    needs = f"a {kind} card needs " + SHAPES[kind]
    if kind == "purchase":
        listed = card.get("items") or card.get("products") or []
        listed = listed if isinstance(listed, list) else []
        names = [(n, isinstance(i, dict) and (i.get("pick") not in (None, False, "", "false", "no") or "pick" in str(i.get("badge") or "").lower()
                                             and "budget" not in str(i.get("badge") or "").lower()))
                 for n, i in ((_name(i, "name", "title"), i) for i in listed[:MAX_PRODUCTS])]
        kept = [(n, p) for n, p in names if n]
        if not kept:
            return "", needs
        pick = next((n for n, p in kept if p), None)
        said = f"purchase: {len(kept)} ({', '.join(n + (' (pick)' if n == pick else '') for n, _ in kept[:4])}{'…' if len(kept) > 4 else ''})"
        if len(kept) < len(names):
            said += f"; {len(names) - len(kept)} left out (each needs a 'name')"
        if len(listed) > MAX_PRODUCTS:
            said += f"; only the first {MAX_PRODUCTS} are shown"
        if pick is None:
            said += "; no pick: give one 'pick': true"
        return said, None
    if kind == "home":
        listed = card.get("devices") or card.get("items") or []
        devices = [d for d in (listed if isinstance(listed, list) else [])[:MAX_DEVICES] if _name(d, "name", "entity", "entity_id")]
        if not devices:
            return "", needs
        def one(d):
            state = d.get("state") if isinstance(d, dict) else None
            return _name(d, "name", "entity", "entity_id") + (f" {state}" if isinstance(state, (str, int, float)) and str(state).strip() else "")
        no_entity = sum(1 for d in devices if not (isinstance(d, dict) and (d.get("entity") or d.get("entity_id"))))
        said = f"home: {len(devices)} device{'s' if len(devices) != 1 else ''} ({', '.join(one(d) for d in devices[:4])}{'…' if len(devices) > 4 else ''})"
        if no_entity:
            said += f"; {no_entity} without an 'entity': give each its entity id, so the person's taps name the right one"
        return said, None
    if kind == "reminder":
        title = _name(card, "title", "what", "text", "name")
        if not title:
            return "", needs
        what = str(card.get("kind") or "reminder").lower()
        what = what if what in REMINDER_KINDS else "reminder"
        at = card.get("at") or card.get("when") or card.get("time")
        said = f"reminder: {what} '{title}'" + (f" at {at}" if isinstance(at, str) and at.strip() else "")
        if isinstance(card.get("repeat"), str) and card["repeat"].strip():
            said += f", {card['repeat'].strip()}"
        if not (isinstance(at, str) and _DAY.match(at.strip())) and not (what == "timer" and card.get("duration")):
            said += "; 'at' isn't an ISO time, so the card says when in words: give it as 2026-10-30T15:45:00-04:00"
        return said, None
    if kind == "compare":
        listed = card.get("options") or card.get("items") or []
        options = [n for n in (_name(o, "title", "name") for o in (listed if isinstance(listed, list) else [])[:MAX_COMPARED]) if n]
        rows = [r for r in card.get("rows") or card.get("criteria") or [] if isinstance(r, dict) and _name(r, "criterion", "name", "label")
                and isinstance(r.get("values"), list) and any(str(v).strip() for v in r["values"])]
        if len(options) < 2 or not rows:
            return "", needs
        pick = card.get("pick")
        said = f"compare: {' vs '.join(options)} ({len(rows)} criteria"
        said += f"; pick {options[pick]})" if isinstance(pick, int) and not isinstance(pick, bool) and 0 <= pick < len(options) else ")"
        if len(listed) > MAX_COMPARED:
            said += f"; only the first {MAX_COMPARED} options are shown"
        return said, None
    listed = card.get("games")
    listed = listed if isinstance(listed, list) else ([card] if card.get("home") else [])
    games = []
    for game in listed[:MAX_GAMES]:
        if not isinstance(game, dict):
            continue
        home, away = _name(game.get("home"), "name", "team"), _name(game.get("away"), "name", "team")
        if home and away:
            def score(side):
                v = game[side].get("score") if isinstance(game[side], dict) else None
                return f" {v}" if isinstance(v, (int, float)) and not isinstance(v, bool) else ""
            status = str(game.get("status") or "").lower()
            games.append(f"{away}{score('away')} at {home}{score('home')}" + (f" ({status})" if status in GAME_STATUSES else ""))
    if not games:
        return "", needs
    return f"score: {'; '.join(games[:3])}{'…' if len(games) > 3 else ''}", None


def _labels(rows, *keys) -> list[str]:
    out = []
    for row in rows or []:
        if isinstance(row, str) and row.strip():
            out.append(row.strip())
        elif isinstance(row, dict):
            for key in keys:
                if isinstance(row.get(key), str) and row[key].strip():
                    out.append(row[key].strip())
                    break
    return out


def _ask(card: dict, kind: str) -> tuple[str, str | None]:
    """What a card the person answers will show, or why it can't be drawn."""
    title = card.get("title") if isinstance(card.get("title"), str) else ""
    if kind in ("review", "form"):
        fields = _labels(card.get("fields"), "label", "name")
        if not title.strip() or not fields:
            return "", f"a {kind} needs a 'title' and 'fields', each with a 'label'"
        drawn = str(card.get("kind") or "").strip().lower() if kind == "review" else ""
        drawn = f"; as {'an' if drawn in ('email', 'event') else 'a'} {drawn}" if drawn in REVIEW_KINDS[:4] else ""
        return f"{kind}: {title.strip()} ({', '.join(fields[:5])}; button {card.get('action') or ('Do It' if kind == 'review' else 'Send')}{drawn})", None
    if kind == "choice":
        options = _labels(card.get("options"), "title", "name", "label")
        if len(options) < 2:
            return "", "a choice needs at least two 'options', each with a 'title'"
        return f"choice: {', '.join(options[:5])}{' (several may be picked)' if card.get('multiple') else ''}", None
    # Its items, or 'sections' (or 'groups') each with its items, as the app reads them.
    items = _labels(card.get("items"), "text", "title")
    groups = {str(i.get("section") or i.get("group") or "").strip() for i in card.get("items") or [] if isinstance(i, dict)} - {""}
    for n, group in enumerate(card.get("sections") or card.get("groups") or [], 1):
        found = _labels(group.get("items"), "text", "title") if isinstance(group, dict) else []
        if found:
            items += found
            groups.add(str(group.get("title") or group.get("name") or "").strip() or f"group {n}")
    if not items:
        return "", "a checklist needs 'items', each with a 'text'"
    return f"checklist: {title.strip() or 'list'} ({len(items)} items{f' in {len(groups)} groups' if len(groups) > 1 else ''})", None


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
    asks = [c for c in args["cards"][:MAX_CARDS] if isinstance(c, dict) and str(c.get("type") or "").lower() in ASKS]
    note = ("The cards are on the person's screen in Redde now. Answer in a sentence or two"
            + (" from what 'said' gives" if said else "") + "; don't read out what the cards already show.")
    if asks:
        note += (" They answer the card with a tap: their answer comes as their next message. Stop here and wait for"
                 " it; for a review, do nothing of it until they tap its button, and then do exactly what their answer"
                 " says, with their changes.")
    answer = {"shown": shown, "note": note}
    if said:
        answer["said"] = said
    if problems:
        answer["not_shown"] = problems
    answer["cards"] = args["cards"][:MAX_CARDS]    # what the app draws, filled in
    return json.dumps(answer, ensure_ascii=False)


# ---- a word at the turn

# Asked the time or the weather, in English: the description alone wasn't enough. Asked "What time
# is it" at 9:06 and 9:09 PM, Sol (no terminal, so no `date`; Hermes gives only the date) said
# 9:55 PM, then 12:05 AM Thursday, on a Friday, and showed no card (2026-10-23).
_ASKS_TIME = re.compile(r"\bwhat(?:'s|’s| is)? the time\b|\bwhat time\b|\btime (?:is it|now|there|in|zone)\b"
                        r"|\b(?:current|local) time\b|\bclock\b|\bo'?clock\b", re.IGNORECASE)
_ASKS_WEATHER = re.compile(r"\bweather\b|\bforecast\b|\btemp(?:erature)?s?\b|\bdegrees\b|\bumbrella\b"
                           r"|\b(?:rain(?:ing|y)?|snow(?:ing)?|sunny|humid(?:ity)?|windy)\b", re.IGNORECASE)
#: Asked to do something for them that is hard to undo, in English: a review card first.
_ASKS_ACTION = re.compile(r"\b(?:send|email|e-mail|text|message|reply to|book|reserve|buy|order|purchase|pay|cancel my|"
                          r"post|publish|schedule (?:a|the)|invite)\b", re.IGNORECASE)
#: Asked for a list to tick off, in English: a checklist card, not the list in words.
_ASKS_LIST = re.compile(r"\b(?:packing|shopping|grocery|to-?do|todo|check)\s*list\b|\bchecklist\b|\blist of (?:things|what) to "
                        r"(?:pack|bring|buy|do|get)\b|\bwhat (?:do|should) (?:i|we) (?:pack|bring)\b", re.IGNORECASE)
#: Asked what is on the calendar, in English (2026-10-29): an 'agenda' card. Not when asked to put
#: something on it: that's an errand, the review note's.
_ASKS_CALENDAR = re.compile(
    r"\b(?:my|the|our) (?:calendar|agenda|schedule)\b|\bcalendar\b.*\?|\bagenda\b"
    r"|\bwhat(?:'s|’s| is) (?:on|happening|planned|going on)\b[^.?!]*\b(?:today|tonight|tomorrow|this (?:week|weekend|morning|"
    r"afternoon|evening)|next week|(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|the \d)"
    r"|\bwhat(?:'s|’s| is) on\s*(?:\?|$)|\bwhat (?:do|did) (?:i|we) have\b|\bwhat have (?:i|we) got\b"
    r"|\b(?:am i|are we) (?:free|busy|booked)\b|\bany (?:meetings|appointments|events|plans)\b"
    r"|\b(?:what|when)(?:'s|’s| is) (?:my )?next (?:meeting|appointment|event)\b|\b(?:when|what time) (?:is|does|do) my\b[^.?!]*\b(?:meeting|appointment|event|call|class|game)s?\b",
    re.IGNORECASE)
_NAMES_CALENDAR = re.compile(r"\b(?:calendar|agenda|schedule|meetings?|appointments?|events?|free|busy)\b", re.IGNORECASE)
_PUTS_ON_CALENDAR = re.compile(
    r"\b(?:add|put|create|make|book|set up|move|reschedule|cancel|delete|remove|invite|block(?: off| out)?)\b"
    r"|\bschedule (?:a|an|the|me|it|that|this|my)\b|\bremind me\b", re.IGNORECASE)
AGENDA_NOTE = (f"[Redde: asked what's on the calendar. Look the events up with the calendar tool first, then show them "
               f"with {TOOL} as an 'agenda' card ('events' with title, start and end as the tool gave them, location, "
               "calendar; 'date' for each day asked about, so a free day shows too), then answer in a line: don't list the "
               "events again in words.")
LIST_NOTE = (f"[Redde: show the list as a 'checklist' card with {TOOL} (its 'items' grouped by 'section', a short 'note' "
             "beside an item where it helps, e.g. ×2, an 'emoji', and a 'verb' for an item done, e.g. packed), "
             "then answer in a line: don't also write the list out in words.]")
#: How much each agent may do unasked (asked 2026-10-28, "Proactive", after Muse's adjustable
#: threshold): set per agent in Redde, kept in the main home. Hermes's own approvals for commands
#: are untouched by it: this is about the person's own errands (a message, a booking, an order).
LEVELS = ("ask", "routine", "act")
LEVEL_NOTES = {
    "routine": ("[Redde: small things that are easy to undo (a reminder, a calendar note, a light, a list), just do and say "
                f"you did; before you send, pay, book, buy or delete anything, show a 'review' card with {TOOL} and stop until "
                "they answer.]"),
    "act": ("[Redde: they let you act on their behalf: do what they ask, then say exactly what you did. Only before paying "
            f"or deleting something show a 'review' card with {TOOL} and wait for their answer.]"),
}
REVIEW_NOTE = ("[Redde: before you send, book, buy or change anything for them, show what you'll do as a 'review' "
               f"card with {TOOL} (its 'kind': email, message, event or purchase) and stop; do it only when their "
               "answer comes back.]")
#: Asked what to buy, in English (2026-10-30): a 'purchase' card. Not an errand ("buy it", "order
#: it", "add to cart": the review note's), not a place to eat (a 'places' card).
_ASKS_PURCHASE = re.compile(
    r"\bwhich\b[^.?!]*\bshould (?:i|we) (?:buy|get|order|pick up|go for)\b|\bwhat\b[^.?!]*\bshould (?:i|we) (?:buy|get)\b"
    r"|\bbest\b[^.?!]*\b(?:under|below|less than|for)\s*(?:[$£€]\s*\d|\d)|\bbest\b[^.?!]*\bto buy\b|\bworth (?:buying|the money)\b"
    r"|\brecommend (?:me )?(?:a|an|some)\b|\blooking for (?:a |an |some )?new\b|\bgift ideas?\b|\b(?:gift|present) for\b"
    r"|\bwhere (?:can|should|do) (?:i|we) buy\b|\bshould (?:i|we) (?:buy|get) (?:the|a|an)\b", re.IGNORECASE)
_NOT_SHOPPING = re.compile(
    r"\b(?:restaurants?|caf[eé]s?|coffee shops?|bars?|places? to (?:eat|go|stay)|hotels?|movies?|films?|shows?|series|podcasts?|"
    r"recipes?|dinner|lunch|breakfast|brunch|to eat|to drink|books?|novels?|apps?|routes?|ways?)\b", re.IGNORECASE)
#: Where to buy something: a purchase card, a book too.
_WHERE_TO_BUY = re.compile(r"\bwhere (?:can|should|do) (?:i|we) buy\b", re.IGNORECASE)
#: Things to buy, where a 'which is better' is shopping and so a 'purchase' card.
_SHOPPING = re.compile(r"[$£€]\s*\d|\b(?:buy|buying|purchase|price|prices|cheaper|deal|budget|worth (?:it|the money))\b", re.IGNORECASE)
#: Asked which of two to four things is better, in English: a 'compare' card.
_ASKS_COMPARE = re.compile(
    r"\bwhich (?:is|one is|would be|one would be|'s|’s) (?:better|best)\b|\bwhich (?:one )?should (?:i|we) (?:choose|pick|go with|learn|use|take)\b"
    r"|\b(?:is|are) [^.?!]+ better than\b|\b(?:is|are) [^.?!]+ or [^.?!]+ (?:better|best)\b|\b\w+ (?:vs\.?|versus) \w+|\bcompare\b|\bdifference between\b[^.?!]*\band\b"
    r"|\bshould (?:i|we) (?:choose|pick|go with|learn|use|take)\b[^.?!]*\bor\b|\bpros and cons of\b[^.?!]*\b(?:and|or|vs)\b",
    re.IGNORECASE)
#: Code and data compared are no 'compare' card (a coding bot's "compare these two functions").
_NOT_COMPARE = re.compile(r"\b(?:functions?|files?|branch(?:es)?|commits?|diffs?|PRs?|pull requests?|quer(?:y|ies)|tables?|logs?|"
                          r"outputs?|errors?|scripts?|configs?|versions? of)\b", re.IGNORECASE)
#: Asked about the home's devices, in English: a 'home' card. A thing of the house and a word
#: that does or reads it, both ("set the house to 70", "is the garage closed?", "turn off the lights").
_HOME_THINGS = re.compile(
    r"\b(?:lights?|lamps?|fans?|heater|heating|heat|thermostat|a/?c|air ?con(?:ditioning)?|tv|plugs?|outlets?|garage(?: door)?|"
    r"(?:front|back|side|patio) door|door ?locks?|smart locks?|blinds|shades|curtains|sprinklers?|house)\b", re.IGNORECASE)
_HOME_ACTS = re.compile(
    r"\b(?:turn|switch|flip)\b[^.?!]*\b(?:on|off|up|down)\b|\b(?:dim|brighten|lock|unlock|open|close|shut)\b|\bset\b[^.?!]*\bto \d"
    r"|\b(?:is|are|did i leave)\b[^.?!]*\b(?:on|off|open|closed|shut|locked|unlocked)\b|\bleft (?:on|open|unlocked)\b"
    r"|\bhow (?:warm|cold|hot) is (?:it )?(?:in )?the house\b", re.IGNORECASE)
#: Asked to be reminded, or for a timer, an alarm or a message at a time, in English: a 'reminder' card.
_ASKS_REMINDER = re.compile(
    r"\bremind (?:me|us)\b|\bset (?:a |an |me a )?(?:timer|alarm|reminder)\b|\b(?:timer|alarm|reminder) for\b|\bwake me(?: up)? at\b"
    r"|\bevery (?:day|morning|evening|night|week|weekday|monday|tuesday|wednesday|thursday|friday|saturday|sunday)s?\b[^.?!]*"
    r"\b(?:tell|send|remind|message|text|give|ping)\b|\bschedule (?:a )?message\b|\bin \d+ (?:min(?:ute)?s?|hours?)\b[^.?!]*\b(?:tell|remind|ping)\b",
    re.IGNORECASE)
#: Asked about a game, in English: a 'score' card. Not a credit score, not a song played.
_ASKS_SCORE = re.compile(
    r"\b(?:did|do|does) (?:the )?(?!you\b|i\b|we\b)[\w.'’ -]{2,30} (?:win|lose|beat)\b|\bwho (?:won|is winning|’s winning|'s winning)\b[^.?!]*\b(?:game|match|series|final|bowl|cup)\b"
    r"|\b(?:final |the )?scores?\b(?! (?:card|sheet))|\bnext\b[\w.'’ -]{0,30}\b(?:game|match)\b|\bwhen (?:do|does|is|are) (?:the )?[\w.'’ -]{2,30} (?:play|game|match)\b"
    r"|\b(?:game|match)\b[^.?!]{0,12}\b(?:tonight|today|tomorrow|last night)\b|\bhow(?:'s| is|’s| are)\b[^.?!]*\b(?:game|match) going\b", re.IGNORECASE)
_NOT_SCORE = re.compile(r"\b(?:credit|test|exam|sat|act|gre|risk|credit) scores?\b|\bscore (?:me|a deal)\b", re.IGNORECASE)
PURCHASE_NOTE = (f"[Redde: asked what to buy. Look it up with your tools first (web search, the stores' own pages): never make up a "
                 f"price, a rating or a link. Then show them with {TOOL} as a 'purchase' card: " + SHAPES["purchase"]
                 + ". Then answer in a line: don't list them again.]")
HOME_NOTE = (f"[Redde: asked about the home. Do or read it with your Home Assistant tools first, then show the devices you touched or "
             f"were asked about with {TOOL} as a 'home' card: " + SHAPES["home"] + ". Then answer in a line.]")
REMINDER_NOTE = (f"[Redde: asked to set a reminder, a timer, an alarm or a message at a time. Set it with your tools first, then show it "
                 f"with {TOOL} as a 'reminder' card: " + SHAPES["reminder"] + ". Then answer in a line.")
COMPARE_NOTE = (f"[Redde: asked which is better. Look up what you need first, then show it with {TOOL} as a 'compare' card: "
                + SHAPES["compare"] + ". Then answer in a line. Things to buy are a 'purchase' card instead.]")
SCORE_NOTE = (f"[Redde: asked about a game. Look it up with your tools first (never guess a score or a time), then show it with "
              f"{TOOL} as a 'score' card: " + SHAPES["score"] + ". Then answer in a line.")
REDDES = ("desktop", "tui", "api_server", "")    # Redde's connections: the Dashboard, the Hermes API


def _text(message) -> str:
    if isinstance(message, str):
        return message
    if isinstance(message, list):    # multimodal: the text parts
        return " ".join(str(p.get("text") or "") for p in message if isinstance(p, dict))
    return ""


def announce() -> bool:
    """Hermes 0.22's Dashboard tells a client of a tool call as it happens only when tool progress
    is on, or for the tools whose card is the turn's answer (`_TOOL_LIFECYCLE_UI_TOOLS`); redde_show
    wasn't among them, so its cards came only when the chat was opened again (GitHub issue 35). It
    is added to them, in the Dashboard's process, once its chat server has loaded (this is called
    as the plugin loads and as each turn starts). True once it is there; releases without the list
    tell of every call already."""
    server = sys.modules.get("tui_gateway.server")
    shown = getattr(server, "_TOOL_LIFECYCLE_UI_TOOLS", None) if server else None
    if shown is None:
        return False
    if TOOL not in shown:
        server._TOOL_LIFECYCLE_UI_TOOLS = frozenset(shown) | {TOOL}
    return True


def turn_note(home: Path, message, platform: str = "", at: datetime | None = None) -> str | None:
    """For `pre_llm_call`: when the person asks the time or the weather, and cards are on, what
    their time is (in the zone their phone said) and to show the card before answering. Added to
    that turn's message only, so it costs nothing on any other."""
    if platform not in REDDES or not offered(home):
        return None
    text = _text(message)
    # A card's answer is the go-ahead itself, not a new ask.
    calendar_asked = bool(_ASKS_CALENDAR.search(text)) and not _PUTS_ON_CALENDAR.search(text)
    # "What's the weather tomorrow" is the weather's, unless the calendar is named too.
    if calendar_asked and (_ASKS_WEATHER.search(text) or _ASKS_TIME.search(text)) and not _NAMES_CALENDAR.search(text):
        calendar_asked = False
    if "[Redde card " not in text and calendar_asked and not gated(home):
        note = AGENDA_NOTE
        tz = forecast.zone(preferences(home).get("tz"))
        if tz is not None:
            # "Tomorrow" is the person's: the server's clock may be in another zone.
            note += f" Where the person is, it is now {forecast.time_said(None, tz, at).split(': ', 1)[1]} ({tz.key}).]"
        else:
            note += "]"
        return note
    if "[Redde card " not in text and not gated(home):
        more = more_note(text)
        if more is not None:
            if more in (REMINDER_NOTE, SCORE_NOTE):
                # "In 20 minutes" and "tonight" are the person's: the server's clock may be in another zone.
                tz = forecast.zone(preferences(home).get("tz"))
                more += (f" Where the person is, it is now {forecast.time_said(None, tz, at).split(': ', 1)[1]} ({tz.key}).]"
                         if tz is not None else "]")
            return more
    time_asked, weather_asked = bool(_ASKS_TIME.search(text)), bool(_ASKS_WEATHER.search(text))
    if not time_asked and not weather_asked:
        # A card's answer is the go-ahead itself, not a new ask.
        if "[Redde card " in text:
            return None
        if _ASKS_LIST.search(text):
            return LIST_NOTE
        if not _ASKS_ACTION.search(text) or gated(home):
            return None
        return LEVEL_NOTES.get(autonomy(home), REVIEW_NOTE)
    asked = " and ".join(w for w, yes in (("the time", time_asked), ("the weather", weather_asked)) if yes)
    note = (f"[Redde: asked about {asked}. Call {TOOL} first (a "
            + " and a ".join(k for k, yes in (("'time'", time_asked), ("'weather'", weather_asked)) if yes)
            + " card; 'place' as the person said it, or none for where they are) and answer from its 'said'.")
    tz = forecast.zone(preferences(home).get("tz"))
    if tz is not None:
        note += f" Where the person is, it is now {forecast.time_said(None, tz, at).split(': ', 1)[1]} ({tz.key});"
        note += " go by this, not by any other clock or a guess.]"
    else:
        note += " Don't guess the time: what the card returns has it.]"
    return note


def more_note(text: str) -> str | None:
    """The note for the newer cards a message asks for (2026-10-30), the first that fits: a reminder
    ("remind me at 5"), a game ("did the Heat win?" is no thermostat), the home ("set the house to
    70"), what to buy, which is better; a
    'which is better' about things to buy is a purchase. The reminder and score notes are completed
    with the person's time by `turn_note`."""
    if _ASKS_REMINDER.search(text):
        return REMINDER_NOTE
    if _ASKS_SCORE.search(text) and not _NOT_SCORE.search(text):
        return SCORE_NOTE
    if _HOME_THINGS.search(text) and _HOME_ACTS.search(text):
        return HOME_NOTE
    compare = bool(_ASKS_COMPARE.search(text)) and not _NOT_COMPARE.search(text)
    if _WHERE_TO_BUY.search(text) or ((_ASKS_PURCHASE.search(text) or (compare and _SHOPPING.search(text))) and not _NOT_SHOPPING.search(text)):
        return PURCHASE_NOTE
    if compare:
        return COMPARE_NOTE
    return None


# ---- how much each agent may do unasked, the phone's to say

def _autonomy_file(home: Path) -> Path:
    from .calls import caller
    return caller(Path(home))[1] / "redde-push" / "autonomy.json"


def autonomy(home: Path) -> str:
    """This agent's level: "ask" (the default), "routine" or "act"."""
    try:
        from .calls import caller
        level = json.loads(_autonomy_file(home).read_text()).get(caller(Path(home))[0], "ask")
        return level if level in LEVELS else "ask"
    except (OSError, ValueError, AttributeError):
        return "ask"


def autonomy_slash(home: Path, words: list[str]) -> str:
    """`autonomy <profile>=<level> ...`: the app's, each agent's level; `autonomy`: what they are."""
    path = _autonomy_file(home)
    try:
        levels = json.loads(path.read_text())
        levels = levels if isinstance(levels, dict) else {}
    except (OSError, ValueError):
        levels = {}
    for word in words:
        profile, _, level = word.partition("=")
        if profile and level in LEVELS:
            levels[profile] = level
    if words:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(levels))
    return "redde-push autonomy " + " ".join(f"{p}={l}" for p, l in sorted(levels.items()))


# ---- agents whose actions Hermes already asks about, the server's to say

def _gated_file(home: Path) -> Path:
    from .calls import caller
    return caller(Path(home))[1] / "redde-push" / "gated.json"


def gated(home: Path) -> bool:
    """Whether this agent's actions already wait for the person in Hermes itself (a coding bot
    whose writes and commands a `pre_tool_call` hook sends for approval): then no review card
    first, or every change is asked twice, once by its card and once by Hermes (2026-10-29: the
    errand words caught coding requests, "the error message", "the POST handler", "sort order").
    Set on the server, never by the app's levels, which each phone sends again as it comes
    forward."""
    try:
        from .calls import caller
        names = json.loads(_gated_file(home).read_text())
        return isinstance(names, list) and caller(Path(home))[0] in names
    except (OSError, ValueError, AttributeError):
        return False


def gated_slash(home: Path, words: list[str]) -> str:
    """`gated <profile> on|off`: whether Hermes's own approvals stand in for that agent's review
    cards; `gated`: which agents. Kept in the main home."""
    path = _gated_file(home)
    try:
        names = json.loads(path.read_text())
        names = [n for n in names if isinstance(n, str)] if isinstance(names, list) else []
    except (OSError, ValueError):
        names = []
    if len(words) == 2 and words[1] in ("on", "off"):
        from .calls import PROFILE
        if not PROFILE.fullmatch(words[0]):
            return "redde-push gated: not a profile name"
        names = sorted(set(names) | {words[0]}) if words[1] == "on" else [n for n in names if n != words[0]]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(names))
    elif words:
        return "redde-push gated: /redde-push gated <profile> on|off"
    return "redde-push gated " + (" ".join(names) or "none")


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
    try:
        announce()
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

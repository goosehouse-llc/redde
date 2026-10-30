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
TYPES = ("map", "places", "weather", "time", "review", "choice", "checklist", "form")
#: The cards the person answers.
ASKS = ("review", "choice", "checklist", "form")
FIELD_KINDS = ("text", "long", "number", "date", "time", "toggle", "choice")
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
        "sentence or two: the cards are on the person's screen, so don't read out everything in them. "
        "Cards they answer with a tap: before you send, buy, book or change anything for them, a 'review' (what "
        "you'll do as 'fields' they can edit, 'action' the button, e.g. Send), then stop and act only on their "
        "answer; 'choice' ('options' to pick from), 'checklist' (a list to tick off: 'items', each with a 'section' "
        "to group them, and an 'emoji'), 'form' ('fields' to fill in, each with a 'kind'). Their answer is their next "
        "message."),
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
                        "action": {"type": "string"},
                        "fields": {"type": "array", "items": {"type": "object", "properties": {
                            "label": {"type": "string"}, "value": {"type": "string"},
                            "kind": {"type": "string", "enum": list(FIELD_KINDS)}, "options": {"type": "array", "items": {"type": "string"}},
                            "required": {"type": "boolean"}}, "required": ["label"]}},
                        "options": {"type": "array", "items": {"type": "object", "properties": {
                            "title": {"type": "string"}, "detail": {"type": "string"}, "image": {"type": "string"}}, "required": ["title"]}},
                        "multiple": {"type": "boolean"},
                        "items": {"type": "array", "items": {"type": "object", "properties": {
                            "text": {"type": "string"}, "done": {"type": "boolean"}, "section": {"type": "string"}}}},
                        "emoji": {"type": "string"},
                        "note": {"type": "string"},
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
        return f"{kind}: {title.strip()} ({', '.join(fields[:5])}; button {card.get('action') or ('Do It' if kind == 'review' else 'Send')})", None
    if kind == "choice":
        options = _labels(card.get("options"), "title", "name", "label")
        if len(options) < 2:
            return "", "a choice needs at least two 'options', each with a 'title'"
        return f"choice: {', '.join(options[:5])}{' (several may be picked)' if card.get('multiple') else ''}", None
    items = _labels(card.get("items"), "text", "title")
    if not items:
        return "", "a checklist needs 'items', each with a 'text'"
    return f"checklist: {title.strip() or 'list'} ({len(items)} items)", None


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
LIST_NOTE = (f"[Redde: show the list as a 'checklist' card with {TOOL} (its 'items' grouped by 'section', an 'emoji'), "
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
               f"card with {TOOL} and stop; do it only when their answer comes back.]")
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

"""Arrivals (1.39.0, asked 2026-11-23 with follow-through): what the person means to watch, told when
it can be.

- New on Jellyfin: a film or series on one of their watch lists (`lists.py`, not yet ticked off)
  that has just come into their Jellyfin library: "Elf is on Jellyfin now", offering to plan a
  night for it.
- New seasons: a series they've finished (ticked off on a watch list, or played to the end on
  Jellyfin) whose next season TVmaze shows starting within a month, or started in the last two
  weeks: "Severance season 3 starts January 16", offering to put it on their list.

Jellyfin is found the way the person's bots already reach it: JELLYFIN_URL (or _SERVER_URL,
_BASE_URL, _HOST) and JELLYFIN_API_KEY (or _TOKEN, _KEY) in any profile's .env; JELLYFIN_USER
names whose "played" counts, else the only user, else the first administrator. Values are read
here and sent to that server only; the app is told whether one was found and in which profile.
No model. Each look at most every half hour, in the day; each series looked up once a day.
"""
from __future__ import annotations

import json
import logging
import os
import re
import time
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta
from pathlib import Path

log = logging.getLogger("redde_push.arrivals")

FILE = "arrivals.json"
URL_NAMES = ("JELLYFIN_URL", "JELLYFIN_SERVER_URL", "JELLYFIN_BASE_URL", "JELLYFIN_HOST", "JELLYFIN_SERVER")
KEY_NAMES = ("JELLYFIN_API_KEY", "JELLYFIN_TOKEN", "JELLYFIN_KEY", "JELLYFIN_ACCESS_TOKEN")
USER_NAMES = ("JELLYFIN_USER", "JELLYFIN_USERNAME", "JELLYFIN_USER_ID")
EVERY, SERIES_EVERY, SERIES_AT_ONCE, CARDS_AT_ONCE = 1800, 86400, 8, 3
SOON, LATELY = 30, 14
TIMEOUT = 10.0

#: (url, headers) -> parsed JSON or None; swapped in tests.
FETCH = None


def _env(path: Path) -> dict[str, str]:
    found = {}
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return found
    wanted = URL_NAMES + KEY_NAMES + USER_NAMES
    for line in lines:
        name, _, value = line.strip().removeprefix("export ").partition("=")
        if name.strip() in wanted and value.strip():
            found[name.strip()] = value.strip().strip("'\"")
    return found


def find(root: Path) -> dict | None:
    """{url, key, user, profile} from the first profile whose .env has both, or None."""
    root = Path(root)
    homes = [("default", root)]
    if (root / "profiles").is_dir():
        homes += [(h.name, h) for h in sorted((root / "profiles").iterdir()) if h.is_dir()]
    for profile, home in homes:
        values = _env(home / ".env")
        if profile == "default":
            values = {**{k: v for k, v in os.environ.items() if k in URL_NAMES + KEY_NAMES + USER_NAMES}, **values}
        url = next((values[n] for n in URL_NAMES if values.get(n)), None)
        key = next((values[n] for n in KEY_NAMES if values.get(n)), None)
        if url and key:
            if not re.match(r"https?://", url, re.IGNORECASE):
                url = "http://" + url
            return {"url": url.rstrip("/"), "key": key, "user": next((values[n] for n in USER_NAMES if values.get(n)), None),
                    "profile": profile}
    return None


def status(root: Path) -> dict:
    found = find(root)
    return {"found": bool(found), **({"profile": found["profile"]} if found else {})}


def _fetch(url: str, headers: dict) -> object | None:
    if FETCH is not None:
        return FETCH(url, headers)
    try:
        request = urllib.request.Request(url, headers={"Accept": "application/json", **headers})
        with urllib.request.urlopen(request, timeout=TIMEOUT) as answer:
            return json.loads(answer.read(4_000_000).decode("utf-8", "replace"))
    except Exception:
        return None


def _jellyfin(server: dict, path: str) -> object | None:
    return _fetch(server["url"] + path, {"X-Emby-Token": server["key"],
                                         "Authorization": f'MediaBrowser Client="Redde", Token="{server["key"]}"'})


def _user(server: dict) -> str | None:
    named = server.get("user") or ""
    if re.fullmatch(r"[0-9a-fA-F-]{32,36}", named):
        return named.replace("-", "")
    users = _jellyfin(server, "/Users")
    if not isinstance(users, list) or not users:
        return None
    pick = next((u for u in users if named and str(u.get("Name") or "").casefold() == named.casefold()), None) \
        or (users[0] if len(users) == 1 else None) \
        or next((u for u in users if (u.get("Policy") or {}).get("IsAdministrator")), None)
    return pick.get("Id") if isinstance(pick, dict) else None


def norm(name: str) -> str:
    name = re.sub(r"\s*\((?:19|20)\d\d\)\s*$", "", str(name or ""))
    name = re.sub(r"[^\w\s]", " ", name.casefold().replace("&", " and "))
    words = [w for w in name.split() if w not in ("the", "a", "an")]
    return " ".join(words)


def _year(item: dict) -> int | None:
    found = re.search(r"\((19\d\d|20\d\d)\)\s*$", str(item.get("text") or ""))
    return item.get("year") or (int(found.group(1)) if found else None)


def _state(root: Path) -> dict:
    try:
        data = json.loads((Path(root) / "redde-push" / FILE).read_text())
    except (OSError, ValueError):
        data = {}
    return data if isinstance(data, dict) else {}


def _save(root: Path, data: dict) -> None:
    path = Path(root) / "redde-push" / FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False))
    os.chmod(temp, 0o600)
    temp.replace(path)


def _watch_items(root: Path) -> list[tuple[dict, dict]]:
    from . import lists
    return [(kept, item) for kept in lists.load(root) if lists.look(kept)["kind"] == "watch"
            for item in kept.get("items") or []]


def new_on_server(server: dict, data: dict, watching: list[tuple[dict, dict]]) -> list[dict]:
    """Cards for watch-list titles that have just come into the library. The first look only
    remembers what's there."""
    got = _jellyfin(server, "/Items?Recursive=true&IncludeItemTypes=Movie,Series&SortBy=DateCreated&SortOrder=Descending"
                            "&Limit=80&Fields=ProductionYear")
    items = (got or {}).get("Items") if isinstance(got, dict) else None
    if not isinstance(items, list):
        return []
    seen = set(data.get("seen") or [])
    first = not seen
    cards = []
    for media in items:
        if not isinstance(media, dict) or not media.get("Id") or media["Id"] in seen:
            continue
        seen.add(media["Id"])
        if first:
            continue
        name, year = norm(media.get("Name")), media.get("ProductionYear")
        for kept, item in watching:
            if item.get("done") or norm(item.get("text")) != name:
                continue
            wanted = _year(item)
            if wanted and year and abs(int(wanted) - int(year)) > 1:
                continue
            title = str(media.get("Name"))
            cards.append({"title": f"{title} is on Jellyfin now"[:60], "why": f"It's on your list \"{kept.get('title')}\""[:140],
                          "request": f"{title} is on my Jellyfin now, from my list \"{kept.get('title')}\". Help me plan a "
                                     "night to watch it."})
            break
    data["seen"] = list(seen)[-2000:]
    return cards


def _seasons(name: str, deadline: float) -> list[dict] | None:
    from . import posters
    how, status_, _, body = posters.GET("https://api.tvmaze.com/singlesearch/shows?q=" + urllib.parse.quote(name)
                                        + "&embed=seasons", deadline)
    if how != "ok" or status_ != 200:
        return None
    try:
        show = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return None
    if norm(show.get("name")) != norm(name):
        return None
    return [s for s in (show.get("_embedded") or {}).get("seasons") or [] if isinstance(s, dict)]


def new_seasons(finished: list[str], data: dict, today: date, now: float) -> list[dict]:
    """Cards for finished series whose next season starts soon or just did. A series' first look
    remembers how many seasons it has."""
    known = data.setdefault("series", {})
    cards, looked = [], 0
    for name in finished:
        key = norm(name)
        entry = known.setdefault(key, {})
        if now - float(entry.get("at") or 0) < SERIES_EVERY or looked >= SERIES_AT_ONCE:
            continue
        looked += 1
        entry["at"] = now
        seasons = _seasons(name, time.monotonic() + TIMEOUT)
        if seasons is None:
            continue
        aired = [s for s in seasons if s.get("premiereDate") and date.fromisoformat(s["premiereDate"][:10]) <= today]
        if "seasons" not in entry:
            entry["seasons"] = max([int(s.get("number") or 0) for s in aired] or [0])
            continue
        for season in sorted(seasons, key=lambda s: int(s.get("number") or 0)):
            number = int(season.get("number") or 0)
            if number <= entry["seasons"] or not season.get("premiereDate"):
                continue
            starts = date.fromisoformat(season["premiereDate"][:10])
            if today - timedelta(days=LATELY) <= starts <= today + timedelta(days=SOON):
                when = "is out" if starts <= today else f"starts {starts.strftime('%B %-d')}"
                cards.append({"title": f"{name} season {number} {when}"[:60], "why": "You finished the last one",
                              "request": f"Put {name} season {number} on my watch list and tell me where I can watch it."})
                entry["seasons"] = number
            break
    return cards


def look(root: Path, offer, now: float | None = None) -> int:
    """One look, when due and in the day: cards sent through `offer(cards) -> bool`. How many."""
    from . import followthrough
    now = now or time.time()
    if not followthrough.DAY_FROM <= datetime.fromtimestamp(now).hour < followthrough.DAY_TO:
        return 0
    if not followthrough.on(root, "arrivals"):
        return 0
    data = _state(root)
    if now - float(data.get("at") or 0) < EVERY:
        return 0
    data["at"] = now
    watching = _watch_items(root)
    # (a series ticked off: its poster came from TVmaze; a film's doesn't, and isn't looked up there)
    finished = {re.sub(r"\s*\((?:19|20)\d\d\)\s*$", "", str(item.get("text"))): True for _, item in watching
                if item.get("done") and "tvmaze" in str(item.get("poster") or "")}
    cards = []
    server = find(root)
    if server:
        try:
            cards += new_on_server(server, data, watching)
            user = _user(server)
            if user:
                got = _jellyfin(server, f"/Users/{user}/Items?Recursive=true&IncludeItemTypes=Series&Filters=IsPlayed&Limit=200")
                for media in (got or {}).get("Items") or [] if isinstance(got, dict) else []:
                    if isinstance(media, dict) and media.get("Name"):
                        finished.setdefault(str(media["Name"]), True)
        except Exception:
            log.debug("redde-push: Jellyfin look failed", exc_info=True)
    try:
        cards += new_seasons(list(finished), data, datetime.fromtimestamp(now).date(), now)
    except Exception:
        log.debug("redde-push: new seasons look failed", exc_info=True)
    cards = cards[:CARDS_AT_ONCE]
    if cards and not offer(cards):
        data["at"] = now - EVERY + 600      # try again in ten minutes
    _save(root, data)
    return len(cards)

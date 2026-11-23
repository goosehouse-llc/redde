"""A show card's posters, checked and found on the Hermes server (1.36.2, 2026-11-22). Asked for
Donnie Brasco, Sol "used a TMDb poster URL (movie id 9366) at a valid image CDN path": TMDb's poster
addresses are file names only TMDb knows, so the one it built went nowhere and the card showed its
film strip where the poster should be.

So before a show card goes to the phone (`cards.look_up`, which hands Redde the card as filled in),
each title's poster is read here, a few at once and for a few seconds at most:
- a poster that loads as a picture stays;
- one that is gone (400, 404, 410, a page that isn't a picture, a site that isn't found) or missing
  is looked for, with no key: a film on Wikipedia, whose page leads with its poster (the REST
  summary's `originalimage`: "<title> (<year> film)", "<title> (film)", then the title alone when
  its page says it's a film); a series on TVmaze (its show's `image`, the year matched when given),
  where Wikipedia's pages for series mostly lead with no picture (Severance's has none);
- one that can't be told (slow, a wall) is left as the agent wrote it;
- one on the person's own network (1.36.3: Sol gave Donnie Brasco's from the Jellyfin server,
  http://100.x… on the tailnet), http or https, isn't read here: it goes in `own_poster`, which
  Redde from 2.7 (298) shows first, and a poster is looked up for `poster` all the same, for an
  older Redde, which shows https posters only. `own` is the app's own test (`ReplyCards.ownNetwork`), by the
  address alone.
A dead poster with none found is taken off, so Redde doesn't try it. The fetching is products.py's:
public addresses only, redirects followed by hand. `GET` is the only way out, swapped in tests.
"""
from __future__ import annotations

import ipaddress
import json
import re
import time
from concurrent.futures import ThreadPoolExecutor, wait
from urllib.parse import quote, urljoin, urlsplit

from . import products

#: Who's asking: Wikimedia asks programs to say so, and answers a browser's name from a script
#: with 429s (2026-11-23: two titles of thirteen on a watch list).
HEADERS = {"User-Agent": "redde-push (https://github.com/goosehouse-llc/redde)", "Accept": "application/json, image/*;q=0.9, */*;q=0.5",
           "Accept-Encoding": "gzip", "Connection": "close"}
#: All of a card's posters: what isn't back by then is left as it was.
WAIT = 6.0
MOST = 6
KEYS = ("poster", "image", "picture", "own_poster")
_YEAR = re.compile(r"(1[89]\d\d|20\d\d)")
_NAMED_YEAR = re.compile(r"\s*\((1[89]\d\d|20\d\d)\)\s*$")
_KIND = re.compile(r"\b(film|movie|television|tv series|series|miniseries|sitcom|anime|documentary|serial)\b", re.I)


_HOME = (".local", ".lan", ".ts.net", ".internal", ".home.arpa")


def own(url: str) -> bool:
    """Whether a picture's address is on the person's own network: a private, Tailscale (CGNAT),
    loopback or link-local address, or a name only a home or a tailnet answers."""
    try:
        parts = urlsplit(url)
        host = (parts.hostname or "").lower()
    except ValueError:
        return False
    if parts.scheme.lower() not in ("http", "https") or not host:
        return False
    if host == "localhost" or host.endswith(_HOME) or ("." not in host and ":" not in host):
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    return address.is_private or address.is_loopback or address.is_link_local or address in products._CGNAT


def _get(url: str, deadline: float) -> tuple[str, int, dict, bytes]:
    """("ok", status, headers, body) once redirects are followed; else (why, 0, {}, b"") with why
    "dead" (the site isn't found), "refused" (not a public address) or "unknown"."""
    current = url
    for _ in range(products.MAX_REDIRECTS + 1):
        try:
            addresses = products.target(current)
        except products.NotFound:
            return "dead", 0, {}, b""
        except products.Refused:
            return "refused", 0, {}, b""
        except (OSError, ValueError):
            return "unknown", 0, {}, b""
        try:
            status, headers, body = products.fetch_once(current, addresses, deadline, HEADERS)
        except Exception:
            return "unknown", 0, {}, b""
        if status in (301, 302, 303, 307, 308) and headers.get("location"):
            current = urljoin(current, headers["location"].strip())
            continue
        return "ok", status, headers, body
    return "unknown", 0, {}, b""


GET = _get


class Found(str):
    """A poster's address, with the page it was found on (1.40.1: the card's title opens it)."""
    page: str | None = None

    @classmethod
    def at(cls, picture: str, page) -> "Found":
        made = cls(picture)
        made.page = page if isinstance(page, str) and page.startswith("https://") else None
        return made


def state(url: str, deadline: float) -> str:
    """"ok", "dead" or "unknown" for a picture's address."""
    how, status, headers, _ = GET(url, deadline)
    if how == "dead":
        return "dead"
    if how != "ok":
        return "unknown"
    if status in (400, 404, 410):
        return "dead"
    if status != 200:
        return "unknown"
    kind = headers.get("content-type", "").lower()
    return "ok" if kind.startswith("image/") else "dead" if "html" in kind or "json" in kind else "unknown"


def _summary(page: str, deadline: float) -> dict | None:
    url = "https://en.wikipedia.org/api/rest_v1/page/summary/" + quote(page.replace(" ", "_"), safe="()_,'!")
    how, status, _, body = GET(url, deadline)
    if how != "ok" or status != 200:
        return None
    try:
        found = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return None
    return found if isinstance(found, dict) and found.get("type") == "standard" else None


def wikipedia(title: str, year: str | None, series: bool | None, deadline: float) -> str | None:
    """The poster on the title's Wikipedia page, or None."""
    kinds = ["TV series"] if series else ["film"] if series is False else ["film", "TV series"]
    pages = [f"{title} ({year} {k})" for k in kinds if year] + [f"{title} ({k})" for k in kinds] + [title]
    plain = re.sub(r"\s+", " ", re.sub(r"[,!?]", "", title)).strip()   # "Love, Actually": the page is "Love Actually"
    if plain and plain != title:
        pages.append(plain)
    for page in pages:
        if time.monotonic() > deadline:
            return None
        found = _summary(page, deadline)
        if not found:
            continue
        said = str(found.get("description") or "")
        if page in (title, plain) and not (_KIND.search(said) and (not year or year in said or not _YEAR.search(said))):
            continue
        picture = (found.get("originalimage") or found.get("thumbnail") or {}).get("source")
        if isinstance(picture, str) and picture.startswith("https://"):
            return Found.at(picture, ((found.get("content_urls") or {}).get("mobile") or {}).get("page")
                            or ((found.get("content_urls") or {}).get("desktop") or {}).get("page"))
    return None


def tvmaze(title: str, year: str | None, deadline: float) -> str | None:
    """A series' poster on TVmaze, or None."""
    how, status, _, body = GET("https://api.tvmaze.com/search/shows?q=" + quote(title), deadline)
    if how != "ok" or status != 200:
        return None
    try:
        found = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return None
    wanted = " ".join(title.lower().split())
    for hit in found if isinstance(found, list) else []:
        show = hit.get("show") if isinstance(hit, dict) else None
        if not isinstance(show, dict) or " ".join(str(show.get("name") or "").lower().split()) != wanted:
            continue
        if year and not str(show.get("premiered") or "").startswith(year):
            continue
        picture = (show.get("image") or {}).get("original") or (show.get("image") or {}).get("medium")
        if isinstance(picture, str) and picture.startswith("https://"):
            return Found.at(picture, show.get("url"))
    return None


def _one(item: dict, deadline: float) -> str | None:
    """The poster an item should show: its own, one found, "" for none, or None to leave it."""
    given = next((item[k].strip() for k in KEYS if isinstance(item.get(k), str) and item[k].strip()), "")
    if own(given):
        given = ""
    if given.startswith("https://"):
        now = state(given, deadline)
        if now != "dead":
            return None
    title = str(item.get("title") or item.get("name") or "").strip()
    # (1.37.1: Sol named it "Donnie Brasco (1997)", the year in the name and nowhere else)
    named = _NAMED_YEAR.search(title)
    if named:
        title = title[:named.start()].strip()
    if not title:
        return None
    year = _YEAR.search(str(item.get("year") or "")) or named
    kind = str(item.get("format") or item.get("kind") or "").lower()
    series = True if "series" in kind or kind in ("tv", "show") else False if kind in ("movie", "film") else None
    found = lookup(title, year.group(1) if year else None, series, deadline)
    return found or ("" if given else None)


def lookup(title: str, year: str | None, series: bool | None, deadline: float) -> str | None:
    """A title's poster, with no key: a film's on Wikipedia, a series' on TVmaze, either when
    it isn't known which (1.37.0: also for the films and series on a watch list, `lists.py`)."""
    if series:
        return tvmaze(title, year, deadline) or wikipedia(title, year, series, deadline)
    return wikipedia(title, year, series, deadline) or (tvmaze(title, year, deadline) if series is None else None)


def fill(card: dict) -> dict:
    """The card with each title's poster checked, found or taken off."""
    key = next((k for k in ("items", "titles", "shows", "movies") if isinstance(card.get(k), list)), None)
    items = card[key] if key else [card]
    todo = [i for i in items[:MOST] if isinstance(i, dict)]
    if not todo:
        return card
    deadline = time.monotonic() + WAIT
    with ThreadPoolExecutor(max_workers=MOST) as pool:
        futures = {pool.submit(_one, item, deadline): item for item in todo}
        done, _ = wait(futures, timeout=WAIT + 0.5)
    filled = []
    for item in items:
        future = next((f for f, i in futures.items() if i is item), None)
        poster = future.result() if future in done and future.exception() is None else None
        home = next((item[k].strip() for k in KEYS if isinstance(item, dict) and isinstance(item.get(k), str) and own(item[k].strip())), None)
        if (poster is not None or home) and isinstance(item, dict):
            item = {k: v for k, v in item.items() if k not in KEYS}
            if poster:
                item["poster"] = str(poster)
                if getattr(poster, "page", None) and not item.get("url"):
                    item["url"] = poster.page      # (what a tap on the title opens, 1.40.1)
            if home:
                item["own_poster"] = home
        filled.append(item)
    return {**card, key: filled} if key else filled[0]

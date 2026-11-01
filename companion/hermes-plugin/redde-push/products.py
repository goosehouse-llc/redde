"""A purchase card's products checked against their own pages, before the card shows (asked
2026-10-31). Asked for smart plugs to buy, Home (a local model with no web search) filled a
'purchase' card with made-up products: Amazon links that went nowhere, no pictures, prices
guessed. "This does not show pictures, and all of the links were dead. I want it to be current."

So `redde_show` reads each product's page itself, on the Hermes server, a few at once and for a
few seconds at most (`check_card`):
- a link that is dead (the site isn't found, the connection is refused, the page is gone: 400,
  404, 410, or it sends you to the site's home or search page) is taken off its product, which
  stays, and the agent hears which;
- a page that loads gives what is true now: its price and currency (the page's win over the
  agent's), whether it is in stock, its picture where the product had none, and its rating and
  reviews where the agent gave none (schema.org Product data, then the Open Graph and product
  metas); the product is marked `checked` with the time, and the card's note says when;
- a store that won't show its page to a program (401, 403, 429, 503, Amazon's Robot Check, a
  captcha) leaves the product as the agent wrote it, unchecked but not dead.

Only public web addresses are read: http and https on ports 80 and 443, never an address on this
machine, the home network or the tailnet (private, loopback, link-local, CGNAT 100.64/10,
multicast, reserved), checked for the link and for every redirect, which are followed by hand,
three at most, each to the address that was checked. No cookies, no keys: a browser's ordinary
request. Nothing new to install: the standard library reads the pages.

`resolve` and `fetch_once` are the only ways out to the network, swapped in tests.
"""

from __future__ import annotations

import html
import http.client
import ipaddress
import json
import re
import socket
import ssl
import threading
import time
import zlib
from concurrent.futures import ThreadPoolExecutor, wait
from datetime import datetime, timezone
from urllib.parse import parse_qsl, urljoin, urlsplit

#: One page, its redirects included: connecting and reading.
PAGE_TIMEOUT = 4.0
#: All of a card's pages: what isn't back by then is left as the agent wrote it.
STEP_TIMEOUT = 5.0
#: Read no more of a page than this.
MAX_BODY = 1_500_000
MAX_REDIRECTS = 3
WORKERS = 6
#: A page's findings are kept this long, by its address: an agent that shows the card twice reads once.
KEEP = 600
PORTS = {"http": 80, "https": 443}
USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
              "Version/18.5 Safari/605.1.15")
HEADERS = {"User-Agent": USER_AGENT, "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5",
           "Accept-Language": "en-US,en;q=0.9", "Accept-Encoding": "gzip", "Connection": "close"}
#: The tailnet's addresses (and any carrier's NAT), which Python doesn't count as private.
_CGNAT = ipaddress.ip_network("100.64.0.0/10")
_NAT64 = ipaddress.ip_network("64:ff9b::/96")

_kept: dict[str, tuple[float, dict]] = {}
_kept_lock = threading.Lock()


class Refused(Exception):
    """An address this won't read: not a public web page."""


class NotFound(Exception):
    """The site's name doesn't exist."""


# ---- where a link may go

def public(address: str) -> bool:
    """Whether an IP address is out on the internet: not this machine, the home network, the
    tailnet, a multicast group or anything reserved."""
    try:
        ip = ipaddress.ip_address(address.split("%", 1)[0])
    except ValueError:
        return False
    if ip.version == 6:
        if ip.ipv4_mapped is not None:
            return public(str(ip.ipv4_mapped))
        if ip in _NAT64:
            return public(str(ipaddress.IPv4Address(int(ip) & 0xFFFFFFFF)))
    if ip.version == 4 and ip in _CGNAT:
        return False
    return ip.is_global and not (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast
                                 or ip.is_reserved or ip.is_unspecified)


def resolve(host: str) -> list[str]:
    """The host's addresses (raises socket.gaierror when it can't be found)."""
    infos = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    seen: list[str] = []
    for info in infos:
        address = info[4][0]
        if address not in seen:
            seen.append(address)
    return seen


def target(url: str) -> list[str]:
    """The addresses a link may be read at, all of them public; else Refused (or NotFound, for a
    name that doesn't exist)."""
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        raise Refused("not a web address")
    scheme = (parts.scheme or "").lower()
    if scheme not in PORTS:
        raise Refused("not an http or https address")
    if parts.username or parts.password:
        raise Refused("a link with a name and password in it")
    host = (parts.hostname or "").rstrip(".")
    if not host:
        raise Refused("no site in the address")
    if port is not None and port not in PORTS.values():
        raise Refused(f"port {port}")
    try:
        ipaddress.ip_address(host.split("%", 1)[0])
        addresses = [host]
    except ValueError:
        if host.lower() == "localhost" or host.lower().endswith((".localhost", ".local", ".internal", ".home.arpa")):
            raise Refused("an address on this network")
        try:
            addresses = resolve(host)
        except socket.gaierror as error:
            if error.errno in (socket.EAI_NONAME, getattr(socket, "EAI_NODATA", socket.EAI_NONAME)):
                raise NotFound(host)
            raise
    if not addresses or not all(public(a) for a in addresses):
        raise Refused("an address on this machine or a private network")
    return addresses


# ---- reading a page

def fetch_once(url: str, addresses: list[str], deadline: float) -> tuple[int, dict, bytes]:
    """One request, to an address that was checked (never looked up again: a name can't change
    its answer between the check and the visit): the status, the headers (lower case) and, for a
    200, the body, no more than MAX_BODY, unzipped."""
    parts = urlsplit(url)
    host = parts.hostname or ""
    secure = parts.scheme.lower() == "https"
    port = parts.port or (443 if secure else 80)
    path = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
    error: Exception | None = None
    for address in addresses[:3]:
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("out of time")
        try:
            sock = socket.create_connection((address, port), timeout=left)
        except OSError as e:
            error = e
            continue
        try:
            if secure:
                sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
            connection = http.client.HTTPConnection(host, port, timeout=left)
            connection.sock = sock
            connection.request("GET", path, headers=HEADERS)
            response = connection.getresponse()
            headers = {k.lower(): v for k, v in response.getheaders()}
            body = b""
            if response.status == 200:
                body = _read(response, sock, deadline, gzip="gzip" in headers.get("content-encoding", "").lower())
            return response.status, headers, body
        finally:
            try:
                sock.close()
            except OSError:
                pass
    raise error or OSError("no address")


def _read(response, sock, deadline: float, gzip: bool) -> bytes:
    unzip = zlib.decompressobj(16 + zlib.MAX_WBITS) if gzip else None
    out = bytearray()
    while len(out) < MAX_BODY:
        left = deadline - time.monotonic()
        if left <= 0:
            break
        try:    # (each wait is bounded by the socket's own time-out, set as it connected)
            sock.settimeout(left)
        except OSError:    # closed by http.client once the server said Connection: close; its reader still reads
            pass
        try:
            chunk = response.read1(65536)
        except (TimeoutError, socket.timeout):
            break
        if not chunk:
            break
        out += unzip.decompress(chunk, MAX_BODY - len(out)) if unzip else chunk
    return bytes(out[:MAX_BODY])


#: A page a program isn't shown: Amazon's Robot Check and its note on automated access, captchas,
#: Cloudflare's and others' checks.
_WALL = re.compile(r"robot check|to discuss automated access|captcha|are you a (?:human|robot)|just a moment\.\.\.|"
                   r"attention required!? \| cloudflare|pardon our interruption|access denied|request unsuccessful|"
                   r"verify you are (?:a )?human|unusual traffic", re.IGNORECASE)
#: A page that says it isn't there, with a 200.
_GONE = re.compile(r"^\s*(?:404\b|page not found|not found\b|error 404)|\b(?:page|product|item) (?:(?:was |could )?not (?:be )?found|"
                   r"(?:is )?no longer available|doesn.t exist)\b|\bwe couldn.t find (?:that|this|the) page\b", re.IGNORECASE)
#: Where a dead product's link is sent: a search.
_SEARCH_PATH = re.compile(r"/(?:s|search|sch|find|results|catalogsearch)(?:/|$|\.)|/search", re.IGNORECASE)
_SEARCH_KEYS = {"k", "q", "query", "keyword", "keywords", "searchterm", "st", "search_query", "_nkw", "text"}


def _homeward(before: str, after: str) -> bool:
    """A redirect that gives up on the product: to the site's home page or a search."""
    a, b = urlsplit(before), urlsplit(after)
    if b.path in ("", "/") and not b.query and a.path not in ("", "/"):
        return True
    searched = bool(_SEARCH_PATH.search(b.path)) or any(k.lower() in _SEARCH_KEYS for k, _ in parse_qsl(b.query))
    was_search = bool(_SEARCH_PATH.search(a.path)) or any(k.lower() in _SEARCH_KEYS for k, _ in parse_qsl(a.query))
    return searched and not was_search


def look(url: str) -> dict:
    """What a product's page says: {"state": "page", "found": {...}} for a page read, "dead" (with
    "why") for a link that goes nowhere, "wall" for a store that won't show a program its page,
    "refused" for an address this won't read, "unchecked" (with "why") for anything else. Kept
    for KEEP seconds by address, but not what may be different in a moment (a time-out)."""
    now = time.time()
    with _kept_lock:
        hit = _kept.get(url)
        if hit and now - hit[0] < KEEP:
            return hit[1]
    outcome = _look(url)
    if outcome["state"] in ("page", "dead", "wall", "refused"):
        with _kept_lock:
            if len(_kept) > 300:
                for old in sorted(_kept, key=lambda u: _kept[u][0])[:100]:
                    _kept.pop(old, None)
            _kept[url] = (time.time(), outcome)
    return outcome


def _look(url: str) -> dict:
    deadline = time.monotonic() + PAGE_TIMEOUT
    first = current = url
    for _ in range(MAX_REDIRECTS + 1):
        try:
            addresses = target(current)
        except NotFound:
            return {"state": "dead", "why": "the site isn't found", "network": True}
        except Refused as refusal:
            return {"state": "refused", "why": str(refusal)}
        except (OSError, ValueError) as error:
            return {"state": "unchecked", "why": f"the site's name couldn't be looked up ({type(error).__name__})"}
        try:
            status, headers, body = fetch_once(current, addresses, deadline)
        except ConnectionRefusedError:
            return {"state": "dead", "why": "the site refuses connections", "network": True}
        except (TimeoutError, socket.timeout):
            return {"state": "unchecked", "why": "too slow"}
        except Exception as error:    # a broken page, a bad certificate, a reset: as the agent wrote it
            return {"state": "unchecked", "why": f"couldn't be read ({type(error).__name__})"}
        if status in (301, 302, 303, 307, 308):
            location = headers.get("location")
            if not location:
                return {"state": "unchecked", "why": f"a redirect ({status}) to nowhere"}
            following = urljoin(current, location.strip())
            if _homeward(first, following):
                return {"state": "dead", "why": "it goes to the store's home or search page, not the product"}
            current = following
            continue
        if status in (400, 404, 410):
            return {"state": "dead", "why": f"the page isn't there ({status})"}
        if status in (401, 403, 429, 503):
            return {"state": "wall", "why": f"the store doesn't show its page to a program ({status})"}
        if status != 200:
            return {"state": "unchecked", "why": f"the store answered {status}"}
        kind = headers.get("content-type", "text/html").lower()
        if "html" not in kind:
            return {"state": "unchecked", "why": "not a web page"}
        text = _decode(body, kind)
        found = read_page(text, current)
        title = _title(text)
        if "price" not in found and title and _GONE.search(title):
            return {"state": "dead", "why": "the page says it isn't there"}
        if not found and (_WALL.search(title) or _WALL.search(text[:20000])):
            return {"state": "wall", "why": "the store asks if it's a robot"}
        return {"state": "page", "found": found, "url": current}
    return {"state": "unchecked", "why": "too many redirects"}


def _decode(body: bytes, kind: str) -> str:
    charset = re.search(r"charset=([\w-]+)", kind)
    try:
        return body.decode(charset.group(1) if charset else "utf-8", errors="replace")
    except LookupError:
        return body.decode("utf-8", errors="replace")


# ---- what a page says of its product

_META = re.compile(r"<meta\b[^>]*>", re.IGNORECASE)
_ITEMPROP = re.compile(r"<[a-zA-Z]+\b[^>]*\bitemprop\s*=[^>]*>")
_ATTR = re.compile(r"""([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))""")
_LD = re.compile(r"<script\b[^>]*type\s*=\s*[\"']?application/ld\+json[\"']?[^>]*>(.*?)</script\s*>", re.IGNORECASE | re.DOTALL)
_TITLE = re.compile(r"<title\b[^>]*>(.*?)</title\s*>", re.IGNORECASE | re.DOTALL)
_PRODUCT_TYPES = {"product", "productgroup", "individualproduct", "productmodel", "vehicle", "book"}


def _attrs(tag: str) -> dict:
    return {m.group(1).lower(): html.unescape(m.group(2) if m.group(2) is not None else m.group(3) if m.group(3) is not None else m.group(4))
            for m in _ATTR.finditer(tag)}


def _title(text: str) -> str:
    found = _TITLE.search(text[:200_000])
    return " ".join(html.unescape(found.group(1)).split()) if found else ""


def read_page(text: str, url: str) -> dict:
    """What a product page says of the product: price, currency, availability ("in_stock" or
    "out_of_stock"), rating, reviews, name, brand and image (https), from its schema.org Product
    data (also inside @graph or lists), then its Open Graph and product metas. Only what it says."""
    found: dict = {}
    for block in _LD.findall(text):
        for data in _json(block):
            for product in _products(data):
                _from_product(product, url, found)
                if "price" in found:
                    break
            if "price" in found:
                break
        if "price" in found:
            break
    metas: dict[str, str] = {}
    for tag in _META.findall(text):
        attrs = _attrs(tag)
        key = (attrs.get("property") or attrs.get("name") or attrs.get("itemprop") or "").lower()
        if key and "content" in attrs and key not in metas:
            metas[key] = attrs["content"].strip()
    # schema.org microdata on any tag: <span itemprop="price" content="24.99">, <link itemprop="availability" href=…>.
    for tag in _ITEMPROP.findall(text):
        attrs = _attrs(tag)
        value = attrs.get("content") or attrs.get("href") or attrs.get("src")
        if value:
            metas.setdefault((attrs.get("itemprop") or "").lower(), value.strip())
    if "amazon." in (urlsplit(url).hostname or ""):
        _amazon(text, url, found)
    if "image" not in found:
        for key in ("og:image:secure_url", "og:image", "twitter:image", "twitter:image:src", "image"):
            image = _image(metas.get(key), url)
            if image:
                found["image"] = image
                break
    if "price" not in found:
        for amount, currency in (("product:price:amount", "product:price:currency"), ("og:price:amount", "og:price:currency"),
                                 ("product:sale_price:amount", "product:sale_price:currency"), ("price", "pricecurrency")):
            price = _amount(metas.get(amount))
            if price:
                found["price"] = price
                code = _currency(metas.get(currency))
                if code:
                    found["currency"] = code
                break
    if "availability" not in found:
        stock = _stock(metas.get("product:availability") or metas.get("og:availability") or metas.get("availability"))
        if stock:
            found["availability"] = stock
    if "rating" not in found and _amount(metas.get("ratingvalue")):
        found["rating"] = round(min(5.0, _amount(metas["ratingvalue"]) / (_amount(metas.get("bestrating")) or 5) * 5), 1)
        if _amount(metas.get("reviewcount")):
            found["reviews"] = int(_amount(metas["reviewcount"]))
    return found


#: Amazon's own pages carry no schema.org data: the buy box's price, the stock line, the stars and
#: the main picture, as its desktop page writes them (2026-10-31).
_AMAZON_CURRENCY = {"com": "USD", "ca": "CAD", "co.uk": "GBP", "de": "EUR", "fr": "EUR", "it": "EUR", "es": "EUR", "nl": "EUR",
                    "ie": "EUR", "com.au": "AUD", "co.jp": "JPY", "in": "INR", "com.mx": "MXN", "com.br": "BRL", "se": "SEK", "pl": "PLN"}


def _amazon(text: str, url: str, found: dict) -> None:
    host = (urlsplit(url).hostname or "").lower()
    currency = _AMAZON_CURRENCY.get(host.split("amazon.", 1)[-1])
    if "price" not in found:
        price = None
        box = re.search(r'"desktop_buybox_group_1"\s*:\s*\[\s*\{[^}]*?"priceAmount"\s*:\s*([\d.]+)', text)
        if box:
            price = _amount(box.group(1))
        else:
            core = re.search(r'id="(?:corePriceDisplay_desktop_feature_div|corePrice_feature_div)"', text)
            shown = re.search(r'class="a-offscreen">\s*([^<]{1,24})<', text[core.end():core.end() + 20000]) if core else None
            price = _amount(shown.group(1)) if shown else None
        if price:
            found["price"] = price
            if currency:
                found["currency"] = currency
    if "availability" not in found:
        line = re.search(r'id="availability"[^>]*>\s*(?:<[^>]*>\s*)*([^<]{2,80})<', text)
        said = line.group(1).strip().lower() if line else ""
        if re.search(r"\bin stock\b|\bleft in stock\b", said):
            found["availability"] = "in_stock"
        elif re.search(r"currently unavailable|out of stock", said):
            found["availability"] = "out_of_stock"
    if "rating" not in found:
        stars = re.search(r'id="acrPopover"[^>]*title="([\d.,]+) out of 5', text)
        if stars and _amount(stars.group(1)):
            found["rating"] = round(min(5.0, _amount(stars.group(1))), 1)
            count = re.search(r'id="acrCustomerReviewText"[^>]*>\s*\(?([\d.,]+)', text)
            if count and _amount(count.group(1)):
                found["reviews"] = int(re.sub(r"\D", "", count.group(1)))
    if "image" not in found:
        tag = re.search(r'<img\b[^>]*\bid="landingImage"[^>]*>', text)
        if tag:
            attrs = _attrs(tag.group(0))
            image = _image(attrs.get("data-old-hires") or attrs.get("src"), url)
            if image:
                found["image"] = image


def _json(block: str) -> list:
    cleaned = block.strip()
    for wrapper in ("<!--", "-->", "/*<![CDATA[*/", "/*]]>*/", "<![CDATA[", "]]>"):
        cleaned = cleaned.replace(wrapper, "")
    try:
        return [json.loads(cleaned, strict=False)]
    except ValueError:
        return []


def _types(node: dict) -> set[str]:
    kinds = node.get("@type")
    kinds = kinds if isinstance(kinds, list) else [kinds]
    return {str(k).rsplit("/", 1)[-1].lower() for k in kinds if k}


def _products(node, depth: int = 0):
    """Products in JSON-LD, the page's own first: a Product, in a list, in @graph or as mainEntity."""
    if depth > 6:
        return
    if isinstance(node, list):
        for each in node:
            yield from _products(each, depth + 1)
    elif isinstance(node, dict):
        if _types(node) & _PRODUCT_TYPES:
            yield node
        for key in ("@graph", "mainEntity", "mainEntityOfPage"):
            if isinstance(node.get(key), (dict, list)):
                yield from _products(node[key], depth + 1)


def _from_product(product: dict, url: str, found: dict) -> None:
    offer = _offer(product.get("offers"))
    if offer is None and isinstance(product.get("hasVariant"), list):    # a ProductGroup's first variant
        for variant in product["hasVariant"]:
            if isinstance(variant, dict):
                offer = _offer(variant.get("offers"))
                if offer is not None:
                    break
    if offer is not None:
        price = _amount(offer.get("price")) or _amount(offer.get("lowPrice"))
        spec = offer.get("priceSpecification")
        spec = spec[0] if isinstance(spec, list) and spec and isinstance(spec[0], dict) else spec
        if not price and isinstance(spec, dict):
            price = _amount(spec.get("price"))
        if price and "price" not in found:
            found["price"] = price
            code = _currency(offer.get("priceCurrency")) or (_currency(spec.get("priceCurrency")) if isinstance(spec, dict) else None)
            if code:
                found["currency"] = code
        stock = _stock(offer.get("availability"))
        if stock and "availability" not in found:
            found["availability"] = stock
    rating = product.get("aggregateRating")
    if isinstance(rating, dict) and "rating" not in found:
        value = _amount(rating.get("ratingValue"))
        best = _amount(rating.get("bestRating")) or 5
        if value and best:
            found["rating"] = round(min(5.0, value / best * 5), 1)
            count = _amount(rating.get("reviewCount")) or _amount(rating.get("ratingCount"))
            if count:
                found["reviews"] = int(count)
    name = product.get("name")
    if isinstance(name, str) and name.strip() and "name" not in found:
        found["name"] = " ".join(html.unescape(name).split())[:160]
    brand = product.get("brand")
    brand = brand.get("name") if isinstance(brand, dict) else brand[0] if isinstance(brand, list) and brand and isinstance(brand[0], str) else brand
    if isinstance(brand, str) and brand.strip() and "brand" not in found:
        found["brand"] = " ".join(html.unescape(brand).split())[:60]
    image = _image(product.get("image"), url)
    if image and "image" not in found:
        found["image"] = image


def _offer(offers) -> dict | None:
    """The offer that has a price: the first of a list, or an AggregateOffer's."""
    if isinstance(offers, list):
        listed = [o for o in offers if isinstance(o, dict)]
        return next((o for o in listed if _amount(o.get("price")) or _amount(o.get("lowPrice"))), listed[0] if listed else None)
    if isinstance(offers, dict):
        inner = offers.get("offers")
        if not (_amount(offers.get("price")) or _amount(offers.get("lowPrice"))) and isinstance(inner, (list, dict)):
            return _offer(inner) or offers
        return offers
    return None


def _image(value, url: str) -> str | None:
    if isinstance(value, list):
        value = next((v for v in value if v), None)
    if isinstance(value, dict):
        value = value.get("url") or value.get("contentUrl")
    if not isinstance(value, str) or not value.strip():
        return None
    image = urljoin(url, html.unescape(value.strip()))
    if not image.lower().startswith("https://") or len(image) >= 2000:
        return None
    # A shop's thumbnail asked for small (Shopify's "&width=100"): big enough for the card.
    small = re.search(r"([?&]width=)(\d+)", image)
    return image[:small.start(2)] + "600" + image[small.end(2):] if small and int(small.group(2)) < 400 else image


def _amount(value) -> float | None:
    """A positive amount: 29.99, "29.99", "$1,299.00", "1.299,00 €"."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value) if value > 0 and value == value and value < 1e9 else None
    if not isinstance(value, str):
        return None
    digits = re.sub(r"[^\d.,]", "", value)
    if not digits or not re.search(r"\d", digits):
        return None
    comma, dot = digits.rfind(","), digits.rfind(".")
    if comma >= 0 and dot >= 0:
        digits = digits.replace(".", "").replace(",", ".") if comma > dot else digits.replace(",", "")
    elif comma >= 0:
        digits = digits.replace(",", "") if len(digits) - comma - 1 == 3 or digits.count(",") > 1 else digits.replace(",", ".")
    elif digits.count(".") > 1:
        digits = digits.replace(".", "")
    try:
        amount = float(digits)
    except ValueError:
        return None
    return amount if 0 < amount < 1e9 else None


def _currency(value) -> str | None:
    if isinstance(value, str) and re.fullmatch(r"\s*[A-Za-z]{3}\s*", value):
        return value.strip().upper()
    return None


def _stock(value) -> str | None:
    """schema.org's availability ("https://schema.org/InStock"), or a meta's words ("instock", "oos")."""
    if not isinstance(value, str):
        return None
    said = re.sub(r"[^a-z]", "", value.rsplit("/", 1)[-1].lower())
    if said in ("instock", "limitedavailability", "instoreonly", "onlineonly", "available"):
        return "in_stock"
    if said in ("outofstock", "soldout", "discontinued", "oos", "unavailable"):
        return "out_of_stock"
    return None


# ---- the card

def _when(at: datetime, tz) -> str:
    """"Oct 31, 3:42 PM", in the person's zone where it is known, else this server's in UTC."""
    local = at.astimezone(tz) if tz is not None else at
    hour = local.hour % 12 or 12
    said = f"{local:%b} {local.day}, {hour}:{local:%M} {'AM' if local.hour < 12 else 'PM'}"
    return said if tz is not None else said + " UTC"


def _money(price: float, currency: str | None) -> str:
    return f"{price:,.2f}".replace(".00", "") + (f" {currency}" if currency else "")


def check_card(card: dict, tz=None, now: datetime | None = None, limit: int = 6) -> tuple[dict, str | None]:
    """A purchase card with its products checked against their pages (see the module's words),
    and the line the agent answers from. A card without links comes back as it was."""
    key = "items" if isinstance(card.get("items"), list) else "products" if isinstance(card.get("products"), list) else None
    if key is None:
        return card, None
    items = [dict(i) if isinstance(i, dict) else i for i in card[key]]
    links: dict[int, str] = {}
    for n, item in enumerate(items[:limit]):
        if isinstance(item, dict):
            link = item.get("url") or item.get("link")
            if isinstance(link, str) and link.strip():
                links[n] = link.strip()
    if not links:
        return card, None
    outcomes: dict[str, dict] = {}
    unique = list(dict.fromkeys(links.values()))
    pool = ThreadPoolExecutor(max_workers=min(WORKERS, len(unique)), thread_name_prefix="redde-products")
    try:
        futures = {pool.submit(look, url): url for url in unique}
        done, _ = wait(futures, timeout=STEP_TIMEOUT)
        for future in done:
            try:
                outcomes[futures[future]] = future.result()
            except Exception as error:    # never the card's undoing
                outcomes[futures[future]] = {"state": "unchecked", "why": type(error).__name__}
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
    for url in unique:
        outcomes.setdefault(url, {"state": "unchecked", "why": "too slow"})
    # Every link "not found" or refused at once is this server offline, not the stores gone.
    offline = all(o["state"] == "dead" and o.get("network") for o in outcomes.values())
    at = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    checked, removed, unchecked = [], [], []
    for n, url in links.items():
        item, outcome = items[n], outcomes[url]
        name = str(item.get("name") or item.get("title") or f"product {n + 1}").strip()
        state = outcome["state"]
        if state == "dead" and not offline:
            item.pop("url", None)
            item.pop("link", None)
            removed.append(f"{name} ({outcome['why']})")
        elif state == "page" and _apply(item, outcome.get("found") or {}, at):
            facts = [_money(item["price"], item.get("currency")) if isinstance(item.get("price"), float) else "",
                     {"in_stock": "in stock", "out_of_stock": "out of stock"}.get(item.get("availability"), "")]
            checked.append(name + (f" {', '.join(f for f in facts if f)}" if any(facts) else ""))
        elif state == "page":
            unchecked.append(f"{name} (its page shows no price)")
        elif state == "dead":
            unchecked.append(f"{name} (the stores couldn't be reached from here)")
        else:
            unchecked.append(f"{name} ({outcome.get('why') or 'not read'})")
    filled = {**card, key: items}
    if checked:
        old = card.get("note") if isinstance(card.get("note"), str) else ""
        stamp = f"Prices checked {_when(at, tz)}"
        filled["note"] = stamp if not old.strip() or re.search(r"\b(?:checked|as of|prices?)\b", old, re.IGNORECASE) else f"{stamp}. {old.strip()}"
    parts = []
    if checked:
        parts.append("from their pages now: " + "; ".join(checked))
    if removed:
        parts.append("links removed (dead): " + "; ".join(removed))
    if unchecked:
        parts.append("not checked: " + "; ".join(unchecked) + ". Don't present those prices as checked")
    line = "purchase: " + ". ".join(parts)
    if checked or removed:
        line += ". The card shows what the pages say: answer from it, not from what you wrote"
    return filled, line


def _apply(item: dict, found: dict, at: datetime) -> bool:
    """What the page says, onto the product. The page's price is the price; its rating, reviews,
    brand and picture fill only what the agent left out. True if anything came from the page."""
    used = False
    price = found.get("price")
    if price:
        item["price"] = float(price)
        if found.get("currency"):
            item["currency"] = found["currency"]
        was = _amount(item.get("was_price"))
        if was is not None and was <= price:
            item.pop("was_price", None)
        used = True
    if found.get("availability"):
        item["availability"] = found["availability"]
        used = True
    if found.get("image") and not (isinstance(item.get("image"), str) and item["image"].lower().startswith("https://")):
        item["image"] = found["image"]
        used = True
    if found.get("rating") and item.get("rating") in (None, "", 0):
        item["rating"] = found["rating"]
        if found.get("reviews") and item.get("reviews") in (None, "", 0):
            item["reviews"] = found["reviews"]
        used = True
    if found.get("brand") and not item.get("brand"):
        item["brand"] = found["brand"]
    if used:
        item["checked"] = at.isoformat(timespec="seconds")
    return used

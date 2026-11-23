"""Paperless (1.40.0, with bills and renewals): each document new in the person's Paperless-ngx is
read once for a bill's day due or something that runs out (`followthrough.from_paper`), the same
as mail. Found from PAPERLESS_URL (or _BASE_URL, _HOST, _API_URL) and a PAPERLESS_…TOKEN or
PAPERLESS_API_KEY in any profile's .env (`envs.py`). The first look only remembers where it's up
to. At most every two hours, in the day; only the newest few documents, their text only.
"""
from __future__ import annotations

import json
import logging
import os
import re
import time
import urllib.request
from datetime import datetime
from pathlib import Path

log = logging.getLogger("redde_push.paper")

FILE = "paper.json"
URL_NAMES = ("PAPERLESS_URL", "PAPERLESS_BASE_URL", "PAPERLESS_HOST", "PAPERLESS_API_URL")
KEY_NAMES = ("PAPERLESS_TOKEN", "PAPERLESS_API_TOKEN", "PAPERLESS_API_KEY")
KEY_SHAPE = r"PAPERLESS_\w*TOKEN"
EVERY, NEWEST, TIMEOUT = 7200, 20, 15.0

#: (url, headers) -> parsed JSON or None; swapped in tests.
FETCH = None


def find(root: Path) -> dict | None:
    from . import envs
    found = envs.find(root, URL_NAMES, KEY_NAMES, key_pattern=KEY_SHAPE)
    if found:
        found["url"] = re.sub(r"/api/?$", "", found["url"])
    return found


def status(root: Path) -> dict:
    found = find(root)
    return {"found": bool(found), **({"profile": found["profile"]} if found else {})}


def _fetch(url: str, key: str) -> object | None:
    headers = {"Authorization": f"Token {key}", "Accept": "application/json; version=5"}
    if FETCH is not None:
        return FETCH(url, headers)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=TIMEOUT) as answer:
            return json.loads(answer.read(8_000_000).decode("utf-8", "replace"))
    except Exception:
        return None


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
    temp.write_text(json.dumps(data))
    os.chmod(temp, 0o600)
    temp.replace(path)


def look(root: Path, now: float | None = None) -> int:
    """New documents read for bills and expiries. How many were read."""
    from . import followthrough
    now = now or time.time()
    if not followthrough.DAY_FROM <= datetime.fromtimestamp(now).hour < followthrough.DAY_TO:
        return 0
    if not followthrough.on(root, "orders"):
        return 0
    data = _state(root)
    if now - float(data.get("at") or 0) < EVERY:
        return 0
    data["at"] = now
    server = find(root)
    if not server:
        _save(root, data)
        return 0
    got = _fetch(f"{server['url']}/api/documents/?ordering=-id&page_size={NEWEST}"
                 "&fields=id,title,content,correspondent,created", server["key"])
    docs = got.get("results") if isinstance(got, dict) else None
    if not isinstance(docs, list):
        _save(root, data)
        return 0
    docs = [d for d in docs if isinstance(d, dict) and isinstance(d.get("id"), int)]
    last = int(data.get("last_id") or 0)
    fresh = [d for d in docs if d["id"] > last] if last else []
    if docs:
        data["last_id"] = max([last] + [d["id"] for d in docs])
    if fresh:
        names = {}
        if any(d.get("correspondent") for d in fresh):
            listed = _fetch(f"{server['url']}/api/correspondents/?page_size=500&fields=id,name", server["key"])
            names = {c.get("id"): c.get("name") for c in (listed or {}).get("results") or []} if isinstance(listed, dict) else {}
        with followthrough._locked(root):
            kept = followthrough.load(root)
            for doc in sorted(fresh, key=lambda d: d["id"]):
                doc["correspondent_name"] = names.get(doc.get("correspondent"))
                followthrough.from_paper(kept, doc, now)
            followthrough.save(root, kept)
    _save(root, data)
    return len(fresh)

"""A service the person's bots already reach (Jellyfin, Paperless), found by the names its address
and key go by in any profile's .env (1.40.0, shared by `arrivals.py` and `paper.py`). Only the names
asked for are read; values go to that service alone, never to the app (which is told whether one
was found, and in which profile)."""
from __future__ import annotations

import os
import re
from pathlib import Path


def _env(path: Path, wanted) -> dict[str, str]:
    found = {}
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return found
    for line in lines:
        name, _, value = line.strip().removeprefix("export ").partition("=")
        name = name.strip()
        if wanted(name) and value.strip():
            found[name] = value.strip().strip("'\"")
    return found


def key(root: Path, names: tuple[str, ...]) -> str | None:
    """The first of `names` set in the environment or in a profile's .env (the main one first), for a
    service that needs only a key (1.44.0: TMDb), or None."""
    for name in names:
        if os.environ.get(name, "").strip():
            return os.environ[name].strip()
    root = Path(root)
    homes = [root]
    if (root / "profiles").is_dir():
        homes += [h for h in sorted((root / "profiles").iterdir()) if h.is_dir()]
    for home in homes:
        values = _env(home / ".env", lambda n: n in names)
        found = next((values[n] for n in names if values.get(n)), None)
        if found:
            return found
    return None


def find(root: Path, urls: tuple[str, ...], keys: tuple[str, ...], users: tuple[str, ...] = (),
         key_pattern: str | None = None) -> dict | None:
    """{url, key, user, profile} from the first profile (the main one first) whose .env has an
    address and a key, or None. `key_pattern` also takes a key by its name's shape
    (PAPERLESS_WATCHER_TOKEN)."""
    root = Path(root)
    shape = re.compile(key_pattern) if key_pattern else None

    def wanted(name: str) -> bool:
        return name in urls or name in keys or name in users or bool(shape and shape.fullmatch(name))

    homes = [("default", root)]
    if (root / "profiles").is_dir():
        homes += [(h.name, h) for h in sorted((root / "profiles").iterdir()) if h.is_dir()]
    for profile, home in homes:
        values = _env(home / ".env", wanted)
        if profile == "default":
            values = {**{k: v for k, v in os.environ.items() if wanted(k)}, **values}
        url = next((values[n] for n in urls if values.get(n)), None)
        key = next((values[n] for n in keys if values.get(n)), None) \
            or next((v for n, v in sorted(values.items()) if shape and shape.fullmatch(n)), None)
        if url and key:
            if not re.match(r"https?://", url, re.IGNORECASE):
                url = "http://" + url
            return {"url": url.rstrip("/"), "key": key, "user": next((values[n] for n in users if values.get(n)), None),
                    "profile": profile}
    return None

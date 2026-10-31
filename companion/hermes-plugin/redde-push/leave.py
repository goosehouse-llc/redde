"""Leave-By Alerts' traffic re-check (asked 2026-10-30, "so the last minutes don't depend on iOS's
background schedule"): Redde works out on the device when to leave for each event at an address
and sets a notification for then. iOS runs the app in the background when it likes, so the
traffic can change after the last time Redde looked. This Hermes wakes the device about twenty
minutes before the leaving time instead: a sealed note of its own kind ("leave") to that one
device, whose notification extension asks Apple Maps again and moves the alert.

What the app hands over, over the Dashboard (`/redde-push leave set <device ids> <wakes>`, a
plugin command): for each alert, an opaque id (a hash of the device's own identifier for it), the
event's title for the note, and when to wake it. No address, no place, no calendar. What it says
is all of that device's wakes: one moved replaces its old time, one gone is no longer listed, and
`leave cancel <device ids>` (Leave-By Alerts turned off) takes them all. A device unpaired is
forgotten with its wakes (`core.Store.remove`).

`Routines`' thread (every half minute, in whichever process holds its lock) sends each wake at its
time and forgets it. One more than `LATE` past its time (Hermes was down) is let go unsent: its
leaving time has come or gone, and a check then would only say so.
"""

from __future__ import annotations

import json
import re
import time

from . import core

#: The most wakes kept for one device: the soonest.
LIMIT = 30
#: A wake this late is let go unsent, in seconds.
LATE = 15 * 60
_ID = re.compile(r"^[0-9a-f]{16,64}$")


def parse(payload: str) -> list[dict] | None:
    """The app's list of wakes (base64url JSON, `[{"i": id, "t": title, "w": when}]`, or "-" for
    none), checked and cut to what is kept; None for one that can't be read."""
    if payload == "-":
        return []
    try:
        listed = json.loads(core.unb64u(payload))
    except Exception:
        return None
    if not isinstance(listed, list):
        return None
    wakes = []
    for wake in listed:
        if not isinstance(wake, dict) or not isinstance(wake.get("i"), str) or not _ID.match(wake["i"]):
            continue
        try:
            at = int(float(wake.get("w")))
        except (TypeError, ValueError):
            continue
        wakes.append({"i": wake["i"], "t": core.clipped(str(wake.get("t") or ""), 80), "w": at})
    by_id = {w["i"]: w for w in sorted(wakes, key=lambda w: w["w"])}   # one wake an alert: the last said
    return sorted(by_id.values(), key=lambda w: w["w"])[:LIMIT]


def set_wakes(store: core.Store, device_ids: list[str], wakes: list[dict], now: float | None = None) -> tuple[list[str], int]:
    """These devices' wakes, all of them: what they said before goes. Those already more than
    `LATE` gone are left out. Returns the devices paired here, and how many wakes each keeps."""
    now = time.time() if now is None else now
    known = {d.get("id") for d in store.devices}
    mine = [i for i in dict.fromkeys(device_ids) if i in known]
    if not mine:
        return [], 0
    kept = [dict(w) for w in wakes if w["w"] >= now - LATE][:LIMIT]
    held = {d: w for d, w in store.leave_wakes().items() if d in known}
    for device in mine:
        held[device] = kept
    store.set_leave_wakes(held)
    return mine, len(kept)


def due(store: core.Store, now: float | None = None) -> list[tuple[dict, dict]]:
    """The wakes whose time has come, as (device, note), each once: taken out of the store as they
    are handed back. Ones more than `LATE` late, and any for a device no longer paired, go unsent.
    Under a lock across Hermes's processes; another holding it now: nothing."""
    now = time.time() if now is None else now
    held = store.leave_wakes()
    if not held:
        return []
    with store.rooms_lock("leave") as mine:
        if not mine:
            return []
        held = store.leave_wakes()   # (read again under the lock: another may have sent some)
        devices = {d.get("id"): d for d in store.devices}
        outgoing, left, changed = [], {}, False
        for device_id, wakes in held.items():
            device = devices.get(device_id)
            if device is None:
                changed = True
                continue
            waiting = []
            for wake in wakes:
                if wake.get("w", 0) > now:
                    waiting.append(wake)
                    continue
                changed = True
                if now - wake.get("w", 0) <= LATE:
                    outgoing.append((device, core.leave_note(str(wake.get("i") or ""), str(wake.get("t") or ""))))
            left[device_id] = waiting
        if changed:
            store.set_leave_wakes(left)
        return outgoing


def send_due(store: core.Store, send, now: float | None = None) -> int:
    """Sends what `due` hands back, each to its one device; how many went."""
    return sum(send([device], made) for device, made in due(store, now))


def slash(store: core.Store, words: list[str]) -> str:
    """`/redde-push leave`, the app's: `set <device ids> <wakes>` and `cancel <device ids>`.
    Answers "redde-push leave <devices paired here> <wakes kept>"."""
    if len(words) == 3 and words[0] == "set":
        wakes = parse(words[2])
        if wakes is None:
            return "redde-push refused: those wakes can't be read"
        mine, kept = set_wakes(store, [w for w in words[1].split(",") if w], wakes)
        return f"redde-push leave {len(mine)} {kept}"
    if len(words) == 2 and words[0] == "cancel":
        mine, _ = set_wakes(store, [w for w in words[1].split(",") if w], [])
        return f"redde-push leave {len(mine)} 0"
    return "redde-push: leave set <device ids> <wakes> | leave cancel <device ids>"

"""Group chats (Hermes's hosted bot rooms) as Redde runs them (lab.sh groups), over the Dashboard socket:

  capabilities  `groups.capabilities` lists the room methods, and the room worker is running
                (`driver`; it starts a moment after the Dashboard, so it is asked again).
  create        a room with the main profile and one more (`groups.create`, members as objects).
  send          a message to everyone (`groups.send`, a fresh `event_id`, thread "main"): each
                member answers, and the log (`groups.log`, read since a cursor) has the message,
                both replies by member, and the round's end (`room.activity`).
  mention       a message tagging one member: only that one answers.
  stop          `groups.stop` with a fresh `cancel_id` is taken.
  rename        `groups.rename` changes the name `groups.list` gives.
  disband       `groups.disband`: the room leaves the list.

Mirrors HermesServeClient's room calls (Echo/Services/Transport/ServerGroups.swift).
Run against a lab that is up with the approval scenario.
"""
import asyncio
import json
import time
import uuid

import check
from check import Dashboard, report

BOT = "scout"


async def log_until(dash, room, cursor, done, seconds=60):
    """Reads the room's log from `cursor` until `done(events)` or `seconds` pass."""
    events = []
    deadline = time.time() + seconds
    while time.time() < deadline:
        page = await dash.call("groups.log", {"room_id": room, "since_seq": cursor, "limit": 200})
        for e in page.get("events") or []:
            if e.get("seq", 0) > cursor:
                events.append(e)
                cursor = e["seq"]
        if done(events):
            break
        await asyncio.sleep(1)
    return events, cursor


def said(events):
    return [(e["kind"], (e.get("actor") or {}).get("id"), str((e.get("payload") or {}).get("text") or "")[:30])
            for e in events if e["kind"] in ("message.user", "message.member")]


async def main():
    dash = await Dashboard.connect()
    await dash.call("profiles.create", {"name": BOT, "clone_from": "default", "no_alias": True})
    caps = {}
    for _ in range(20):
        caps = await dash.call("groups.capabilities", {})
        if caps.get("driver"):
            break
        await asyncio.sleep(1)
    methods = set(caps.get("methods") or [])
    need = {"groups.list", "groups.create", "groups.state", "groups.send", "groups.log", "groups.stop", "groups.rename", "groups.disband"}
    report(need <= methods and caps.get("driver") is True, "the room worker runs and has the room methods",
           f"driver {caps.get('driver')}, missing {sorted(need - methods)}")

    room = "redde-lab-" + uuid.uuid4().hex[:8]
    members = [{"member_id": "default", "profile": "default", "handle": "hermes", "display_name": "Hermes"},
               {"member_id": BOT, "profile": BOT, "handle": BOT, "display_name": "Scout"}]
    made = await dash.call("groups.create", {"room_id": room, "name": "Lab room", "members": members})
    report((made.get("room") or {}).get("room_id") == room, "a room is made with two bots", json.dumps(made)[:200])

    await dash.call("groups.send", {"room_id": room, "event_id": uuid.uuid4().hex, "payload": {"text": "hello both", "thread_id": "main"}})
    events, cursor = await log_until(dash, room, 0, lambda es: any(e["kind"] == "room.activity" for e in es))
    replies = [e for e in events if e["kind"] == "message.member"]
    report({(e.get("actor") or {}).get("id") for e in replies} == {"default", BOT} and any(e["kind"] == "room.activity" for e in events),
           "a message to everyone: each bot answers, and the round ends", json.dumps(said(events))[:300])
    print(f"  info  kinds seen: {sorted({e['kind'] for e in events})}")

    await dash.call("groups.send", {"room_id": room, "event_id": uuid.uuid4().hex, "payload": {"text": f"@{BOT} just you", "thread_id": "main"}})
    events, cursor = await log_until(dash, room, cursor, lambda es: any(e["kind"] == "room.activity" for e in es))
    replies = [e for e in events if e["kind"] == "message.member"]
    report([(e.get("actor") or {}).get("id") for e in replies] == [BOT], "a message tagging one bot: only that one answers",
           json.dumps(said(events))[:300])

    state = await dash.call("groups.state", {"room_id": room})
    print(f"  info  state: latest_seq {state.get('room', {}).get('latest_seq')}, driver_status {json.dumps(state.get('driver_status'))[:160]}")
    stopped = await dash.call("groups.stop", {"room_id": room, "cancel_id": "stop-" + uuid.uuid4().hex})
    report("cancelled" in stopped, "a stop is taken", json.dumps(stopped)[:160])

    await dash.call("groups.rename", {"room_id": room, "event_id": "rename-" + uuid.uuid4().hex, "name": "Renamed room"})
    rooms = (await dash.call("groups.list", {})).get("rooms") or []
    report(any(r.get("room_id") == room and r.get("name") == "Renamed room" for r in rooms), "the room is renamed in the list")

    for _ in range(5):
        try:
            await dash.call("groups.disband", {"room_id": room, "cancel_id": "disband-" + uuid.uuid4().hex})
            break
        except RuntimeError as error:
            if "stopping" not in str(error):
                raise
            await asyncio.sleep(2)
    rooms = (await dash.call("groups.list", {})).get("rooms") or []
    report(not any(r.get("room_id") == room for r in rooms), "a disbanded room leaves the list")
    await dash.ws.close()
    raise SystemExit(1 if check.failures else 0)


if __name__ == "__main__":
    asyncio.run(main())

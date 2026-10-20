"""Group chats (Hermes's hosted bot rooms) as Redde runs them (lab.sh groups), over the Dashboard socket:

  capabilities  `groups.capabilities` lists the room methods, and the room worker is running
                (`driver`; it starts a moment after the Dashboard, so it is asked again).
  create        a room with the main profile and one more (`groups.create`, members as objects).
  send          a message to everyone (`groups.send`, a fresh `event_id`, thread "main"): each
                member answers, and the log (`groups.log`, read since a cursor) has the message,
                both replies by member, and the round's end (`room.activity`).
  mention       a message tagging one member: only that one answers.
  live          "@scout lab:drip" (a reply streamed a word a second): while it is written, the
                bot's hidden session for the room is in `session.active_list` (titled "Group:
                <room>", working), found on its profile by that title (`session.list`), and its
                words come from `session.events.since` before the room's log has the reply.
  approval      "@scout danger": the bot's command (the stub's rm -rf) waits in the room's state
                (`driver_status.pending_actions`, kind "approval", with what `groups.approve`
                needs), and only for the person (`blocked` is a stop or recovery, not this);
                denied with `groups.approve`, the command isn't run and the reply lands; answered
                again, it is refused as no longer pending (5119).
  stop          `groups.stop` with a fresh `cancel_id` is taken.
  rename        `groups.rename` changes the name `groups.list` gives.
  disband       `groups.disband`: the room leaves the list.

Mirrors HermesServeClient's room calls (Echo/Services/Transport/ServerGroups.swift).
Run against a lab that is up with the approval scenario.
"""
import asyncio
import json
import os
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

    # The reply as it is written, read from the bot's own session (never resumed or activated).
    await dash.call("groups.send", {"room_id": room, "event_id": uuid.uuid4().hex, "payload": {"text": f"@{BOT} lab:drip", "thread_id": "main"}})
    title, words, seen, live_key, landed = f"Group: {room}", "", {}, None, False
    deadline = time.time() + 60
    while time.time() < deadline and not landed:
        rows = (await dash.call("session.active_list", {})).get("sessions") or []
        for row in rows:
            if row.get("title") != title or row.get("status") not in ("working", "starting"):
                continue
            live_key = row.get("session_key")
            got = await dash.call("session.events.since", {"session_id": row["id"], "last_seen": seen.get(row["id"], 0)})
            seen[row["id"]] = got.get("latest_seq", 0)
            for e in got.get("events") or []:
                if e.get("type") == "message.start":
                    words = ""
                elif e.get("type") == "message.delta":
                    words += str((e.get("payload") or {}).get("text") or "")
        page = await dash.call("groups.log", {"room_id": room, "since_seq": cursor, "limit": 200})
        landed = any(e["kind"] == "message.member" and "drip done" in str((e.get("payload") or {}).get("text") or "")
                     for e in page.get("events") or [])
        if not landed:
            await asyncio.sleep(0.5)
    report("word2" in words, "a bot's reply in a room is read as it is written, from its own session", repr(words[:80]))
    found = await dash.call("session.list", {"profile": BOT, "title": title, "include_hidden": True, "limit": 20})
    keys = {r.get("resolved_id") or r.get("id") for r in found.get("sessions") or [] if r.get("title") == title}
    report(live_key is not None and live_key in keys, "that session is the bot's, found by its title on its profile", f"{live_key} in {keys}")
    events, cursor = await log_until(dash, room, cursor, lambda es: any(e["kind"] == "room.activity" for e in es))

    await dash.call("groups.send", {"room_id": room, "event_id": uuid.uuid4().hex, "payload": {"text": f"@{BOT} danger", "thread_id": "main"}})
    pending, status = None, {}
    for _ in range(60):
        status = (await dash.call("groups.state", {"room_id": room})).get("driver_status") or {}
        pending = next((a for a in status.get("pending_actions") or [] if a.get("kind") == "approval"), None)
        if pending:
            break
        await asyncio.sleep(1)
    choices = set(((pending or {}).get("approval") or {}).get("choices") or [])
    report(bool(pending) and pending.get("member_id") == BOT and bool(pending.get("request_id")) and bool(pending.get("task_id"))
           and isinstance(pending.get("execution_generation"), int) and choices and choices <= {"once", "deny"},
           "a bot's command in a room waits for the person's approval", json.dumps(pending)[:300])
    print(f"  info  while it waits: working {status.get('working')}, blocked {status.get('blocked')}, counts {status.get('counts')}")
    if pending:
        answer = {"room_id": room, "member_id": pending["member_id"], "task_id": pending["task_id"],
                  "execution_generation": pending["execution_generation"], "request_id": pending["request_id"], "choice": "deny"}
        await dash.call("groups.approve", answer)
        try:
            await dash.call("groups.approve", answer)
            stale = "taken twice"
        except RuntimeError as error:
            stale = str(error)
        report("no longer pending" in stale, "answered again, it is refused as no longer pending", stale)
        events, cursor = await log_until(dash, room, cursor, lambda es: any(e["kind"] == "room.activity" for e in es))
        said_now = [str((e.get("payload") or {}).get("text") or "") for e in events if e["kind"] == "message.member"]
        report(any("[kept]" in t for t in said_now) and os.path.isdir(os.environ["LAB_TARGET"]),
               "denied, the command isn't run, and the bot's reply lands", json.dumps(said_now)[:200])

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

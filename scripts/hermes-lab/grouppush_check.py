"""Group chat notes from the push plugin (its rooms.py), inside a running lab Hermes (lab.sh grouppush,
the push scenario, which has the plugin and the Dashboard's login):

  follow    a stand-in phone pairs, and says which group chats it follows the way the app does
            (`/redde-push rooms <device> <room>` over the Dashboard): "following 1".
  messages  a message to everyone in a room: each bot's reply reaches the phone as a "group" note,
            once (`g` the room, `t` its name, `d` the bot's name, `b` its words), and nothing is
            announced as an ordinary reply, with every conversation set to notify, for the bots'
            own turns in the room (platform bot_room).
  history   what a room said before the phone followed it isn't sent.
  approval  "@scout danger": the bot's command waiting in the room reaches the phone as a
            "group_wait" note (`w` approval, `h` the digest of the command the room's state shows,
            which is what the app answers by), once; denied, nothing more is said of it.
  mute      `mutes <device> g:<room>=0` (the app's Mute…): the room's next message is not sent;
            `mutes <device>` with none: it is again.
  unfollow  `rooms <device>` with no rooms: the next message in the room is not sent.

usage: grouppush_check.py <hermes executable>   (the lab's Python: websockets, cryptography)
"""
import asyncio
import json
import time
import uuid

import check
from check import Dashboard
import push_check
from push_check import Phone, core, hermes, pair, report

BOT = "scout"


async def plugin(dash, words):
    reply = await dash.call("command.dispatch", {"name": "redde-push", "arg": words})
    return str(reply.get("output") or "")


async def round_ends(dash, room, cursor, seconds=90):
    """Reads the room's log from `cursor` to the end of the round; its events, and the new cursor."""
    events, deadline = [], time.time() + seconds
    while time.time() < deadline:
        page = await dash.call("groups.log", {"room_id": room, "since_seq": cursor, "limit": 200})
        for e in page.get("events") or []:
            if e.get("seq", 0) > cursor:
                events.append(e)
                cursor = e["seq"]
        if any(e["kind"] == "room.activity" for e in events):
            break
        await asyncio.sleep(1)
    return events, cursor


def wait_notes(phone, test, count, seconds=30):
    deadline = time.time() + seconds
    while time.time() < deadline:
        found = [made for made in phone.notes() if test(made)]
        if len(found) >= count:
            time.sleep(6)   # (and nothing more comes after: a second reading would have sent it again)
            return [made for made in phone.notes() if test(made)]
        time.sleep(0.5)
    return [made for made in phone.notes() if test(made)]


async def main():
    phone = Phone()
    pair(phone)
    report(phone.wait_for("paired") is not None, "a stand-in phone pairs")
    hermes("notify", "all")   # every conversation notifies: the bots' own turns in a room still must not

    dash = await Dashboard.connect()
    await dash.call("profiles.create", {"name": BOT, "clone_from": "default", "no_alias": True})
    for _ in range(20):
        if (await dash.call("groups.capabilities", {})).get("driver"):
            break
        await asyncio.sleep(1)
    room = "redde-lab-" + uuid.uuid4().hex[:8]
    members = [{"member_id": "default", "profile": "default", "handle": "hermes", "display_name": "Hermes"},
               {"member_id": BOT, "profile": BOT, "handle": BOT, "display_name": "Scout"}]
    await dash.call("groups.create", {"room_id": room, "name": "Lab room", "members": members})

    # Said before the phone follows the room: not news once it does.
    await dash.call("groups.send", {"room_id": room, "event_id": uuid.uuid4().hex, "payload": {"text": f"@{BOT} early", "thread_id": "main"}})
    _, cursor = await round_ends(dash, room, 0)

    answer = await plugin(dash, f"rooms {phone.id} {room}")
    report(answer == "redde-push following 1", "the phone says which group chats it follows", answer)
    time.sleep(6)   # (the plugin's first reading of the room: where its log stands)

    before = len(phone.notes())
    await dash.call("groups.send", {"room_id": room, "event_id": uuid.uuid4().hex, "payload": {"text": "hello both", "thread_id": "main"}})
    events, cursor = await round_ends(dash, room, cursor)
    replies = {(e.get("actor") or {}).get("id"): str((e.get("payload") or {}).get("text") or "") for e in events if e["kind"] == "message.member"}
    group = wait_notes(phone, lambda m: m["k"] == "group" and m.get("g") == room, len(replies))
    heard = sorted((m.get("d"), m.get("b")) for m in group)
    wanted = sorted(("Hermes" if member == "default" else "Scout", text[: core.BODY_LIMIT]) for member, text in replies.items())
    report(len(replies) == 2 and heard == wanted and all(m.get("t") == "Lab room" for m in group),
           "each bot's message in the room reaches the phone, once, named for the room and the bot", json.dumps(heard)[:300])
    report(not any("early" in str(m.get("b")) for m in group), "what the room said before it was followed isn't sent")
    ordinary = [m for m in phone.notes()[before:] if m["k"] in ("reply", "failed", "task")]
    report(not ordinary, "the bots' own turns in the room aren't announced as ordinary replies", json.dumps(ordinary)[:300])

    await dash.call("groups.send", {"room_id": room, "event_id": uuid.uuid4().hex, "payload": {"text": f"@{BOT} danger", "thread_id": "main"}})
    pending = None
    for _ in range(60):
        status = (await dash.call("groups.state", {"room_id": room})).get("driver_status") or {}
        pending = next((a for a in status.get("pending_actions") or [] if a.get("kind") == "approval"), None)
        if pending:
            break
        await asyncio.sleep(1)
    command = str(((pending or {}).get("approval") or {}).get("command") or "")
    waits = wait_notes(phone, lambda m: m["k"] == "group_wait" and m.get("g") == room, 1)
    report(bool(pending) and len(waits) == 1 and waits[0].get("w") == "approval" and waits[0].get("d") == "Scout"
           and waits[0].get("h") == core.digest(command) and waits[0].get("b") == command[: core.BODY_LIMIT],
           "a bot's command waiting in the room reaches the phone once, answerable by its digest", json.dumps(waits)[:300])
    if pending:
        await dash.call("groups.approve", {"room_id": room, "member_id": pending["member_id"], "task_id": pending["task_id"],
                                           "execution_generation": pending["execution_generation"], "request_id": pending["request_id"],
                                           "choice": "deny"})
    _, cursor = await round_ends(dash, room, cursor)
    time.sleep(6)
    report(len([m for m in phone.notes() if m["k"] == "group_wait"]) == 1, "answered, nothing more is said of it")

    # Muted on the phone (Mute… in Redde): the plugin sends nothing for the room; unmuted, again.
    answer = await plugin(dash, f"mutes {phone.id} g:{room}=0")
    count = len([m for m in phone.notes() if m["k"] == "group"])
    await dash.call("groups.send", {"room_id": room, "event_id": uuid.uuid4().hex, "payload": {"text": f"@{BOT} while muted", "thread_id": "main"}})
    _, cursor = await round_ends(dash, room, cursor)
    time.sleep(8)
    report(answer == "redde-push muted 1" and len([m for m in phone.notes() if m["k"] == "group"]) == count,
           "a room the phone muted sends nothing", answer)
    await plugin(dash, f"mutes {phone.id}")
    await dash.call("groups.send", {"room_id": room, "event_id": uuid.uuid4().hex, "payload": {"text": f"@{BOT} unmuted", "thread_id": "main"}})
    _, cursor = await round_ends(dash, room, cursor)
    report(len(wait_notes(phone, lambda m: m["k"] == "group" and m.get("g") == room, count + 1)) == count + 1,
           "unmuted, it is heard again")

    answer = await plugin(dash, f"rooms {phone.id}")
    count = len([m for m in phone.notes() if m["k"] == "group"])
    await dash.call("groups.send", {"room_id": room, "event_id": uuid.uuid4().hex, "payload": {"text": f"@{BOT} once more", "thread_id": "main"}})
    await round_ends(dash, room, cursor)
    time.sleep(8)
    report(answer == "redde-push following 1" and len([m for m in phone.notes() if m["k"] == "group"]) == count,
           "a room the phone no longer follows sends nothing", answer)


asyncio.run(main())
raise SystemExit(1 if push_check.failures else 0)

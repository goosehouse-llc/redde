"""Bot templates (lab.sh templates), over the Dashboard socket, as Redde's New Bot makes a bot from one:

  toolsets  `profiles.describe` on the main profile lists the toolsets a bot can be given.
  pinned    a bot made as a copy of the main profile, then `profiles.configure` with
            `enabled_toolsets` (the template's, less any the server doesn't have): describe shows
            those enabled and no others.
  chat      a turn in its Bot Chat is offered the pinned toolsets' tools and not the others (no
            terminal for a writer), and still `message_agent` once a profile is a bot.
  room      in a group chat with the main profile, it still answers.

Run against a lab that is up with the approval scenario.
"""
import asyncio
import json
import time
import uuid

import check
from check import HITS, Dashboard, report
from bots_check import hits, turn

BOT = "quill"


def release():
    """This Hermes's version, (0, 21, 5); a build from source that says 0.0.0 counts as the newest."""
    import hermes_cli
    parts = tuple(int(p) for p in str(getattr(hermes_cli, "__version__", "0.0.0")).split(".")[:3] if p.isdigit())
    return (99, 0, 0) if parts in ((), (0, 0, 0)) else parts
WANTED = ["file", "memory", "clarify", "todo", "web"]


async def main():
    dash = await Dashboard.connect()
    main_profile = await dash.call("profiles.describe", {"name": "default"})
    offered = [t.get("name") for t in main_profile.get("toolsets") or []]
    print(f"  info  toolsets offered: {offered}")
    report(bool(offered) and all(isinstance(t, str) for t in offered), "the main profile's toolsets are listed", json.dumps(main_profile)[:200])
    wanted = [t for t in WANTED if t in offered]

    await dash.call("profiles.create", {"name": BOT, "clone_from": "default", "no_alias": True, "share_auth": True,
                                        "description": "Drafts and tightens writing.", "soul": "You are Quill, a writer."})
    applied = await dash.call("profiles.configure", {"name": BOT, "enabled_toolsets": wanted})
    print(f"  info  configure: {json.dumps(applied)[:300]}")
    described = await dash.call("profiles.describe", {"name": BOT})
    enabled = sorted(t.get("name") for t in described.get("toolsets") or [] if t.get("enabled"))
    report(enabled == sorted(wanted), "a bot's toolsets pinned to the template's", f"wanted {sorted(wanted)}, enabled {enabled}")

    await dash.call("profiles.configure", {"name": "default", "ui_meta": {"hermes-bots": {"title": "Hermes"}}})
    made = await dash.call("session.create", {"profile": BOT, "title": "Bot Chat", "hidden": True, "follow_profile_config": True,
                                              "source": "desktop", "close_on_disconnect": False})
    await dash.call("session.title", {"session_id": made.get("session_id"), "title": "Bot Chat"})
    reply = await turn(dash, made.get("session_id"), "hello quill")
    first = hits()[:1]
    names = (first[0].get("names") if first else None) or []
    print(f"  info  tools offered in its chat ({len(names)}): {names}")
    # 0.21.0 and 0.21.3 write the list where their Dashboard's chats don't read it (they read the
    # cli platform's toolsets), so a bot there has every tool; from 0.21.5 it is kept to its own.
    # 0.21.5 and later may keep some (the to-do list) behind tool_search.
    old = release() < (0, 21, 5)
    kept = "terminal" not in names and "web_search" in names and ("todo" in names or "tool_search" in names)
    if old:
        print(f"  info  this release gives the bot every tool all the same: {'terminal' in names}")
    report(reply.startswith("[") and "message_agent" in names and (kept or old),
           "its chat is offered the template's tools (from 0.21.5), not a terminal, and still message_agent", f"{reply} {names}")

    main_chat = await dash.call("session.create", {"profile": "default", "source": "desktop", "close_on_disconnect": False})
    await turn(dash, main_chat.get("session_id"), "and the main agent?")
    first = hits()[:1]
    main_names = (first[0].get("names") if first else None) or []
    report("terminal" in main_names, "the main profile keeps its own tools", f"{main_names}")

    room = "redde-lab-" + uuid.uuid4().hex[:8]
    members = [{"member_id": "default", "profile": "default", "handle": "hermes", "display_name": "Hermes"},
               {"member_id": BOT, "profile": BOT, "handle": BOT, "display_name": "Quill"}]
    for _ in range(20):
        if (await dash.call("groups.capabilities", {})).get("driver"):
            break
        await asyncio.sleep(1)
    await dash.call("groups.create", {"room_id": room, "name": "Lab room", "members": members})
    await dash.call("groups.send", {"room_id": room, "event_id": uuid.uuid4().hex, "payload": {"text": f"@{BOT} a line please", "thread_id": "main"}})
    replied, deadline = False, time.time() + 90
    while time.time() < deadline and not replied:
        page = await dash.call("groups.log", {"room_id": room, "since_seq": 0, "limit": 200})
        replied = any(e["kind"] == "message.member" and (e.get("actor") or {}).get("id") == BOT for e in page.get("events") or [])
        await asyncio.sleep(1)
    report(replied, "in a group chat, the template's bot still answers")


asyncio.run(main())
raise SystemExit(1 if check.failures else 0)

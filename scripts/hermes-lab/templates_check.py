"""Bot templates (lab.sh templates), over the Dashboard socket, as Redde's New Bot makes a bot from one:

  toolsets  `profiles.describe` on the main profile lists the toolsets a bot can be given.
  pinned    a bot made as a copy of the main profile, then `profiles.configure` with
            `enabled_toolsets` (the template's, less any the server doesn't have): describe shows
            those enabled and no others.
  chat      a turn in its Bot Chat is offered the pinned toolsets' tools and not the others (no
            terminal for a writer), and still `message_agent` once a profile is a bot.
  room      in a group chat with the main profile, it still answers.
  kanban    a bot given Kanban (off by default) in its Dashboard list, as Edit Bot gives it, makes a
            kanban card in a group chat once open chats have their tools again (`reload.mcp`, as
            Redde sends after a change): its room session is a Dashboard one (from 0.21.5).

Run against a lab that is up with the approval scenario.
"""
import asyncio
import http.cookiejar
import json
import os
import sqlite3
import time
import urllib.request
import uuid

import check
from check import HITS, SERVE, Dashboard, report
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

    # Kanban in a group chat (2026-10-26: no bot there could make a card; Hermes lists Kanban,
    # off by default, only once a profile has it, so Edit Bot never offered it).
    opener = rest_opener()
    known = [t.get("name") for t in rest(opener, "GET", f"/api/tools/toolsets?profile={BOT}")]
    if "kanban" not in known:
        print("  info  no kanban toolset on this release")
        return
    await room_turn(dash, room, f"@{BOT} lab:card before")
    made = cards(opener)
    print(f"  info  before: a card made {made > 0}")

    model_before = (await dash.call("profiles.describe", {"name": BOT})).get("model")
    await dash.call("profiles.configure", {"name": BOT, "enabled_toolsets": sorted(set(wanted) | {"kanban"})})
    described = await dash.call("profiles.describe", {"name": BOT})
    listed = sorted(t.get("name") for t in described.get("toolsets") or [] if t.get("enabled"))
    report("kanban" in listed and described.get("model") == model_before,
           "Kanban given in its Dashboard list (Edit Bot → Tools), listed for it though off by default", f"{listed}")
    # As Redde does after a tool change: open chats, its room's included, get their tools again.
    await dash.call("reload.mcp", {"confirm": True})
    after = await room_turn(dash, room, f"@{BOT} lab:card dashboard list")
    print(f"  info  offered there: {after}")
    print(f"  info  it said: {await last_said(dash, room)}")
    by_dashboard = cards(opener) > made
    made = cards(opener)
    print(f"  info  with Kanban in its Dashboard list, a card made in the group chat: {by_dashboard}; terminal {'terminal' in after}")

    if release() < (0, 21, 5):
        # 0.21.3 gives a bot every one of the main agent's tools whatever its list says.
        print("  info  this release keeps no bot to its own list: Kanban there is the main agent's to have")
    else:
        report(by_dashboard, "a bot given Kanban makes a kanban card in a group chat")


async def last_said(dash, room):
    page = await dash.call("groups.log", {"room_id": room, "since_seq": 0, "limit": 500})
    said = [e for e in page.get("events") or [] if e["kind"] == "message.member" and (e.get("actor") or {}).get("id") == BOT]
    return json.dumps(said[-1].get("payload"))[:300] if said else None


def rest_opener():
    """Signed in to the Dashboard the way the app is, for its REST routes."""
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    request = urllib.request.Request(f"http://{SERVE}/auth/password-login", method="POST",
                                     data=json.dumps({"provider": "basic", "username": "lab", "password": "labpass-labpass"}).encode(),
                                     headers={"Content-Type": "application/json"})
    opener.open(request, timeout=10).read()
    return opener


def rest(opener, method, path, body=None):
    request = urllib.request.Request(f"http://{SERVE}{path}", method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Content-Type": "application/json"})
    with opener.open(request, timeout=30) as response:
        return json.loads(response.read().decode() or "{}")


def cards(opener):
    """Kanban cards titled as the stub makes them: on the board, or in its database where the
    Dashboard has no board."""
    try:
        board = rest(opener, "GET", "/api/plugins/kanban/board")
        return sum(1 for column in board.get("columns") or [] for task in column.get("tasks") or []
                   if task.get("title") == "Lab card from a group chat")
    except Exception:
        path = os.path.join(os.environ.get("HERMES_HOME", ""), "kanban.db")
        if not os.path.exists(path):
            return 0
        with sqlite3.connect(path) as db:
            return db.execute("SELECT count(*) FROM tasks WHERE title = ?", ("Lab card from a group chat",)).fetchone()[0]


async def room_turn(dash, room, text):
    """A message to the bot in the group chat; the tools its turn there was first offered."""
    page = await dash.call("groups.log", {"room_id": room, "since_seq": 0, "limit": 500})
    since = max([e.get("seq", 0) for e in page.get("events") or []] or [0])
    check.clear_hits()
    await dash.call("groups.send", {"room_id": room, "event_id": uuid.uuid4().hex, "payload": {"text": text, "thread_id": "main"}})
    deadline = time.time() + 90
    while time.time() < deadline:
        page = await dash.call("groups.log", {"room_id": room, "since_seq": since, "limit": 200})
        if any(e.get("seq", 0) > since and e["kind"] == "message.member" and (e.get("actor") or {}).get("id") == BOT
               for e in page.get("events") or []):
            break
        await asyncio.sleep(1)
    rows = hits()
    return (rows[0].get("names") if rows else None) or []


asyncio.run(main())
raise SystemExit(1 if check.failures else 0)

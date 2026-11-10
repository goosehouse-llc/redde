"""Workstreams (lab.sh work), as plugin 1.22.0 runs them in the Dashboard:

  start     a Dashboard turn whose model calls `redde_work` (the stub, on "lab:work") starts W1:
            `/redde-push work list` (the app's Work sheet) shows it, with its chat
  hidden    its chat is a hidden session titled "Work: W1 · Lab errand", out of the chat list
  runs      its chat answers its brief by itself, with no client on it
  done      W1 is "done", its last words the workstream's answer
  report    the chat that started it gets a hidden turn with the report, and answers it
  stop      `/redde-push work stop W1` on one that ended says it isn't running
  note      a paired phone hears W1 is done, in a "work" note naming the agent, W1 and its chat
  needs     one whose step needs approval (its brief says "danger") is "needs you", the phone hears so, and once
            the approval is answered it goes on and is done
  stop      `/redde-push work stop default W3` stops one mid-turn: "stopped", and no report
  bot       the same from a bot's Bot Chat (profile "scout"): its workstream runs in its profile,
            numbered and listed there, and reports to its Bot Chat

usage: work_check.py <hermes>   (a lab up with the push scenario)
"""
import asyncio
import json
import time

import check
from check import Dashboard, report
from push_check import Phone, pair


async def say(dash, arg, profile=None):
    params = {"name": "redde-push", "arg": arg, **({"profile": profile} if profile else {})}
    return (await dash.call("command.dispatch", params)).get("output", "")


def parsed(output):
    return json.loads(output.removeprefix("redde-push work ")) if output.startswith("redde-push work {") else None


async def history(dash, stored, profile=None):
    resumed = await dash.call("session.resume", {"session_id": stored, **({"profile": profile} if profile else {})})
    rows = (await dash.call("session.history", {"session_id": resumed["session_id"]})).get("messages") or []
    return rows


def text_of(row):
    content = row.get("text") or row.get("content") or ""
    if isinstance(content, list):
        content = " ".join(str(p.get("text") or "") for p in content if isinstance(p, dict))
    return str(content)


async def main():
    dash = await Dashboard.connect()
    try:
        await dash.call("client.capabilities", {"server_requests": True})
    except RuntimeError:
        pass
    phone = Phone()
    await asyncio.to_thread(pair, phone)
    before = parsed(await say(dash, "work list default"))
    report(before is not None and before["work"] == [] and before["engine"] == "serve",
           "the app's `work list`: none yet, run by the Dashboard", before)

    made = await dash.call("session.create", {"source": "desktop", "close_on_disconnect": False})
    await dash.call("prompt.submit", {"session_id": made["session_id"], "text": "lab:work hand it off"})
    started, deadline = None, time.time() + 90
    while time.time() < deadline and not started:
        await asyncio.sleep(2)
        started = next(iter((parsed(await say(dash, "work list default")) or {}).get("work") or []), None)
    report(bool(started) and started["id"] == "W1" and started["title"] == "Lab errand" and started["session"]
           and started["chat"] == made.get("stored_session_id"),
           "a turn's redde_work call starts W1, listed with its chat and the chat that started it", started)
    if not started:
        return

    listed = (await dash.call("session.list", {"limit": 200})).get("sessions") or []
    report(not any(str(s.get("title") or "").startswith("Work: ") for s in listed),
           "its chat stays out of the chat list", [s.get("title") for s in listed])

    done, deadline = None, time.time() + 120
    while time.time() < deadline:
        await asyncio.sleep(2)
        now = next(iter((parsed(await say(dash, "work list default")) or {}).get("work") or []), None)
        if now and now["status"] not in ("starting", "working"):
            done = now
            break
    report(bool(done) and done["status"] == "done" and done["last"] == "Workstream report: the lab errand is done.",
           "it answers its brief by itself and is done, its last words kept", done)

    # (Its title is kept once its first turn has ended: until then it is the live session's alone.)
    found = (await dash.call("session.list", {"title": "Work: W1 · Lab errand", "include_hidden": True})).get("sessions") or []
    report(bool(found) and found[0].get("id") in (started["session"], found[0].get("resolved_id")),
           "its chat is the hidden session \"Work: W1 · Lab errand\"", found[:1])
    rows, deadline = [], time.time() + 90
    while time.time() < deadline:
        await asyncio.sleep(2)
        rows = await history(dash, made["stored_session_id"])
        if any("The agent's word" in text_of(r) for r in rows):
            break
    said = [text_of(r) for r in rows]
    report(any(s.lstrip().startswith("[Workstream W1") for s in said) or any("The agent's word" in s for s in said),
           "the chat that started it gets the report as a turn of its own", said[-4:])
    report(any("The agent's word: W1 finished" in s for s in said), "and answers it", said[-2:])

    stop = parsed(await say(dash, "work stop default W1")) or {}
    report("isn't running" in str(stop.get("error") or ""), "stopping one that ended says it isn't running", stop)
    made_note = await asyncio.to_thread(phone.wait_for, "work", started["session"], 20)
    report(bool(made_note) and made_note.get("w") == "done" and made_note.get("x") == "W1" and made_note.get("p") == "default"
           and made_note.get("b") == "Workstream report: the lab errand is done.",
           "the phone hears W1 is done, in a work note with its id and its chat", made_note)

    async def row(ref, profile="default"):
        return next((w for w in (parsed(await say(dash, f"work list {profile}")) or {}).get("work") or [] if w["id"] == ref), None)

    async def until(ref, statuses, seconds=90):
        deadline = time.time() + seconds
        while time.time() < deadline:
            now = await row(ref)
            if now and now["status"] in statuses:
                return now
            await asyncio.sleep(1)
        return await row(ref)

    # One that needs approval: "needs you", told to the phone, and on once it's answered.
    await dash.call("prompt.submit", {"session_id": made["session_id"], "text": "lab:work-risky hand this off too"})
    waiting = await until("W2", ("needs_you", "done", "failed"))
    report(bool(waiting) and waiting["status"] == "needs_you" and "rm -rf" in waiting["asked"],
           "a workstream waiting on an approval is \"needs you\", with the command", waiting)
    needs = await asyncio.to_thread(phone.wait_for, "work", (waiting or {}).get("session"), 20)
    report(bool(needs) and needs.get("w") == "needs" and needs.get("x") == "W2", "the phone hears it needs you", needs)
    if waiting and waiting["status"] == "needs_you":
        opened = await dash.call("session.resume", {"session_id": waiting["session"], "omit_messages": True})
        pending = opened.get("pending_approval") or {}
        await dash.call("approval.respond", {"session_id": opened["session_id"], "choice": "once",
                                             **({"request_id": pending["request_id"]} if pending.get("request_id") else {})})
        after = await until("W2", ("done", "failed", "stopped"))
        report(bool(after) and after["status"] == "done" and after["asked"] == "",
               "answered, it goes on and is done", after)

    # One stopped mid-turn: "stopped", and the chat that started it isn't told.
    await dash.call("prompt.submit", {"session_id": made["session_id"], "text": "lab:work-slow and this"})
    slow = await until("W3", ("working",), 60)
    await asyncio.sleep(3)
    stopped = parsed(await say(dash, "work stop default W3")) or {}
    after = await until("W3", ("stopped", "done", "failed"), 30)
    report(stopped.get("stopped") == "W3" and bool(after) and after["status"] == "stopped",
           "the app's `work stop` stops one mid-turn, and it reads as stopped", (stopped, after))

    # A bot: its own profile, its own Bot Chat, its own workstreams.
    mine = [w["id"] for w in (parsed(await say(dash, "work list default")) or {}).get("work") or []]
    await dash.call("profiles.create", {"name": "scout", "clone_from": "default", "no_alias": True})
    chat = await dash.call("session.create", {"profile": "scout", "title": "Bot Chat", "hidden": True,
                                              "follow_profile_config": True, "close_on_disconnect": False})
    await dash.call("prompt.submit", {"session_id": chat["session_id"], "text": "lab:work hand it off"})
    bot, deadline = None, time.time() + 150
    while time.time() < deadline:
        await asyncio.sleep(2)
        bot = parsed(await say(dash, "work list scout")) or {}
        row = next(iter(bot.get("work") or []), None)
        if row and row["status"] not in ("starting", "working"):
            break
    row = next(iter((bot or {}).get("work") or []), None)
    report(bool(row) and bot.get("profile") == "scout" and row["id"] == "W1" and row["status"] == "done"
           and row["chat"] == chat.get("stored_session_id"),
           "a bot's workstream runs in its own profile, numbered there, and is done", bot)
    bot_note = await asyncio.to_thread(phone.wait_for, "work", (row or {}).get("session"), 20)
    report(bool(bot_note) and bot_note.get("p") == "scout" and bot_note.get("w") == "done" and bot_note.get("d"),
           "the phone paired with the Hermes hears the bot's, by the bot's name", bot_note)
    main_list = parsed(await say(dash, "work list default")) or {}
    report([w["id"] for w in main_list.get("work") or []] == mine, "and the main agent's list is still its own", main_list)
    rows, deadline = [], time.time() + 90
    while time.time() < deadline:
        await asyncio.sleep(2)
        rows = await history(dash, chat["stored_session_id"], "scout")
        if any("The agent's word" in text_of(r) for r in rows):
            break
    report(any("The agent's word: W1 finished" in text_of(r) for r in rows), "the bot's Bot Chat hears the report and answers it",
           [text_of(r) for r in rows][-3:])
    await dash.ws.close()


asyncio.run(main())
raise SystemExit(1 if check.failures else 0)

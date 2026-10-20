"""A bot's schedules (lab.sh routines), as Redde makes one, over the Dashboard (REST and socket):

  store     `POST /api/cron/jobs?profile=<bot>` with `deliver: bot-chat:<bot>` and Hermes Desktop's
            name tag ("[bot:<bot>] …") puts the job in the bot's own store: `GET ?profile=<bot>`
            lists it, and the main profile's list doesn't.
  run       `POST …/{id}/trigger?profile=<bot>` runs it as the bot, and its output comes into the
            bot's Bot Chat as a message under Hermes's banner ("[Cronjob …"), which the bot
            answers there; the job then has its last run.
  note      the push plugin tells a paired phone the schedule ran: a "routine" note with the
            bot's profile, the schedule's name (less the tag) and what it came up with.
  change    `PUT …?profile=<bot>` renames it and moves its time; pause and resume; delete.

usage: routines_check.py <hermes executable>   (a lab up with the push scenario)
"""
import asyncio
import json
import time

import check
from check import Dashboard, report
from bots_check import lookup, turn
from status_check import rest, rest_opener
from push_check import Phone, pair

BOT = "scout"


def release():
    """This Hermes's version, (0, 21, 5); a build from source that says 0.0.0 counts as the newest."""
    import hermes_cli
    parts = tuple(int(p) for p in str(getattr(hermes_cli, "__version__", "0.0.0")).split(".")[:3] if p.isdigit())
    return (99, 0, 0) if parts in ((), (0, 0, 0)) else parts


async def bot_chat_messages(dash, stored):
    resumed = await dash.call("session.resume", {"session_id": stored, "profile": BOT, "omit_messages": False})
    return [(m.get("role"), str(m.get("text") or m.get("content") or "")) for m in resumed.get("messages") or []]


async def main():
    phone = Phone()
    pair(phone)
    report(phone.wait_for("paired") is not None, "a stand-in phone pairs")
    dash = await Dashboard.connect()
    opener = rest_opener()
    await dash.call("profiles.create", {"name": BOT, "clone_from": "default", "no_alias": True, "share_auth": True})
    await dash.call("profiles.configure", {"name": BOT, "ui_meta": {"hermes-bots": {"title": "Scout"}}})
    made = await dash.call("session.create", {"profile": BOT, "title": "Bot Chat", "hidden": True, "follow_profile_config": True,
                                              "source": "desktop", "close_on_disconnect": False})
    await dash.call("session.title", {"session_id": made.get("session_id"), "title": "Bot Chat"})
    await turn(dash, made.get("session_id"), "hello scout")
    stored = (await lookup(dash, BOT) or {}).get("id")
    await dash.call("session.close", {"session_id": made.get("session_id")})   # (the phone has left the chat)

    created = rest(opener, "POST", f"/api/cron/jobs?profile={BOT}",
                   {"name": f"[bot:{BOT}] What to wear", "schedule": "0 7 * * 1-5", "prompt": "lab routine: what should I wear today",
                    "deliver": f"bot-chat:{BOT}"})
    job = created.get("job") or created
    job_id = job.get("id") or job.get("job_id")
    print(f"  info  made: {json.dumps(created)[:240]}")
    mine = rest(opener, "GET", f"/api/cron/jobs?profile={BOT}")
    mine = mine if isinstance(mine, list) else mine.get("jobs") or []
    main_jobs = rest(opener, "GET", "/api/cron/jobs?profile=default")
    main_jobs = main_jobs if isinstance(main_jobs, list) else main_jobs.get("jobs") or []
    report(any(j.get("id") == job_id for j in mine) and not any(j.get("id") == job_id for j in main_jobs),
           "a bot's schedule is in its own store", f"{[j.get('id') for j in mine]} / {[j.get('id') for j in main_jobs]}")
    listed = next((j for j in mine if j.get("id") == job_id), {})
    print(f"  info  as listed: profile {listed.get('profile')}, deliver {listed.get('deliver')}, next {listed.get('next_run_at')}")

    # The app's word to the plugin as it reads its list: the plugin, loaded, reads the schedules.
    await dash.call("command.dispatch", {"name": "redde-push", "arg": f"rooms {phone.id}"})
    await asyncio.sleep(5)
    before = await bot_chat_messages(dash, stored)
    started = time.time()
    try:
        rest(opener, "POST", f"/api/cron/jobs/{job_id}/trigger?profile={BOT}")
    except Exception as error:
        print(f"  info  trigger: {error}")
    after, deadline = before, time.time() + 240
    while time.time() < deadline:
        after = await bot_chat_messages(dash, stored)
        new = after[len(before):]
        if any(role == "user" and text.startswith("[Cronjob") for role, text in new) and new and new[-1][0] == "assistant":
            break
        await asyncio.sleep(3)
    new = after[len(before):]
    print(f"  info  in its chat after {time.time() - started:.0f} s: {json.dumps(new)[:400]}")
    report(any(role == "user" and text.startswith("[Cronjob") and "What to wear" in text for role, text in new),
           "run, its output comes into the bot's chat under Hermes's banner", json.dumps(new)[:300])
    report(bool(new) and new[-1][0] == "assistant", "and the bot answers it there")
    ran = rest(opener, "GET", f"/api/cron/jobs/{job_id}?profile={BOT}")
    ran = ran.get("job") or ran
    report(bool(ran.get("last_run_at")), "the job has its last run", "")
    print(f"  info  its run: {json.dumps({k: ran.get(k) for k in ('last_run_at', 'last_status', 'last_error', 'last_delivery_error', 'last_delivery_unverified')})[:400]}")
    note = phone.wait_for("routine", seconds=90)
    report(note is not None and note.get("p") == BOT and note.get("t") == "What to wear" and bool(note.get("b")),
           "the phone is told it ran, with what it came up with", json.dumps(note)[:300])
    chats = (await dash.call("session.list", {"profile": BOT, "include_hidden": True, "limit": 50})).get("sessions") or []
    print(f"  info  the bot's sessions: {[(c.get('id'), c.get('title'), c.get('source')) for c in chats][:8]}")

    rest(opener, "PUT", f"/api/cron/jobs/{job_id}?profile={BOT}", {"updates": {"name": f"[bot:{BOT}] Morning outfit", "schedule": "30 7 * * *"}})
    changed = rest(opener, "GET", f"/api/cron/jobs/{job_id}?profile={BOT}")
    changed = changed.get("job") or changed
    report(changed.get("name") == f"[bot:{BOT}] Morning outfit" and "30 7" in json.dumps(changed.get("schedule")),
           "renamed and moved", json.dumps({k: changed.get(k) for k in ("name", "schedule")})[:200])
    rest(opener, "POST", f"/api/cron/jobs/{job_id}/pause?profile={BOT}")
    paused = rest(opener, "GET", f"/api/cron/jobs/{job_id}?profile={BOT}")
    paused = paused.get("job") or paused
    rest(opener, "POST", f"/api/cron/jobs/{job_id}/resume?profile={BOT}")
    resumed = rest(opener, "GET", f"/api/cron/jobs/{job_id}?profile={BOT}")
    resumed = resumed.get("job") or resumed
    report(paused.get("enabled") is False and resumed.get("enabled") is True, "paused and resumed",
           f"{paused.get('enabled')} {resumed.get('enabled')}")
    rest(opener, "DELETE", f"/api/cron/jobs/{job_id}?profile={BOT}")
    left = rest(opener, "GET", f"/api/cron/jobs?profile={BOT}")
    left = left if isinstance(left, list) else left.get("jobs") or []
    report(not any(j.get("id") == job_id for j in left), "and deleted")

    # On its own: the gateway's ticker fires a bot's schedule when it is due (from 0.21.5 it ticks
    # every profile's store; 0.21.0 and 0.21.3 only with gateway.multiplex_profiles on).
    before = await bot_chat_messages(dash, stored)
    rest(opener, "POST", f"/api/cron/jobs?profile={BOT}",
         {"name": f"[bot:{BOT}] In a minute", "schedule": "in 1m", "prompt": "lab routine: on its own", "deliver": f"bot-chat:{BOT}"})
    fired, deadline = False, time.time() + 200
    while time.time() < deadline and not fired:
        await asyncio.sleep(5)
        fired = any(role == "user" and "In a minute" in text for role, text in (await bot_chat_messages(dash, stored))[len(before):])
    if release() < (0, 21, 5):
        print(f"  info  fired on its own (multiplex off): {fired}")
    else:
        report(fired, "due, it fires on its own and comes into the bot's chat")


asyncio.run(main())
raise SystemExit(1 if check.failures else 0)

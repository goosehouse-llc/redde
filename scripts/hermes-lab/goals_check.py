"""Goals, skipping a run and email watches (lab.sh goals), as Redde 2.4 uses them (plugin 1.15.0):

  goal      `goals.set_up` in this Hermes's own modules (as the agent's `redde_goal` "set" does)
            makes a `[redde-goal:<id>]` job the Dashboard lists and a card in triage for each step
            on the Kanban board (tenant `redde-goal-<id>`); its check-in, triggered, is told the
            goal's steps and answers with a PROGRESS line (the stub's), which reaches a paired
            phone as a briefing with the goal's id (`o`) and progress (`q`), and
            `/redde-push goals list` gives it back with that progress.
  skip      a repeating job marked ` [redde-skip:<its next run>]` (renamed over the Dashboard, as
            the app does) is moved on to the run after within a minute and the mark taken off; it
            doesn't run at the skipped time, the moved time sticks through Hermes's own due checks,
            and it runs at the new one.
  at once   `/redde-push skip default <job> <next run>` moves it on at once.
  no email  a watch whose run answers NO EMAIL ACCESS reaches the phone as a watch note with
            `w` "noemail", and the watch is paused.

usage: goals_check.py <hermes executable>   (a lab up with the push scenario)
"""
import asyncio
import importlib.util
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

import check
from check import Dashboard, report
from status_check import rest, rest_opener
from push_check import Phone, pair

HOME = Path(os.environ["HERMES_HOME"])


def plugin():
    """The plugin as the lab installed it, imported here, in this Hermes's Python."""
    here = HOME / "plugins" / "redde-push"
    spec = importlib.util.spec_from_file_location("redde_push", here / "__init__.py", submodule_search_locations=[str(here)])
    module = importlib.util.module_from_spec(spec)
    sys.modules["redde_push"] = module
    spec.loader.exec_module(module)
    return module


def jobs(opener):
    listed = rest(opener, "GET", "/api/cron/jobs?profile=default")
    return listed if isinstance(listed, list) else listed.get("jobs") or []


def job(opener, job_id):
    return next((j for j in jobs(opener) if j.get("id") == job_id), {})


def seconds(text):
    return datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp() if text else None


async def say(dash, arg):
    return (await dash.call("command.dispatch", {"name": "redde-push", "arg": arg})).get("output", "")


async def main():
    phone = Phone()
    pair(phone)
    report(phone.wait_for("paired") is not None, "a stand-in phone pairs")
    dash = await Dashboard.connect()
    opener = rest_opener()
    await say(dash, f"rooms {phone.id}")   # (the app's word as it reads its list: the schedules' reader starts)
    redde = plugin()
    goals = redde.goals

    # ---- a goal
    made = goals.set_up(HOME, "default", "Lab goal", "2027-01-01", ["Lab step one", "Lab step two"])
    print(f"  info  set: {json.dumps(made)}")
    goal = made.get("set")
    kept = next((g for g in goals.load(HOME) if g.get("id") == goal), {})
    check_in = next((j for j in jobs(opener) if str(j.get("name") or "").startswith(f"[redde-goal:{goal}]")), {})
    report(bool(goal) and bool(check_in), "a goal's check-in is a job the Dashboard lists", json.dumps(check_in)[:200])
    print(f"  info  check-ins: {json.dumps(check_in.get('schedule'))}, next {check_in.get('next_run_at')}")
    cards = [s.get("card") for s in kept.get("steps") or []]
    statuses = goals._card_statuses(goal)
    report(all(cards) and [statuses.get(c) for c in cards] == ["triage", "triage"],
           "its steps are Kanban cards in triage under the goal's tenant", f"{cards} {statuses}")
    await asyncio.sleep(35)   # (the reader has seen the job once: a run from now on is news)
    rest(opener, "POST", f"/api/cron/jobs/{check_in.get('id')}/trigger?profile=default")
    deadline, note = time.time() + 150, None
    while time.time() < deadline and note is None:
        note = next((n for n in phone.notes() if n["k"] == "routine" and n.get("o") == goal), None)
        await asyncio.sleep(2)
    report(note is not None and note.get("x") == "brief" and note.get("q") == "1/2" and note.get("t") == "Lab goal",
           "its check-in reaches the phone as a briefing with the goal and its progress", json.dumps(note)[:300])
    report(note is not None and "told its steps" in str(note.get("b")) and "not told" not in str(note.get("b")),
           "and the check-in's turn was told the goal's steps", str((note or {}).get("b"))[:200])
    listed = await say(dash, "goals list")
    found = next((g for g in json.loads(listed.removeprefix("redde-push goals ") or "[]") if g.get("id") == goal), {}) \
        if listed.startswith("redde-push goals ") else {}
    report((found.get("progress") or {}).get("done") == 1 and len(found.get("steps") or []) == 2,
           "/redde-push goals list gives it back with its progress", listed[:300])
    # Approved in Redde: a card in triage moved to Ready (it has an assignee) or To do, as the app
    # does (PATCH, then POST …/dispatch): does the goal's agent take it up?
    for card, target in zip(cards, ("ready", "todo")):
        rest(opener, "PATCH", f"/api/plugins/kanban/tasks/{card}", {"status": target})
    try:
        rest(opener, "POST", "/api/plugins/kanban/dispatch")
    except Exception as error:
        print(f"  info  dispatch: {error}")
    deadline, now_status = time.time() + 150, {}
    while time.time() < deadline:
        now_status = goals._card_statuses(goal)
        if all(now_status.get(c) not in ("ready", "todo", "triage") for c in cards):
            break
        await asyncio.sleep(5)
    print(f"  info  approved cards now: {now_status}")
    report(now_status.get(cards[0]) not in ("ready", "todo", "triage", None),
           "a card approved to Ready is taken up by the goal's agent", json.dumps(now_status))
    report(now_status.get(cards[1]) not in ("ready", "todo", "triage", None),
           "and one approved to To do is promoted and taken up too", json.dumps(now_status))
    for card in cards:   # (done: their workers, on the stub, would keep the lab busy)
        try:
            rest(opener, "PATCH", f"/api/plugins/kanban/tasks/{card}", {"status": "done", "summary": "lab"})
        except Exception as error:
            print(f"  info  done: {error}")

    # The check-in's job is the truth: its schedule edited (the app's picker), then it deleted (End Goal).
    rest(opener, "PUT", f"/api/cron/jobs/{check_in.get('id')}?profile=default", {"updates": {"schedule": "30 18 * * 3"}})
    listed = json.loads((await say(dash, "goals list")).removeprefix("redde-push goals ") or "[]")
    report(next((g.get("every") for g in listed if g.get("id") == goal), None) == "30 18 * * 3",
           "goals list follows the job's schedule", json.dumps(listed)[:300])
    rest(opener, "DELETE", f"/api/cron/jobs/{check_in.get('id')}?profile=default")
    listed = json.loads((await say(dash, "goals list")).removeprefix("redde-push goals ") or "[]")
    report(not any(g.get("id") == goal for g in listed) and bool(next(g for g in goals.load(HOME) if g["id"] == goal).get("ended")),
           "a goal whose check-in is deleted is ended", json.dumps(listed)[:300])
    other = goals.set_up(HOME, "default", "Lab goal two", None, ["Only step"]).get("set")
    said = await say(dash, f"goals end default {other}")
    report(said == f"redde-push goals ended {other}"
           and not any(str(j.get("name") or "").startswith(f"[redde-goal:{other}]") for j in jobs(opener)),
           "/redde-push goals end deletes its job and ends it", said)

    # ---- skipping a run: every two minutes, on the cron lattice, made when its next run is far
    # enough off for the plugin's reader to get to the mark first
    if 120 - time.time() % 120 < 85:
        await asyncio.sleep(120 - time.time() % 120 + 2)
    created = rest(opener, "POST", "/api/cron/jobs?profile=default",
                   {"name": "[redde-notify] Lab skip", "schedule": "*/2 * * * *", "prompt": "lab skip run", "deliver": "local"})
    skip_id = (created.get("job") or created).get("id")
    upcoming, deadline = seconds(job(opener, skip_id).get("next_run_at")), time.time() + 300
    while upcoming and upcoming - time.time() < 75 and time.time() < deadline:   # (far enough off for the reader to get to it first)
        await asyncio.sleep(max(5, upcoming - time.time() + 15))
        upcoming = seconds(job(opener, skip_id).get("next_run_at"))
    if not upcoming or upcoming - time.time() < 75:
        report(False, "a run far enough off to skip", json.dumps(job(opener, skip_id))[:400])
        return
    print(f"  info  skipping the run at {datetime.fromtimestamp(upcoming).isoformat() if upcoming else None}")
    last_before = job(opener, skip_id).get("last_run_at")
    rest(opener, "PUT", f"/api/cron/jobs/{skip_id}?profile=default",
         {"updates": {"name": f"[redde-notify] Lab skip [redde-skip:{int(upcoming)}]"}})
    deadline, moved = time.time() + 50, {}
    while time.time() < deadline:
        moved = job(opener, skip_id)
        if "[redde-skip:" not in str(moved.get("name")):
            break
        await asyncio.sleep(2)
    report(moved.get("name") == "[redde-notify] Lab skip" and seconds(moved.get("next_run_at")) == upcoming + 120,
           "marked, it moves on to the run after and loses the mark", json.dumps({k: moved.get(k) for k in ("name", "next_run_at")}))
    await asyncio.sleep(max(0, upcoming + 50 - time.time()))
    after = job(opener, skip_id)
    report(after.get("last_run_at") == last_before and seconds(after.get("next_run_at")) == upcoming + 120,
           "it didn't run at the skipped time, and the moved time stuck",
           json.dumps({k: after.get(k) for k in ("last_run_at", "next_run_at")}))
    await asyncio.sleep(max(0, upcoming + 120 + 75 - time.time()))
    ran = job(opener, skip_id)
    report(bool(ran.get("last_run_at")) and abs(seconds(ran.get("last_run_at")) - (upcoming + 120)) < 70,
           "and it ran at the new time", json.dumps({k: ran.get(k) for k in ("last_run_at", "next_run_at")}))

    # ---- at once, over the Dashboard
    upcoming = seconds(job(opener, skip_id).get("next_run_at"))
    said = await say(dash, f"skip default {skip_id} {int(upcoming)}")
    moved = job(opener, skip_id)
    report(said.startswith(f"redde-push skipped {skip_id}") and seconds(moved.get("next_run_at")) == upcoming + 120,
           "/redde-push skip moves it on at once", f"{said} / {moved.get('next_run_at')}")
    print(f"  info  unknown: {await say(dash, 'skip default nosuchjob 1')}")
    rest(opener, "DELETE", f"/api/cron/jobs/{skip_id}?profile=default")

    # ---- a watch on email where there's none
    created = rest(opener, "POST", "/api/cron/jobs?profile=default",
                   {"name": "[redde-watch:lab-mail] Lab mail", "schedule": "0 9 * * *", "deliver": "local",
                    "prompt": "[redde-watch:lab-mail] Watch, for the user: urgent email. If you have no tool that can read "
                              "their email, answer exactly NO EMAIL ACCESS."})
    mail_id = (created.get("job") or created).get("id")
    await asyncio.sleep(35)
    rest(opener, "POST", f"/api/cron/jobs/{mail_id}/trigger?profile=default")
    deadline, note = time.time() + 150, None
    while time.time() < deadline and note is None:
        note = next((n for n in phone.notes() if n["k"] == "watch" and n.get("i") == "lab-mail"), None)
        await asyncio.sleep(2)
    report(note is not None and note.get("w") == "noemail", "an email watch with no email reaches the phone as such",
           json.dumps(note)[:300])
    paused = job(opener, mail_id)
    report(paused.get("enabled") is False or paused.get("state") == "paused", "and the watch is paused",
           json.dumps({k: paused.get(k) for k in ("enabled", "state")}))
    rest(opener, "DELETE", f"/api/cron/jobs/{mail_id}?profile=default")


asyncio.run(main())
raise SystemExit(1 if check.failures else 0)

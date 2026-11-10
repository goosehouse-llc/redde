"""Workstreams over the Hermes API (lab.sh workapi), as plugin 1.23.0 runs them in the gateway:

  route     `/v1/redde/command` answers the app's `/redde-push work …` with the main API key, and
            refuses another key
  start     an API turn (a run) whose model calls `redde_work` (the stub, on "lab:work") starts W1,
            run by the gateway ("api"), listed with the chat that started it
  done      W1 answers its brief by itself and is "done", its last words kept; its chat is the
            API session "Work: W1 · Lab errand"
  report    the chat that started it gets the report as a run of its own, and answers it
  note      the paired phone hears W1 is done
  needs     one whose step needs approval is "needs you" with the command, the phone hears so, and
            `work answer default W2 once` (the Work sheet's) lets it go on to "done"
  stop      `work stop default W3` stops one mid-run: "stopped"
  bot       a bot with a key of its own (LAB_API_BOT=ranger): its chat at /p/ranger/ starts one in
            its own profile, listed by `work list ranger`, done, and reported in its chat

usage: work_api_check.py <hermes>   (a lab up with the push scenario and LAB_API_BOT=ranger)
"""
import asyncio
import json
import time
import urllib.error
import urllib.request

import check
from check import report
from push_check import Phone, pair

API = "http://127.0.0.1:18642"
KEY = "labkey-labkey-labkey"
BOT = "ranger"
BOT_KEY = f"{BOT}key-{BOT}key-{BOT}key"


def api(method, path, body=None, key=KEY, prefix=""):
    request = urllib.request.Request(API + prefix + path, method=method,
                                     data=None if body is None else json.dumps(body).encode(),
                                     headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=60) as answer:
            return answer.status, json.loads(answer.read() or b"{}")
    except urllib.error.HTTPError as error:
        return error.code, {"raw": error.read()[:300].decode(errors="replace")}


def say(command, key=KEY):
    status, body = api("POST", "/v1/redde/command", {"command": command}, key)
    return body.get("output", "") if status == 200 else f"HTTP {status} {body}"


def parsed(output):
    return json.loads(output.removeprefix("redde-push work ")) if output.startswith("redde-push work {") else None


def chat(prefix="", key=KEY, title=None):
    status, made = api("POST", "/api/sessions", {"title": title or f"Work lab {time.time()}"}, key, prefix)
    return made["session"]["id"]


def turn(session, text, prefix="", key=KEY):
    status, made = api("POST", "/v1/runs", {"input": text, "session_id": session}, key, prefix)
    return made.get("run_id")


def said(session, prefix="", key=KEY):
    status, body = api("GET", f"/api/sessions/{session}/messages", None, key, prefix)
    rows = body.get("messages") or body.get("data") or []
    out = []
    for row in rows:
        content = row.get("content")
        if isinstance(content, list):
            content = " ".join(str(p.get("text") or "") for p in content if isinstance(p, dict))
        out.append(str(content or ""))
    return out


def row(ref, profile="default"):
    return next((w for w in (parsed(say(f"work list {profile}")) or {}).get("work") or [] if w["id"] == ref), None)


def until(ref, statuses, seconds=120, profile="default"):
    deadline = time.time() + seconds
    while time.time() < deadline:
        now = row(ref, profile)
        if now and now["status"] in statuses:
            return now
        time.sleep(1)
    return row(ref, profile)


def heard(session, words, seconds=90, prefix="", key=KEY):
    deadline, rows = time.time() + seconds, []
    while time.time() < deadline:
        rows = said(session, prefix, key)
        if any(words in r for r in rows):
            break
        time.sleep(2)
    return rows


async def main():
    phone = Phone()
    await asyncio.to_thread(pair, phone)

    before = parsed(say("work list default"))
    report(before is not None and before["work"] == [] and before["engine"] == "api",
           "the app's `work list` over the Hermes API: none yet, run by the gateway", before)
    report(say("work list default", key="not-the-key-not-the-key").startswith("HTTP 401"),
           "and another key is refused")

    made = chat()
    turn(made, "lab:work hand it off")
    started = until("W1", ("starting", "working", "done", "failed", "needs_you"), 90)
    report(bool(started) and started["engine"] == "api" and started["title"] == "Lab errand" and started["chat"] == made
           and started["session"], "an API turn's redde_work call starts W1 in the gateway, with the chat that started it", started)
    if not started:
        return
    done = until("W1", ("done", "failed", "stopped"))
    report(bool(done) and done["status"] == "done" and done["last"] == "Workstream report: the lab errand is done.",
           "it answers its brief by itself and is done, its last words kept", done)
    status, found = api("GET", "/api/sessions/" + started["session"])
    report(status == 200 and (found.get("session") or {}).get("title") == "Work: W1 · Lab errand",
           "its chat is the API session \"Work: W1 · Lab errand\"", found)

    rows = heard(made, "The agent's word")
    report(any(r.lstrip().startswith("[Workstream W1") for r in rows), "the chat that started it gets the report as a run of its own", rows[-4:])
    report(any("The agent's word: W1 finished" in r for r in rows), "and answers it", rows[-2:])
    note = await asyncio.to_thread(phone.wait_for, "work", started["session"], 20)
    report(bool(note) and note.get("w") == "done" and note.get("x") == "W1" and note.get("p") == "default" and note.get("r") == "api",
           "the phone hears W1 is done, run by the API (so a tap opens its chat there)", note)

    # One that needs approval: "needs you", told to the phone, and answered from the Work sheet.
    turn(made, "lab:work-risky hand this off too")
    waiting = until("W2", ("needs_you", "done", "failed"))
    report(bool(waiting) and waiting["status"] == "needs_you" and "rm -rf" in waiting["asked"],
           "a workstream waiting on an approval is \"needs you\", with the command", waiting)
    needs = await asyncio.to_thread(phone.wait_for, "work", (waiting or {}).get("session"), 20)
    report(bool(needs) and needs.get("w") == "needs" and needs.get("x") == "W2", "the phone hears it needs you", needs)
    if waiting and waiting["status"] == "needs_you":
        answered = parsed(say("work answer default W2 once")) or {}
        after = until("W2", ("done", "failed", "stopped"))
        report(answered.get("answered") == "W2" and bool(after) and after["status"] == "done" and after["asked"] == "",
               "`work answer` lets it go on, and it is done", (answered, after))

    # One stopped mid-run.
    turn(made, "lab:work-slow and this")
    until("W3", ("working",), 60)
    time.sleep(3)
    stopped = parsed(say("work stop default W3")) or {}
    after = until("W3", ("stopped", "done", "failed"), 30)
    report(stopped.get("stopped") == "W3" and bool(after) and after["status"] == "stopped",
           "`work stop` stops one mid-run, and it reads as stopped", (stopped, after))

    # A bot over the API alone, with its own key: its own profile, its own list.
    prefix = f"/p/{BOT}"
    bot_chat = chat(prefix, BOT_KEY, "Bot Chat")
    turn(bot_chat, "lab:work hand it off", prefix, BOT_KEY)
    bot = until("W1", ("done", "failed", "stopped"), 150, BOT)
    report(bool(bot) and bot["engine"] == "api" and bot["status"] == "done" and bot["chat"] == bot_chat,
           "a bot's chat over its own key starts one in its own profile, listed by `work list ranger`, and it is done", bot)
    rows = heard(bot_chat, "The agent's word", prefix=prefix, key=BOT_KEY)
    report(any("The agent's word: W1 finished" in r for r in rows), "and its chat hears the report and answers it", rows[-3:])


asyncio.run(main())
raise SystemExit(1 if check.failures else 0)

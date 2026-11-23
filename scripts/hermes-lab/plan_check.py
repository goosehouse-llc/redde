"""Plan For It (lab.sh plan, plugin 1.41.0), inside a real Hermes, as Redde sends it:

  note      "We're driving to Montreal Friday", over the Dashboard: the turn reaches the model with
            the plugin's word to show a 'plan' card first; "I'm going to bed" doesn't
  answer    the card's answer as Redde sends it (`PlanCard.note`: Do these: … and its
            `[Redde card <key>: plan {...}]`): the turn gets the word to do the 'now' ones; the
            later one is kept, and `/redde-push follow list` lists it
  card      at its time, the Hermes's own loop sends it to a paired stand-in phone as an idea card

usage: plan_check.py <hermes executable>   (a lab up with the push scenario, in the day)
"""
import asyncio
import json
import time
from datetime import datetime, timedelta

import check
from check import Dashboard, report, HITS
from push_check import Phone, pair


async def say(dash, arg):
    return (await dash.call("command.dispatch", {"name": "redde-push", "arg": arg})).get("output", "")


def hits():
    return [json.loads(line) for line in open(HITS) if line.strip()]


async def turn(dash, session, text, field, seconds=60):
    before = len(hits())
    await dash.call("prompt.submit", {"session_id": session, "text": text})
    deadline = time.time() + seconds
    while time.time() < deadline:
        await asyncio.sleep(1)
        new = [h for h in hits()[before:] if h.get("stream")]
        if new:
            await asyncio.sleep(3)      # (the turn ends before the next)
            return any(h.get(field) for h in new)
    return None


async def main():
    if not 7 <= datetime.now().hour < 21:
        print("  SKIP  a plan's card goes 7 am to 9 pm: run this in the day")
        return
    phone = Phone()
    await asyncio.to_thread(pair, phone)
    report(bool(phone.key), "a stand-in phone pairs")
    dash = await Dashboard.connect()
    session = (await dash.call("session.create", {"source": "desktop", "close_on_disconnect": False}))["session_id"]

    report(await turn(dash, session, "We're driving to Montreal Friday", "plan_note") is True,
           "\"We're driving to Montreal Friday\": the model is told to show a plan card first")
    report(await turn(dash, session, "I'm going to bed", "plan_note") is False, "\"I'm going to bed\": no plan")

    at = (datetime.now() + timedelta(seconds=40)).astimezone().replace(microsecond=0).isoformat()
    body = {"later": [{"at": at, "request": "Tell me when to leave for Montreal, with traffic", "title": "Leave-By alert"}],
            "left": ["Packing list"], "now": [{"request": "Look up the weather on the drive", "title": "Weather on the route"}],
            "title": "Driving to Montreal · Friday"}
    answer = "Do these: Weather on the route, Leave-By alert\n\n[Redde card labplan1: plan " + json.dumps(body, ensure_ascii=False) + "]"
    report(await turn(dash, session, answer, "plan_answer") is True, "the answer: the model is told to do the 'now' ones")
    listed = json.loads((await say(dash, "follow list")).removeprefix("redde-push follow ") or "{}")
    kept = [i for i in listed.get("items") or [] if i.get("kind") == "planned"]
    report([(i.get("title"), i.get("what")) for i in kept] == [("Leave-By alert", "Driving to Montreal · Friday")],
           "the later one is kept, and the app's list shows it", listed)

    deadline, card = time.time() + 150, None
    while time.time() < deadline and not card:
        await asyncio.sleep(3)
        card = next((c for n in phone.notes() if n.get("k") == "ideas" for c in n.get("y") or [] if c.get("t") == "Leave-By alert"), None)
    report(card is not None and card.get("r") == "Tell me when to leave for Montreal, with traffic"
           and "Driving to Montreal" in (card.get("w") or ""), "at its time, the loop sends it to the phone as a card", card)
    await dash.ws.close()


asyncio.run(main())
raise SystemExit(1 if check.failures else 0)

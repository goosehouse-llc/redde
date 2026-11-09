"""The person's lists (lab.sh lists), as Redde uses them (plugin 1.20.0):

  turn      a Dashboard turn whose model calls `redde_list` (the stub, on "lab:list") makes the
            list "Lab groceries" with two items, found or not through tool search
  list      `/redde-push lists list` gives it back, as the app's Today row reads it
  check     `/redde-push lists do <change>` (the app's tap) checks an item off, and the answer is
            the lists as they are now

usage: lists_check.py   (a lab up with the push scenario)
"""
import asyncio
import base64
import json
import time

import check
from check import Dashboard, report


async def say(dash, arg):
    return (await dash.call("command.dispatch", {"name": "redde-push", "arg": arg})).get("output", "")


def parsed(output):
    return json.loads(output.removeprefix("redde-push lists ")) if output.startswith("redde-push lists {") else None


async def main():
    dash = await Dashboard.connect()
    try:
        await dash.call("client.capabilities", {"server_requests": True})
    except RuntimeError:
        pass
    before = parsed(await say(dash, "lists list"))
    report(before is not None and before["lists"] == [], "the app's `lists list`: none yet", before)

    session = (await dash.call("session.create", {"source": "desktop", "close_on_disconnect": False}))["session_id"]
    await dash.call("prompt.submit", {"session_id": session, "text": "lab:list make me a grocery list"})
    found, deadline = None, time.time() + 90
    while time.time() < deadline and not found:
        await asyncio.sleep(2)
        now = parsed(await say(dash, "lists list")) or {}
        found = next((l for l in now.get("lists") or [] if l.get("title") == "Lab groceries"), None)
    report(bool(found) and [i["text"] for i in found["items"]] == ["Milk", "Eggs"],
           "a turn's redde_list call makes the list, and `lists list` gives it back", found)
    if not found:
        return

    change = {"action": "check", "list": found["id"], "items": [found["items"][1]["id"]]}
    encoded = base64.urlsafe_b64encode(json.dumps(change).encode()).decode().rstrip("=")
    answer = parsed(await say(dash, f"lists do {encoded}")) or {}
    items = (answer.get("lists") or [{}])[0].get("items") or []
    report(answer.get("said", {}).get("checked") == ["Eggs"] and [i["done"] for i in items] == [False, True],
           "the app's `lists do` checks Eggs off, and says the lists as they are now", answer)
    again = parsed(await say(dash, "lists list")) or {}
    report([i["done"] for i in again["lists"][0]["items"]] == [False, True], "and it stays checked", again)
    await dash.ws.close()


asyncio.run(main())
raise SystemExit(1 if check.failures else 0)

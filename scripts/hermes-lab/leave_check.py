"""Leave-By Alerts' traffic re-check (lab.sh leave), as Redde asks for it, over the Dashboard:

  wake      two stand-in phones pair in one step (`offer`, `accept`); one says when to wake it
            (`leave set <its id> <wakes>`), and at that time "Apple" is handed a sealed note of kind
            "leave" for it alone, with the alert's id and the event's title and nothing else; the
            other phone hears nothing.
  moved     a wake said again with a later time is sent at the new time, once.
  cancel    `leave cancel` takes a wake back before its time: nothing arrives.
  stranger  a device this Hermes hasn't paired is answered "leave 0 0".

The plugin's schedules thread sends wakes every half minute, so this takes a minute or two.

usage: leave_check.py <hermes executable>   (a lab up with the push scenario)
"""
import asyncio
import json
import time

import check
from check import Dashboard
from push_check import Phone, core, report, failures


def wakes(*listed):
    return core.b64u(json.dumps([{"i": i, "t": t, "w": int(w)} for i, t, w in listed]).encode())


async def pair_directly(dash, name):
    phone = Phone()
    offer = (await dash.call("command.dispatch", {"name": "redde-push", "arg": "offer"})).get("output", "")
    phone.answer_directly(offer.split()[2], name=name)
    accepted = (await dash.call("command.dispatch", {"name": "redde-push", "arg": f"accept {offer.split()[2]} {phone.pub} {phone.box}"})).get("output", "")
    report(accepted.startswith("redde-push paired "), f"{name} pairs in one step", accepted)
    return phone


def leave_notes(phone):
    return [made for made in phone.notes() if made["k"] == "leave"]


def wait_for_leave(phone, wake, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        found = [made for made in leave_notes(phone) if made.get("i") == wake]
        if found:
            return found
        time.sleep(1)
    return []


async def main():
    dash = await Dashboard.connect()
    phone, other = await pair_directly(dash, "Lab phone"), await pair_directly(dash, "Lab iPad")

    async def say(arg):
        return (await dash.call("command.dispatch", {"name": "redde-push", "arg": arg})).get("output", "")

    dentist, lunch, gym = "a1b2c3d4e5f60718", "0f1e2d3c4b5a6978", "1122334455667788"
    now = time.time()
    said = await say(f"leave set {phone.id} {wakes((dentist, 'Dentist', now + 5), (lunch, 'Lunch', now + 3600))}")
    report(said == "redde-push leave 1 2", "the plugin keeps a device's wakes", said)
    found = await asyncio.to_thread(wait_for_leave, phone, dentist, 75)
    report(len(found) == 1 and found[0].get("t") == "Dentist" and set(found[0]) <= {"v", "k", "at", "n", "i", "t"},
           "at its time the device is sent a sealed leave note: the id and the title, nothing else", found)
    report(not leave_notes(other), "and no other paired device", leave_notes(other))

    # Moved: the same alert said again for later; then lunch's wake taken back by a list without it.
    now = time.time()
    said = await say(f"leave set {phone.id} {wakes((gym, 'Gym', now + 40))}")
    report(said == "redde-push leave 1 1", "a new list replaces the old one", said)
    said = await say(f"leave set {phone.id} {wakes((gym, 'Gym', now + 50))}")
    found = await asyncio.to_thread(wait_for_leave, phone, gym, 110)
    await asyncio.sleep(35)
    report(len(wait_for_leave(phone, gym, 1)) == 1, "a moved wake is sent once, at its new time", found)
    report(not [m for m in leave_notes(phone) if m.get("i") == lunch], "a wake left out of the list is never sent")

    # Cancelled before its time.
    now = time.time()
    await say(f"leave set {other.id} {wakes((dentist, 'Dentist', now + 30))}")
    said = await say(f"leave cancel {other.id}")
    report(said == "redde-push leave 1 0", "leave cancel takes them all back", said)
    await asyncio.sleep(70)
    report(not leave_notes(other), "and nothing arrives", leave_notes(other))

    said = await say(f"leave set someone-else {wakes((dentist, 'Dentist', time.time() + 600))}")
    report(said == "redde-push leave 0 0", "a device not paired here is told so", said)
    await dash.ws.close()


if __name__ == "__main__":
    asyncio.run(main())
    print("\nAll checks passed." if not failures else f"\nFAILED: {failures}")
    raise SystemExit(1 if failures else 0)

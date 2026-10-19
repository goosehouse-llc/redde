"""Does a turn go on when the app leaves it for another conversation? (GitHub issue 12.)

Each check starts a slow turn (the stub's "lab:slow", eight seconds) in conversation A, leaves
it the way the app leaves a conversation, starts a turn in conversation B, and then looks at A:

  Dashboard, switch     A's turn left without session.interrupt; B resumed on the same socket
                        and asked something. A's turn should still finish there, and its reply be
                        in A's history.
  Dashboard, interrupt  the same with session.interrupt sent for A, as the app does today: A's
                        reply should not come (the control, so the first check means something).
  Dashboard, closed     the socket closed altogether right after A's turn starts (the app
                        closed): is the reply in A's history once a new socket looks?
  API, run left         A's turn as a run (POST /v1/runs, as the app starts one from 1.10), its
                        events dropped while the reply streams: the reply must be in A's history.
  API, hang up          A's turn on /api/sessions/{id}/chat/stream, the request dropped after a
                        second (the app leaving a conversation on the Hermes API): is the reply in
                        A's history afterwards? Once with a turn that says nothing until the end,
                        once with one that streams all along ("lab:drip"), as a model's does.

Run against a lab that is up with the approval scenario (lab.sh switch does both).
"""
import asyncio
import http.client
import json
import sys
import time

import check
from check import API, KEY, Dashboard, api, api_session, report

SLOW = "lab:slow, please"
DRIP = "lab:drip, please"
WANT = "[slow done]"


async def complete(dash, sid, seconds):
    """The text of `sid`'s next message.complete within `seconds`, or None."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            event = await asyncio.wait_for(dash.events.get(), 1)
        except asyncio.TimeoutError:
            continue
        if event.get("session_id") == sid and event.get("type") == "message.complete":
            return (event.get("payload") or {}).get("text") or ""
    return None


def said(messages):
    return [str(m.get("content") or m.get("text") or "") for m in messages if m.get("role") == "assistant"]


async def history(dash, stored):
    result = await dash.call("session.resume", {"session_id": stored, "omit_messages": False})
    return said(result.get("messages") or [])


async def new(dash):
    result = await dash.call("session.create", {"source": "desktop", "close_on_disconnect": False})
    return result["session_id"], result.get("stored_session_id") or result["session_id"]


async def dashboard(interrupt):
    dash = await Dashboard.connect()
    # B exists before A starts, as a conversation from the list does.
    b_runtime, b_stored = await new(dash)
    await dash.call("prompt.submit", {"session_id": b_runtime, "text": "hi"})
    await complete(dash, b_runtime, 30)
    a_runtime, a_stored = await new(dash)
    await dash.call("prompt.submit", {"session_id": a_runtime, "text": SLOW})
    await asyncio.sleep(1.5)
    if interrupt:
        await dash.call("session.interrupt", {"session_id": a_runtime})
    # Leaving: what the app does when another conversation is opened, and a question asked there.
    resumed = await dash.call("session.resume", {"session_id": b_stored, "omit_messages": False})
    await dash.call("prompt.submit", {"session_id": resumed["session_id"], "text": "hi again"})
    heard = await complete(dash, a_runtime, 25)
    await asyncio.sleep(1)
    kept = await history(dash, a_stored)
    await dash.ws.close()
    return heard, kept


async def dashboard_closed():
    dash = await Dashboard.connect()
    a_runtime, a_stored = await new(dash)
    await dash.call("prompt.submit", {"session_id": a_runtime, "text": SLOW})
    await asyncio.sleep(1.5)
    await dash.ws.close()
    await asyncio.sleep(30)    # past the eight seconds, and past 0.21.0's twenty for an orphan
    dash = await Dashboard.connect()
    kept = await history(dash, a_stored)
    await dash.ws.close()
    return kept


def api_hang_up(text=SLOW):
    sid = api_session()
    host, port = API.removeprefix("http://").split(":")
    connection = http.client.HTTPConnection(host, int(port), timeout=10)
    connection.request("POST", f"/api/sessions/{sid}/chat/stream", body=json.dumps({"input": text}),
                       headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    response = connection.getresponse()
    time.sleep(1.0)
    response.read1(1024) if hasattr(response, "read1") else None
    connection.sock.close()     # the app leaving: the request dropped mid-reply
    time.sleep(14)
    status, text = api("GET", f"/api/sessions/{sid}/messages")
    rows = json.loads(text).get("data") or json.loads(text).get("messages") or [] if status < 300 else []
    return status, said(rows)


def api_run_left():
    """A turn as the app starts it from 1.10: a run in the session, its events read for a moment
    and dropped (the app leaving, or iOS cutting it off), while the reply streams."""
    sid = api_session()
    status, text = api("POST", "/v1/runs", {"input": DRIP, "session_id": sid})
    if status >= 300:
        return status, [f"HTTP {status} {text[:120]}"]
    run = json.loads(text)["run_id"]
    host, port = API.removeprefix("http://").split(":")
    connection = http.client.HTTPConnection(host, int(port), timeout=10)
    connection.request("GET", f"/v1/runs/{run}/events", headers={"Authorization": f"Bearer {KEY}"})
    response = connection.getresponse()
    time.sleep(2.5)
    response.read1(4096) if hasattr(response, "read1") else None
    connection.sock.close()
    time.sleep(14)
    status, text = api("GET", f"/api/sessions/{sid}/messages")
    rows = json.loads(text).get("data") or json.loads(text).get("messages") or [] if status < 300 else []
    return status, said(rows)


async def main():
    print("Leaving a turn for another conversation")
    heard, kept = await dashboard(interrupt=False)
    report(heard == WANT and any(WANT in k for k in kept), "Dashboard, switch: A's turn finishes, its reply kept",
           f"heard {heard!r}, A's history {kept}")
    heard, kept = await dashboard(interrupt=True)
    report(heard != WANT and not any(WANT in k for k in kept), "Dashboard, interrupt (control): A's turn stopped",
           f"heard {heard!r}, A's history {kept}")
    kept = await dashboard_closed()
    print(f"  (info) Dashboard, closed: A's history afterwards {kept}")
    status, kept = api_hang_up()
    print(f"  (info) API, hang up: HTTP {status}, A's history afterwards {kept}")
    # The same with a reply that streams all along, as a model's does: Hermes writes to the
    # dropped request, finds it gone and stops the run (all of 0.21.0 to 0.22.2).
    status, kept = api_hang_up(DRIP)
    print(f"  (info) API, hang up while it streams: HTTP {status}, A's history afterwards {kept}")
    status, kept = api_run_left()
    report(any("[drip done]" in k for k in kept), "API, a run left while it streams: it goes on, its reply kept",
           f"HTTP {status}, A's history {kept}")


if __name__ == "__main__":
    asyncio.run(main())
    sys.exit(1 if check.failures else 0)

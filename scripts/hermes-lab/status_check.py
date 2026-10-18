"""What Hermes says about a conversation for the chat list's marks: Working, Needs you, Unread.

  Dashboard, working   `session.active_list` while a slow turn runs ("lab:slow", eight seconds):
                       the conversation, by its stored id, is "working"; once it is over, "idle"
                       or not listed.
  Dashboard, waiting   the same while the turn waits on a person: a question (the clarify tool)
                       is "waiting" on every release; an approval is "waiting" from 0.21.3
                       (0.21.0 says "working", shown as info).
  Dashboard, unread    `GET /api/sessions` rows: `unread` false while nobody has marked the
                       conversation; `PATCH /api/sessions/{id} {"unread": false}`, then a turn:
                       true; marked read: false; marked unread: true. And `sessions.changed`
                       reaches the socket after a reply (info: the app also looks every few
                       seconds).
  API, run             `GET /v1/runs/{id}` for a turn on /api/sessions/{id}/chat/stream (its id
                       comes with `run.started`): "running" while it runs, "waiting_for_approval"
                       while an approval waits, finished afterwards.
  API, unread          `PATCH /api/sessions/{id} {"unread": true}` is taken, and the Dashboard's
                       list says so (the API's own list never carries it).

Mirrors HermesServeClient.activeSessions / setUnread and HermesSessionsAPI.runStatus / setUnread.
Run against a lab that is up with the approval scenario (lab.sh status does both).
"""
import asyncio
import http.client
import http.cookiejar
import json
import sys
import time
import urllib.request

import check
from check import API, KEY, SERVE, Dashboard, api, api_session, report

SLOW = "lab:slow, please"


class Asked(Dashboard):
    """A Dashboard client that keeps the host's own requests (an approval, a question) aside."""

    def __init__(self, ws):
        self.requests = asyncio.Queue()
        super().__init__(ws)

    async def _read(self):
        try:
            async for raw in self.ws:
                msg = json.loads(raw)
                if msg.get("method") == "event":
                    await self.events.put(msg["params"])
                elif "method" in msg and "id" in msg:
                    await self.requests.put(msg)
                elif msg.get("id") in self.pending:
                    self.pending.pop(msg["id"]).set_result(msg)
        except Exception:
            pass


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


def row(opener, stored):
    for s in rest(opener, "GET", "/api/sessions?limit=100&offset=0&order=recent").get("sessions") or []:
        if s.get("id") == stored:
            return s
    return {}


async def new(dash):
    result = await dash.call("session.create", {"source": "desktop", "close_on_disconnect": False})
    return result["session_id"], result.get("stored_session_id") or result["session_id"]


async def status(dash, stored):
    """The conversation's status in `session.active_list`, or None when it isn't listed."""
    for s in (await dash.call("session.active_list", {})).get("sessions") or []:
        if s.get("session_key") == stored:
            return s.get("status")
    return None


async def until(dash, runtime, types, seconds):
    """The first event of one of `types` for `runtime` within `seconds` (its type), or None."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            event = await asyncio.wait_for(dash.events.get(), 1)
        except asyncio.TimeoutError:
            continue
        if event.get("type") in types and event.get("session_id") in (runtime, None, ""):   # "" on a global event
            return event.get("type")
    return None


async def asked(dash, runtime, seconds):
    """Waits for the host to put something to a person: a request (0.21.3 and later) or a
    `<kind>.request` event (0.21.0). True when it came."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        if not dash.requests.empty():
            return True
        while not dash.events.empty():
            event = dash.events.get_nowait()
            if event.get("session_id") == runtime and str(event.get("type", "")).endswith(".request"):
                return True
        await asyncio.sleep(0.2)
    return False


async def waiting(dash, text):
    """Status while a turn waits on a person, then the turn stopped."""
    runtime, stored = await new(dash)
    await dash.call("prompt.submit", {"session_id": runtime, "text": text})
    came = await asked(dash, runtime, 30)
    await asyncio.sleep(0.5)
    during = await status(dash, stored)
    await dash.call("session.interrupt", {"session_id": runtime})
    while not dash.requests.empty():
        dash.requests.get_nowait()
    return came, during


async def dashboard():
    print("Dashboard")
    dash = await Asked.connect()
    try:
        # Without this, 0.21.5 and later turn an approval down at once instead of asking.
        await dash.call("client.capabilities", {"server_requests": True})
    except RuntimeError:
        pass
    opener = rest_opener()

    runtime, stored = await new(dash)
    await dash.call("prompt.submit", {"session_id": runtime, "text": SLOW})
    await asyncio.sleep(2)
    during = await status(dash, stored)
    report(during == "working", "working while its turn runs", f"status {during!r}")
    done = await until(dash, runtime, {"message.complete"}, 25)
    await asyncio.sleep(1)
    after = await status(dash, stored)
    report(done and after in (None, "idle"), "idle once it is over", f"complete {done!r}, status {after!r}")
    report(row(opener, stored).get("unread") is False, "a conversation nobody has marked is not unread",
           f"row unread {row(opener, stored).get('unread')!r}")

    came, during = await waiting(dash, "lab:question")
    report(came and during == "waiting", "waiting while it asks a question", f"asked {came}, status {during!r}")
    came, during = await waiting(dash, "danger")
    if came and during == "working":
        print("  (info) an approval reads \"working\" on this release")
    else:
        report(came and during == "waiting", "waiting while it asks for an approval", f"asked {came}, status {during!r}")

    # Unread: a read mark, then a reply after it.
    marked = rest(opener, "PATCH", f"/api/sessions/{stored}", {"unread": False})
    report(row(opener, stored).get("unread") is False, "marked read: not unread", f"PATCH {marked}")
    await asyncio.sleep(1.2)   # the mark is a time: what comes after it has to come later
    while not dash.events.empty():
        dash.events.get_nowait()
    await dash.call("prompt.submit", {"session_id": runtime, "text": "hi"})
    await until(dash, runtime, {"message.complete"}, 30)
    changed = await until(dash, runtime, {"sessions.changed"}, 6)
    print(f"  (info) sessions.changed after the reply: {'yes' if changed else 'not within 6 s'}")
    report(row(opener, stored).get("unread") is True, "a reply after the mark: unread", f"row unread {row(opener, stored).get('unread')!r}")
    rest(opener, "PATCH", f"/api/sessions/{stored}", {"unread": False})
    report(row(opener, stored).get("unread") is False, "marked read again: not unread")
    rest(opener, "PATCH", f"/api/sessions/{stored}", {"unread": True})
    report(row(opener, stored).get("unread") is True, "marked unread: unread")
    await dash.ws.close()
    return opener


def run_status(run_id):
    code, text = api("GET", f"/v1/runs/{run_id}")
    return json.loads(text).get("status") if code < 300 else f"HTTP {code}"


def started_turn(sid, text):
    """Starts a turn on the chat stream and returns its run id (from `run.started`) and the open
    response, still being read by nobody."""
    host, port = API.removeprefix("http://").split(":")
    connection = http.client.HTTPConnection(host, int(port), timeout=60)
    connection.request("POST", f"/api/sessions/{sid}/chat/stream", body=json.dumps({"input": text}),
                       headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    response = connection.getresponse()
    name = ""
    while True:
        line = response.readline().decode()
        if not line:
            return None, response
        if line.startswith("event:"):
            name = line[6:].strip()
        elif line.startswith("data:") and name == "run.started":
            return json.loads(line[5:]).get("run_id"), response


def api_checks(opener):
    print("Hermes API")
    sid = api_session()
    run_id, response = started_turn(sid, SLOW)
    time.sleep(1.5)
    during = run_status(run_id) if run_id else None
    report(during == "running", "running while its turn runs", f"run {run_id!r}, status {during!r}")
    response.read()
    time.sleep(0.5)
    after = run_status(run_id) if run_id else None
    report(after in ("completed", "failed", "cancelled", "interrupted") or str(after).startswith("HTTP 404"),
           "finished afterwards", f"status {after!r}")

    run_id, response = started_turn(sid, "danger")
    deadline, seen = time.time() + 30, None
    while run_id and time.time() < deadline:
        seen = run_status(run_id)
        if seen == "waiting_for_approval":
            break
        time.sleep(0.5)
    if seen in ("completed", "failed"):
        # Before 0.22 a turn on this route doesn't stop for an approval: there is nothing to wait on.
        print(f"  (info) no approval waited on this release: the run {seen}")
    else:
        report(seen == "waiting_for_approval", "waiting_for_approval while an approval waits", f"status {seen!r}")
    if run_id:
        api("POST", f"/v1/runs/{run_id}/approval", {"choice": "deny"})
    response.read()

    code, text = api("PATCH", f"/api/sessions/{sid}", {"unread": True})
    report(code < 300, "PATCH unread is taken", f"HTTP {code} {text[:120]}")
    report(row(opener, sid).get("unread") is True, "and the Dashboard's list says unread", f"row unread {row(opener, sid).get('unread')!r}")


async def main():
    print("The chat list's marks")
    opener = await dashboard()
    api_checks(opener)


if __name__ == "__main__":
    asyncio.run(main())
    sys.exit(1 if check.failures else 0)

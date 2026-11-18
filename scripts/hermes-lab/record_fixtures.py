"""Records what a running lab Hermes answers to the requests the app parses, for the replay tests
(EchoTests/HermesReplayTests.swift): the Dashboard's REST routes and WebSocket calls, the Hermes
API's, and the errors each says (an unknown session, an unknown run, a wrong key, a delete of a
session that is still working). One file per answer, under <out>/<name>.json:

    {"kind": "rest" | "api", "request": "GET /api/status", "status": 200, "body": <JSON> }
    {"kind": "rest" | "api", "request": "…", "status": 200, "text": "<not JSON: an event stream>"}
    {"kind": "ws", "method": "session.list", "params": {…}, "result": <JSON> }   (or "error": {code, message})
    {"kind": "ws-events", "events": [{"type": …, "session_id": …, "payload": …}, …]}

Names start with where they came from: `rest.` (the Dashboard's REST, `hermes serve` on :19119),
`ws.` (its WebSocket), `api.` (the Hermes API on :18642) and, on 0.23 with LAB_WEBAPP=1, `webapp.`
(the Dashboard the gateway serves itself, on :19120, whose sessions are the canonical owner's).
Machine-specific things are taken out: the lab's folders become <run>, <lab>, <repo> and ~, the
lab's key, password and secret become <redacted>, and so does anything named like a token, a
ticket, a cookie or a password. Nothing else is changed.

Run through lab.sh (`lab.sh fixtures [tag ...]`), which brings the lab up with the approval scenario
and runs this with that release's Python (it needs `websockets`).

usage: record_fixtures.py <out-folder>
"""
import asyncio
import http.cookiejar
import itertools
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.request

SERVE = "http://127.0.0.1:19119"
WEBAPP = "http://127.0.0.1:19120"
API = "http://127.0.0.1:18642"
KEY = "labkey-labkey-labkey"
LOGIN = {"provider": "basic", "username": "lab", "password": "labpass-labpass"}
SECRETS = [KEY, "labpass-labpass", "0123456789abcdef0123456789abcdef0123456789abcdef", "sk-stub"]
SECRET_KEYS = re.compile(r"(token|ticket|secret|password|passwd|api_key|apikey|cookie|authorization|bearer|credential)", re.I)
ids = itertools.count(1)
OUT = ""
saved = []


# ---- Writing ----------------------------------------------------------------------------------

def _places():
    """Folders to take out of what is saved, longest first, with what stands for each."""
    home = os.path.expanduser("~")
    hermes_home = os.environ.get("HERMES_HOME", "")
    places = []
    if hermes_home:
        places.append((os.path.dirname(hermes_home), "<run>"))
    lab = os.environ.get("REDDE_LAB_HOME") or os.path.join(home, ".cache", "redde-hermes-lab")
    places.append((lab, "<lab>"))
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    places.append((repo, "<repo>"))
    places.append((home, "~"))
    out = []
    for path, name in places:
        out.append((path, name))
        real = os.path.realpath(path)
        if real != path:
            out.append((real, name))
    # /private/var/folders/… (a temporary folder) is the machine's own too.
    out.append(("/private/var/folders", "<tmp>"))
    out.append(("/var/folders", "<tmp>"))
    return sorted(out, key=lambda p: -len(p[0]))


PLACES = []
USER = os.path.basename(os.path.expanduser("~"))
HOST = socket.gethostname().split(".")[0]


def clean_text(text):
    for path, name in PLACES:
        text = text.replace(path, name)
    for secret in SECRETS:
        text = text.replace(secret, "<redacted>")
    if USER and len(USER) > 2:
        text = text.replace(USER, "user")
    if HOST and len(HOST) > 2:
        text = re.sub(re.escape(HOST), "<host>", text, flags=re.I)
    return text


def clean(value, key=""):
    if isinstance(value, dict):
        return {k: clean(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [clean(v, key) for v in value]
    if isinstance(value, str):
        # A count of tokens is not a token.
        if key and SECRET_KEYS.search(key) and not key.endswith(("_tokens", "_token_count")) and value:
            return "<redacted>"
        return clean_text(value)
    return value


def save(name, record):
    path = os.path.join(OUT, f"{name}.json")
    with open(path, "w") as f:
        json.dump(clean(record), f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    saved.append(name)
    status = record.get("status")
    error = record.get("error")
    note = f"HTTP {status}" if status is not None else (f"error {error.get('code')} {str(error.get('message'))[:60]}" if error else "ok")
    print(f"  {name:<40} {note}")


# ---- HTTP -------------------------------------------------------------------------------------

def fetch(base, method, path, body=None, headers=None, opener=None, timeout=60, kind="rest"):
    """One request; the answer as a fixture record (status and JSON body, or its text)."""
    request = urllib.request.Request(base + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Content-Type": "application/json", **(headers or {})})
    try:
        response = (opener or urllib.request.build_opener()).open(request, timeout=timeout)
        status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    except Exception as error:   # a timeout, a reset: said as such
        return {"kind": kind, "request": f"{method} {path}", "status": 0, "text": f"no answer: {error!r}"}
    record = {"kind": kind, "request": f"{method} {path}", "status": status}
    if body is not None:
        record["sent"] = body
    text = raw.decode("utf-8", "replace")
    try:
        record["body"] = json.loads(text) if text.strip() else None
    except ValueError:
        record["text"] = text
    return record


def login(base):
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    request = urllib.request.Request(base + "/auth/password-login", method="POST", data=json.dumps(LOGIN).encode(),
                                     headers={"Content-Type": "application/json"})
    opener.open(request, timeout=15).read()
    return opener


def api(method, path, body=None, key=KEY, timeout=60, headers=None):
    return fetch(API, method, path, body, headers={"Authorization": f"Bearer {key}", **(headers or {})}, timeout=timeout, kind="api")


def api_stream(method, path, body=None, until=90):
    """An event stream read to its end (or `until` seconds), as text."""
    request = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json",
                                              "Accept": "text/event-stream"})
    record = {"kind": "api", "request": f"{method} {path}"}
    if body is not None:
        record["sent"] = body
    try:
        with urllib.request.urlopen(request, timeout=until) as response:
            record["status"] = response.status
            lines, deadline = [], time.time() + until
            while time.time() < deadline:
                line = response.readline()
                if not line:
                    break
                lines.append(line.decode("utf-8", "replace"))
            record["text"] = "".join(lines)
    except urllib.error.HTTPError as error:
        record["status"] = error.code
        record["text"] = error.read().decode("utf-8", "replace")
    except Exception as error:
        record.setdefault("status", 0)
        record["text"] = record.get("text", "") + f"\n(stream cut: {error!r})"
    return record


# ---- The Dashboard's WebSocket ----------------------------------------------------------------

class Socket:
    def __init__(self, ws):
        self.ws, self.pending, self.events, self.first = ws, {}, asyncio.Queue(), []
        self.reader = asyncio.create_task(self._read())

    @classmethod
    async def connect(cls, base):
        import websockets
        opener = login(base)
        request = urllib.request.Request(base + "/api/auth/ws-ticket", method="POST", data=b"{}",
                                         headers={"Content-Type": "application/json"})
        ticket = json.loads(opener.open(request, timeout=15).read())["ticket"]
        host = base.removeprefix("http://")
        return cls(await websockets.connect(f"ws://{host}/api/ws?ticket={ticket}", max_size=None))

    async def _read(self):
        try:
            async for raw in self.ws:
                msg = json.loads(raw)
                if msg.get("method") == "event":
                    params = msg.get("params") or {}
                    if len(self.first) < 20:
                        self.first.append(params)
                    await self.events.put(params)
                elif "method" in msg and "id" in msg:
                    # The host asks the client something (a terminal, an approval): not served here.
                    await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": msg["id"],
                                                   "error": {"code": -32601, "message": "not served by the recorder"}}))
                elif msg.get("id") in self.pending:
                    self.pending.pop(msg["id"]).set_result(msg)
        except Exception:
            pass

    async def call(self, method, params, timeout=60):
        """The call's fixture record: its result, or its error."""
        rid = f"rec-{next(ids)}"
        self.pending[rid] = asyncio.get_running_loop().create_future()
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
        record = {"kind": "ws", "method": method, "params": params}
        try:
            msg = await asyncio.wait_for(self.pending[rid], timeout)
        except asyncio.TimeoutError:
            self.pending.pop(rid, None)
            record["error"] = {"code": 0, "message": f"no answer in {timeout} s (recorder)"}
            return record
        if "error" in msg:
            record["error"] = msg["error"]
        else:
            record["result"] = msg.get("result")
        return record

    def drain(self):
        while not self.events.empty():
            self.events.get_nowait()

    async def turn_events(self, runtime, seconds=60):
        """The events of one turn on `runtime`, to its `message.complete` (or an `error`)."""
        events, deadline = [], time.time() + seconds
        while time.time() < deadline:
            try:
                event = await asyncio.wait_for(self.events.get(), 1)
            except asyncio.TimeoutError:
                continue
            if event.get("session_id") not in (runtime, None, ""):
                continue
            events.append(event)
            if event.get("session_id") == runtime and event.get("type") in ("message.complete", "error"):
                break
        return events

    async def ready(self, seconds=6):
        deadline = time.time() + seconds
        while time.time() < deadline:
            if any(e.get("type") == "gateway.ready" for e in self.first):
                break
            await asyncio.sleep(0.1)
        return next((e for e in self.first if e.get("type") == "gateway.ready"), None)


def result(record):
    return record.get("result") or {}


# ---- What is recorded -------------------------------------------------------------------------

UNKNOWN = "20260101_000000_nosuch"


async def dashboard():
    print("Dashboard (hermes serve, :19119)")
    save("rest.status", fetch(SERVE, "GET", "/api/status"))
    save("rest.error.signed-out", fetch(SERVE, "GET", "/api/sessions?limit=1"))
    opener = login(SERVE)

    sock = await Socket.connect(SERVE)
    ready = await sock.ready()
    save("ws.gateway-ready", {"kind": "ws-events", "events": [ready] if ready else []})
    save("ws.client-capabilities", await sock.call("client.capabilities", {"server_requests": True}))

    # A conversation with two turns: a plain one, and one where the agent uses a tool.
    create = await sock.call("session.create", {"source": "desktop", "close_on_disconnect": False})
    save("ws.session-create", create)
    runtime = result(create).get("session_id")
    stored = result(create).get("stored_session_id") or runtime
    sock.drain()
    save("ws.prompt-submit", await sock.call("prompt.submit", {"session_id": runtime, "text": "Hello from the replay recorder"}))
    save("ws.turn-events", {"kind": "ws-events", "events": await sock.turn_events(runtime)})
    sock.drain()
    await sock.call("prompt.submit", {"session_id": runtime, "text": "lab:todo"})
    save("ws.turn-events-tool", {"kind": "ws-events", "events": await sock.turn_events(runtime)})
    await asyncio.sleep(1.5)   # the last rows written

    # The routes the app reads, about that conversation and the rest.
    sid = stored
    save("rest.sessions", fetch(SERVE, "GET", "/api/sessions?limit=100&offset=0&order=recent", opener=opener))
    save("rest.session", fetch(SERVE, "GET", f"/api/sessions/{sid}", opener=opener))
    save("rest.messages", fetch(SERVE, "GET", f"/api/sessions/{sid}/messages?order=latest&limit=500", opener=opener))
    snapshot = fetch(SERVE, "GET", f"/api/sessions/{sid}/mutation-snapshot", opener=opener)
    save("rest.mutation-snapshot", snapshot)
    save("rest.profiles", fetch(SERVE, "GET", "/api/profiles", opener=opener))
    save("rest.profiles-sessions", fetch(SERVE, "GET", "/api/profiles/sessions?profile=all&order=recent&limit=150", opener=opener))
    save("rest.skills", fetch(SERVE, "GET", "/api/skills", opener=opener))
    save("rest.toolsets", fetch(SERVE, "GET", "/api/tools/toolsets", opener=opener))
    save("rest.cron-jobs", fetch(SERVE, "GET", "/api/cron/jobs", opener=opener))
    save("rest.model-options", fetch(SERVE, "GET", "/api/model/options", opener=opener))
    save("rest.config", fetch(SERVE, "GET", "/api/config?include_defaults=false", opener=opener))
    save("rest.plugins-hub", fetch(SERVE, "GET", "/api/dashboard/plugins/hub", opener=opener))
    save("rest.mcp-servers", fetch(SERVE, "GET", "/api/mcp/servers", opener=opener))
    save("rest.system-stats", fetch(SERVE, "GET", "/api/system/stats", opener=opener))
    save("rest.auth-me", fetch(SERVE, "GET", "/api/auth/me", opener=opener))

    # A rename as the app sends it (fenced where the snapshot route is: PR 53), and bare (issue 70).
    body = {"title": "Replay rename"}
    if snapshot.get("status") == 200 and isinstance(snapshot.get("body"), dict):
        snap = snapshot["body"]
        body.update(request_id="00000000-0000-4000-8000-000000000001", expected_revision=snap.get("runtime_revision"),
                    expected_generation=snap.get("runtime_generation"))
    save("rest.patch-rename", fetch(SERVE, "PATCH", f"/api/sessions/{sid}", body, opener=opener))
    save("rest.patch-rename-bare", fetch(SERVE, "PATCH", f"/api/sessions/{sid}", {"title": "Replay rename, bare"}, opener=opener))

    save("rest.error.unknown-session", fetch(SERVE, "GET", f"/api/sessions/{UNKNOWN}", opener=opener))
    save("rest.error.unknown-session-messages", fetch(SERVE, "GET", f"/api/sessions/{UNKNOWN}/messages?order=latest&limit=500", opener=opener))
    save("rest.error.unknown-mutation-snapshot", fetch(SERVE, "GET", f"/api/sessions/{UNKNOWN}/mutation-snapshot", opener=opener))

    # The socket's calls.
    save("ws.session-resume", await sock.call("session.resume", {"session_id": sid, "omit_messages": False}, timeout=120))
    save("ws.session-list", await sock.call("session.list", {"limit": 50}))
    save("ws.model-options", await sock.call("model.options", {"explicit_only": True, "refresh": False}))
    save("ws.profiles-list", await sock.call("profiles.list", {}))
    save("ws.profiles-describe", await sock.call("profiles.describe", {"name": "default"}))
    save("ws.projects-tree", await sock.call("projects.tree", {"preview_limit": 0}))
    save("ws.complete-slash", await sock.call("complete.slash", {"text": "/"}, timeout=15))
    save("ws.plugins-list", await sock.call("plugins.manage", {"action": "list"}))
    save("ws.groups-capabilities", await sock.call("groups.capabilities", {}))
    save("ws.toolsets-list", await sock.call("toolsets.list", {}))
    save("ws.error.resume-unknown", await sock.call("session.resume", {"session_id": UNKNOWN, "omit_messages": True}))
    save("ws.error.unknown-method", await sock.call("redde.no_such_method", {}))

    # A conversation still working: what the list of live ones says, and what a delete answers
    # (issue 78: 4023 "cannot delete an active session").
    busy = await sock.call("session.create", {"source": "desktop", "close_on_disconnect": False})
    busy_runtime = result(busy).get("session_id")
    busy_stored = result(busy).get("stored_session_id") or busy_runtime
    sock.drain()
    await sock.call("prompt.submit", {"session_id": busy_runtime, "text": "lab:slow, please"})
    await asyncio.sleep(2)
    save("ws.session-active-list", await sock.call("session.active_list", {}))
    save("ws.error.delete-running", await sock.call("session.delete", {"session_id": busy_stored}))
    await sock.call("session.interrupt", {"session_id": busy_runtime})
    await sock.turn_events(busy_runtime, 20)
    # Closed first, as the app does, then deleted.
    await sock.call("session.close", {"session_id": busy_runtime})
    await asyncio.sleep(1)
    save("ws.session-delete", await sock.call("session.delete", {"session_id": busy_stored}))
    await sock.ws.close()
    return stored


def hermes_api():
    print("Hermes API (:18642)")
    save("api.health", api("GET", "/health"))
    save("api.models", api("GET", "/v1/models"))
    save("api.toolsets", api("GET", "/v1/toolsets"))
    save("api.skills", api("GET", "/v1/skills"))
    save("api.model-options", api("GET", "/api/model/options"))
    save("api.error.bad-key", api("GET", "/v1/models", key="wrong-key-wrong-key"))
    save("api.error.bad-key-sessions", api("GET", "/api/sessions?limit=1", key="wrong-key-wrong-key"))

    made = api("POST", "/api/sessions", {"title": "Replay API chat"})
    save("api.session-create", made)
    sid = ((made.get("body") or {}).get("session") or {}).get("id")
    if not sid:
        print("  (no session from the API: its session routes are left out)")
        return

    # A turn as a run (the app from 1.10): started, its events read to the end, then its status.
    started = api("POST", "/v1/runs", {"input": "Hello from the replay recorder", "session_id": sid})
    save("api.run-start", started)
    run = (started.get("body") or {}).get("run_id")
    if run:
        save("api.run-events", api_stream("GET", f"/v1/runs/{run}/events"))
        for _ in range(60):
            state = api("GET", f"/v1/runs/{run}")
            if (state.get("body") or {}).get("status") not in ("queued", "running", "stopping"):
                break
            time.sleep(0.5)
        save("api.run-status", state)

    # The older way, still the app's where a gateway has no runs: the chat stream.
    save("api.chat-stream", api_stream("POST", f"/api/sessions/{sid}/chat/stream", {"input": "lab:todo"}))
    time.sleep(1)
    save("api.sessions", api("GET", "/api/sessions?limit=100&offset=0"))
    save("api.session", api("GET", f"/api/sessions/{sid}"))
    save("api.messages", api("GET", f"/api/sessions/{sid}/messages?order=latest&limit=500"))
    save("api.patch-rename", api("PATCH", f"/api/sessions/{sid}", {"title": "Replay API rename"}))

    save("api.error.unknown-run", api("GET", "/v1/runs/run_nosuch000000"))
    save("api.error.unknown-session", api("GET", f"/api/sessions/{UNKNOWN}"))
    save("api.error.unknown-session-messages", api("GET", f"/api/sessions/{UNKNOWN}/messages?order=latest&limit=500"))

    # A run still working: its status, a delete of its session, and a stop.
    busy = api("POST", "/api/sessions", {"title": "Replay API busy"})
    busy_sid = ((busy.get("body") or {}).get("session") or {}).get("id")
    slow = api("POST", "/v1/runs", {"input": "lab:slow, please", "session_id": busy_sid})
    slow_run = (slow.get("body") or {}).get("run_id")
    if slow_run:
        time.sleep(2)
        save("api.run-status-running", api("GET", f"/v1/runs/{slow_run}"))
        save("api.error.delete-running", api("DELETE", f"/api/sessions/{busy_sid}"))
        save("api.run-stop", api("POST", f"/v1/runs/{slow_run}/stop", {}))
        for _ in range(40):
            if (api("GET", f"/v1/runs/{slow_run}").get("body") or {}).get("status") not in ("queued", "running", "stopping"):
                break
            time.sleep(0.5)
        time.sleep(1)
    save("api.session-delete", api("DELETE", f"/api/sessions/{busy_sid}"))


async def webapp():
    """Hermes 0.23's own Dashboard, whose sessions are the canonical owner's (issue 81)."""
    for _ in range(30):
        try:
            urllib.request.urlopen(WEBAPP + "/api/status", timeout=2).read()
            break
        except urllib.error.HTTPError:
            break
        except Exception:
            time.sleep(1)
    else:
        print("(no Webapp on :19120)")
        return
    print("Webapp (the gateway's Dashboard, :19120)")
    save("webapp.rest.status", fetch(WEBAPP, "GET", "/api/status"))
    try:
        sock = await Socket.connect(WEBAPP)
    except Exception as error:
        print(f"  (the Webapp's socket didn't open: {error!r})")
        return
    opener = login(WEBAPP)
    ready = await sock.ready()
    save("webapp.ws.gateway-ready", {"kind": "ws-events", "events": [ready] if ready else []})
    create = await sock.call("session.create", {"source": "gui"})
    save("webapp.ws.session-create", create)
    runtime = result(create).get("session_id")
    stored = result(create).get("stored_session_id") or runtime
    sock.drain()
    save("webapp.ws.prompt-submit", await sock.call("prompt.submit", {"session_id": runtime, "text": "Hello from the replay recorder",
                                                                      "submission_id": "00000000-0000-4000-8000-000000000002"}))
    save("webapp.ws.turn-events", {"kind": "ws-events", "events": await sock.turn_events(runtime)})
    await asyncio.sleep(1.5)
    resume = await sock.call("session.resume", {"session_id": stored, "omit_messages": False}, timeout=120)
    save("webapp.ws.session-resume", resume)
    snap = result(resume)
    save("webapp.ws.session-mutate-rename", await sock.call("session.mutate", {
        "session_id": stored, "request_id": "00000000-0000-4000-8000-000000000003", "operation": "rename",
        "expected_revision": snap.get("revision") or 0, "payload": {"title": "Replay rename on the Webapp"}}))
    # A title another session has (the Dashboard's chat above): what a bot's chat made at the same
    # moment by another app meets (ServerBots.makeBotChat looks for "already in use").
    snap = result(await sock.call("session.resume", {"session_id": stored, "omit_messages": True}))
    save("webapp.ws.error.mutate-rename-taken", await sock.call("session.mutate", {
        "session_id": stored, "request_id": "00000000-0000-4000-8000-000000000006", "operation": "rename",
        "expected_revision": snap.get("revision") or 0, "payload": {"title": "Replay rename"}}))
    save("webapp.ws.session-list", await sock.call("session.list", {"limit": 50}))
    save("webapp.rest.sessions", fetch(WEBAPP, "GET", "/api/sessions?limit=100&offset=0&order=recent", opener=opener))
    save("webapp.rest.messages", fetch(WEBAPP, "GET", f"/api/sessions/{stored}/messages?order=latest&limit=500", opener=opener))
    save("webapp.rest.mutation-snapshot", fetch(WEBAPP, "GET", f"/api/sessions/{stored}/mutation-snapshot", opener=opener))
    # What the canonical owner refuses: `hermes serve`'s own shapes (issue 81).
    save("webapp.ws.error.serve-create", await sock.call("session.create", {"source": "desktop", "close_on_disconnect": False}))
    save("webapp.ws.error.session-delete", await sock.call("session.delete", {"session_id": stored}))

    # A delete as the app sends it there, while a turn runs (issue 78 on the canonical owner).
    busy = await sock.call("session.create", {"source": "gui"})
    busy_runtime = result(busy).get("session_id")
    busy_stored = result(busy).get("stored_session_id") or busy_runtime
    await sock.call("prompt.submit", {"session_id": busy_runtime, "text": "lab:slow, please", "submission_id": "00000000-0000-4000-8000-000000000004"})
    await asyncio.sleep(2)
    save("webapp.ws.session-active-list", await sock.call("session.active_list", {}))
    snap = result(await sock.call("session.resume", {"session_id": busy_stored, "omit_messages": True}))
    save("webapp.ws.session-mutate-delete-running", await sock.call("session.mutate", {
        "session_id": busy_stored, "request_id": "00000000-0000-4000-8000-000000000005", "operation": "delete",
        "expected_revision": snap.get("revision") or 0, "expected_generation": snap.get("execution_generation") or 0, "payload": {}}))
    await sock.ws.close()


async def main():
    global OUT, PLACES
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    OUT = sys.argv[1]
    os.makedirs(OUT, exist_ok=True)
    for old in os.listdir(OUT):
        if old.endswith(".json"):
            os.remove(os.path.join(OUT, old))
    PLACES = _places()
    await dashboard()
    hermes_api()
    if os.environ.get("LAB_WEBAPP"):
        await webapp()
    print(f"{len(saved)} fixtures in {OUT}")


if __name__ == "__main__":
    asyncio.run(main())

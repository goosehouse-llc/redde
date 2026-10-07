"""Sends a running lab Hermes the requests Redde sends for a picked model, and checks that every
turn reaches the endpoint that serves it. Run through lab.sh (it needs the lab's Python, which has
`websockets`).

usage: check.py [dashboard|api|both]

Mirrors, and must stay in step with:
  - Conversation.liveProvider                     -> live_provider()
  - HermesServeClient.openSession / modelSwitchValue -> session.create, config.set "<m> --provider <p>"
  - HermesSessionsTransport (chat body, lock route, isLockBucketMismatch) -> ApiCheck
"""
import asyncio
import itertools
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

HITS = os.environ["LAB_HITS"]
SERVE = "127.0.0.1:19119"
API = "http://127.0.0.1:18642"
KEY = "labkey-labkey-labkey"
# Which stub serves which model (lab.sh starts stub A with alpha,beta and stub B with gamma).
WANT = {"alpha": "A", "beta": "A", "gamma": "B"}
failures = []
ids = itertools.count(1)


def report(ok, what, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {what}{'  ' + detail if detail and not ok else ''}")
    if not ok:
        failures.append(what)


def clear_hits():
    open(HITS, "w").close()


def first_hit():
    time.sleep(0.4)
    # Title generation and other side calls reach the stubs too; the streamed call is the turn.
    rows = [json.loads(line) for line in open(HITS) if line.strip()]
    rows = [r for r in rows if r["stream"]] or rows
    return f"{rows[0]['stub']}:{rows[0]['model']}" if rows else "no endpoint reached"


def local_pairs(options):
    """(provider slug, model, provider is current) for the rows the lab's stubs serve."""
    pairs = []
    for row in options.get("providers", []):
        slug = row.get("slug") or row.get("id") or ""
        for model in row.get("models", []):
            model = model if isinstance(model, str) else (model.get("id") or model.get("model"))
            if model in WANT:
                pairs.append((slug, model, bool(row.get("is_current")) and model == options.get("model")))
    return pairs


def live_provider(model, saved, pairs):
    """Conversation.liveProvider: the provider to send for a pick, given the host's list."""
    if not pairs:
        return saved
    serving = [p for p, m, _ in pairs if m == model]
    named = next((p for p in serving if p != "custom"), None)
    if saved and saved in serving:
        bare_leftover = saved == "custom" and not any(p == "custom" and cur for p, _, cur in pairs)
        return (named or saved) if bare_leftover else saved
    if named or serving:
        return named or serving[0]
    if saved and any(p == saved for p, _, _ in pairs):
        return saved
    return next((p for p, _, cur in pairs if cur), None)


# ---- Dashboard (hermes serve) -------------------------------------------------------------

class Dashboard:
    def __init__(self, ws):
        self.ws, self.events, self.pending = ws, asyncio.Queue(), {}
        self.reader = asyncio.create_task(self._read())

    @classmethod
    async def connect(cls):
        import websockets
        # Loopback serve has no login: the socket takes the session token from the root page.
        try:
            page = urllib.request.urlopen(f"http://{SERVE}/", timeout=10).read().decode()
        except urllib.error.HTTPError:
            page = ""
        token = re.search(r'__HERMES_SESSION_TOKEN__="([^"]+)"', page)
        if token:
            return cls(await websockets.connect(f"ws://{SERVE}/api/ws?token={token.group(1)}", max_size=None))
        # A Dashboard with a login (the approval and push scenarios): sign in the way the app
        # does, with the user lab.sh set, and open the socket with a ticket.
        import http.cookiejar
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        def post(path, body):
            request = urllib.request.Request(f"http://{SERVE}{path}", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
            return opener.open(request, timeout=10).read().decode()
        post("/auth/password-login", {"provider": "basic", "username": "lab", "password": "labpass-labpass"})
        ticket = json.loads(post("/api/auth/ws-ticket", {}))["ticket"]
        return cls(await websockets.connect(f"ws://{SERVE}/api/ws?ticket={ticket}", max_size=None))

    async def _read(self):
        try:
            async for raw in self.ws:
                msg = json.loads(raw)
                if msg.get("method") == "event":
                    await self.events.put(msg["params"])
                elif msg.get("id") in self.pending:
                    self.pending.pop(msg["id"]).set_result(msg)
        except Exception:
            pass

    async def call(self, method, params):
        rid = f"lab-{next(ids)}"
        self.pending[rid] = asyncio.get_running_loop().create_future()
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
        msg = await asyncio.wait_for(self.pending[rid], 60)
        if "error" in msg:
            raise RuntimeError(f"{method}: {msg['error'].get('message')}")
        return msg.get("result") or {}

    async def turn(self, sid):
        """One prompt, read the way HermesServeTransport does: ends on message.complete or error."""
        while not self.events.empty():
            self.events.get_nowait()
        clear_hits()
        await self.call("prompt.submit", {"session_id": sid, "text": "hi"})
        deadline, error = time.time() + 90, "timed out"
        while time.time() < deadline:
            try:
                event = await asyncio.wait_for(self.events.get(), 2)
            except asyncio.TimeoutError:
                continue
            if event.get("session_id") != sid:
                continue
            payload = event.get("payload") or {}
            if event.get("type") == "message.complete":
                error = str(payload.get("error") or payload.get("text"))[:120] if payload.get("status") == "error" else ""
                break
            if event.get("type") == "error":
                error = str(payload.get("message"))[:120]
                break
        return first_hit() + (f" then: {error}" if error else "")


async def check_dashboard():
    print("Dashboard (hermes serve)")
    dash = await Dashboard.connect()
    pairs = local_pairs(await dash.call("model.options", {"explicit_only": True}))
    create = {"source": "desktop", "close_on_disconnect": False}
    for picked, model, _ in pairs:
        provider, want = live_provider(model, picked, pairs), f"{WANT[model]}:{model}"
        label = f"{model} picked under {picked!r}" + (f", sent as {provider!r}" if provider != picked else "")
        try:
            sid = (await dash.call("session.create", {**create, "model": model, "provider": provider}))["session_id"]
            got = await dash.turn(sid)
            report(got == want, f"new conversation: {label}", got)
            sid = (await dash.call("session.create", create))["session_id"]
            await dash.turn(sid)
            await dash.call("config.set", {"session_id": sid, "key": "model", "value": f"{model} --provider {provider}"})
            got = await dash.turn(sid)
            report(got == want, f"live switch:      {label}", got)
        except Exception as error:
            report(False, f"{label}", str(error)[:160])
    await dash.ws.close()


# ---- Hermes API (api_server) --------------------------------------------------------------

LOCK_MISMATCH = re.compile(r"lock runtime mismatch: expected provider=(\S+) model=(\S+); actual provider=(\S+) model=(\S+)")


def is_lock_bucket_mismatch(message):
    """HermesSessionsTransport.isLockBucketMismatch: the pre-0.21.4 post-run check on a named endpoint."""
    match = LOCK_MISMATCH.search(message or "")
    return bool(match) and match.group(2) == match.group(4) and match.group(3) == "custom" and match.group(1) != "custom"


def api(method, path, body=None):
    request = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def api_session(**body):
    return json.loads(api("POST", "/api/sessions", {"title": f"lab {time.time()}", **body})[1])["session"]["id"]


def api_turn(sid, model=None, provider=None):
    """One chat turn with the body the app sends: a picked model rides with its provider and the lock."""
    body = {"input": "hi"}
    if model:
        body.update(model=model, provider=provider, require_model_lock=True)
    clear_hits()
    status, text = api("POST", f"/api/sessions/{sid}/chat/stream", body)
    if status >= 300:
        return f"HTTP {status} {text[:120]}"
    error, name = "", ""
    for line in text.splitlines():
        if line.startswith("event:"):
            name = line[6:].strip()
        elif line.startswith("data:") and name == "error":
            message = json.loads(line[5:]).get("message", "")
            if not is_lock_bucket_mismatch(message):
                error = f" then: {message[:120]}"
            break
    return first_hit() + error


def check_api():
    print("Hermes API (api_server)")
    pairs = local_pairs(json.loads(api("GET", "/api/model/options")[1]))
    for picked, model, _ in pairs:
        provider, want = live_provider(model, picked, pairs), f"{WANT[model]}:{model}"
        label = f"{model} picked under {picked!r}" + (f", sent as {provider!r}" if provider != picked else "")
        sid = api_session(model=model, provider=provider)
        got = [api_turn(sid, model, provider) for _ in range(2)]
        report(all(g == want for g in got), f"new conversation: {label}", str(got))
        sid = api_session()
        api_turn(sid)
        status, text = api("POST", f"/api/sessions/{sid}/model", {"model": model, "provider": provider})
        got = [api_turn(sid, model, provider) for _ in range(2)]
        report(status < 300 and all(g == want for g in got), f"live switch:      {label}", f"lock HTTP {status} {got}")


async def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "both"
    if which in ("both", "dashboard"):
        try:
            await check_dashboard()
        except Exception as error:
            report(False, "dashboard checks could not run", repr(error)[:200])
    if which in ("both", "api"):
        try:
            check_api()
        except Exception as error:
            report(False, "api checks could not run", repr(error)[:200])
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    asyncio.run(main())

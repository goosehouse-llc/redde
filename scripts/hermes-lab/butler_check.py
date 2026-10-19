"""The butler (lab.sh butler): the main profile ("Sol") hands coding to a "claude" bot, the bot does it
with Claude Code on another machine, and Sol applies what comes back, asking the person first.

  roster    the claude bot is a profile Hermes lists, set up as a bot.
  hand-off  a message to Sol on the Dashboard: Sol makes a kanban card for the claude bot.
  worker    the dispatcher runs the claude bot's worker, which runs Claude Code on "Workbox" over its
            SSH terminal and finishes the card with where the patch is.
  no keys   what Claude Code saw: the main profile's secret neither in its environment nor readable,
            and nothing of the main profile's copied over to Workbox.
  asked     Sol, woken by the finished card, wants to apply the patch: the Dashboard client is asked
            first (a server request, `approval`), the command in the question.
  verbatim  approved once: the patch goes in as Claude wrote it (the repository's diff is the patch).
  denied    a second card, its command denied: nothing goes in.
  API       a card made over the Hermes API: the turn Hermes starts when it is done has no one to
            ask, so the command is refused and nothing goes in.

Run against a lab that is up with the butler scenario (lab.sh butler sets it up).
"""
import asyncio
import json
import os
import sqlite3
import time
import urllib.request

import check
from check import Dashboard, report

RUN = os.environ["LAB_BUTLER"]
HOME = os.environ["HERMES_HOME"]
REPO = f"{RUN}/host/repo"
WORKBOX = f"{RUN}/workbox/home"


class Butler(Dashboard):
    """The lab's Dashboard client, also taking the server's requests (approvals)."""

    def __init__(self, ws):
        self.requests = asyncio.Queue()
        super().__init__(ws)

    async def _read(self):
        try:
            async for raw in self.ws:
                msg = json.loads(raw)
                if msg.get("method") == "event":
                    await self.events.put(msg["params"])
                elif msg.get("method") and "id" in msg:
                    await self.requests.put(msg)
                elif msg.get("id") in self.pending:
                    self.pending.pop(msg["id"]).set_result(msg)
        except Exception:
            pass

    async def answer(self, request, choice):
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {"choice": choice}}))

    async def said(self, sid, seconds=120):
        """The text of the session's next finished turn, or None."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                event = await asyncio.wait_for(self.events.get(), 2)
            except asyncio.TimeoutError:
                continue
            if event.get("session_id") == sid and event.get("type") == "message.complete":
                payload = event.get("payload") or {}
                return str(payload.get("text") or payload.get("error") or "")
        return None

    async def approval(self, seconds=150):
        try:
            return await asyncio.wait_for(self.requests.get(), seconds)
        except asyncio.TimeoutError:
            return None


def task(title, seconds=180, settled=("done", "blocked", "failed", "archived")):
    """The kanban card with that title, once it is settled (or as it is when time runs out)."""
    deadline, row = time.time() + seconds, None
    while time.time() < deadline:
        try:
            db = sqlite3.connect(f"file:{HOME}/kanban.db?mode=ro", uri=True)
            db.row_factory = sqlite3.Row
            found = [dict(r) for r in db.execute("SELECT * FROM tasks") if r["title"] == title]
            db.close()
            row = found[-1] if found else None
        except sqlite3.Error:
            row = None
        if row and row.get("status") in settled:
            return row
        time.sleep(2)
    return row


def code():
    with open(f"{REPO}/hello.py") as f:
        return f.read()


def hook_log():
    try:
        with open(os.environ["LAB_HOOK_LOG"]) as f:
            return [json.loads(line) for line in f if line.strip()]
    except OSError:
        return []


def api(method, path, body=None):
    request = urllib.request.Request(check.API + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {check.KEY}", "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.loads(response.read().decode() or "{}")


async def main():
    canary = next(line.split("=", 1)[1].strip() for line in open(f"{HOME}/.env") if line.startswith("LAB_CANARY_KEY="))
    dash = await Butler.connect()
    await dash.call("client.capabilities", {"server_requests": True})

    roster = await dash.call("profiles.list", {})
    claude = next((p for p in roster.get("profiles") or [] if p.get("name") == "claude"), None)
    report(claude is not None and "hermes-bots" in (claude.get("ui_meta") or {}), "the claude bot is a profile, set up as a bot",
           json.dumps(claude)[:200] if claude else "not listed")

    # 1. Sol hands the task over, and the claude bot does it.
    sid = (await dash.call("session.create", {"source": "desktop", "close_on_disconnect": False}))["session_id"]
    await dash.call("prompt.submit", {"session_id": sid, "text": "lab:butler tag=one Please add a line to hello.py."})
    first = await dash.said(sid)
    report(first == "[queued]", "Sol hands the coding task to the claude bot on the kanban board", str(first))
    card = task("Lab change one")
    report(card is not None and card.get("assignee") == "claude" and card.get("status") == "done",
           "the claude bot's worker runs and finishes the card",
           json.dumps({k: (card or {}).get(k) for k in ("id", "assignee", "status", "result", "summary")})[:300])
    patch_path = f"{WORKBOX}/work/one/change.patch"
    patch = open(patch_path).read() if os.path.exists(patch_path) else ""
    report("changed by the claude bot: one" in patch, "Claude Code ran on Workbox and wrote a patch there", patch_path)

    # 2. What Claude Code could see.
    saw = {}
    try:
        saw = json.load(open(f"{WORKBOX}/work/one/claude-saw.json"))
    except (OSError, ValueError):
        pass
    report(bool(saw) and not saw.get("env_has_canary"), "the main profile's secret is not in Claude Code's environment",
           f"secret-looking names it had: {saw.get('env_secret_names')}")
    report(bool(saw.get("checked")) and not saw.get("main_env_readable"), "the main profile's .env is out of Claude Code's reach",
           f"tried {saw.get('checked')}")
    copied, leaked = [], []
    for root, _, files in os.walk(f"{WORKBOX}/.hermes"):
        for name in files:
            path = os.path.join(root, name)
            copied.append(os.path.relpath(path, WORKBOX))
            try:
                if canary in open(path, errors="ignore").read():
                    leaked.append(path)
            except OSError:
                pass
    report(not leaked, "nothing Hermes copied to Workbox holds the main profile's secret", f"{len(copied)} files copied: {copied[:6]}")

    # 3. Sol is woken, wants to apply it, and is asked; approved once, it goes in as written.
    request = await dash.approval()
    params = (request or {}).get("params") or {}
    words = f"{params.get('command', '')} {params.get('description', '')}"
    report(request is not None and request.get("method") == "approval" and "git -C" in words and "apply" in words and "ssh workbox cat" in words,
           "woken by the finished card, Sol wants to apply the patch, and the person is asked first", words[:240])
    print(f"  info  choices offered: {params.get('choices')}")
    if request:
        await dash.answer(request, "once")
    applied = await dash.said(sid)
    import subprocess
    diff = subprocess.run(["git", "-C", REPO, "diff"], capture_output=True, text=True).stdout
    report(applied == "[applied]" and diff == patch and diff != "", "approved once, the patch goes in exactly as Claude wrote it",
           f"{applied}; diff {'matches' if diff == patch else 'differs'} ({len(diff)} vs {len(patch)} bytes)")

    # 4. A second card, denied: nothing goes in.
    await dash.call("prompt.submit", {"session_id": sid, "text": "lab:butler tag=two And another line."})
    report(await dash.said(sid) == "[queued]", "a second card is made")
    report((task("Lab change two") or {}).get("status") == "done", "and done by the claude bot")
    request = await dash.approval()
    if request:
        await dash.answer(request, "deny")
    after = await dash.said(sid)
    report(request is not None and after == "[not applied]" and "two" not in code(), "denied, nothing goes in", str(after))

    # 5. Over the Hermes API: the turn Hermes starts when the card is done has no one to ask.
    stored = check.api_session()
    run = api("POST", "/v1/runs", {"input": "lab:butler tag=api A line from the API.", "session_id": stored})["run_id"]
    deadline, state = time.time() + 90, {}
    while time.time() < deadline:
        state = api("GET", f"/v1/runs/{run}")
        if state.get("status") in ("completed", "failed", "cancelled", "interrupted"):
            break
        time.sleep(0.5)
    report(state.get("status") == "completed", "over the Hermes API, Sol makes the card too", state.get("status", ""))
    report((task("Lab change api") or {}).get("status") == "done", "and the claude bot does it")
    deadline, tried = time.time() + 60, []
    while time.time() < deadline and not tried:
        tried = [e for e in hook_log() if e.get("asked") and "/work/api/" in str(e.get("message"))]
        time.sleep(2)
    time.sleep(8)
    messages = api("GET", f"/api/sessions/{stored}/messages").get("messages") or []
    last = next((str(m.get("content")) for m in reversed(messages) if m.get("role") == "assistant" and m.get("content")), "")
    report(bool(tried) and "api" not in code(), "woken over the API, Sol's command is refused: no one there to ask, nothing goes in",
           f"asked {len(tried)} time(s); last reply {last[:80]!r}")

    print(f"  info  the hook saw {len(hook_log())} tool calls, asked about {sum(1 for e in hook_log() if e.get('asked'))}")
    await dash.ws.close()
    if check.failures:
        raise SystemExit(1)


if __name__ == "__main__":
    asyncio.run(main())

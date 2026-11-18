"""Ask Me First for Hermes's own hand-offs (lab.sh asks, plugin 1.32.0): with the plugin in, a bot's
`message_agent` is held for the person as an approval ("<message_agent> (plugin approval rule)",
described "Ask @scout: …", which Redde draws as its Ask card); denied, nothing is delivered;
allowed, it is; and with the app's `asks off`, it goes without asking.

Mirrors asks.py in the plugin and AgentAsks.hermesAsk in the app. Run against a lab that is up
with the push scenario (the plugin from this repository).
"""
import asyncio
import json
import time

import check
from check import Dashboard, report
from bots_check import lookup

ASKED = "Ask @scout: Which trailhead for Lost Lake?"


class Asker(Dashboard):
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

    async def approval(self, seconds=60):
        """The next approval Hermes asks, as a request or (older releases) an event; or None."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                request = await asyncio.wait_for(self.requests.get(), 1)
                if request.get("method") in ("approval", "approval.request"):
                    return request
            except asyncio.TimeoutError:
                pass
        return None

    async def done(self, sid, seconds=120):
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                event = await asyncio.wait_for(self.events.get(), 2)
            except asyncio.TimeoutError:
                continue
            if event.get("session_id") == sid and event.get("type") == "message.complete":
                return str((event.get("payload") or {}).get("text") or "")
        return None


async def delivered(dash, seconds):
    """Scout's Bot Chat came to be (a delivery makes it) within `seconds`."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        if await lookup(dash, "scout") is not None:
            return True
        await asyncio.sleep(1)
    return False


async def say(dash, words):
    return (await dash.call("command.dispatch", {"name": "redde-push", "arg": words})).get("output", "")


async def main():
    dash = await Asker.connect()
    await dash.call("client.capabilities", {"server_requests": True})
    for name in ("scout", "writer"):
        await dash.call("profiles.create", {"name": name, "clone_from": "default", "no_alias": True})
    await dash.call("profiles.configure", {"name": "default", "ui_meta": {"hermes-bots": {"title": "Hermes"}}})
    made = await dash.call("session.create", {"profile": "writer", "title": "Bot Chat", "hidden": True, "follow_profile_config": True,
                                              "source": "desktop", "close_on_disconnect": False})
    sid = made.get("session_id")
    await dash.call("session.title", {"session_id": sid, "title": "Bot Chat"})
    report((await say(dash, "asks")).strip() == "redde-push asks on", "Ask Me First is on until the app says otherwise")

    # Asked first: the card's words, then "deny".
    await dash.call("prompt.submit", {"session_id": sid, "text": "lab:dm:scout"})
    request = await dash.approval()
    params = (request or {}).get("params") or {}
    report(request is not None and str(params.get("command", "")).startswith("<message_agent>")
           and params.get("description") == ASKED, "a hand-off waits for the person, said as what it asks", json.dumps(params)[:300])
    if request:
        await dash.answer(request, "deny")
    reply = await dash.done(sid)
    report(reply is not None and not await delivered(dash, 15), "denied, nothing is delivered and the turn ends", str(reply)[:160])

    # Allowed this once: delivered.
    await dash.call("prompt.submit", {"session_id": sid, "text": "lab:dm:scout again"})
    request = await dash.approval()
    if request:
        await dash.answer(request, "once")
    await dash.done(sid)
    report(request is not None and await delivered(dash, 60), "allowed, it is delivered")

    # The app's switch off: no question.
    report((await say(dash, "asks off")).strip() == "redde-push asks off", "the app turns it off")
    await dash.call("prompt.submit", {"session_id": sid, "text": "lab:dm:scout once more"})
    request = await dash.approval(seconds=20)
    report(request is None, "off, a hand-off goes without asking", json.dumps(request)[:200] if request else "")
    await dash.done(sid)
    await say(dash, "asks on")
    await dash.ws.close()
    raise SystemExit(1 if check.failures else 0)


if __name__ == "__main__":
    asyncio.run(main())

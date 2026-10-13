"""Checks phone tools (companion/hermes-plugin/redde-push/device.py) inside a running lab Hermes:
the agent calls a tool of the phone's, a stand-in phone hears of it, asks the plugin what is
wanted over the Dashboard, and hands back an answer, which has to reach the model. Over both
connections: a turn over the Hermes API runs in the gateway's process and the phone's command
in the Dashboard's, so this is where the two have to find each other.
Run through `lab.sh device` (it needs the lab's Python, which has `websockets`).

usage: device_check.py
"""
import asyncio
import base64
import json
import os
import pathlib
import sys
import threading
import time
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
API, KEY = "http://127.0.0.1:18642", "labkey-labkey-labkey"
HITS = os.environ["LAB_HITS"]
failures = []


def report(ok, what, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {what}{'  ' + str(detail)[:300] if detail and not ok else ''}")
    if not ok:
        failures.append(what)


def b64(value):
    return base64.b64encode(json.dumps(value).encode()).decode()


def offered():
    """The phone tools the model was offered in the last request it got."""
    lines = [json.loads(line) for line in open(HITS) if line.strip()]
    return lines[-1].get("phone", []) if lines else []


class ApiTurn:
    """One turn over the Hermes API, read as the app reads it: the tools that start, and the reply."""

    def __init__(self, text):
        self.tools, self.reply, self.done = [], "", threading.Event()
        request = urllib.request.Request(f"{API}/api/sessions", method="POST", data=json.dumps({"title": f"device lab {time.time()}"}).encode(),
                                         headers={"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"})
        self.session = json.loads(urllib.request.urlopen(request, timeout=30).read())["session"]["id"]
        threading.Thread(target=self._run, args=(text,), daemon=True).start()

    def _run(self, text):
        request = urllib.request.Request(f"{API}/api/sessions/{self.session}/chat/stream", method="POST", data=json.dumps({"input": text}).encode(),
                                         headers={"Content-Type": "application/json", "Authorization": f"Bearer {KEY}", "Accept": "text/event-stream"})
        event = ""
        try:
            with urllib.request.urlopen(request, timeout=200) as stream:
                for raw in stream:
                    line = raw.decode().rstrip("\n")
                    if line.startswith("event:"):
                        event = line[6:].strip()
                    elif line.startswith("data:"):
                        try:
                            data = json.loads(line[5:])
                        except ValueError:
                            continue
                        if event == "tool.started":
                            self.tools.append(data.get("tool_name"))
                        elif event == "assistant.delta" and isinstance(data.get("delta"), str):
                            self.reply += data["delta"]
        except Exception as error:
            self.reply += f" <stream ended: {error}>"
        self.done.set()


async def main():
    from check import Dashboard
    print("Phone tools (companion/hermes-plugin/redde-push/device.py)")
    dash = await Dashboard.connect()
    try:
        await dash.call("client.capabilities", {"server_requests": True})
    except RuntimeError:
        pass

    async def say(arg):
        return (await dash.call("command.dispatch", {"name": "redde-push", "arg": arg})).get("output", "")

    async def pending():
        reply = await say("device next")
        return json.loads(base64.b64decode(reply.split()[-1])) if reply.startswith("redde-push device next ") else None

    async def wait_for_request(session=None, seconds=20):
        """The request waiting for the phone: the one made in `session`, if the turn's session is known."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            found = [r for r in await pending() or [] if session is None or r.get("session") == session]
            if found:
                return found[0]
            await asyncio.sleep(0.3)
        return None

    async def dashboard_turn(text, seconds=60):
        """A turn over the Dashboard: the tools that start (as the app is told), and the reply."""
        made = await dash.call("session.create", {"source": "desktop", "close_on_disconnect": False})
        sid = made["session_id"]
        while not dash.events.empty():
            dash.events.get_nowait()
        await dash.call("prompt.submit", {"session_id": sid, "text": text})
        return sid

    async def read_turn(sid, seconds=60):
        tools, reply, deadline = [], "", time.time() + seconds
        while time.time() < deadline:
            try:
                event = await asyncio.wait_for(dash.events.get(), 1)
            except asyncio.TimeoutError:
                continue
            if event.get("session_id") != sid:
                continue
            kind, payload = event.get("type"), event.get("payload") or {}
            if kind == "tool.start":
                tools.append(payload.get("name"))
            elif kind == "message.delta":
                reply += payload.get("text") or ""
            elif kind == "message.complete":
                return tools, payload.get("text") or reply
            elif kind == "error":
                return tools, f"<error: {payload.get('message')}>"
        return tools, reply + " <timed out>"

    # ---- off, which is how it starts
    report(await say("device status") == "redde-push device status none", "nothing is on until the phone says so", await say("device status"))
    turn = ApiTurn("lab:reminder please")
    await asyncio.to_thread(turn.done.wait, 60)
    report(await pending() == [] and "[phone: added]" not in turn.reply and "phone_reminders_add" not in offered(),
           "Hermes API: with everything off the agent is offered no phone tool and nothing waits for the phone",
           (turn.reply, offered(), await pending()))

    # ---- on, for some
    report(await say("device areas reminders,photos") == "redde-push device areas reminders,photos", "the phone turns two areas on")
    await asyncio.sleep(5)   # each Hermes process hears of it within a couple of seconds
    turn = ApiTurn("hi")
    await asyncio.to_thread(turn.done.wait, 60)
    names = offered()
    tool_search = not names   # (from 0.21.3 most tools are found by the model, not offered outright)
    report(tool_search or (set(names) == {"phone_info", "phone_reminders_list", "phone_reminders_add", "phone_reminders_complete",
                                          "phone_photos_search", "phone_photos_get", "phone_photos_delete"}),
           "Hermes API: the agent is offered the tools of those areas and no others" + (" (they are found through tool search here)" if tool_search else ""), names)

    # ---- a call over the Hermes API: the turn is the gateway's, the phone's command the Dashboard's
    turn = ApiTurn("lab:reminder please")
    request = await wait_for_request(turn.session)
    report(bool(request) and request["tool"] == "phone_reminders_add" and request["args"].get("title") == "Renew the car registration",
           "Hermes API: the call waits where the phone finds it, with its arguments", request)
    if request:
        report("phone_reminders_add" in turn.tools or "tool_call" in turn.tools,
               "Hermes API: the app is told a tool has started" + ("" if "phone_reminders_add" in turn.tools else f" (as {turn.tools})"), turn.tools)
        answered = await say(f"device done {request['id']} {b64({'ok': True, 'result': {'added': {'title': 'Renew the car registration'}}})}")
        report(answered == "redde-push device done", "Hermes API: the phone's answer is taken", answered)
        await asyncio.to_thread(turn.done.wait, 60)
        report("[phone: added]" in turn.reply, "Hermes API: and it reaches the model", turn.reply)
    api_named = "phone_reminders_add" in turn.tools

    # ---- the same over the Dashboard
    sid = await dashboard_turn("lab:reminder please")
    reading = asyncio.create_task(read_turn(sid))
    request = await wait_for_request()
    report(bool(request) and request["tool"] == "phone_reminders_add", "Dashboard: the call waits where the phone finds it", request)
    if request:
        await say(f"device done {request['id']} {b64({'ok': False, 'error': 'The person said no on the iPhone.'})}")
    tools, reply = await reading
    report("phone_reminders_add" in tools or "tool_call" in tools,
           "Dashboard: the app is told a tool has started" + ("" if "phone_reminders_add" in tools else f" (as {tools})"), tools)
    report("[phone: no]" in reply, "Dashboard: a no from the phone reaches the model as one", reply)
    print(f"  note  the tool's own name shows when it starts: Hermes API {'yes' if api_named else 'NO'}, Dashboard {'yes' if 'phone_reminders_add' in tools else 'NO'}")

    # ---- a photo: half a megabyte through the command, and a file on this machine at the end of it
    sid = await dashboard_turn("lab:photo please")
    reading = asyncio.create_task(read_turn(sid))
    request = await wait_for_request()
    picture = os.urandom(450_000)
    if request:
        answer = {"ok": True, "result": {"kind": "photo", "file": {"name": "photo-ABC.jpg", "base64": base64.b64encode(picture).decode()}}}
        try:
            answered = await say(f"device done {request['id']} {b64(answer)}")
        except Exception as error:
            answered = repr(error)
        report(answered == "redde-push device done", "a picture of 450 KB goes through the phone's command", answered[:200])
    tools, reply = await reading
    saved = [path for path in pathlib.Path(os.environ["HERMES_HOME"]).glob("redde-push/device/files/*") if path.read_bytes() == picture]
    report("[phone: file]" in reply and len(saved) == 1, "the picture is kept on the server and the model is given its path", (reply, len(saved)))

    # ---- off again
    report(await say("device areas none") == "redde-push device areas none", "the phone turns everything off again")
    await asyncio.sleep(5)
    turn = ApiTurn("lab:reminder please")
    await asyncio.to_thread(turn.done.wait, 60)
    report(await pending() == [] and "[phone: added]" not in turn.reply, "and nothing is asked of it any more", (turn.reply, await pending()))
    left = [str(p) for kind in ("requests", "answers") for p in pathlib.Path(os.environ["HERMES_HOME"]).glob(f"redde-push/device/{kind}/*")]
    report(not left, "no request or answer is left lying in the Hermes home", left)
    await dash.ws.close()


asyncio.run(main())
sys.exit(1 if failures else 0)

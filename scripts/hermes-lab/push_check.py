"""Checks the Redde push plugin (companion/hermes-plugin/redde-push) inside a running lab Hermes:
pairs a stand-in phone through the lab's relay, then makes the agent reply and ask for an
approval over both connections and reads the notes that reach "Apple", as the phone would.
Run through `lab.sh push` (it needs the lab's Python, which has `websockets` and `cryptography`).

usage: push_check.py <hermes executable>
"""
import asyncio
import base64
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.request

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

HERE = pathlib.Path(__file__).resolve().parent
PLUGIN = HERE.parent.parent / "companion" / "hermes-plugin" / "redde-push"
spec = importlib.util.spec_from_file_location("redde_push_core", PLUGIN / "core.py")
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)
sys.path.insert(0, str(HERE))

HERMES = sys.argv[1]
RELAY = "http://127.0.0.1:18980"
API, KEY, SERVE = "http://127.0.0.1:18642", "labkey-labkey-labkey", "127.0.0.1:19119"
APNS = os.environ["LAB_APNS"]
failures = []


def report(ok, what, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {what}{'  ' + str(detail)[:200] if detail and not ok else ''}")
    if not ok:
        failures.append(what)


def http(method, url, body=None, headers=None):
    request = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(request, timeout=120) as response:
        text = response.read().decode()
        return json.loads(text) if text.startswith("{") else text


class Phone:
    """What Redde does: registers with the relay, answers a pairing link, opens what arrives."""

    def __init__(self):
        self.send = secrets.token_urlsafe(32)
        self.token = secrets.token_hex(32)
        made = http("POST", f"{RELAY}/v1/devices", {"token": self.token, "env": "dev", "auth": hashlib.sha256(self.send.encode()).hexdigest()})
        self.id = made["id"]
        self.key = None

    def answer(self, link):
        offered = core.unb64u(re.search(r"#push=([A-Za-z0-9_-]+)", link).group(1))
        private = X25519PrivateKey.generate()
        public = private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.key, box_key = core.derive(private.exchange(X25519PublicKey.from_public_bytes(offered)), offered, public)
        inside = json.dumps({"id": self.id, "send": self.send, "name": "Lab phone"}).encode()
        http("PUT", f"{RELAY}/v1/pairings/{core.rendezvous(offered)}",
             {"pub": core.b64u(public), "box": core.b64u(core.seal(box_key, inside, b"redde-push pairing"))},
             {"Authorization": f"Bearer {self.send}", "X-Redde-Device": self.id})

    def notes(self):
        """Every note that has reached Apple for this phone, opened."""
        opened = []
        for line in open(APNS):
            record = json.loads(line)
            if record["token"] != self.token:
                continue
            blob = base64.b64decode(record["body"]["e"])
            opened.append(json.loads(core.unseal(self.key, blob[4:], self.id.encode())))
        return opened

    def wait_for(self, kind, session=None, seconds=30):
        deadline = time.time() + seconds
        while time.time() < deadline:
            for made in self.notes():
                if made["k"] == kind and (session is None or made.get("s") == session):
                    return made
            time.sleep(0.5)
        return None


def hermes(*args, timeout=90):
    return subprocess.run([HERMES, "redde-push", *args], capture_output=True, text=True, timeout=timeout).stdout


def pair(phone):
    process = subprocess.Popen([HERMES, "redde-push", "pair", "--relay", RELAY, "--wait", "60"], stdout=subprocess.PIPE, text=True)
    output = ""
    for line in process.stdout:
        output += line
        if "#push=" in line:
            phone.answer(line.strip())
    process.wait(timeout=90)
    return output


def api_turn(text):
    session = http("POST", f"{API}/api/sessions", {"title": f"push lab {time.time()}"}, {"Authorization": f"Bearer {KEY}"})["session"]["id"]
    threading.Thread(target=lambda: http("POST", f"{API}/api/sessions/{session}/chat/stream", {"input": text}, {"Authorization": f"Bearer {KEY}"}),
                     daemon=True).start()
    return session


async def dashboard(phone):
    from check import Dashboard
    dash = await Dashboard.connect()
    create = {"source": "desktop", "close_on_disconnect": False}

    async def turn(text):
        made = await dash.call("session.create", create)
        return made["session_id"], made.get("stored_session_id") or made["session_id"]

    async def say(runtime, text):
        await dash.call("prompt.submit", {"session_id": runtime, "text": text})

    runtime, stored = await turn("hi")
    await say(runtime, "hi")
    await asyncio.sleep(4)
    report(not any(n.get("s") == stored for n in phone.notes()), "Dashboard: a conversation the phone hasn't joined stays quiet")

    runtime, stored = await turn("hi")
    watching = await dash.call("slash.exec", {"session_id": runtime, "command": f"redde-push watch {stored} {phone.id}"})
    report("watching 1" in json.dumps(watching), "Dashboard: the app's follow command reaches the plugin", watching)
    await say(runtime, "hi")
    made = await asyncio.to_thread(phone.wait_for, "reply", stored)
    report(bool(made) and made["b"] == "[A:alpha]", "Dashboard: a followed conversation's reply reaches the phone", made)

    runtime, stored = await turn("danger")
    await dash.call("slash.exec", {"session_id": runtime, "command": f"redde-push watch {stored} {phone.id}"})
    await say(runtime, "Do the danger thing.")
    made = await asyncio.to_thread(phone.wait_for, "approval", stored)
    report(bool(made) and "rm -rf" in made.get("b", "") and bool(made.get("d")), "Dashboard: an approval the agent waits on reaches the phone", made)
    await dash.ws.close()


def main():
    print("Push plugin (companion/hermes-plugin/redde-push)")
    phone = Phone()
    output = pair(phone)
    report("Paired with Lab phone" in output, "a phone pairs through the relay with `hermes redde-push pair`", output[-300:])
    made = phone.wait_for("paired", seconds=10)
    report(bool(made) and bool(made.get("n")), "the phone is told it is paired, in a note only it can read", made)
    report("Lab phone" in hermes("list"), "`hermes redde-push list` shows it")

    session = api_turn("hi")
    made = phone.wait_for("reply", session)
    report(bool(made) and made["b"] == "[A:alpha]" and made.get("t", "").startswith("push lab"), "Hermes API: a reply reaches the phone, with the conversation's title", made)
    # No approval over the Hermes API: there a guarded command isn't held for a person, the agent
    # is told it needs approval and says so in its reply, which is the note above.

    try:
        asyncio.run(dashboard(phone))
    except Exception as error:
        report(False, "Dashboard checks could not run", repr(error))

    records = [json.loads(line) for line in open(APNS)]
    plain = json.dumps(records)
    report(all(set(r["body"]) == {"aps", "e"} and r["body"]["aps"]["alert"]["body"] == "Open Redde to see what's new." for r in records)
           and "alpha" not in plain and "rm -rf" not in plain and "push lab" not in plain, "what Apple and the relay carry is sealed: no reply, command or title in it")

    said = hermes("test")
    report(bool(phone.wait_for("test", seconds=10)), "`hermes redde-push test` sends a test note", said)
    hermes("remove", "Lab phone")
    time.sleep(3)                      # what was already on its way lands
    before = len(phone.notes())
    api_turn("hi")
    time.sleep(4)
    report(len(phone.notes()) == before and "No phone is paired" in hermes("list"), "a removed phone hears nothing more")
    sys.exit(1 if failures else 0)


main()

"""Checks the Redde push plugin (companion/hermes-plugin/redde-push) inside a running lab Hermes:
pairs a stand-in phone through the lab's relay, then makes the agent reply, stop for an approval,
ask a question, want a sudo password and a secret, hand off a task, and fail, over both
connections where they apply, and reads the notes that reach "Apple", as the phone would.
Run through `lab.sh push` (it needs the lab's Python, which has `websockets` and `cryptography`).

A turn that fails after Hermes has retried it is announced two and a half minutes after its last
attempt, which on Hermes 0.21.5 comes five minutes in. That check is left out unless
LAB_PUSH_SLOW=1.

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
SLOW = os.environ.get("LAB_PUSH_SLOW") == "1"
failures = []
#: Conversations whose turn failed once or twice and then got its reply: (session, when). None of
#: them may have been called a failure by the end.
recovered = []


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

    def answer_directly(self, offered_text, name="Lab phone"):
        """This phone's half of the key agreement, for an offer: its public key and its box."""
        offered = core.unb64u(offered_text)
        private = X25519PrivateKey.generate()
        public = private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.key, box_key = core.derive(private.exchange(X25519PublicKey.from_public_bytes(offered)), offered, public)
        inside = json.dumps({"id": self.id, "send": self.send, "name": name}).encode()
        self.pub, self.box = core.b64u(public), core.b64u(core.seal(box_key, inside, b"redde-push pairing"))
        return offered

    def answer(self, link):
        offered = self.answer_directly(re.search(r"#push=([A-Za-z0-9_-]+)", link).group(1))
        http("PUT", f"{RELAY}/v1/pairings/{core.rendezvous(offered)}", {"pub": self.pub, "box": self.box},
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


def store_ids():
    """The ids of the phones the plugin has, as `hermes redde-push list` shows them."""
    return [line.split()[-3] for line in hermes("list").splitlines() if " paired " in line]


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

    def run():
        try:
            http("POST", f"{API}/api/sessions/{session}/chat/stream", {"input": text}, {"Authorization": f"Bearer {KEY}"})
        except Exception:
            pass    # a turn that is meant to fail may end the stream any way it likes

    threading.Thread(target=run, daemon=True).start()
    return session


def notes_of(phone, session):
    return [(made["k"], made.get("b")) for made in phone.notes() if made.get("s") == session]


async def dashboard(phone):
    from check import Dashboard
    dash = await Dashboard.connect()
    try:   # as the app does; without it Hermes 0.21.5 withdraws an approval the moment it is asked
        await dash.call("client.capabilities", {"server_requests": True})
    except RuntimeError:
        pass   # an older Hermes doesn't know the method, and needs no telling
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
    # Approve and Deny on the notification answer by session and by the command's digest: the note's
    # has to be of the command the Dashboard tells a client is waiting.
    waiting = (await dash.call("session.resume", {"session_id": stored, "omit_messages": True})).get("pending_approval") or {}
    report(bool(made) and made.get("h") == core.digest(waiting.get("command", "")) != core.digest(""),
           "Dashboard: the note names the waiting command by its digest", f"note {made and made.get('h')} for {waiting.get('command')!r}")

    async def followed(text):
        """A turn in a conversation the phone follows."""
        runtime, stored = await turn(text)
        await dash.call("slash.exec", {"session_id": runtime, "command": f"redde-push watch {stored} {phone.id}"})
        await say(runtime, text)
        return runtime, stored

    async def waiting_on(stored):
        """What the Dashboard says the session waits on a person for, as it tells a client that
        opens the conversation. None from a Hermes that keeps no such list (0.21.0)."""
        listed = (await dash.call("session.resume", {"session_id": stored, "omit_messages": True})).get("open_requests")
        return [request.get("method") for request in listed] if isinstance(listed, list) else None

    # A turn that fails twice and then gets its reply is a reply, and never "couldn't reply".
    runtime, stored = await followed("lab:hiccup please")
    made = await asyncio.to_thread(phone.wait_for, "reply", stored, 60)
    report(bool(made) and made["b"] == "[A:alpha]", "Dashboard: a turn Hermes had to retry still ends in its reply", made)
    recovered.append((stored, time.time()))

    # The agent asks the person something.
    runtime, stored = await followed("lab:question please")
    made = await asyncio.to_thread(phone.wait_for, "question", stored)
    report(bool(made) and made.get("b") == "Which branch should I deploy?" and made.get("d") == "main · release" and "h" not in made,
           "Dashboard: a question the agent asks reaches the phone, with its choices", made)
    waiting = await waiting_on(stored)
    lists = waiting is not None
    if lists:
        report(waiting == ["clarify"], "Dashboard: and waits to be answered by whoever opens the conversation", waiting)
    else:
        print("  ----  this Hermes keeps no list of what it waits on (0.21.0): no card on opening, and sudo and secret go unannounced")
    await dash.call("session.interrupt", {"session_id": runtime})

    # A command wants the sudo password. (Not where sudo asks for none: then there is no prompt.)
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0:
        print("  ----  sudo needs no password here: nothing to check")
    else:
        runtime, stored = await followed("lab:sudo please")
        made = await asyncio.to_thread(phone.wait_for, "sudo", stored, 15)
        if lists:
            report(bool(made) and made.get("b", "sudo true") == "sudo true", "Dashboard: a command waiting for the sudo password reaches the phone", made)
            report(await waiting_on(stored) == ["sudo"], "Dashboard: and waits for whoever opens the conversation")
        else:
            report(made is None, "Dashboard: no sudo note from a Hermes that can't say one is waiting", made)
        await dash.call("session.interrupt", {"session_id": runtime})

    # A skill wants a secret.
    runtime, stored = await followed("lab:secret please")
    made = await asyncio.to_thread(phone.wait_for, "secret", stored, 15)
    if lists:
        report(bool(made) and made.get("b") == "Enter the lab token" and made.get("d") == "LAB_SECRET_TOKEN", "Dashboard: a skill waiting for a secret reaches the phone", made)
        report(await waiting_on(stored) == ["secret"], "Dashboard: and waits for whoever opens the conversation")
    else:
        report(made is None, "Dashboard: no secret note from a Hermes that can't say one is waiting", made)
    await dash.call("session.interrupt", {"session_id": runtime})

    # A task handed to a subagent: when it comes back Hermes starts a turn to say so, and that
    # turn's reply is the news.
    runtime, stored = await followed("lab:delegate please")
    made = await asyncio.to_thread(phone.wait_for, "task", stored, 45)
    report(bool(made) and made.get("b") == "[A:alpha]" and ("reply", "[kept]") in notes_of(phone, stored),
           "Dashboard: a handed-off task coming back reaches the phone as that", notes_of(phone, stored))

    # A request the provider refuses: Hermes doesn't retry, the turn ends, and no hook says so.
    runtime, stored = await followed("lab:refused please")
    made = await asyncio.to_thread(phone.wait_for, "failed", stored, 40)
    report(bool(made) and made.get("b") == "HTTP 401: Incorrect API key provided.", "Dashboard: a turn that ends without a reply says why", made)

    # Pairing with no code, as an app signed in to this Dashboard does it: the plugin's offer and
    # the phone's answer cross on this connection, and no session is needed for it.
    tapped = Phone()
    offer = (await dash.call("command.dispatch", {"name": "redde-push", "arg": "offer"})).get("output", "")
    words = offer.split()
    report(words[:2] == ["redde-push", "offer"] and words[3:] == [RELAY], "Dashboard: the plugin makes an app its offer, and says which relay it uses", offer)
    tapped.answer_directly(words[2])
    accepted = (await dash.call("command.dispatch", {"name": "redde-push", "arg": f"accept {words[2]} {tapped.pub} {tapped.box}"})).get("output", "")
    made = await asyncio.to_thread(tapped.wait_for, "paired", None, 15)
    report(accepted.startswith("redde-push paired ") and bool(made), "Dashboard: an app pairs in one step, and its first note arrives", f"{accepted!r} {made}")
    again = (await dash.call("command.dispatch", {"name": "redde-push", "arg": f"accept {words[2]} {tapped.pub} {tapped.box}"})).get("output", "")
    report(again.startswith("redde-push refused"), "Dashboard: an offer is answered once", again)
    await dash.ws.close()


def scan():
    """Hermes scans a plugin before installing it, and refuses one from GitHub that it finds
    anything in: an address written as numbers, a path that climbs out of the folder."""
    try:
        from tools.skills_guard import scan_skill
    except Exception as error:
        return f"no scanner in this Hermes ({error})", []
    result = scan_skill(PLUGIN, source="community")
    return result.verdict, [f"{f.category} {f.file}:{f.line}" for f in result.findings]


def main():
    print("Push plugin (companion/hermes-plugin/redde-push)")
    verdict, findings = scan()
    report(not findings, "Hermes's install scan finds nothing in the plugin", f"{verdict}: {findings}")
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

    session = api_turn("lab:refused please")
    made = phone.wait_for("failed", session, 40)
    report(bool(made) and made.get("b") == "HTTP 401: Incorrect API key provided." and made.get("t", "").startswith("push lab"),
           "Hermes API: a turn that ends without a reply says why", made)
    # A handed-off task: on 0.21.0 Hermes starts a turn when it comes back, as on the Dashboard;
    # later releases start none over the Hermes API, and the task's own summary is sent.
    session = api_turn("lab:delegate please")
    made = phone.wait_for("task", session, 60)
    report(bool(made) and made.get("b") == "[A:alpha]", "Hermes API: a handed-off task coming back reaches the phone", notes_of(phone, session))
    if SLOW:
        session = api_turn("lab:outage please")
        made = phone.wait_for("failed", session, 600)
        report(bool(made) and made.get("b", "").startswith("HTTP 500: "), "Hermes API: a turn Hermes gives up on after retrying says why", made)
        report(len([k for k, _ in notes_of(phone, session) if k == "failed"]) == 1, "Hermes API: and says it once, when Hermes has stopped trying", notes_of(phone, session))

    try:
        asyncio.run(dashboard(phone))
    except Exception as error:
        report(False, "Dashboard checks could not run", repr(error))

    records = [json.loads(line) for line in open(APNS)]
    plain = json.dumps(records)
    report(all(set(r["body"]) == {"aps", "e"} and r["body"]["aps"]["alert"]["body"] == "Open Redde to see what's new." for r in records)
           and not any(word in plain for word in ("alpha", "rm -rf", "push lab", "Which branch", "lab token", "API key")),
           "what Apple and the relay carry is sealed: no reply, command, question, error or title in it")
    for session, since in recovered:
        if SLOW:    # long enough for the longest wait to have run out
            time.sleep(max(0, since + core.Turns.RETRYING + 10 - time.time()))
        report(not any(kind == "failed" for kind, _ in notes_of(phone, session)),
               f"the turn that recovered was never called a failure ({time.time() - since:.0f} s on)", notes_of(phone, session))

    said = hermes("test")
    report(bool(phone.wait_for("test", seconds=10)), "`hermes redde-push test` sends a test note", said)
    for device in store_ids():         # the one paired by code and the one paired over the Dashboard
        hermes("remove", device)
    time.sleep(3)                      # what was already on its way lands
    before = len(phone.notes())
    api_turn("hi")
    time.sleep(4)
    report(len(phone.notes()) == before and "No phone is paired" in hermes("list"), "a removed phone hears nothing more")
    sys.exit(1 if failures else 0)


main()

"""Calls from the agent (companion/hermes-plugin/redde-push/calls.py) inside a running lab Hermes,
through `lab.sh calls`:

  no voip   a phone registered without a call address is let be called by the main agent; its
            call is refused by the relay ("not ready"), the phone stays paired, the call isn't
            counted against the limit.
  off       a stand-in phone, registered with the relay with an address for calls as Redde
            registers once calls are on, pairs; nobody may call it yet, and a bot's call_user
            rings nothing.
  allowed   the phone lets the bot call (`/redde-push calls <phone> <bot>` over the Dashboard);
            in the bot's chat, reopened (Hermes keeps the tools a chat started with), the model
            calls call_user, and the relay hands "Apple" a VoIP push on the `.voip` topic, to the
            call address, holding the call sealed: the bot's profile and name, the line, the
            conversation. Before 0.22 a bot's Dashboard chat runs in the main home, so there the
            main agent is the one let call.
  limits    a second call within five minutes is refused and rings nothing.
  others    the main agent, not let, can't ring the phone (0.22 and later).

usage: calls_check.py <hermes executable>   (a lab up with the push scenario)
"""
import asyncio
import hashlib
import json
import secrets
import time

import check
from check import Dashboard, report
from bots_check import lookup, turn
from push_check import APNS, RELAY, Phone, http, pair

BOT = "scout"


def release():
    """This Hermes's version, (0, 21, 5); a build from source that says 0.0.0 counts as the newest.
    (As routines_check.py has it: that file runs its check when imported.)"""
    import hermes_cli
    parts = tuple(int(p) for p in str(getattr(hermes_cli, "__version__", "0.0.0")).split(".")[:3] if p.isdigit())
    return (99, 0, 0) if parts in ((), (0, 0, 0)) else parts


class CallingPhone(Phone):
    """A phone that has turned calls on: it gives the relay its PushKit address too."""

    def __init__(self, voip=True):
        self.send = secrets.token_urlsafe(32)
        self.token = secrets.token_hex(32)
        self.voip = secrets.token_hex(32) if voip else None
        body = {"token": self.token, "env": "dev", "auth": hashlib.sha256(self.send.encode()).hexdigest()}
        if self.voip:
            body["voip"] = self.voip
        self.id = http("POST", f"{RELAY}/v1/devices", body)["id"]
        self.key = None

    def calls(self):
        """Every call that has reached Apple for this phone: (what Apple was told, the note)."""
        found = []
        for line in open(APNS):
            record = json.loads(line)
            if record["token"] != self.voip:
                continue
            import base64
            from push_check import core
            blob = base64.b64decode(record["body"]["e"])
            found.append((record, json.loads(core.unseal(self.key, blob[4:], self.id.encode()))))
        return found

    def wait_for_call(self, count, seconds=30):
        deadline = time.time() + seconds
        while time.time() < deadline:
            made = self.calls()
            if len(made) >= count:
                return made
            time.sleep(0.5)
        return self.calls()


async def tool_said(dash, session, profile=None):
    """What the last tool in a conversation answered, for a check that fails."""
    params = {"session_id": session, "omit_messages": False}
    if profile:
        params["profile"] = profile
    try:
        messages = (await dash.call("session.resume", params)).get("messages") or []
    except Exception as error:
        return f"<{error}>"
    return json.dumps(messages[-4:])[:1500]


async def main():
    dash = await Dashboard.connect()

    async def say(arg):
        return (await dash.call("command.dispatch", {"name": "redde-push", "arg": arg})).get("output", "")

    phone = CallingPhone()
    pair(phone)
    report(phone.wait_for("paired") is not None, "a stand-in phone with an address for calls pairs")

    await dash.call("profiles.create", {"name": BOT, "clone_from": "default", "no_alias": True, "share_auth": True})
    await dash.call("profiles.configure", {"name": BOT, "ui_meta": {"hermes-bots": {"title": "Scout"}}})
    made = await dash.call("session.create", {"profile": BOT, "title": "Bot Chat", "hidden": True, "follow_profile_config": True,
                                              "source": "desktop", "close_on_disconnect": False})
    chat = made.get("session_id")
    await dash.call("session.title", {"session_id": chat, "title": "Bot Chat"})
    stored = (await lookup(dash, BOT) or {}).get("id") or made.get("stored_session_id") or chat

    # ---- a phone with no address for calls: refused by the relay, still paired, the call not counted
    plain = CallingPhone(voip=False)
    pair(plain)
    report(plain.wait_for("paired") is not None, "a phone without an address for calls pairs")
    report(await say(f"calls {plain.id} default") == "redde-push calls 1", "and lets the main agent call it")
    await asyncio.sleep(5)
    main = await dash.call("session.create", {"source": "desktop", "close_on_disconnect": False})   # (with the tools as they are now)
    reply = await turn(dash, main["session_id"], "lab:call please")
    listed = await say("status")
    report("[call: not ready]" in reply and listed == "redde-push status 2",
           "its call is refused by the relay and the phone stays paired", f"{reply} / {listed}")
    report(await say(f"calls {plain.id} none") == "redde-push calls 1", "and lets nobody call it again")

    # ---- off: nobody may call
    reply = await turn(dash, chat, "lab:call please")
    report("[call: ringing]" not in reply and phone.calls() == [], "with calls off the bot's call rings nothing", reply)

    # ---- allowed
    report(await say(f"calls {phone.id} {BOT}") == "redde-push calls 1", "the phone lets the bot call it")
    await asyncio.sleep(5)   # each process hears of it within a couple of seconds
    reply = await turn(dash, chat, "lab:call please")
    print(f"  info  in the chat open since before: {'rang' if '[call: ringing]' in reply else 'not offered'}")
    # Hermes keeps the tools a conversation started with: the app reopens the bot's chat.
    await dash.call("session.close", {"session_id": chat})
    resumed = await dash.call("session.resume", {"session_id": stored, "profile": BOT})
    print(f"  info  resumed: {json.dumps({k: v for k, v in resumed.items() if k != 'messages'})[:300]}")
    chat = resumed.get("session_id") or chat
    caller, name = BOT, "Scout"
    if release() < (0, 22, 0):
        # Before 0.22 the Dashboard runs a bot's chat in the main profile's home, so the plugin
        # takes the call for the main agent's: here the main agent is the one let call.
        print("  info  before 0.22 a bot's Dashboard chat runs in the main home: the main agent calls instead")
        caller, name = "default", "Hermes"
        await say(f"calls {phone.id} default")
        await asyncio.sleep(5)
        chat = (await dash.call("session.create", {"source": "desktop", "close_on_disconnect": False}))["session_id"]
        stored = chat
    if "[call: ringing]" not in reply:
        reply = await turn(dash, chat, "lab:call me please")
    report("[call: ringing]" in reply, f"{'the bot' if caller == BOT else 'the main agent'} calls from its chat, reopened, "
           "and is told the phone is ringing", reply)
    hits = [json.loads(line) for line in open(check.HITS) if line.strip()]
    report(any(h.get("call_note") for h in hits), "a message asking to be called tells the agent how to (call_user behind tool search)")
    if "[call: ringing]" not in reply:
        print(f"  info  the tool answered: {[h.get('tool_said') for h in map(json.loads, open(check.HITS)) if h.get('tool_said')]}")
    made = phone.wait_for_call(1)
    record, note = made[0] if made else ({}, {})
    report(record.get("type") == "voip" and record.get("topic") == "com.goosehouse.echo.voip",
           "the relay hands Apple a VoIP push on the .voip topic, to the call address",
           json.dumps({k: record.get(k) for k in ("type", "topic", "collapse")}))
    if note.get("s") not in (stored, chat):
        print(f"  info  the conversation it called from: {note.get('s')} (chat {chat}, stored {stored})")
    report(note.get("k") == "call" and note.get("p") == caller and note.get("d") == name
           and note.get("b") == "Lab call: the garage door is open." and bool(note.get("s")) and len(note.get("i", "")) == 16,
           "the call is sealed to the phone: the bot, its name, its line, its conversation", json.dumps(note))
    report(not any(n.get("k") == "call" for n in phone.notes()), "and nothing went as a notification")

    # ---- limits
    reply = await turn(dash, chat, "lab:call again")
    report("[call: not now]" in reply and len(phone.wait_for_call(2, seconds=4)) == 1,
           "a second call within five minutes is refused and rings nothing", reply)

    # ---- others: the main agent isn't let (0.22 and later, where the bot is the one let)
    main = await dash.call("session.create", {"source": "desktop", "close_on_disconnect": False})
    if caller == BOT:
        reply = await turn(dash, main["session_id"], "lab:call please")
        report("[call: not let]" in reply and len(phone.calls()) == 1,
               "the main agent, not let, has the tool (calls are on here) and is told it may not call", reply)
    hits = [json.loads(line) for line in open(check.HITS) if line.strip()]
    print(f"  info  offered to the main agent outright: {any('call_user' in h.get('names', []) for h in hits)}; tool search: "
          f"{any(h.get('search') for h in hits)}")

asyncio.run(main())
raise SystemExit(1 if check.failures else 0)

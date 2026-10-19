"""What Hermes does for Bot Mode, as Redde's bots use it (lab.sh bots), over the Dashboard socket:

  roster       `profiles.list` lists every profile, the default first or flagged `is_default`, each
               with `canonical_session` (none before its first chat).
  bot chat     a profile's chat is its session titled exactly "Bot Chat": `session.list {profile,
               title, include_hidden}` finds none at first; `session.create {profile, title,
               hidden, follow_profile_config}` and an eager `session.title` make it; the lookup and
               the roster's `canonical_session` then name it, and a turn in it is answered.
  hidden       the Dashboard's list of the profile's conversations (`GET /api/sessions?profile=`)
               leaves it out.
  resume       `session.resume` with the profile finds it.
  bot mode     with no profile set up as a bot the chat has no `message_agent`; once one profile's
               `ui_meta` has a "hermes-bots" entry (`profiles.configure`), a turn in a Bot Chat
               carries the teammate protocol and the tool, and an ordinary conversation still
               doesn't.

Mirrors HermesServeClient's bot calls (Echo/Services/Transport/ServerBots.swift).
Run against a lab that is up with the approval scenario.
"""
import asyncio
import json
import time

import check
from check import HITS, Dashboard, report
from status_check import rest, rest_opener

BOT = "scout"


def hits():
    time.sleep(0.4)
    rows = [json.loads(line) for line in open(HITS) if line.strip()]
    return [r for r in rows if r["stream"]] or rows


async def turn(dash, runtime, text):
    """One prompt; the reply's text, or what went wrong."""
    while not dash.events.empty():
        dash.events.get_nowait()
    check.clear_hits()
    await dash.call("prompt.submit", {"session_id": runtime, "text": text})
    deadline = time.time() + 90
    while time.time() < deadline:
        try:
            event = await asyncio.wait_for(dash.events.get(), 2)
        except asyncio.TimeoutError:
            continue
        if event.get("session_id") != runtime:
            continue
        payload = event.get("payload") or {}
        if event.get("type") == "message.complete":
            return str(payload.get("text") or "")
        if event.get("type") == "error":
            return "error: " + str(payload.get("message"))[:120]
    return "timed out"


async def lookup(dash, profile):
    rows = (await dash.call("session.list", {"profile": profile, "title": "Bot Chat", "include_hidden": True, "limit": 200})).get("sessions") or []
    return next((r for r in rows if r.get("title") == "Bot Chat"), None)


async def main():
    dash = await Dashboard.connect()
    opener = rest_opener()

    await dash.call("profiles.create", {"name": BOT, "clone_from": "default", "no_alias": True})
    roster = (await dash.call("profiles.list", {})).get("profiles") or []
    names = [p.get("name") for p in roster]
    default = next((p for p in roster if p.get("is_default")), None)
    scout = next((p for p in roster if p.get("name") == BOT), {})
    report(BOT in names and default is not None and scout.get("canonical_session") is None,
           "roster: every profile, the default flagged, no chat yet", f"names {names}, scout {json.dumps(scout)[:200]}")

    report(await lookup(dash, BOT) is None, "no Bot Chat before the first")
    made = await dash.call("session.create", {"profile": BOT, "title": "Bot Chat", "hidden": True, "follow_profile_config": True,
                                              "source": "desktop", "close_on_disconnect": False})
    runtime, stored = made.get("session_id"), made.get("stored_session_id") or made.get("session_id")
    titled = ""
    try:
        await dash.call("session.title", {"session_id": runtime, "title": "Bot Chat"})
    except Exception as error:
        titled = str(error)[:160]
    print(f"  info  eager session.title: {'taken' if not titled else titled}")
    found = await lookup(dash, BOT)
    report(found is not None and found.get("id") == stored, "the eager title makes the Bot Chat findable before a turn",
           f"found {json.dumps(found)[:200]}, stored {stored}")

    reply = await turn(dash, runtime, "hello scout")
    report(reply.startswith("["), "a turn in the bot's chat is answered", reply)
    first = hits()[:1]
    report(bool(first) and not first[0].get("message_agent"), "no message_agent while no profile is a bot", json.dumps(first))

    found = await lookup(dash, BOT)
    report(found is not None and found.get("id") == stored, "the lookup finds the same chat after a turn", json.dumps(found)[:200])
    roster = (await dash.call("profiles.list", {})).get("profiles") or []
    scout = next((p for p in roster if p.get("name") == BOT), {})
    canonical = scout.get("canonical_session") or {}
    report(stored in (canonical.get("id"), canonical.get("resolved_id")), "the roster names it as the bot's chat",
           json.dumps(canonical)[:200])

    listed = [s.get("id") for s in rest(opener, "GET", f"/api/sessions?limit=100&offset=0&order=recent&profile={BOT}").get("sessions") or []]
    report(stored not in listed, "the profile's conversation list leaves it out", f"{len(listed)} listed")

    resumed = await dash.call("session.resume", {"session_id": stored, "profile": BOT, "omit_messages": False})
    texts = [m.get("text") or m.get("content") for m in resumed.get("messages") or []]
    report(any("hello scout" in json.dumps(t) for t in texts), "resumed with its profile, with its messages", json.dumps(texts)[:200])

    applied = await dash.call("profiles.configure", {"name": "default", "ui_meta": {"hermes-bots": {"title": "Hermes"}}})
    report((applied.get("applied") or {}).get("ui_meta") is True, "a profile set up as a bot", json.dumps(applied)[:200])
    # A new connection's resume builds the agent again, with the protocol now that one is a bot.
    fresh = await Dashboard.connect()
    again = await fresh.call("session.resume", {"session_id": stored, "profile": BOT, "omit_messages": True})
    reply = await turn(fresh, again.get("session_id"), "@hermes what do you think?")
    first = hits()[:1]
    report(bool(first) and first[0].get("message_agent"), "with a bot set up, a bot's chat made before has message_agent",
           f"{reply} {json.dumps(first)}")
    # Its system prompt was written before there were bots: Hermes keeps it, without the protocol.
    print(f"  info  and the teammate protocol in its prompt: {bool(first and first[0].get('bots'))}")
    await fresh.call("profiles.create", {"name": "writer", "clone_from": "default", "no_alias": True})
    made = await fresh.call("session.create", {"profile": "writer", "title": "Bot Chat", "hidden": True, "follow_profile_config": True,
                                               "source": "desktop", "close_on_disconnect": False})
    await fresh.call("session.title", {"session_id": made.get("session_id"), "title": "Bot Chat"})
    reply = await turn(fresh, made.get("session_id"), "hello writer")
    first = hits()[:1]
    report(bool(first) and first[0].get("bots") and first[0].get("message_agent"),
           "a bot's chat made after has the protocol and message_agent", f"{reply} {json.dumps(first)}")

    plain = await fresh.call("session.create", {"profile": BOT, "source": "desktop", "close_on_disconnect": False})
    await turn(fresh, plain.get("session_id"), "an ordinary conversation")
    first = hits()[:1]
    report(bool(first) and not first[0].get("bots") and not first[0].get("message_agent"),
           "an ordinary conversation on the same profile has neither", json.dumps(first))

    # Leave the lab as it was found: the next check starts with no bots.
    await fresh.call("profiles.configure", {"name": "default", "ui_meta": {"hermes-bots": None}})
    for d in (dash, fresh):
        await d.ws.close()
    raise SystemExit(1 if check.failures else 0)


if __name__ == "__main__":
    asyncio.run(main())

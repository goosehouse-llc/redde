"""Calls from the agent: it rings the person's iPhone the way a phone call rings, for something
that shouldn't wait until they next look.

How a call travels. The agent calls `call_user` with what it will say first. The plugin seals a
note for each paired phone that takes calls from this agent (kind "call": who is calling, that
opening line, the conversation it called from) and hands it to the relay as a call, which the
relay sends to Apple as a VoIP push, to the address the phone gave it for calls. iOS wakes Redde,
which shows the call with CallKit, on the Lock Screen too. Answered, it opens voice mode in that
agent's chat, the agent's opening line is spoken, and what the person says goes to the agent as
a new turn there. Not answered, it becomes a missed-call notification with the line. The tool
returns once Apple has the call: it doesn't wait to hear whether it was answered.

Who may call is the phone's to say, agent by agent (`/redde-push calls <device,...>
<profile,...>`, or `none`; the main agent is "default"). It is kept with the paired phones, in the
main Hermes home, whichever profile is calling. Once a phone takes calls from any agent, every
agent is offered the tool (Hermes fixes a chat's tools as it starts, so an agent let call later
would otherwise have none in a chat already open), and one not let is refused when it rings. A
message asking to be called tells an agent that may call how (`turn_note`). However the agent goes about it, one agent rings at most once in five minutes,
and all of them twenty times a day.
"""

from __future__ import annotations

import json
import logging
import re
import time
import uuid
from pathlib import Path

from . import core
from .routines import Stores

log = logging.getLogger("redde_push")

TOOLSET = "redde_calls"
TOOL = "call_user"
#: One agent rings at most this often, in seconds; after a call the person picked up, this soon
#: (hung up by mistake, or the agent has more to say),
GAP = 300.0
GAP_ANSWERED = 60.0
#: and all of them together this many times in a day.
DAILY = 20
#: How long Apple keeps trying a phone that is off, in seconds: a call is no use later.
TTL = 60
#: A profile's name, as Hermes allows it.
PROFILE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")

DESCRIPTION = (
    "Calls the user: their iPhone rings, through the Redde app, like a phone call, on the Lock Screen too. For "
    "what shouldn't wait until they next look: something they asked to be called about, something due now, "
    "something wrong at home. Not to chat, not with what a message would do, and not while they are talking with "
    "you. If they answer, Redde speaks your `line` and their answer comes to you as a new message in your chat "
    "with them; if they don't, they see the line as a missed call. You are not told whether they answered. Only "
    "for an agent the user has let call them in Redde. At most "
    "one call in five minutes, or in one minute after a call they answered.")
LINE = ("What you say first when they answer: one or two short sentences, spoken aloud, that say why you called. "
        "A missed call shows the same words.")


#: A message asking to be called: the person's, or a scheduled job's prompt ("at 7, call me").
_ASKS_CALL = re.compile(r"\b(?:call|ring|phone)\s+(?:me|us)\b|\bgive (?:me|us) a (?:call|ring)\b|\bcall_user\b", re.IGNORECASE)
NOTE = ("[Redde: to ring the user's iPhone, use the call_user tool; if it isn't among your tools, find it with "
        "tool_search and call it through tool_call. Say you are calling only once it answers that the phone is "
        "ringing, and if it answers with an error, say what it said.]")


def turn_note(home: Path, store_in, message) -> str | None:
    """For `pre_llm_call`: a message asks to be called, and this agent may call, so the turn is told
    how. Hermes 0.22 lists a plugin's tools behind its tool search, and a model asked to call said
    "calling you now" without the tool (Marta, 2026-10-26). That turn only."""
    text = message if isinstance(message, str) else " ".join(
        str(p.get("text") or "") for p in message or [] if isinstance(p, dict)) if isinstance(message, list) else ""
    if not _ASKS_CALL.search(text):
        return None
    profile, main = caller(home)
    return NOTE if store_in(main).call_takers(profile) else None


def caller(home: Path) -> tuple[str, Path]:
    """Which agent a Hermes home is (its profile's name; "default", the main agent) and the main
    home, which keeps the paired phones."""
    home = Path(home)
    if home.parent.name == "profiles":
        return home.name, home.parent.parent
    return "default", home


def slash(store: core.Store, words: list[str]) -> str:
    """`/redde-push calls <device,...> <profile,...|none>`, which is the app's: the agents these
    phones take calls from. `calls answered <call>`: the phone picked that call up, so its agent
    may call again sooner (`GAP_ANSWERED`). Every reply starts "redde-push calls"."""
    if len(words) == 2 and words[0] == "answered":
        return "redde-push calls answered" if store.answered_call(words[1]) else "redde-push calls unknown"
    if len(words) != 2:
        return "redde-push calls: this command is for the Redde app."
    profiles = [] if words[1] == "none" else [p for p in words[1].split(",") if PROFILE.fullmatch(p)]
    taking = store.set_callers([w for w in words[0].split(",") if w], profiles)
    return f"redde-push calls {len(taking)}"


def wait(store: core.Store, profile: str, now: float | None = None) -> float:
    """How many seconds until this agent may ring again; 0 if it may now."""
    now = time.time() if now is None else now
    made = store.calls_made(now)
    mine = [(t, answered) for p, t, _, answered in made if p == profile]
    waits = [mine[-1][0] + (GAP_ANSWERED if mine[-1][1] else GAP) - now] if mine else []
    if len(made) >= DAILY:
        waits.append(made[-DAILY][1] + 86400 - now)
    return max([0.0, *waits])


def ring(store: core.Store, profile: str, name: str, line: str, session: str = "", now: float | None = None,
         tries: int = 2) -> dict:
    """Rings the phones that take calls from this agent; what the tool answers."""
    line = core.clipped(line, core.BODY_LIMIT, lines=True)
    if not line:
        return {"error": "The argument \"line\" is missing: say what you will say first when they answer."}
    phones = store.call_takers(profile)
    if not phones:
        return {"error": "The user hasn't let you call their phone: they turn that on for you in Redde (Settings, "
                         "Notifications, Calls from Agents). Reach them some other way, and say so."}
    later = wait(store, profile, now)
    if later:
        minutes = max(1, round(later / 60))
        return {"error": f"Not now: you can call again in about {minutes} minute{'s' if minutes != 1 else ''}. "
                         "Don't call over and over; reach them some other way if it can't wait."}
    made = core.call_note(profile, name, line, session, uuid.uuid4().hex[:16])
    rang = unready = 0
    for device in phones:
        for attempt in range(1, tries + 1):
            try:
                core.push(device, made, ttl=TTL, call=True)
                rang += 1
                break
            except core.Gone:
                store.remove(device["id"])
                log.info("redde-push: %s is no longer registered; forgotten", device.get("name"))
                break
            except core.NoCalls:
                unready += 1
                break
            except Exception as error:   # the network, the relay, Apple: once more, then let it go
                if attempt == tries:
                    log.warning("redde-push: couldn't ring %s: %s", device.get("name"), error)
                else:
                    time.sleep(2)
    if rang:
        store.made_call(profile, now, made.get("i", ""))
        return {"ringing": "The phone is ringing. If they answer, they hear your line and answer you in your chat "
                           "with them; if not, it shows as a missed call. You won't hear back from this tool.",
                "phones": rang}
    if unready:
        return {"error": "The phone isn't ready for calls yet: Redde has to be opened on it once after calls are "
                         "turned on. Reach them some other way."}
    return {"error": "The call didn't go through: the relay or Apple didn't take it. Reach them some other way, or "
                     "try again later."}


def register(ctx, home_of, store_in) -> None:
    """Offers `call_user` to an agent some paired phone takes calls from. `home_of` gives the
    Hermes home in use, asked for at each call (a process can serve several profiles);
    `store_in(main)`, the paired phones a main home keeps."""
    from . import device

    def offered() -> bool:
        """With calls on for any agent here: Hermes fixes a chat's tools as it starts, so an agent
        let call later, in a chat already open, would have no tool to call with (Home, on Marta,
        2026-10-26, sent a Home Assistant notification instead). Who may call is held at `ring`."""
        try:
            return bool(store_in(caller(home_of())[1]).callers())
        except Exception:
            return False
    offered.__qualname__ = "redde_calls_offered"
    try:    # (a check that reads a file is quick and must not be remembered for half a minute)
        from tools.registry import no_cache_check_fn
        no_cache_check_fn(offered)
    except Exception:
        pass

    def handle(args, **kwargs) -> str:
        args = args if isinstance(args, dict) else {}
        home = Path(home_of())
        profile, main = caller(home)
        return json.dumps(ring(store_in(main), profile, Stores(main).name(home, profile), str(args.get("line") or ""),
                               str(kwargs.get("session_id") or "")))

    schema = {"name": TOOL, "description": DESCRIPTION,
              "parameters": {"type": "object", "properties": {"line": {"type": "string", "description": LINE}},
                             "required": ["line"]}}
    ctx.register_tool(name=TOOL, toolset=TOOLSET, schema=schema, handler=handle, check_fn=offered, emoji="📞")
    # The phone's word comes in by the Dashboard's process; every process has to hear it.
    device.watch(lambda: store_in(caller(home_of())[1]).dir / "calls.json")

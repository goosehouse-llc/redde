"""Ask Me First for Hermes's own hand-offs (1.32.0, 2026-11-17).

A bot hands work to another with Hermes's `message_agent`, and nobody is asked: on 11-17 Sol,
told to ask Claude Code, passed the work to its Code bot by itself. Redde can hold the tags an
agent writes in a chat there (its Ask Me First card), but `message_agent` never passes through the
app. So the call is held here, before it runs, and put to the person through Hermes's own
approval gate (a `pre_tool_call` hook answering `{"action": "approve"}`, Hermes 0.22.2 onward):
the same card, voice question and notification as a risky command's. Said no, the bot hears so
and goes on without it. Where nobody can say yes (a scheduled run, one bot asking a third in a
turn no person is in), Hermes refuses it: nothing is handed on unasked.

On until the app says otherwise (`asks off`, Settings › Replies & Writing › Ask Me First), kept
in the main home for every profile. Withdrawing one's own request (`cancel`) is never held.

The approval's description is what Redde reads to draw its card: "Ask @code: <the message>".
"""
from __future__ import annotations

import json
import time
from pathlib import Path

TOOL = "message_agent"
#: The approval's description starts with this, and Redde knows it by it.
OPENING = "Ask "
MOST = 600


def _file(root: Path) -> Path:
    return Path(root) / "redde-push" / "asks.json"


def on(root: Path) -> bool:
    try:
        return bool(json.loads(_file(root).read_text()).get("on", True))
    except (OSError, ValueError):
        return True   # asked until a phone says not to


def set_on(root: Path, value: bool) -> bool:
    path = _file(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"on": bool(value), "at": time.time()}))
    return on(root)


def slash(root: Path, words: list[str]) -> str:
    """`asks on`, `asks off`, `asks` (what it is now): "redde-push asks on|off"."""
    if words[:1] in (["on"], ["off"]):
        set_on(root, words[0] == "on")
    return f"redde-push asks {'on' if on(root) else 'off'}"


def targets(args: dict) -> list[str]:
    return [t.strip().lstrip("@") for t in str(args.get("target") or "").split(",") if t.strip()]


def describe(args: dict) -> str:
    """What the person is shown: whom, and what would be asked (with what's wanted back)."""
    whom = ", ".join("@" + t for t in targets(args)) or "another agent"
    text = " ".join(str(args.get("message") or "").split())
    wanted = " ".join(str(args.get("expecting") or "").split())
    if wanted:
        text += f" (wants back: {wanted})"
    if len(text) > MOST:
        text = text[: MOST - 1].rstrip() + "…"
    return f"{OPENING}{whom}: {text}" if text else f"{OPENING}{whom}"


def gate(root: Path, asker: str, tool_name: str, args) -> dict | None:
    """`pre_tool_call`, kept fast (one small file): a hand-off to another agent, to the person first."""
    if tool_name != TOOL or not on(root):
        return None
    args = args if isinstance(args, dict) else {}
    if str(args.get("cancel") or "").strip():
        return None
    whom = targets(args)
    return {"action": "approve", "message": describe(args),
            # Its own key per asker and whom: an "always" said elsewhere (Hermes Desktop) covers no one else.
            "rule_key": f"redde_ask:{asker}>{','.join(sorted(whom))}"}


def register(ctx, home_of) -> None:
    from .calls import caller

    def on_tool(tool_name: str = "", args=None, **_) -> dict | None:
        if tool_name != TOOL:
            return None
        try:
            asker, root = caller(Path(home_of()))
            return gate(root, asker, tool_name, args)
        except Exception:
            return None   # (a hook that fails must not stop the tool on its own)

    ctx.register_hook("pre_tool_call", on_tool)

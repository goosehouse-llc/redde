"""A bot's hand-off outlives the chat that made it (1.23.1).

`message_agent` hands a message to another bot through a background process (Hermes's
`tools/bot_mode_dm.py --run-delivery`, or `--wait-reply` across connections) that carries the
other bot's answer back when it comes. Hermes ties that process to the asking agent: when the
Dashboard closes the asking chat (its client gone for 20 seconds: a phone locked or in another
app or chat, `ws_orphan_reap`), `AIAgent.close()` kills it, and the other bot's work is lost
half-way ("terminated (SIGTERM)", measured on 0.22 2026-11-10: Watcher stopped twice, at 90 and
45 seconds, while the phone watched its chat). The Desktop app stays connected, so it never sees
this; a phone does every time.

Hermes spares a process marked `persist_on_release` (its own opt-out, #41225: "survives agent
close"); a finished hand-off still reaches the asking chat by its completion notice, which
Hermes delivers into a closed chat as a new turn. So after each `message_agent` call, its
delivery processes are marked so.
"""
from __future__ import annotations

import logging

log = logging.getLogger("redde-push")

TOOLS = frozenset({"message_agent"})
RUNNER, MODES = "bot_mode_dm.py", ("--run-delivery", "--wait-reply")


def keep(tool_name: str, registry=None) -> int:
    """Marks the running hand-off processes to outlive their chat; how many it marked."""
    if tool_name not in TOOLS:
        return 0
    if registry is None:
        try:
            from tools.process_registry import process_registry as registry
        except Exception:
            return 0
    kept = 0
    for session in list(getattr(registry, "_running", {}).values()):
        command = str(getattr(session, "command", "") or "")
        if getattr(session, "persist_on_release", True) or RUNNER not in command or not any(m in command for m in MODES):
            continue
        try:
            session.persist_on_release = True
            kept += 1
        except Exception:
            log.debug("redde-push: couldn't keep a hand-off", exc_info=True)
    if kept:
        log.info("redde-push: %d hand-off(s) kept past their chat's close", kept)
    return kept

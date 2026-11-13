"""The Redde app's answers to its commands: `redde-push <command> <JSON>`, one line.

The app reads them with `PluginReply` (PushService.swift); anything else (an older plugin's usage, a
refusal) it takes for "not this one". Standard library only, so any module can use it.
"""
from __future__ import annotations

import json


def reply(command: str, value, compact: bool = False) -> str:
    """`value` as the answer to `command` ("lists", "work", "device cache", …)."""
    return f"redde-push {command} " + json.dumps(value, ensure_ascii=False, separators=(",", ":") if compact else None)

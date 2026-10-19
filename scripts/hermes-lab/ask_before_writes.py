#!/usr/bin/env python3
"""A pre_tool_call hook (lab.sh butler, in the main profile's config): before any tool call that can
change files or run something, Hermes asks the person, each call on its own (a fresh rule_key, so
answering "always" once can't stand for later ones). A command that only reads goes ahead.

This is the shape suggested for a real server too: hooks.pre_tool_call with
matcher "terminal|write_file|patch|execute_code" and hooks_auto_accept: true. What it saw goes to
$LAB_HOOK_LOG (one JSON line a call) for the lab's check.
"""
import json
import os
import re
import sys
import uuid

event = json.load(sys.stdin)
tool = event.get("tool_name") or ""
args = event.get("tool_input") or {}
# Reading only: one of these commands, with no pipe, redirection, or second command after it.
READS = re.compile(r"^\s*(ls|pwd|cat|head|tail|wc|grep|rg|find|git\s+(status|diff|log|show))\b[^|;&><`$]*$")
ask = None
if tool == "terminal":
    command = str(args.get("command") or "")
    if not READS.match(command):
        ask = f"Sol wants to run: {command}"
elif tool in ("write_file", "patch"):
    ask = f"Sol wants to write {args.get('path') or args.get('file_path') or 'a file'}"
elif tool == "execute_code":
    ask = "Sol wants to run code"
log = os.environ.get("LAB_HOOK_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps({"tool": tool, "asked": bool(ask), "message": ask, "session": event.get("session_id")}) + "\n")
if ask:
    print(json.dumps({"action": "approve", "message": ask[:500], "rule_key": "ask-" + uuid.uuid4().hex[:12]}))

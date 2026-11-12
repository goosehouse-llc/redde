"""A scripted ACP agent over stdio, for the bridge's tests.

Prompts:
  "slow ..."  three chunks, 0.6 s apart
  "ask ..."   asks permission first, then says which option it was given
  "commands ..." announces two slash commands
  "question ..." asks a form (elicitation/create), then says what came back
  anything else: one chunk, "echo: <text>"

It keeps sessions in memory and logs every method it is called with to $FAKE_AGENT_LOG.
"""
import json
import os
import sys
import threading
import time
import uuid

LOG = os.environ.get("FAKE_AGENT_LOG")
lock = threading.Lock()
sessions: dict[str, list] = {}
waiting: dict = {}
next_id = [1000]


def write(message):
    with lock:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def note(method, params):
    if LOG:
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": method, "params": params}) + "\n")


def update(sid, body):
    write({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": body}})
    sessions.setdefault(sid, []).append(body)


def chunk(sid, text, kind="agent_message_chunk"):
    update(sid, {"sessionUpdate": kind, "content": {"type": "text", "text": text}})


def prompt(rid, params):
    sid = params["sessionId"]
    text = " ".join(p.get("text", "") for p in params["prompt"])
    sessions.setdefault(sid, []).append({"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": text}})
    if text.startswith("slow"):
        for word in ("one ", "two ", "three"):
            chunk(sid, word)
            time.sleep(0.6)
    elif text.startswith("ask"):
        next_id[0] += 1
        ask = next_id[0]
        event = threading.Event()
        waiting[ask] = {"event": event}
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "terminal: rm -rf x", "kind": "execute", "status": "pending"})
        write({"jsonrpc": "2.0", "id": ask, "method": "session/request_permission", "params": {
            "sessionId": sid, "toolCall": {"toolCallId": "t1", "title": "terminal: rm -rf x"},
            "options": [{"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"},
                        {"optionId": "deny", "name": "Deny", "kind": "reject_once"}]}})
        event.wait(30)
        outcome = waiting.pop(ask).get("result", {}).get("outcome", {})
        chunk(sid, f"picked {outcome.get('optionId', outcome.get('outcome'))}")
    elif text.startswith("commands"):
        update(sid, {"sessionUpdate": "available_commands_update", "availableCommands": [
            {"name": "compact", "description": "Summarise the chat"}, {"name": "review", "description": "Review a change"}]})
        chunk(sid, "listed")
    elif text.startswith("question"):
        next_id[0] += 1
        ask = next_id[0]
        event = threading.Event()
        waiting[ask] = {"event": event}
        write({"jsonrpc": "2.0", "id": ask, "method": "elicitation/create", "params": {
            "sessionId": sid, "mode": "form", "message": "Which colour?",
            "requestedSchema": {"type": "object", "properties": {
                "question_0": {"type": "string", "oneOf": [{"const": "Red", "title": "Red"}, {"const": "Blue", "title": "Blue"}]},
                "question_0_custom": {"type": "string", "title": "Other"}}}}})
        event.wait(30)
        result = waiting.pop(ask).get("result", {})
        chunk(sid, f"{result.get('action')} {json.dumps(result.get('content', {}), sort_keys=True)}")
    else:
        chunk(sid, f"echo: {text}")
    write({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


def main():
    for line in sys.stdin:
        if not line.strip():
            continue
        message = json.loads(line)
        method, rid, params = message.get("method"), message.get("id"), message.get("params") or {}
        if method is None:
            if rid in waiting:
                waiting[rid]["result"] = message.get("result", {})
                waiting[rid]["event"].set()
            continue
        note(method, params)
        if method == "initialize":
            write({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": 1, "agentInfo": {"name": "fake", "version": "1"},
                   "agentCapabilities": {"loadSession": True, "sessionCapabilities": {"list": {}, "resume": {}}}}})
        elif method == "session/new":
            sid = "s-" + uuid.uuid4().hex[:8]
            sessions[sid] = []
            write({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": sid}})
        elif method == "session/load":
            for body in sessions.get(params["sessionId"], []):
                write({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": params["sessionId"], "update": body}})
            write({"jsonrpc": "2.0", "id": rid, "result": {}})
        elif method == "session/resume":
            write({"jsonrpc": "2.0", "id": rid, "result": {}})
        elif method == "session/list":
            write({"jsonrpc": "2.0", "id": rid, "result": {"sessions": [{"sessionId": s, "cwd": "/tmp"} for s in sessions]}})
        elif method == "session/prompt":
            threading.Thread(target=prompt, args=(rid, params), daemon=True).start()
        elif method == "session/cancel":
            pass
        elif rid is not None:
            write({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "nope"}})


if __name__ == "__main__":
    main()

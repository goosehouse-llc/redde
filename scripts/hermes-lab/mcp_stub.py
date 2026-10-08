#!/usr/bin/env python3
"""A stand-in MCP server over stdio, for the lab's `admin` scenario: it answers the handshake and
lists one tool, which is all Hermes asks of a server it is testing."""
import json
import sys

TOOLS = [{"name": "lab_echo", "description": "Says back what it is given.",
          "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}]

for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    method, ident = message.get("method"), message.get("id")
    if ident is None:       # a notification: nothing to answer
        continue
    if method == "initialize":
        result = {"protocolVersion": (message.get("params") or {}).get("protocolVersion", "2025-06-18"),
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "lab-notes", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        text = ((message.get("params") or {}).get("arguments") or {}).get("text", "")
        result = {"content": [{"type": "text", "text": str(text)}]}
    elif method == "ping":
        result = {}
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": f"no {method}"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": ident, "result": result}), flush=True)

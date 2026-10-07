"""A stand-in OpenAI-compatible endpoint for the Hermes lab. Every chat completion answers
"[<name>:<model>]" and is appended to $LAB_HITS, so a check can tell which endpoint a Hermes turn
actually reached.

One message is different: a user message containing "danger" makes the model call the terminal
tool with `rm -rf $LAB_TARGET`, a command Hermes asks before running. The stub makes that folder
first, and answers the tool's result with "[gone]" or "[kept]" by looking for it, so a check knows
whether the command really ran.

usage: stub_llm.py <port> <name> <model,model,...>
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, NAME, MODELS = int(sys.argv[1]), sys.argv[2], sys.argv[3].split(",")
HITS = os.environ["LAB_HITS"]
TARGET = os.environ.get("LAB_TARGET", "")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self._json(200, {"object": "list", "data": [{"id": m, "object": "model", "owned_by": NAME} for m in MODELS]})
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self._json(404, {"error": {"message": "not found"}})
        model = body.get("model", "")
        with open(HITS, "a") as f:
            f.write(json.dumps({"stub": NAME, "model": model, "stream": bool(body.get("stream"))}) + "\n")
        text, call = f"[{NAME}:{model}]", None
        messages = body.get("messages") or []
        if TARGET.endswith("/redde-lab-target") and messages:
            def said(message):
                content = message.get("content")
                return content if isinstance(content, str) else " ".join(p.get("text", "") for p in content or [] if isinstance(p, dict))
            asked = next((said(m) for m in reversed(messages) if m.get("role") == "user"), "")
            offered = [tool.get("function", {}).get("name") for tool in body.get("tools") or []]
            if messages[-1].get("role") == "tool":
                text = "[kept]" if os.path.isdir(TARGET) else "[gone]"
            elif "danger" in asked and "terminal" in offered:
                os.makedirs(TARGET, exist_ok=True)
                text, call = "", {"index": 0, "id": f"call_{int(time.time() * 1000)}", "type": "function",
                                  "function": {"name": "terminal", "arguments": json.dumps({"command": f"rm -rf {TARGET}"})}}
        usage = {"prompt_tokens": 10, "completion_tokens": 3, "total_tokens": 13}
        if not body.get("stream"):
            message = {"role": "assistant", "content": text or None}
            if call:
                message["tool_calls"] = [{k: v for k, v in call.items() if k != "index"}]
            return self._json(200, {"id": "c1", "object": "chat.completion", "created": int(time.time()), "model": model,
                                    "choices": [{"index": 0, "message": message, "finish_reason": "tool_calls" if call else "stop"}],
                                    "usage": usage})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()

        def chunk(delta, finish=None, extra=None):
            payload = {"id": "c1", "object": "chat.completion.chunk", "created": int(time.time()), "model": model,
                       "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            payload.update(extra or {})
            self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())
            self.wfile.flush()

        chunk({"role": "assistant", "content": ""})
        if call:
            chunk({"tool_calls": [call]})
            chunk({}, "tool_calls", {"usage": usage})
        else:
            chunk({"content": text})
            chunk({}, "stop", {"usage": usage})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

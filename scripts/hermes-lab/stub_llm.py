"""A stand-in OpenAI-compatible endpoint for the Hermes lab. Every chat completion answers
"[<name>:<model>]" and is appended to $LAB_HITS, so a check can tell which endpoint a Hermes turn
actually reached.

One message is different: a user message containing "danger" makes the model call the terminal
tool with `rm -rf $LAB_TARGET`, a command Hermes asks before running. The stub makes that folder
first, and answers the tool's result with "[gone]" or "[kept]" by looking for it, so a check knows
whether the command really ran.

A few more, for the push plugin's check, each only while it is the last thing said (so the turn
that follows in the same conversation is an ordinary one):

    lab:question   the model asks the person a question (the clarify tool, two choices)
    lab:delegate   it hands a small task to a subagent (delegate_task)
    lab:sudo       it runs `sudo true`, which wants a password
    lab:secret     it opens the skill "lab-secret", which wants a secret
    lab:refused    the endpoint answers 401: a failure Hermes doesn't retry
    lab:outage     the endpoint answers 500 every time: one it retries, then gives up on
    lab:hiccup     the endpoint answers 500 twice, then as usual: one it retries and gets past

And one for attachments: a message with "lab:file" in it is answered "[file seen]" when what
reached the model also holds "lab-file-token" (a text file's contents, as Hermes inlines them)
or "lab-clip.mp4" (how it names a file it can't inline), and "[file missing]" when it doesn't.

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
#: What a message makes the model call: the tool and its arguments.
CALLS = {
    "lab:question": ("clarify", {"questions": [{"question": "Which branch should I deploy?", "choices": ["main", "release"]}]}),
    "lab:delegate": ("delegate_task", {"goal": "Say hello."}),
    "lab:sudo": ("terminal", {"command": "sudo true"}),
    "lab:secret": ("skill_view", {"name": "lab-secret"}),
}
#: How many more times each "lab:hiccup" message is answered with a failure.
HICCUPS = {}
#: What a message makes the endpoint answer in place of a completion.
FAILURES = {
    "lab:refused": (401, {"error": {"message": "Incorrect API key provided.", "type": "invalid_request_error", "code": "invalid_api_key"}}),
    "lab:outage": (500, {"error": {"message": "The server had an error while processing your request.", "type": "server_error"}}),
}


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
            just_said = asked if messages[-1].get("role") == "user" else ""
            failure = next((answer for word, answer in FAILURES.items() if word in just_said), None)
            if "lab:hiccup" in just_said and HICCUPS.setdefault(just_said, 2) > 0:
                HICCUPS[just_said] -= 1
                failure = FAILURES["lab:outage"]
            if failure:
                return self._json(*failure)
            planned = next((plan for word, plan in CALLS.items() if word in just_said and plan[0] in offered), None)
            if "lab:file" in just_said:
                text = "[file seen]" if "lab-file-token" in just_said or "lab-clip.mp4" in just_said else "[file missing]"
            if messages[-1].get("role") == "tool":
                text = "[kept]" if os.path.isdir(TARGET) else "[gone]"
            elif "danger" in asked and "terminal" in offered:
                os.makedirs(TARGET, exist_ok=True)
                planned = ("terminal", {"command": f"rm -rf {TARGET}"})
            if planned:
                text, call = "", {"index": 0, "id": f"call_{int(time.time() * 1000)}", "type": "function",
                                  "function": {"name": planned[0], "arguments": json.dumps(planned[1])}}
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

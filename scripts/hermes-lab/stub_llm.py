"""A stand-in OpenAI-compatible endpoint for the Hermes lab. Every chat completion answers
"[<name>:<model>]" and is appended to $LAB_HITS, so a check can tell which endpoint a Hermes turn
actually reached.

One message is different: a user message containing "danger" makes the model call the terminal
tool with `rm -rf $LAB_TARGET`, a command Hermes asks before running. The stub makes that folder
first, and answers the tool's result with "[gone]" or "[kept]" by looking for it, so a check knows
whether the command really ran.

A few more, for the push plugin's check, each only while it is the last thing said (so the turn
that follows in the same conversation is an ordinary one):

    lab:question   the model asks the person a question (the clarify tool, two choices), and
                   answers what it is told with "[answered: <the answer>]"
    lab:delegate   it hands a small task to a subagent (delegate_task)
    lab:sudo       it runs `sudo true`, which wants a password
    lab:secret     it opens the skill "lab-secret", which wants a secret
    lab:refused    the endpoint answers 401: a failure Hermes doesn't retry
    lab:outage     the endpoint answers 500 every time: one it retries, then gives up on
    lab:hiccup     the endpoint answers 500 twice, then as usual: one it retries and gets past
    lab:todo       it writes a task list of three with the to-do tool (`todo_list`, or `todo` as
                   Hermes 0.21.0 calls it): the first in progress, two waiting
    lab:tick       it merges into that list: the first done, the second in progress
    lab:badtick    it merges an item that names no words, which Hermes 0.21.3 and later turn
                   down without running the tool (0.21.0 takes it)

And one for a long turn: a message with "lab:slow" in it is answered "[slow done]" after eight
seconds, for a check that leaves a turn under way (switching to another conversation). "lab:drip"
takes as long but streams all the while, a word a second, then "[drip done]".

And a voice, for the speech scenario (`lab.sh speech`): `/v1/audio/speech` answers as OpenAI's
speech API does, with a 440 Hz tone at 24 kHz, 50 ms for each character of the input, so a check
can tell from the length and loudness of what it heard that nothing was lost or misread. `pcm`
streams it in odd-sized pieces (a sample split across two); `wav` is a file; `mp3` needs ffmpeg.

And the butler (lab.sh butler, with LAB_BUTLER the lab's run folder): "lab:butler tag=<word>" to
the main profile makes it hand a coding task to the "claude" bot on the kanban board
(kanban_create). The claude bot's worker reads the task (kanban_show), runs Claude Code on
"Workbox" through its SSH terminal (the lab's stand-in, fakebin/claude, in a clone there), and
finishes the card with where the patch is (kanban_complete, "lab-patch workbox:<path>"). When the
main profile is woken with that, it applies the patch as it is (`ssh workbox cat <path> | git apply`),
a command Hermes asks the person about (ask_before_writes.py), and says "[applied]" or
"[not applied]" by looking at the repository.

And one for bots messaging bots (lab.sh bots): "lab:dm:<bot>" makes the model message that bot
with Bot Mode's own tool (`message_agent`): "Which trailhead for Lost Lake?".

And one for attachments: a message with "lab:file" in it is answered "[file seen]" when what
reached the model also holds "lab-file-token" (a text file's contents, as Hermes inlines them)
or "lab-clip.mp4" (how it names a file it can't inline), and "[file missing]" when it doesn't.

usage: stub_llm.py <port> <name> <model,model,...>
"""
import json
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from lab_tone import tone, wav

PORT, NAME, MODELS = int(sys.argv[1]), sys.argv[2], sys.argv[3].split(",")
HITS = os.environ["LAB_HITS"]
TARGET = os.environ.get("LAB_TARGET", "")
#: The to-do tool's name from Hermes 0.21.3, and before: the stub calls whichever it is offered.
TODO = ("todo_list", "todo")
#: What a message makes the model call: the tool (or the names it may go by) and its arguments.
CALLS = {
    "lab:todo": (TODO, {"todos": [{"id": "1", "content": "Export the posts", "status": "in_progress"},
                                   {"id": "2", "content": "Import them", "status": "pending"},
                                   {"id": "3", "content": "Check the feed", "status": "pending"}]}),
    # (Every item with its words: from 0.21.3 Hermes turns a call down whose items leave any out.)
    "lab:tick": (TODO, {"todos": [{"id": "1", "content": "Export the posts", "status": "completed"},
                                   {"id": "2", "content": "Import them", "status": "in_progress"}], "merge": True}),
    # One Hermes 0.21.3 and later refuse without running the tool: an item with no words.
    "lab:badtick": (TODO, {"todos": [{"id": "2", "status": "completed"}], "merge": True}),
    "lab:question": ("clarify", {"questions": [{"question": "Which branch should I deploy?", "choices": ["main", "release"]}]}),
    "lab:delegate": ("delegate_task", {"goal": "Say hello."}),
    "lab:sudo": ("terminal", {"command": "sudo true"}),
    "lab:secret": ("skill_view", {"name": "lab-secret"}),
    # Phone tools (the Redde plugin's): carried out by whoever plays the phone in the check.
    "lab:reminder": ("phone_reminders_add", {"title": "Renew the car registration", "due": "2026-10-20"}),
    "lab:photo": ("phone_photos_get", {"id": "ABC-123"}),
    "lab:note": ("phone_files_write", {"path": "lab/note.txt", "text": "from the agent"}),
}
#: What the model says once a phone tool has answered, by what the answer holds.
PHONE_SAID = (('"added"', "[phone: added]"), ("file_path", "[phone: file]"), ('"saved"', "[phone: saved]"), ("said no", "[phone: no]"),
              ("didn't answer", "[phone: no answer]"), ("turned off", "[phone: off]"))
#: How many more times each "lab:hiccup" message is answered with a failure.
HICCUPS = {}
#: What a message makes the endpoint answer in place of a completion.
FAILURES = {
    "lab:refused": (401, {"error": {"message": "Incorrect API key provided.", "type": "invalid_request_error", "code": "invalid_api_key"}}),
    "lab:outage": (500, {"error": {"message": "The server had an error while processing your request.", "type": "server_error"}}),
}


BUTLER = os.environ.get("LAB_BUTLER", "")
# Steps of a check kept elsewhere (LAB_STUB_EXTRA, a Python file with flow(messages, body, call)):
# asked first; None hands the conversation on to the steps here.
EXTRA = None
if os.environ.get("LAB_STUB_EXTRA"):
    import importlib.util
    _spec = importlib.util.spec_from_file_location("lab_stub_extra", os.environ["LAB_STUB_EXTRA"])
    EXTRA = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(EXTRA)


def text_of(message):
    content = message.get("content")
    return content if isinstance(content, str) else " ".join(p.get("text", "") for p in content or [] if isinstance(p, dict))


def tool_call(body, name, arguments):
    """How the model calls a tool it may be offered only through tool search."""
    offered = [tool.get("function", {}).get("name") for tool in body.get("tools") or []]
    if name in offered or "tool_call" not in offered:
        return "", (name, arguments)
    bridge = next(t.get("function", {}) for t in body.get("tools") or [] if t.get("function", {}).get("name") == "tool_call")
    batched = "calls" in (bridge.get("parameters") or {}).get("properties", {})
    return "", ("tool_call", {"calls": [{"name": name, "arguments": arguments}]} if batched else {"name": name, "arguments": arguments})


def butler(messages, body):
    """The butler's steps (lab.sh butler): what the model says or calls next, or None if this
    conversation isn't one of them. (text, (tool, arguments) or None)."""
    import re
    offered = [tool.get("function", {}).get("name") for tool in body.get("tools") or []]
    last = messages[-1] if messages else {}
    users = [text_of(m) for m in messages if m.get("role") == "user"]
    called = [c.get("function", {}).get("name") for m in messages if m.get("role") == "assistant" for c in m.get("tool_calls") or []]
    def call(name, arguments):
        if name in offered or "tool_call" not in offered:
            return "", (name, arguments)
        bridge = next(t.get("function", {}) for t in body.get("tools") or [] if t.get("function", {}).get("name") == "tool_call")
        batched = "calls" in (bridge.get("parameters") or {}).get("properties", {})
        return "", ("tool_call", {"calls": [{"name": name, "arguments": arguments}]} if batched else {"name": name, "arguments": arguments})
    said = text_of(last)
    # The claude bot's worker: "work kanban task t_…".
    if users and users[0].startswith("work kanban task"):
        if last.get("role") == "user":
            return call("kanban_show", {})
        if last.get("role") != "tool":
            return None
        step = called[-1] if called else ""
        if step == "kanban_show" or (step == "tool_call" and len(called) == 1):
            tag = (re.search(r"tag=(\w+)", said) or re.search(r"tag=(\w+)", " ".join(users)))
            tag = tag.group(1) if tag else "one"
            # (Nothing Hermes counts as dangerous, rm -rf say: a kanban worker has no one to ask,
            # so Hermes refuses it outright.)
            work = f"~/work/{tag}"
            return call("terminal", {"command": f"mkdir -p {work} && cd {work} && git clone -q {BUTLER}/workbox/origin repo "
                                                f"&& cd repo && claude -p 'Add one line to hello.py. tag={tag}' --permission-mode acceptEdits"})
        if step == "terminal" or (step == "tool_call" and len(called) == 2):
            done = re.search(r"Patch at (\S+change\.patch)", said)
            tag = (re.search(r"tag=(\w+)", " ".join(text_of(m) for m in messages if m.get("role") == "tool")) or [None, "one"])[1]
            if not done:
                return call("kanban_block", {"reason": f"lab-failed: Claude Code didn't finish: {said[:200]}"})
            return call("kanban_complete", {"summary": f"lab-patch workbox:{done.group(1)} one line added to hello.py (tag={tag})",
                                            "metadata": {"changed_files": ["hello.py"], "tag": tag}})
        return "[worker done]", None
    # The main profile.
    if any("lab:butler" in u for u in users):
        if last.get("role") == "user" and "lab:butler" in said:
            tag = (re.search(r"tag=(\w+)", said) or [None, "one"])[1]
            return call("kanban_create", {"title": f"Lab change {tag}", "assignee": "claude",
                                          "body": f"lab:claude-work tag={tag}: add one line to hello.py",
                                          "workspace_kind": "dir", "workspace_path": f"{BUTLER}/kanban-work/{tag}"})
        if last.get("role") == "user" and "lab-patch workbox:" in said:
            path = re.search(r"lab-patch workbox:(\S+)", said).group(1)
            # The lab's own ssh by its path: a login shell puts the system's first, and "workbox" may
            # name a real machine on the network. (A real server uses `ssh workbox` and its ~/.ssh/config.)
            return call("terminal", {"command": f"{BUTLER}/bin/ssh workbox cat {path} | git -C {BUTLER}/host/repo apply --whitespace=nowarn -"})
        if last.get("role") == "tool":
            asked = called[-1] if called else ""
            if asked == "kanban_create" or (asked == "tool_call" and "kanban" in said.lower() and "lab-patch" not in said):
                return "[queued]", None
            tags = re.findall(r"tag=(\w+)", " ".join(text_of(m) for m in messages if m.get("role") == "user"))
            try:
                code = open(f"{BUTLER}/host/repo/hello.py").read()
            except OSError:
                code = ""
            return ("[applied]" if tags and f"changed by the claude bot: {tags[-1]}" in code else "[not applied]"), None
        if last.get("role") == "user":
            # Any other news (a card blocked, say): noted, nothing done.
            return "[noted]", None
    return None


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

    def _speech(self, body):
        pcm = tone(len(str(body.get("input") or "")) * 0.05, 24000)
        kind = body.get("response_format") or "mp3"
        if kind == "pcm":
            self.send_response(200)
            self.send_header("Content-Type", "audio/pcm")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for start in range(0, len(pcm), 4801):
                piece = pcm[start:start + 4801]
                self.wfile.write(f"{len(piece):x}\r\n".encode() + piece + b"\r\n")
                self.wfile.flush()
                time.sleep(0.005)
            self.wfile.write(b"0\r\n\r\n")
            return
        if kind == "wav":
            data, mime = wav(pcm, 24000), "audio/wav"
        elif kind == "mp3":
            try:
                data = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "s16le", "-ar", "24000", "-ac", "1", "-i", "-", "-f", "mp3", "-"],
                                      input=pcm, capture_output=True, check=True).stdout
            except (OSError, subprocess.CalledProcessError):
                return self._json(501, {"error": {"message": "the lab's mp3 needs ffmpeg"}})
            mime = "audio/mpeg"
        else:
            return self._json(400, {"error": {"message": f"no {kind} here"}})
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path.rstrip("/").endswith("/audio/speech"):
            return self._speech(body)
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self._json(404, {"error": {"message": "not found"}})
        model = body.get("model", "")
        tools = [tool.get("function", {}).get("name") or "" for tool in body.get("tools") or []]
        messages = body.get("messages") or []
        system = " ".join(json.dumps(m.get("content")) for m in messages if m.get("role") == "system")
        last_user = next((json.dumps(m.get("content")) for m in reversed(messages) if m.get("role") == "user"), "")
        with open(HITS, "a") as f:
            f.write(json.dumps({"stub": NAME, "model": model, "stream": bool(body.get("stream")),
                                "phone": sorted(name for name in tools if name.startswith("phone_")), "tools": len(tools),
                                "search": "tool_call" in tools,
                                # Bot Mode (lab.sh bots): the teammate protocol in the system prompt,
                                # its tool, and the @mention note on the message.
                                "bots": "Messaging other agents" in system, "message_agent": "message_agent" in tools,
                                "mention": "[@mentions resolved from the Bot Mode roster" in last_user}) + "\n")
        text, call = f"[{NAME}:{model}]", None
        last = messages[-1] if messages else {}
        planned = EXTRA.flow(messages, body, tool_call) if EXTRA else None
        if planned is None and BUTLER:
            planned = butler(messages, body)
        if planned is not None:
            text, step = planned
            if step:
                text, call = "", {"index": 0, "id": f"call_{int(time.time() * 1000)}", "type": "function",
                                  "function": {"name": step[0], "arguments": json.dumps(step[1])}}
            messages = []   # the rest below is for the other checks
        if last.get("role") == "user" and "lab:slow" in json.dumps(last.get("content")):
            time.sleep(8)
            text = "[slow done]"
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
            planned = None
            for word, (names, arguments) in CALLS.items():
                if word not in just_said:
                    continue
                names = (names,) if isinstance(names, str) else names
                name = next((n for n in names if n in offered), None)
                if name:
                    planned = (name, arguments)
                elif (names is TODO or names[0].startswith("phone_")) and "tool_call" in offered:
                    # From Hermes 0.21.3 most tools are not offered outright: the model finds
                    # them and calls them through `tool_call`, by name. (0.21.0 does the same once
                    # enough tools are on, and its `tool_call` takes one call, not a list of them.)
                    bridge = next(tool.get("function", {}) for tool in body.get("tools") or [] if tool.get("function", {}).get("name") == "tool_call")
                    batched = "calls" in (bridge.get("parameters") or {}).get("properties", {})
                    planned = ("tool_call", {"calls": [{"name": names[0], "arguments": arguments}]} if batched else {"name": names[0], "arguments": arguments})
                break
            dm = re.search(r"lab:dm:([a-z0-9][a-z0-9_-]*)", just_said)
            if dm and planned is None and "message_agent" in offered:
                planned = ("message_agent", {"target": dm.group(1), "message": "Which trailhead for Lost Lake?"})
            if "lab:file" in just_said:
                text = "[file seen]" if "lab-file-token" in just_said or "lab-clip.mp4" in just_said else "[file missing]"
            if messages[-1].get("role") == "tool":
                text = "[kept]" if os.path.isdir(TARGET) else "[gone]"
                # A question's answer comes back as the tool's result: say what it was.
                try:
                    answers = json.loads(said(messages[-1])).get("responses") or []
                    if answers:
                        text = f"[answered: {answers[0].get('user_response', '')}]"
                except (ValueError, AttributeError):
                    pass
                text = next((words for mark, words in PHONE_SAID if mark in said(messages[-1])), text)
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
        elif last.get("role") == "user" and "lab:drip" in json.dumps(last.get("content")):
            # A reply that streams as a model's does, a word a second, so Hermes writes to its
            # client all along: what it does when that client has gone (lab.sh switch).
            for i in range(8):
                chunk({"content": f"word{i} "})
                time.sleep(1)
            chunk({"content": "[drip done]"})
            chunk({}, "stop", {"usage": usage})
        else:
            chunk({"content": text})
            chunk({}, "stop", {"usage": usage})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

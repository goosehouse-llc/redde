#!/usr/bin/python3
"""An OpenAI-compatible stand-in for SmoothnessUITests (scripts/smoothness.sh): THINK seconds of
reasoning, then a long Markdown reply at TPS tokens a second (a token ~4 characters), LONG times
over. Non-streaming requests (follow-ups) get a short JSON answer. On 127.0.0.1:PORT (8799)."""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", 8799))
THINK = float(os.environ.get('THINK', 4))
TPS = float(os.environ.get('TPS', 40))
LONG = int(os.environ.get('LONG', 1))

REPLY = ("## The plan\n\nHere is how the weekend could go, step by step, with what to bring.\n\n"
         + "".join(f"{i}. **Step {i}**: leave at {6 + i % 4}:{i % 6}0, walk the {['ridge', 'loop', 'creek', 'notch'][i % 4]} trail and stop at the overlook for a while.\n" for i in range(1, 13))
         + "\n| Trail | Miles | Time |\n|---|---|---|\n| Bear Ridge | 6 | 1h20 |\n| Falls Loop | 4 | 50 min |\n| Cedar Notch | 8 | 1h45 |\n\n"
         + "```python\ndef pack(weather):\n    kit = ['water', 'layers', 'snacks']\n    if weather == 'rain':\n        kit.append('shell')\n    return kit\n```\n\n"
         + "Some longer prose to wrap: " + "the trail climbs through the trees and opens onto the ridge, where the wind picks up and the views go on for miles. " * 8
         + "\n\n- Boots, not sneakers\n- Two litres of water each\n- A map, in case the signal drops\n") * LONG
THOUGHT = "Let me think about the trails, the weather and the times. " * 40


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a): pass

    def do_GET(self):
        body = json.dumps({'data': [{'id': 'test'}]}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        req = json.loads(self.rfile.read(n) or b'{}')
        print(f"{time.time():.3f} {'stream' if req.get('stream') else 'plain'} request, {len(req.get('messages', []))} messages", flush=True)
        if not req.get('stream'):
            body = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': '["What should I pack?", "Which trail is shortest?"]'}}]}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers()
            self.wfile.write(body); return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()

        def send(obj):
            data = f'data: {json.dumps(obj) if not isinstance(obj, str) else obj}\n\n'.encode()
            self.wfile.write(f'{len(data):x}\r\n'.encode() + data + b'\r\n'); self.wfile.flush()

        def delta(**d): send({'choices': [{'index': 0, 'delta': d, 'finish_reason': None}]})
        try:
            step = 1 / TPS
            t0 = time.time()
            words = THOUGHT.split(' ')
            i = 0
            while time.time() - t0 < THINK:
                delta(reasoning_content=words[i % len(words)] + ' '); i += 1; time.sleep(step)
            for k in range(0, len(REPLY), 4):
                delta(content=REPLY[k:k + 4]); time.sleep(step)
            send({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]})
            send('[DONE]')
            self.wfile.write(b'0\r\n\r\n'); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


print(f'sse stand-in on {PORT}: think {THINK}s, {TPS} tok/s, reply {len(REPLY)} chars', flush=True)
ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()

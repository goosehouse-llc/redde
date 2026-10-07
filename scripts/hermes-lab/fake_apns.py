"""Stands in for Apple's push service in the lab. Every notification the relay sends is appended
to $LAB_APNS, one JSON object per line, and, when $LAB_SIMULATOR names a booted simulator, handed
to it as a simulated push (`xcrun simctl push`). A simulated push reaches the app but skips its
notification extension, which only a real one from Apple starts; the app opens the note itself
when it is in front.

usage: fake_apns.py <port>
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.environ["LAB_APNS"]
SIMULATOR = os.environ.get("LAB_SIMULATOR", "")
BUNDLE = os.environ.get("LAB_BUNDLE", "com.goosehouse.echo")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        record = {"token": self.path.rsplit("/", 1)[-1], "collapse": self.headers.get("apns-collapse-id"),
                  "expiration": self.headers.get("apns-expiration"), "body": body}
        with open(LOG, "a") as log:
            log.write(json.dumps(record) + "\n")
        if SIMULATOR:
            threading.Thread(target=deliver, args=(body,), daemon=True).start()   # Apple answers at once
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()


def deliver(body):
    with tempfile.NamedTemporaryFile("w", suffix=".apns", delete=False) as payload:
        json.dump(body, payload)
    done = subprocess.run(["xcrun", "simctl", "push", SIMULATOR, BUNDLE, payload.name], capture_output=True, text=True)
    os.unlink(payload.name)
    if done.returncode != 0:
        sys.stderr.write(f"simctl push failed: {done.stderr.strip()}\n")
        sys.stderr.flush()


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()

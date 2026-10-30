"""Restarts the lab's Dashboard when a test asks, for the checks of a Dashboard with no sign-in
(`lab.sh open`): a restart gives Hermes a new session token, which the app has to read again.
The app's test runs in the simulator, which shares this Mac's loopback, and asks here:

    POST /restart?as=serve      `hermes serve` again (the headless backend, its token-only page)
    POST /restart?as=dashboard  `hermes dashboard`, the whole Dashboard page (a stand-in page from
                                `HERMES_WEB_DIST`: the lab installs no web build)
    POST /restart?as=gated      `hermes serve` with a public address and a login, so it asks for one

The answer comes once the new one answers its status (or says why not). Only the process listening
on the lab's Dashboard port is stopped, and only when it is a Hermes. Every one started is written
to $LAB_HOME/pids, which `lab.sh down` stops.

usage: restart_dashboard.py <port> <hermes> <run folder>
"""
import json
import os
import signal
import subprocess
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT, HERMES, RUN = int(sys.argv[1]), sys.argv[2], sys.argv[3]
DASHBOARD = 19119
PIDS = os.path.join(os.environ.get("LAB_HOME", os.path.expanduser("~/.cache/redde-hermes-lab")), "pids")
PAGE = "<!doctype html><html><head><meta charset=\"UTF-8\"><title>Hermes (lab stand-in)</title></head><body><div id=\"root\"></div></body></html>"


def listening():
    found = subprocess.run(["lsof", "-ti", f"tcp:{DASHBOARD}", "-sTCP:LISTEN"], capture_output=True, text=True).stdout.split()
    pids = []
    for pid in found:
        command = subprocess.run(["ps", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        if "hermes" in command:
            pids.append(int(pid))
    return pids


def status():
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{DASHBOARD}/api/status", timeout=2) as answer:
            return json.load(answer)
    except Exception:
        return None


def restart(kind):
    for pid in listening():
        os.kill(pid, signal.SIGTERM)
    for _ in range(40):
        if not listening():
            break
        time.sleep(0.25)
    for pid in listening():
        os.kill(pid, signal.SIGKILL)
    env = dict(os.environ)
    for name in ("HERMES_DASHBOARD_PUBLIC_URL", "HERMES_DASHBOARD_BASIC_AUTH_USERNAME", "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD",
                 "HERMES_DASHBOARD_BASIC_AUTH_SECRET", "HERMES_SERVE_HEADLESS", "HERMES_WEB_DIST"):
        env.pop(name, None)
    command = [HERMES, "serve", "--host", "127.0.0.1", "--port", str(DASHBOARD), "--skip-build"]
    if kind == "dashboard":
        dist = os.path.join(RUN, "web-dist")
        os.makedirs(dist, exist_ok=True)
        with open(os.path.join(dist, "index.html"), "w") as page:
            page.write(PAGE)
        env["HERMES_WEB_DIST"] = dist
        command = [HERMES, "dashboard", "--host", "127.0.0.1", "--port", str(DASHBOARD), "--skip-build", "--no-open", "--isolated"]
    elif kind == "gated":
        env.update(HERMES_DASHBOARD_PUBLIC_URL="http://redde-lab.test:19119", HERMES_DASHBOARD_BASIC_AUTH_USERNAME="lab",
                   HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="labpass-labpass",
                   HERMES_DASHBOARD_BASIC_AUTH_SECRET="0123456789abcdef0123456789abcdef0123456789abcdef")
    log = open(os.path.join(RUN, f"{kind}.log"), "a")
    process = subprocess.Popen(command, cwd=RUN, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    with open(PIDS, "a") as pids:
        pids.write(f"{process.pid}\n")
    for _ in range(240):
        said = status()
        if said is not None:
            return {"ok": True, "as": kind, "pid": process.pid, "auth_required": said.get("auth_required")}
        if process.poll() is not None:
            return {"ok": False, "as": kind, "why": f"it exited with {process.returncode}; see {log.name}"}
        time.sleep(0.5)
    return {"ok": False, "as": kind, "why": "no status in two minutes"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        url = urlparse(self.path)
        kind = parse_qs(url.query).get("as", ["serve"])[0]
        said = restart(kind) if url.path == "/restart" and kind in ("serve", "dashboard", "gated") else {"ok": False, "why": "no such thing"}
        body = json.dumps(said).encode()
        self.send_response(200 if said.get("ok") else 500)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

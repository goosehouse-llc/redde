"""Do pictures cross devices? (GitHub issue 18.) What Redde sends with a picture, and what Hermes
keeps of it for every other client:

  Dashboard        image.attach_bytes (a JPEG with a .jpg name) and prompt.submit, as
                   HermesServeTransport sends a picture: the session keeps "@image:<path on the
                   server>", and the Dashboard's file reader gives the picture back from that path
                   (how Redde shows it, and Hermes Desktop on another machine).
  Dashboard, HEIC  the same with the name a shared photo had before (IMG_0412.HEIC): refused,
                   which is why Redde names the JPEG it makes .jpg.
  API              a run with the picture inline, as before: the session keeps "[screenshot]".
  API, named       the picture put on the server first (POST /api/chat/image-upload, through the
                   Dashboard's login) and named on a line of the message, as
                   Conversation.namingPictures does: the session keeps the line, and the file
                   reader gives the picture back.

Run against a lab that is up with the approval scenario (lab.sh pictures does both).
"""
import asyncio
import base64
import io
import json
import sys
import time
import urllib.parse

import check
from check import Dashboard, api, api_session, report
from status_check import new, rest, rest_opener

ASK = "What's this bird?"


def jpeg():
    """A small real JPEG: the model's side may open it."""
    try:
        from PIL import Image
        out = io.BytesIO()
        Image.new("RGB", (16, 16), (200, 80, 40)).save(out, "JPEG")
        return out.getvalue()
    except ImportError:
        # 1×1, made by Pillow once.
        return base64.b64decode("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==")


PICTURE = jpeg()
DATA_URL = "data:image/jpeg;base64," + base64.b64encode(PICTURE).decode()


def readable(opener, path):
    """Whether the Dashboard's file reader gives back a picture from that path, as Redde asks it."""
    try:
        got = rest(opener, "GET", "/api/fs/read-data-url?path=" + urllib.parse.quote(path, safe=""))
        return str(got.get("dataUrl", "")).startswith("data:image/")
    except Exception as error:
        print(f"    (read-data-url {path}: {error})")
        return False


async def finished(dash, sid, seconds=60):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            event = await asyncio.wait_for(dash.events.get(), 1)
        except asyncio.TimeoutError:
            continue
        if event.get("session_id") == sid and event.get("type") in ("message.complete", "error"):
            return
    print("    (the turn didn't finish; looking at what was kept anyway)")


def user_rows(messages):
    return [str(m.get("content") or m.get("text") or "") for m in messages if m.get("role") == "user"]


async def dashboard(opener):
    dash = await Dashboard.connect()
    runtime, stored = await new(dash)
    attached = await dash.call("image.attach_bytes", {"session_id": runtime, "content_base64": base64.b64encode(PICTURE).decode(),
                                                      "filename": "IMG_0412.jpg"})
    path = attached.get("path") or ""
    await dash.call("prompt.submit", {"session_id": runtime, "text": ASK})
    await finished(dash, runtime)
    await asyncio.sleep(1)
    resumed = await dash.call("session.resume", {"session_id": stored, "omit_messages": False})
    rows = user_rows(resumed.get("messages") or [])
    try:
        await dash.call("image.attach_bytes", {"session_id": runtime, "content_base64": base64.b64encode(PICTURE).decode(),
                                               "filename": "IMG_0412.HEIC"})
        heic = "taken"
    except RuntimeError as error:
        heic = f"refused: {error}"
    await dash.ws.close()
    return path, rows, heic


def api_run(text):
    """A run as HermesSessionsTransport sends one: the text and the picture inline."""
    sid = api_session()
    content = [{"type": "text", "text": text}, {"type": "image_url", "image_url": {"url": DATA_URL}}]
    status, body = api("POST", "/v1/runs", {"input": [{"role": "user", "content": content}], "session_id": sid})
    if status >= 300:
        return [f"HTTP {status} {body[:160]}"]
    run = json.loads(body)["run_id"]
    deadline = time.time() + 90
    while time.time() < deadline:
        state = json.loads(api("GET", f"/v1/runs/{run}")[1])
        if state.get("status") in ("completed", "failed", "cancelled", "interrupted"):
            break
        time.sleep(0.5)
    status, body = api("GET", f"/api/sessions/{sid}/messages")
    rows = (json.loads(body).get("data") or json.loads(body).get("messages") or []) if status < 300 else []
    return user_rows(rows)


async def main():
    print("Pictures across devices")
    opener = rest_opener()
    path, rows, heic = await dashboard(opener)
    kept = next((r for r in rows if ASK in r), "")
    report(bool(path) and f"@image:{path}" in kept, "Dashboard: the session names the picture on the server",
           f"attached at {path!r}, kept {kept!r}")
    report(bool(path) and readable(opener, path), "Dashboard: the file reader gives it back", path)
    report(heic.startswith("refused"), "Dashboard: a .heic name is refused (Redde names its JPEGs .jpg)", heic)

    rows = api_run(ASK)
    print(f"  (info) API, inline only: kept {rows}")

    uploaded = rest(opener, "POST", "/api/chat/image-upload", {"data_url": DATA_URL, "filename": "IMG_0412.jpg"})
    server_path = uploaded.get("path") or ""
    line = "@image:" + server_path
    rows = api_run(ASK + "\n" + line)
    kept = next((r for r in rows if ASK in r), "")
    report(bool(server_path) and kept == f"{ASK}\n{line}\n[screenshot]", "API, named: the session keeps the line naming it",
           f"uploaded to {server_path!r}, kept {kept!r}")
    report(bool(server_path) and readable(opener, server_path), "API, named: the file reader gives it back", server_path)


if __name__ == "__main__":
    asyncio.run(main())
    sys.exit(1 if check.failures else 0)

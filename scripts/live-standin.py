#!/usr/bin/env python3
"""A stand-in for OpenAI's GPT-Live sessions, to try Redde's GPT-Live calls (LiveVoice) end to end
with no OpenAI key and no bill: it answers the phone's WebRTC offer as POST /v1/live/sessions
does, says on the `oai-events` channel what the voice model would, plays a tone while its voice
"speaks", hands one request to the agent, says back what the phone sends for it, and logs every
event the phone sends, with the time since the call started.

    python3 -m venv /tmp/live-lab && /tmp/live-lab/bin/pip install aiortc aiohttp
    /tmp/live-lab/bin/python scripts/live-standin.py [--port 8790] [--log live-events.jsonl]

Then launch Redde with `-voiceEngine gptLive -echo.liveEndpoint http://<this Mac>:8790/v1/live/sessions`
(DEBUG builds only), on a connection whose agent can answer. This answers as one too, an
OpenAI-compatible model on the same port, so a phone needn't ask the real agent anything:
`-transport chatCompletions -fastLaneURL http://<this Mac>:8790 -fastLaneModel stand-in`.

The script per call: the person asks "What's next on my calendar?", the voice says "Let me
check." and hands the request over; every `session.commentary.append` that comes back is spoken
(a tone as long as the text) and echoed as the voice's transcript. `--say "words"` changes the
question; `--stop [seconds]` has the person say "goodbye" that long (10) after the answer, which
should end the call from the phone; `--no-handover` hands nothing to the agent (a call to
measure, with `-echo.liveMeasure`).
"""
import argparse
import asyncio
import fractions
import json
import math
import time
from array import array

from aiohttp import web
from aiortc import MediaStreamTrack, RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from av import AudioFrame

RATE = 48_000
FRAME = 960  # 20 ms


class Voice(MediaStreamTrack):
    """The voice model's audio: silence, or a speech-like tone while it "speaks"."""

    kind = "audio"

    def __init__(self):
        super().__init__()
        self.pts = 0
        self.start = None
        self.until = 0.0

    def speak(self, seconds):
        self.until = max(self.until, time.time()) + seconds

    async def recv(self):
        if self.start is None:
            self.start = time.time()
        wait = self.start + self.pts / RATE - time.time()
        if wait > 0:
            await asyncio.sleep(wait)
        if time.time() < self.until:
            # 180 Hz under a 4 Hz swell, like syllables: loud enough for an audio level of ~0.2.
            samples = array("h", (int(4000 * (0.55 + 0.45 * math.sin(2 * math.pi * 4 * (self.pts + i) / RATE))
                                      * math.sin(2 * math.pi * 180 * (self.pts + i) / RATE)) for i in range(FRAME)))
        else:
            samples = array("h", bytes(FRAME * 2))
        frame = AudioFrame(format="s16", layout="mono", samples=FRAME)
        frame.planes[0].update(samples.tobytes())
        frame.pts = self.pts
        frame.sample_rate = RATE
        frame.time_base = fractions.Fraction(1, RATE)
        self.pts += FRAME
        return frame


class Call:
    def __init__(self, args, log):
        self.args = args
        self.log = log
        # Host addresses only, as OpenAI's own servers need no more.
        self.peer = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        self.voice = Voice()
        self.channel = None
        self.started = time.time()
        self.clock_ms = 0
        self.peer.addTrack(self.voice)
        self.peer.on("datachannel", self.opened)

    def note(self, direction, event):
        line = {"t": round(time.time() - self.started, 3), "dir": direction, **event}
        print(json.dumps(line), flush=True)
        if self.log:
            with open(self.log, "a") as f:
                f.write(json.dumps(line) + "\n")

    def send(self, event):
        if self.channel and self.channel.readyState == "open":
            self.channel.send(json.dumps(event))
            self.note("out", event)

    def transcript(self, kind, text):
        """As the service sends it: in pieces, with times."""
        words = text.split(" ")
        for i in range(0, len(words), 3):
            piece = " ".join(words[i:i + 3]) + (" " if i + 3 < len(words) else "")
            self.send({"type": f"session.{kind}_transcript.delta", "delta": piece,
                       "start_ms": self.clock_ms, "end_ms": self.clock_ms + 300})
            self.clock_ms += 300

    def say(self, text):
        self.transcript("output", text)
        self.voice.speak(min(8.0, 0.06 * len(text)))

    def opened(self, channel):
        self.channel = channel
        channel.on("message", self.heard)
        asyncio.ensure_future(self.script())

    def heard(self, message):
        try:
            event = json.loads(message)
        except ValueError:
            return
        self.note("in", event)
        kind = event.get("type")
        if kind == "session.commentary.append":
            self.say(event.get("content", ""))
            if self.args.stop and not getattr(self, "stopping", False):
                self.stopping = True
                asyncio.ensure_future(self.goodbye())
        elif kind == "session.close":
            self.send({"type": "session.closed", "reason": "close_requested",
                       "usage": {"seconds": round(time.time() - self.started, 1)}})
            asyncio.ensure_future(self.peer.close())

    async def goodbye(self):
        await asyncio.sleep(self.args.stop)
        self.transcript("input", "Goodbye.")

    async def script(self):
        self.send({"type": "session.started", "session": {"id": "stand-in"}})
        await asyncio.sleep(1.5)
        self.transcript("input", self.args.say)
        await asyncio.sleep(1.0)
        self.say("Let me check.")
        await asyncio.sleep(1.2)
        if self.args.no_handover:
            if self.args.stop:
                asyncio.ensure_future(self.goodbye())
            return
        self.send({"type": "session.delegation.created", "delegation": {"id": "d1", "type": "client", "target": "backend"}})


AGENT = ["Your next meeting is at 4 pm, ", "with Ana, in the Garden room. ", "After that ", "your evening is free."]


async def agent(request):
    """The agent's answer to a handed-over request, streamed as an OpenAI-compatible model does."""
    body = await request.json()
    system = " ".join(m["content"] for m in body.get("messages", []) if m.get("role") == "system" and isinstance(m.get("content"), str))
    print(json.dumps({"agent": "asked", "live_note": "live spoken conversation" in system,
                      "question": body["messages"][-1]["content"]}), flush=True)
    response = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
    await response.prepare(request)
    await asyncio.sleep(0.8)
    for piece in AGENT:
        chunk = {"choices": [{"index": 0, "delta": {"content": piece}}]}
        await response.write(f"data: {json.dumps(chunk)}\n\n".encode())
        await asyncio.sleep(0.15)
    await response.write(b"data: [DONE]\n\n")
    return response


async def sessions(request):
    body = await request.json()
    offer = body["transport"]["sdp"]
    call = Call(request.app["args"], request.app["args"].log)
    session = body.get("session", {})
    call.note("in", {"type": "POST /v1/live/sessions", "model": session.get("model"),
                     "voice": session.get("audio", {}).get("output", {}).get("voice"),
                     "delegation": session.get("delegation"), "history": len(session.get("input", [])),
                     "offer_bytes": len(offer), "offer_ends_crlf": offer.endswith("\r\n")})

    @call.peer.on("connectionstatechange")
    async def changed():
        call.note("state", {"connection": call.peer.connectionState})

    await call.peer.setRemoteDescription(RTCSessionDescription(sdp=offer, type="offer"))
    await call.peer.setLocalDescription(await call.peer.createAnswer())
    request.app["calls"].append(call)
    return web.json_response({"session": {"id": "stand-in"},
                              "transport": {"type": "webrtc", "sdp": call.peer.localDescription.sdp}})


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--port", type=int, default=8790)
    parser.add_argument("--log")
    parser.add_argument("--say", default="What's next on my calendar?")
    parser.add_argument("--stop", type=float, nargs="?", const=10.0, default=None)
    parser.add_argument("--no-handover", action="store_true", help="talk without handing anything to the agent")
    args = parser.parse_args()
    app = web.Application()
    app["args"] = args
    app["calls"] = []
    app.router.add_post("/v1/live/sessions", sessions)
    app.router.add_post("/v1/chat/completions", agent)
    web.run_app(app, host="0.0.0.0", port=args.port, print=lambda *_: print(f"stand-in on :{args.port}", flush=True))


if __name__ == "__main__":
    main()

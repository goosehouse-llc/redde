#!/usr/bin/env python3
"""A stand-in for OpenAI's GPT-Live WebSocket (`wss://api.openai.com/v1/live/sessions`), to try
Redde's GPT-Live calls (LiveVoice, LiveCall) end to end with no OpenAI key and no bill: it takes the
phone's `session.start`, says what the voice model would, sends a tone as PCM16 (at the rate the
phone asked for) while its voice "speaks", hands one request to the agent, says back what the phone
sends for it, and logs every event the phone sends (its audio summed up once a second), with the
time since the call started.

    python3 -m venv /tmp/live-lab && /tmp/live-lab/bin/pip install aiohttp
    /tmp/live-lab/bin/python scripts/live-standin.py [--port 8790] [--log live-events.jsonl]

Then launch Redde with `-voiceEngine gptLive -echo.liveEndpoint ws://<this Mac>:8790/v1/live/sessions`
(DEBUG builds only), on a connection whose agent can answer. This answers as one too, an
OpenAI-compatible model on the same port, so a phone needn't ask the real agent anything:
`-transport chatCompletions -fastLaneURL http://<this Mac>:8790 -fastLaneModel stand-in`.

The script per call: the person asks "What's next on my calendar?", the voice says "Let me
check." and hands the request over; every `session.commentary.append` that comes back is spoken
(a tone as long as the text) and echoed as the voice's transcript. `--say "words"` changes the
question; `--stop [seconds]` has the person say "goodbye" that long (10) after the answer, which
should end the call from the phone; `--no-handover` hands nothing to the agent (a call to
measure, with `-echo.liveMeasure`); `--stream` sends the voice's audio all the while, silence
included, as OpenAI does (the voice went unheard on the phone only that way), `--chunk-ms` in
pieces of that length. Until 2026-10-24 Redde's calls went over WebRTC, and this
answered those too (git history).
"""
import argparse
import asyncio
import base64
import json
import math
import time
from array import array

from aiohttp import WSMsgType, web


class Script:
    """What the voice model says and does in a call, whatever carries it."""

    def __init__(self, args, log):
        self.args = args
        self.log = log
        self.started = time.time()
        self.clock_ms = 0

    def note(self, direction, event):
        line = {"t": round(time.time() - self.started, 3), "dir": direction, **event}
        print(json.dumps(line), flush=True)
        if self.log:
            with open(self.log, "a") as f:
                f.write(json.dumps(line) + "\n")

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
        self.speak(min(8.0, 0.06 * len(text)))

    def answered(self, text):
        """The agent's answer to say; the person's goodbye after it, with `--stop`."""
        self.say(text)
        if self.args.stop and not getattr(self, "stopping", False):
            self.stopping = True
            asyncio.ensure_future(self.goodbye())

    def heard(self, message):
        try:
            event = json.loads(message)
        except ValueError:
            return
        self.note("in", event)
        self.handle(event)

    def handle(self, event):
        kind = event.get("type")
        # As OpenAI does: an append names the delegation it belongs to, null included.
        if kind in ("session.commentary.append", "session.thinking.append", "session.instructions.append") and "delegation_id" not in event:
            self.send({"type": "error", "error": {"type": "invalid_request_error", "message": "missing required parameter 'delegation_id'"}})
            return
        if kind == "session.commentary.append":
            self.say(event.get("content", ""))
            if self.args.stop and not getattr(self, "stopping", False):
                self.stopping = True
                asyncio.ensure_future(self.goodbye())
        elif kind == "session.close":
            self.send({"type": "session.closed", "reason": "close_requested",
                       "usage": {"seconds": round(time.time() - self.started, 1)}})
            asyncio.ensure_future(self.hang_up())

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


class SocketCall(Script):
    """Everything JSON, the voice as 100 ms of PCM16 at a time at the rate the phone asked for,
    sent as it would be heard (in real time); the phone's audio counted, not logged. It answers
    whichever wire the phone opens with: GPT-Live's `session.start`, Gemini Live's `setup`, or
    Grok Voice's `session.update` (`self.wire`); the script is written in GPT-Live's events and
    put into the others' here (`worded`)."""

    def __init__(self, args, log, ws):
        super().__init__(args, log)
        self.ws = ws
        self.wire = "gpt"
        self.RATE = 24_000
        self.CHUNK = 2_400
        self.until = 0.0
        self.pts = 0
        self.heard_bytes = 0
        self.heard_chunks = 0
        self.output = None

    def send(self, event):
        if not self.ws.closed:
            for message in self.worded(event):
                asyncio.ensure_future(self.ws.send_str(json.dumps(message)))
            if event.get("type") != "session.output_audio.delta":
                self.note("out", event)

    def worded(self, event):
        """A GPT-Live event as the wire in use has it."""
        kind = event.get("type")
        if self.wire == "gpt":
            return [event]
        if self.wire == "gemini":
            if kind == "session.started":
                return [{"setupComplete": {}}]
            if kind == "session.input_transcript.delta":
                return [{"serverContent": {"inputTranscription": {"text": event["delta"]}}}]
            if kind == "session.output_transcript.delta":
                return [{"serverContent": {"outputTranscription": {"text": event["delta"]}}}]
            if kind == "session.delegation.created":
                return [{"toolCall": {"functionCalls": [{"id": event["delegation"]["id"], "name": "ask_agent", "args": {"request": self.args.say}}]}}]
            if kind == "session.output_audio.delta":
                return [{"serverContent": {"modelTurn": {"parts": [{"inlineData": {"mimeType": f"audio/pcm;rate={self.RATE}", "data": event["delta"]}}]}}}]
            return []
        if self.wire == "eleven":
            self.events = getattr(self, "events", 0) + 1
            if kind == "session.started":
                return [{"type": "conversation_initiation_metadata", "conversation_initiation_metadata_event": {
                    "conversation_id": "stand-in", "agent_output_audio_format": f"pcm_{self.RATE}", "user_input_audio_format": "pcm_16000"}}]
            if kind == "session.input_transcript.delta":
                return [{"type": "user_transcript", "user_transcription_event": {"user_transcript": event["delta"]}}]
            if kind == "session.output_transcript.delta":
                return [{"type": "agent_response", "agent_response_event": {"agent_response": event["delta"]}}]
            if kind == "session.delegation.created":
                return [{"type": "client_tool_call", "client_tool_call": {"tool_name": "ask_agent", "tool_call_id": event["delegation"]["id"],
                                                                          "parameters": {"request": self.args.say}, "event_id": self.events}}]
            if kind == "session.output_audio.delta":
                return [{"type": "audio", "audio_event": {"audio_base_64": event["delta"], "event_id": self.events}}]
            return []
        if kind == "session.started":
            return [{"type": "session.updated", "session": {}}]
        if kind == "session.input_transcript.delta":
            return [{"type": "conversation.item.input_audio_transcription.completed", "item_id": "i1", "transcript": event["delta"]}]
        if kind == "session.output_transcript.delta":
            return [{"type": "response.output_audio_transcript.delta", "delta": event["delta"]}]
        if kind == "session.delegation.created":
            return [{"type": "response.function_call_arguments.done", "call_id": event["delegation"]["id"], "name": "ask_agent",
                     "arguments": json.dumps({"request": self.args.say})}]
        if kind == "session.output_audio.delta":
            return [{"type": "response.output_audio.delta", "delta": event["delta"]}]
        if kind == "error":
            return [event]
        return []

    def speak(self, seconds):
        self.until = max(self.until, time.time()) + seconds

    async def pump(self):
        """The voice's audio while it speaks, a chunk every 100 ms; and once a second, how much
        of the phone's audio has come."""
        tick = time.time()
        last_report = tick
        while not self.ws.closed:
            tick += self.CHUNK / self.RATE
            await asyncio.sleep(max(0, tick - time.time()))
            speaking = time.time() < self.until
            if speaking or self.args.stream:
                samples = array("h", (int(4000 * (0.55 + 0.45 * math.sin(2 * math.pi * 4 * (self.pts + i) / self.RATE))
                                          * math.sin(2 * math.pi * 180 * (self.pts + i) / self.RATE)) for i in range(self.CHUNK))) if speaking \
                    else array("h", bytes(2 * self.CHUNK))
                start = self.pts * 1000 // self.RATE
                self.pts += self.CHUNK
                for message in self.worded({"type": "session.output_audio.delta", "delta": base64.b64encode(samples.tobytes()).decode(),
                                             "start_ms": start, "end_ms": self.pts * 1000 // self.RATE}):
                    await self.ws.send_str(json.dumps(message))
            if time.time() - last_report >= 1:
                last_report = time.time()
                if self.heard_chunks:
                    self.note("in", {"type": "session.input_audio.append (summary)", "chunks": self.heard_chunks,
                                     "ms": round(self.heard_bytes / 2 / self.RATE * 1000)})
                    self.heard_bytes = self.heard_chunks = 0

    def begin(self, rate):
        self.RATE = rate
        self.CHUNK = self.RATE * self.args.chunk_ms // 1000
        asyncio.ensure_future(self.script())
        asyncio.ensure_future(self.pump())

    def handle(self, event):
        kind = event.get("type")
        if kind == "session.start":
            session = event.get("session", {})
            self.note("in", {"type": "session.start", "rate": session.get("audio", {}).get("format", {}).get("rate"), "model": session.get("model"),
                             "voice": session.get("audio", {}).get("output", {}).get("voice"),
                             "delegation": session.get("delegation"), "history": len(session.get("input", []))})
            self.begin(session.get("audio", {}).get("format", {}).get("rate", 24_000))
        elif "setup" in event:
            # Gemini Live: 16 kHz in, 24 kHz out; the agent a function.
            self.wire = "gemini"
            setup = event["setup"]
            self.note("in", {"type": "setup", "model": setup.get("model"),
                             "voice": setup.get("generationConfig", {}).get("speechConfig", {}).get("voiceConfig", {}).get("prebuiltVoiceConfig", {}).get("voiceName"),
                             "tools": [f.get("name") for t in setup.get("tools", []) for f in t.get("functionDeclarations", [])]})
            self.begin(24_000)
        elif kind == "conversation_initiation_client_data":
            # ElevenLabs: its agent's audio formats (24 kHz out); a first line said at once.
            self.wire = "eleven"
            override = event.get("conversation_config_override", {})
            self.note("in", {"type": kind, "voice": override.get("tts", {}).get("voice_id"),
                             "first_message": override.get("agent", {}).get("first_message")})
            self.begin(24_000)
            first = override.get("agent", {}).get("first_message")
            if first:
                self.say(first)
        elif self.wire == "eleven":
            if kind == "client_tool_result":
                self.answered(event.get("result", ""))
            elif kind == "user_message":
                self.say(event.get("text", ""))
        elif kind == "session.update" and self.wire != "grok":
            # Grok Voice: its output at the rate asked for; the agent a function.
            self.wire = "grok"
            session = event.get("session", {})
            self.note("in", {"type": "session.update", "voice": session.get("voice"), "tools": [t.get("name") for t in session.get("tools", [])]})
            self.begin(session.get("audio", {}).get("output", {}).get("format", {}).get("rate", 24_000))
        elif self.wire == "gemini":
            if "toolResponse" in event:
                for response in event["toolResponse"].get("functionResponses", []):
                    self.answered(str(response.get("response", {}).get("result", "")))
            elif "clientContent" in event and event["clientContent"].get("turnComplete"):
                turns = event["clientContent"].get("turns", [])
                if turns and turns[-1].get("role") == "user":
                    self.say(" ".join(p.get("text", "") for p in turns[-1].get("parts", [])))
        elif self.wire == "grok":
            item = event.get("item", {})
            if kind == "conversation.item.create" and item.get("type") == "function_call_output":
                self.output = item.get("output", "")
            elif kind == "conversation.item.create" and item.get("type") == "force_message":
                self.say(" ".join(c.get("text", "") for c in item.get("content", [])))
            elif kind == "conversation.item.create" and item.get("type") == "message":
                self.output = "Still working on it."
            elif kind == "response.create" and self.output is not None:
                (self.say if self.output == "Still working on it." else self.answered)(self.output)
                self.output = None
        else:
            super().handle(event)

    def heard(self, message):
        if '"user_audio_chunk"' in message:
            try:
                self.heard_bytes += len(base64.b64decode(json.loads(message).get("user_audio_chunk", "")))
                self.heard_chunks += 1
            except ValueError:
                pass
            return
        if '"session.input_audio.append"' in message or '"input_audio_buffer.append"' in message or '"realtimeInput"' in message and '"audio"' in message:
            try:
                event = json.loads(message)
                audio = event.get("audio") or event.get("realtimeInput", {}).get("audio", {})
                self.heard_bytes += len(base64.b64decode(audio.get("data", "") if isinstance(audio, dict) else audio))
                self.heard_chunks += 1
            except ValueError:
                pass
            return
        super().heard(message)

    async def hang_up(self):
        await asyncio.sleep(0.2)
        await self.ws.close()


async def socket_sessions(request):
    ws = web.WebSocketResponse(max_msg_size=8 << 20)
    await ws.prepare(request)
    call = SocketCall(request.app["args"], request.app["args"].log, ws)
    call.note("in", {"type": "GET /v1/live/sessions (WebSocket)", "authorization": "Bearer" in request.headers.get("Authorization", "")})
    async for message in ws:
        if message.type == WSMsgType.TEXT:
            call.heard(message.data)
    call.note("state", {"socket": "closed"})
    return ws


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


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--port", type=int, default=8790)
    parser.add_argument("--log")
    parser.add_argument("--say", default="What's next on my calendar?")
    parser.add_argument("--stop", type=float, nargs="?", const=10.0, default=None)
    parser.add_argument("--no-handover", action="store_true", help="talk without handing anything to the agent")
    parser.add_argument("--stream", action="store_true", help="send the voice's audio all the while, silence included, as OpenAI does")
    parser.add_argument("--chunk-ms", type=int, default=100, help="the voice's audio this many ms at a time")
    args = parser.parse_args()
    app = web.Application()
    app["args"] = args
    app["calls"] = []
    app.router.add_get("/v1/live/sessions", socket_sessions)
    app.router.add_post("/v1/chat/completions", agent)
    web.run_app(app, host="0.0.0.0", port=args.port, print=lambda *_: print(f"stand-in on :{args.port}", flush=True))


if __name__ == "__main__":
    main()

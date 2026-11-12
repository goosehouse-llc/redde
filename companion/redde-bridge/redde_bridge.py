#!/usr/bin/env python3
"""Redde bridge: ACP agents (Claude Code, Codex, Gemini CLI, Goose, Hermes, …) for Redde.

ACP (the Agent Client Protocol) runs over stdio: an editor starts the agent as its child. A phone
can't, so this runs on the machine with the agents. It starts each one when it is first wanted,
keeps it, and serves it to Redde over a WebSocket (one JSON-RPC message per text frame, the ACP
remote transport RFD's WebSocket profile), with what a phone needs and ACP leaves out:

- several devices on one session, each hearing its updates;
- a turn that goes on when the phone locks, and `_redde/attach` to catch up on it;
- approvals any device can answer, the first answer taken;
- a session loaded again quietly before it is used after a restart;
- the working folder filled in when the phone names none;
- notifications when Redde is closed (a reply, an approval, a failed turn), through Redde's relay,
  sealed so the relay can't read them (`redde_push.py`, `_redde/push`).

Standard library only, Python 3.11 or later. See README.md and docs/acp.md.

    python3 redde_bridge.py                 # serve (writes a config and a token the first time)
    python3 redde_bridge.py --print-setup   # what to type into Redde
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import hmac
import json
import logging
import os
import secrets
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import time
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import redde_push  # noqa: E402  (beside this file)

VERSION = "0.4.0"
PROTOCOL_VERSION = 1
DEFAULT_CONFIG = Path(os.environ.get("REDDE_BRIDGE_CONFIG", "~/.config/redde-bridge/config.toml")).expanduser()
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_MESSAGE = 64 * 1024 * 1024        # a prompt with photos, a long history replayed
PING_EVERY = 20.0
LOG_LIMIT = 4000                      # updates kept per session for catch-up (one turn's worth)
BUSY = -32002                         # ACP's "resource not found" range; used here for "busy"

log = logging.getLogger("redde-bridge")


# MARK: - Config

@dataclass
class AgentConfig:
    id: str
    name: str
    command: list[str]
    cwd: str = "~"
    env: dict[str, str] = field(default_factory=dict)

    @property
    def folder(self) -> str:
        return str(Path(self.cwd).expanduser())


@dataclass
class Config:
    listen: str
    token: str
    agents: list[AgentConfig]
    tls_cert: str | None = None
    tls_key: str | None = None
    #: Where the paired devices are kept (`push.json` beside the config), and the relay notes go through.
    push_path: Path | None = None
    push_relay: str = redde_push.DEFAULT_RELAY

    @property
    def host_port(self) -> tuple[str, int]:
        host, _, port = self.listen.rpartition(":")
        return host or "0.0.0.0", int(port)


def first_config() -> str:
    """The config written on first run: a fresh token, and the agents found on this machine."""
    token = secrets.token_urlsafe(32)
    lines = [
        "# Redde bridge. Redde connects to ws://<this machine>:8765 with the token below.",
        "# Each [agents.<id>] is a command that speaks ACP over stdio.",
        'listen = "0.0.0.0:8765"',
        f'token = "{token}"',
        '# tls_cert = "/path/to/cert.pem"',
        '# tls_key = "/path/to/key.pem"',
        "",
    ]
    known = [
        ("hermes", "Hermes", ["hermes", "acp"], "hermes", "~"),
        ("claude", "Claude Code", ["npx", "-y", "@agentclientprotocol/claude-agent-acp"], "npx", "~"),
        ("codex", "Codex", ["npx", "-y", "@agentclientprotocol/codex-acp"], "codex", "~"),
        ("gemini", "Gemini CLI", ["gemini", "--acp"], "gemini", "~"),
        ("goose", "Goose", ["goose", "acp"], "goose", "~"),
    ]
    for ident, name, command, needs, cwd in known:
        found = shutil.which(needs) is not None
        # Claude Code through npx only where Claude Code itself is installed: npx alone says nothing.
        if ident == "claude":
            found = found and shutil.which("claude") is not None
        prefix = "" if found else "# "
        lines += [f"{prefix}[agents.{ident}]", f'{prefix}name = "{name}"',
                  f"{prefix}command = {json.dumps(command)}", f'{prefix}cwd = "{cwd}"', ""]
    return "\n".join(lines)


def load_config(path: Path) -> Config:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(first_config())
        path.chmod(0o600)
        log.info("wrote %s with a new token", path)
    raw = tomllib.loads(path.read_text())
    agents = [AgentConfig(id=ident, name=a.get("name", ident), command=list(a["command"]),
                          cwd=a.get("cwd", "~"), env=dict(a.get("env", {})))
              for ident, a in (raw.get("agents") or {}).items()]
    if not raw.get("token"):
        raise SystemExit(f"{path}: no token")
    return Config(listen=raw.get("listen", "0.0.0.0:8765"), token=raw["token"], agents=agents,
                  tls_cert=raw.get("tls_cert"), tls_key=raw.get("tls_key"),
                  push_path=path.parent / "push.json", push_relay=raw.get("push_relay", redde_push.DEFAULT_RELAY))


# MARK: - WebSocket (RFC 6455, server side)

class Closed(Exception):
    pass


class WebSocket:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.reader, self.writer = reader, writer
        self.closed = False
        self.last_heard = time.monotonic()

    async def receive(self) -> str:
        """The next text message, whole. Pings are answered, pongs noted, a close ends it."""
        parts: list[bytes] = []
        size = 0
        while True:
            head = await self.reader.readexactly(2)
            fin, opcode = head[0] & 0x80, head[0] & 0x0F
            masked, length = head[1] & 0x80, head[1] & 0x7F
            if length == 126:
                length = struct.unpack("!H", await self.reader.readexactly(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", await self.reader.readexactly(8))[0]
            if size + length > MAX_MESSAGE:
                await self.close(1009)
                raise Closed("message too big")
            mask = await self.reader.readexactly(4) if masked else b""
            data = await self.reader.readexactly(length)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data)) if length < 4096 else _unmask(data, mask)
            self.last_heard = time.monotonic()
            if opcode == 0x8:
                await self.close()
                raise Closed("closed by peer")
            if opcode == 0x9:
                await self._send(0xA, data)
                continue
            if opcode == 0xA:
                continue
            if opcode in (0x1, 0x2, 0x0):
                parts.append(data)
                size += length
                if fin:
                    return b"".join(parts).decode("utf-8", errors="replace")

    async def send(self, text: str) -> None:
        await self._send(0x1, text.encode())

    async def ping(self) -> None:
        await self._send(0x9, b"redde")

    async def _send(self, opcode: int, payload: bytes) -> None:
        if self.closed:
            return
        n = len(payload)
        if n < 126:
            head = struct.pack("!BB", 0x80 | opcode, n)
        elif n < 65536:
            head = struct.pack("!BBH", 0x80 | opcode, 126, n)
        else:
            head = struct.pack("!BBQ", 0x80 | opcode, 127, n)
        try:
            self.writer.write(head + payload)
            await self.writer.drain()
        except (ConnectionError, RuntimeError) as error:
            self.closed = True
            raise Closed(str(error)) from error

    async def close(self, code: int = 1000) -> None:
        if self.closed:
            return
        try:
            await self._send(0x8, struct.pack("!H", code))
        except Closed:
            pass
        self.closed = True
        self.writer.close()


def _unmask(data: bytes, mask: bytes) -> bytes:
    """XOR a long payload with its mask, a machine word at a time rather than a byte."""
    n = len(data)
    key = int.from_bytes((mask * ((n // 4) + 1))[:n], "big")
    return (int.from_bytes(data, "big") ^ key).to_bytes(n, "big")


# MARK: - One agent process

class AgentError(Exception):
    def __init__(self, error: dict):
        super().__init__(error.get("message", "agent error"))
        self.error = error


@dataclass
class Waiting:
    """A request of the agent's to the phone (an approval, a form): sent to every follower of its
    session under one id, and answered by the first."""
    id: str
    agent_id: Any
    message: dict
    session: str | None


@dataclass
class Session:
    id: str
    cwd: str | None = None
    followers: set = field(default_factory=set)
    running: bool = False
    prompt: list | None = None
    last_stop: str | None = None
    seq: int = 0
    updates: list = field(default_factory=list)
    loading: Any = None          # the connection a load's replay goes to, while it runs
    title: str | None = None     # what the agent calls it (`session_info_update`), for notifications


class Agent:
    """One ACP agent, started on first use and shared by every connection to it."""

    def __init__(self, config: AgentConfig, pusher: redde_push.Pusher | None = None):
        self.config = config
        self.pusher = pusher
        self.proc: asyncio.subprocess.Process | None = None
        self.init_result: dict | None = None
        self.next_id = 0
        self.pending: dict[int, asyncio.Future] = {}
        self.sessions: dict[str, Session] = {}
        self.loaded: set[str] = set()
        self.waiting: dict[str, Waiting] = {}
        self.next_waiting = 0
        self.connections: set = set()
        self.start_lock = asyncio.Lock()
        # The agent's slash commands as its last session said them: a device gets them on
        # initialize, for a new chat, which hears none until it has a session.
        self.commands: list | None = None

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.returncode is None

    def session(self, sid: str) -> Session:
        if sid not in self.sessions:
            self.sessions[sid] = Session(id=sid)
        return self.sessions[sid]

    async def ensure_started(self) -> dict:
        async with self.start_lock:
            if self.running and self.init_result is not None:
                return self.init_result
            env = dict(os.environ)
            env.update(self.config.env)
            log.info("starting %s: %s", self.config.id, " ".join(self.config.command))
            try:
                self.proc = await asyncio.create_subprocess_exec(
                    *self.config.command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE, cwd=self.config.folder, env=env, limit=MAX_MESSAGE)
            except FileNotFoundError as error:
                raise AgentError({"code": -32603, "message": f"Can't start {self.config.name}: {error}"}) from error
            self.loaded.clear()
            asyncio.create_task(self._read(self.proc))
            asyncio.create_task(self._drain_stderr(self.proc))
            self.init_result = None
            result = await self._request("initialize", {
                "protocolVersion": PROTOCOL_VERSION,
                # Forms are shown in Redde as question cards (Claude Code asks its questions this way).
                "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False,
                                       "elicitation": {"form": {}}},
                "clientInfo": {"name": "redde-bridge", "title": "Redde bridge", "version": VERSION},
            }, timeout=120)
            self.init_result = result
            return result

    async def request(self, method: str, params: Any, timeout: float | None = None) -> Any:
        await self.ensure_started()
        return await self._request(method, params, timeout=timeout)

    async def _request(self, method: str, params: Any, timeout: float | None = None) -> Any:
        self.next_id += 1
        rid = self.next_id
        future = asyncio.get_running_loop().create_future()
        self.pending[rid] = future
        await self._write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        try:
            return await asyncio.wait_for(future, timeout) if timeout else await future
        finally:
            self.pending.pop(rid, None)

    async def notify(self, method: str, params: Any) -> None:
        await self.ensure_started()
        await self._write({"jsonrpc": "2.0", "method": method, "params": params})

    async def respond(self, agent_id: Any, reply: dict) -> None:
        message = {"jsonrpc": "2.0", "id": agent_id}
        message.update({k: v for k, v in reply.items() if k in ("result", "error")})
        await self._write(message)

    async def _write(self, message: dict) -> None:
        if not self.running or self.proc.stdin is None:
            raise AgentError({"code": -32603, "message": f"{self.config.name} isn't running"})
        self.proc.stdin.write((json.dumps(message, separators=(",", ":")) + "\n").encode())
        await self.proc.stdin.drain()

    async def _drain_stderr(self, proc) -> None:
        while line := await proc.stderr.readline():
            log.debug("%s: %s", self.config.id, line.decode(errors="replace").rstrip())

    async def _read(self, proc) -> None:
        try:
            while line := await proc.stdout.readline():
                line = line.strip()
                if not line:
                    continue
                try:
                    message = json.loads(line)
                except ValueError:
                    log.debug("%s said (not JSON): %s", self.config.id, line[:200])
                    continue
                await self._heard(message)
        except (asyncio.LimitOverrunError, ValueError) as error:
            log.warning("%s: a line too long to read (%s)", self.config.id, error)
        await proc.wait()
        log.info("%s exited (%s)", self.config.id, proc.returncode)
        await self._ended()

    async def _ended(self) -> None:
        """The agent is gone: every call to it fails, every turn ends, and the next use starts it."""
        for future in list(self.pending.values()):
            if not future.done():
                future.set_exception(AgentError({"code": -32603, "message": f"{self.config.name} exited"}))
        self.pending.clear()
        self.init_result = None
        self.loaded.clear()
        for sid in list(self.waiting):
            self.waiting.pop(sid, None)
        for session in self.sessions.values():
            if session.running:
                session.running = False
                await self.broadcast(session, "_redde/turn_ended", {"sessionId": session.id, "stopReason": "agent_exited"})

    async def _heard(self, message: dict) -> None:
        if "method" not in message:
            future = self.pending.get(message.get("id"))
            if future and not future.done():
                if "error" in message:
                    future.set_exception(AgentError(message["error"]))
                else:
                    future.set_result(message.get("result"))
            return
        method, params = message["method"], message.get("params") or {}
        if "id" not in message:
            if method == "session/update":
                await self._update(params)
            elif method == "elicitation/complete":
                await self.broadcast_all(method, params)
            return
        # A request of the agent's. The ones a phone can answer go to the session's followers;
        # the file and terminal ones were never offered.
        if method in ("session/request_permission", "elicitation/create"):
            await self._ask(message)
        else:
            await self.respond(message["id"], {"error": {"code": -32601, "message": f"{method} isn't offered by Redde"}})

    async def _update(self, params: dict) -> None:
        sid = params.get("sessionId")
        if not sid:
            return
        session = self.session(sid)
        said = params.get("update") or {}
        if said.get("sessionUpdate") == "available_commands_update" and isinstance(said.get("availableCommands"), list):
            self.commands = said["availableCommands"]
        if session.loading is not None:
            # A load's replay: the asking connection's alone, and not part of any turn.
            await session.loading.send_message({"jsonrpc": "2.0", "method": "session/update", "params": params})
            return
        update = params.get("update") or {}
        if update.get("sessionUpdate") == "session_info_update" and isinstance(update.get("title"), str):
            session.title = update["title"]
        session.seq += 1
        meta = dict(params.get("_meta") or {})
        meta["redde"] = {"seq": session.seq}
        params = dict(params, _meta=meta)
        session.updates.append(params)
        if len(session.updates) > LOG_LIMIT:
            del session.updates[: len(session.updates) - LOG_LIMIT]
        await self.broadcast(session, "session/update", params)

    async def _ask(self, message: dict) -> None:
        params = message.get("params") or {}
        sid = params.get("sessionId")
        self.next_waiting += 1
        waiting = Waiting(id=f"req-{self.next_waiting}", agent_id=message["id"], message=message, session=sid)
        self.waiting[waiting.id] = waiting
        out = {"jsonrpc": "2.0", "id": waiting.id, "method": message["method"], "params": params}
        targets = self.session(sid).followers if sid else self.connections
        log.info("%s asks %s (%s), %d device(s) to hear it", self.config.id, message["method"], waiting.id, len(targets))
        for connection in list(targets):
            await connection.send_message(out)
        if message["method"] == "session/request_permission" and sid:
            call = params.get("toolCall") or {}
            raw = call.get("rawInput") if isinstance(call.get("rawInput"), dict) else {}
            asked = call.get("title") or raw.get("command") or raw.get("file_path") or "a tool"
            self.tell("approval", self.session(sid), asked)
        elif message["method"] == "elicitation/create" and sid:
            self.tell("question", self.session(sid), params.get("message") or "")

    async def answered(self, connection, waiting_id: str, reply: dict) -> None:
        waiting = self.waiting.pop(waiting_id, None)
        if waiting is None:
            return   # another device was first
        await self.respond(waiting.agent_id, reply)
        resolved = {"id": waiting_id, "sessionId": waiting.session}
        targets = self.session(waiting.session).followers if waiting.session else self.connections
        for other in list(targets):
            if other is not connection:
                await other.send_message({"jsonrpc": "2.0", "method": "_redde/request_resolved", "params": resolved})

    async def broadcast(self, session: Session, method: str, params: dict) -> None:
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        for connection in list(session.followers):
            await connection.send_message(message)

    async def broadcast_all(self, method: str, params: dict) -> None:
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        for connection in list(self.connections):
            await connection.send_message(message)

    def tell(self, kind: str, session: Session, body: str = "") -> None:
        """A notification about a session to every paired device: a phone with Redde in front
        doesn't show it, and one with Redde in the background drops it for its own banner."""
        if self.pusher is None:
            return
        title = session.title or _prompt_text(session.prompt) or self.config.name
        sent = self.pusher.notify(redde_push.note(kind, session.id, body, title, self.config.name))
        if sent:
            log.info("%s: %s note for %s to %d device(s)", self.config.id, kind, session.id[:16], sent)

    def forget(self, connection) -> None:
        self.connections.discard(connection)
        for session in self.sessions.values():
            session.followers.discard(connection)
            if session.loading is connection:
                session.loading = None

    def waiting_in(self, sid: str) -> list[dict]:
        return [{"jsonrpc": "2.0", "id": w.id, "method": w.message["method"], "params": w.message.get("params") or {}}
                for w in self.waiting.values() if w.session == sid]

    def capability(self, *path: str) -> Any:
        value: Any = (self.init_result or {}).get("agentCapabilities") or {}
        for key in path:
            if not isinstance(value, dict):
                return None
            value = value.get(key)
        return value

    def folder(self, cwd: Any, sid: str | None = None) -> str:
        """The working folder for a session: the phone's when it names an absolute one, else the
        session's own, else the agent's from config."""
        if isinstance(cwd, str) and cwd.strip():
            path = Path(cwd.strip()).expanduser()
            if path.is_absolute():
                return str(path)
        if sid and (known := self.sessions.get(sid)) and known.cwd:
            return known.cwd
        return self.config.folder

    async def make_ready(self, sid: str) -> None:
        """Before a prompt to a session this process hasn't loaded (after a restart): resume it,
        or load it with its replay dropped."""
        if sid in self.loaded:
            return
        session = self.session(sid)
        params = {"sessionId": sid, "cwd": self.folder(None, sid), "mcpServers": []}
        if self.capability("sessionCapabilities", "resume") is not None:
            await self.request("session/resume", params)
        elif self.capability("loadSession"):
            session.loading = _Nowhere()
            try:
                await self.request("session/load", params)
            finally:
                session.loading = None
        self.loaded.add(sid)


class _Nowhere:
    """Where a quiet load's replay goes."""
    async def send_message(self, message: dict) -> None:
        pass


# MARK: - One phone's connection

class Connection:
    def __init__(self, ws: WebSocket, agent: Agent, peer: str):
        self.ws, self.agent, self.peer = ws, agent, peer
        self.tasks: set[asyncio.Task] = set()

    async def send_message(self, message: dict) -> None:
        try:
            await self.ws.send(json.dumps(message, separators=(",", ":")))
        except Closed:
            pass

    async def run(self) -> None:
        self.agent.connections.add(self)
        pinger = asyncio.create_task(self._ping())
        try:
            while True:
                text = await self.ws.receive()
                try:
                    message = json.loads(text)
                except ValueError:
                    await self.send_message({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
                    continue
                if isinstance(message, list):
                    await self.send_message({"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Batches aren't supported"}})
                    continue
                task = asyncio.create_task(self._handle(message))
                self.tasks.add(task)
                task.add_done_callback(self.tasks.discard)
        except (Closed, asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            pinger.cancel()
            self.agent.forget(self)
            await self.ws.close()
            log.info("%s left %s", self.peer, self.agent.config.id)

    async def _ping(self) -> None:
        while True:
            await asyncio.sleep(PING_EVERY)
            if time.monotonic() - self.ws.last_heard > PING_EVERY * 2.5:
                log.info("%s went quiet", self.peer)
                await self.ws.close(1001)
                return
            try:
                await self.ws.ping()
            except Closed:
                return

    async def _handle(self, message: dict) -> None:
        method = message.get("method")
        rid = message.get("id")
        if method is None:
            # A reply to something the agent asked.
            if isinstance(rid, str) and rid in self.agent.waiting:
                await self.agent.answered(self, rid, message)
            return
        params = message.get("params") or {}
        try:
            result = await self._dispatch(method, params, rid)
        except AgentError as error:
            if rid is not None:
                await self.send_message({"jsonrpc": "2.0", "id": rid, "error": error.error})
            return
        except Exception as error:   # keep the connection; say what broke
            log.exception("handling %s", method)
            if rid is not None:
                await self.send_message({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": str(error)}})
            return
        if rid is not None and result is not _NO_REPLY:
            await self.send_message({"jsonrpc": "2.0", "id": rid, "result": result})

    async def _dispatch(self, method: str, params: dict, rid: Any) -> Any:
        agent = self.agent
        if method == "initialize":
            result = dict(await agent.ensure_started())
            meta = dict(result.get("_meta") or {})
            meta["redde"] = {"bridge": VERSION, "agent": agent.config.id, "name": agent.config.name,
                             "cwd": agent.config.folder, "attach": True}
            if agent.commands is not None:
                meta["redde"]["commands"] = agent.commands
            result["_meta"] = meta
            return result
        if method in ("session/new", "session/load", "session/resume", "session/fork"):
            sid = params.get("sessionId")
            params = dict(params, cwd=agent.folder(params.get("cwd"), sid), mcpServers=params.get("mcpServers") or [])
            if method == "session/load":
                session = agent.session(sid)
                if session.running:
                    raise AgentError({"code": BUSY, "message": "A turn is under way in this session; attach to it instead."})
                session.loading = self
                try:
                    result = await agent.request(method, params)
                finally:
                    session.loading = None
            else:
                result = await agent.request(method, params)
            # A fork is a new session, open in the agent already: it's the one to follow.
            sid = (result or {}).get("sessionId") if method == "session/fork" else sid or (result or {}).get("sessionId")
            if sid:
                session = agent.session(sid)
                session.cwd = params["cwd"]
                session.followers.add(self)
                agent.loaded.add(sid)
            return result
        if method == "session/prompt":
            return await self._prompt(params, rid)
        if method == "session/cancel":
            await agent.notify(method, params)
            return _NO_REPLY
        if method == "session/list":
            result = await agent.request(method, params)
            for info in (result or {}).get("sessions") or []:
                if info.get("sessionId") and info.get("cwd"):
                    agent.session(info["sessionId"]).cwd = info["cwd"]
            return result
        if method in ("session/delete", "session/close"):
            result = await agent.request(method, params)
            if method == "session/delete":
                agent.sessions.pop(params.get("sessionId"), None)
                agent.loaded.discard(params.get("sessionId"))
            return result
        if method == "_redde/attach":
            sid = params["sessionId"]
            session = agent.session(sid)
            session.followers.add(self)
            # The turn under way, or the last one: a phone that dropped mid-reply finishes it from here.
            return {"running": session.running, "prompt": session.prompt, "seq": session.seq,
                    "stopReason": None if session.running else session.last_stop,
                    "updates": session.updates, "requests": agent.waiting_in(sid)}
        if method == "_redde/detach":
            agent.session(params["sessionId"]).followers.discard(self)
            return {}
        if method == "_redde/push":
            # Pairing for notifications, in the words of Redde's Hermes plugin (PushService.pairDirectly).
            if agent.pusher is None:
                raise AgentError({"code": -32601, "message": "This bridge doesn't send notifications"})
            return {"output": await asyncio.to_thread(agent.pusher.command, str(params.get("command") or ""))}
        if method == "_redde/agents":
            return {"agents": [{"id": agent.config.id, "name": agent.config.name, "running": agent.running}]}
        # Everything else goes to the agent as it is: set_config_option, set_mode, authenticate…
        if rid is None:
            await agent.notify(method, params)
            return _NO_REPLY
        return await agent.request(method, params)

    async def _prompt(self, params: dict, rid: Any) -> Any:
        agent = self.agent
        sid = params["sessionId"]
        session = agent.session(sid)
        session.followers.add(self)
        await agent.make_ready(sid)
        session.running = True
        session.prompt = params.get("prompt")
        session.last_stop = None
        session.updates = []
        log.info("%s: prompt in %s", agent.config.id, sid[:16])
        stop: Any = None
        failure = ""
        try:
            result = await agent.request("session/prompt", params)
            stop = (result or {}).get("stopReason")
            return result
        except AgentError as error:
            stop = "error"
            failure = str(error)
            raise error
        finally:
            session.running = False
            session.last_stop = stop
            ended = {"sessionId": sid, "stopReason": stop, "seq": session.seq}
            await agent.broadcast(session, "_redde/turn_ended", ended)
            if stop == "error":
                agent.tell("failed", session, failure)
            elif stop and stop != "cancelled":
                agent.tell("reply", session, _reply_text(session.updates))


_NO_REPLY = object()


def _prompt_text(prompt: Any) -> str:
    """The words of a prompt, for a chat the agent hasn't named."""
    words = " ".join(b.get("text", "") for b in prompt or [] if isinstance(b, dict) and b.get("type") == "text")
    return redde_push.clipped(words, 60)


def _reply_text(updates: list) -> str:
    """What the agent wrote in a turn, from its updates."""
    parts = []
    for params in updates:
        update = params.get("update") or {}
        content = update.get("content") or {}
        if update.get("sessionUpdate") == "agent_message_chunk" and isinstance(content, dict) and content.get("type") == "text":
            parts.append(content.get("text", ""))
    return "".join(parts).strip()


# MARK: - HTTP front door

class Bridge:
    def __init__(self, config: Config):
        self.config = config
        pusher = redde_push.Pusher(config.push_path, config.push_relay) if config.push_path else None
        self.agents = {a.id: Agent(a, pusher) for a in config.agents}

    def authorized(self, headers: dict[str, str], query: dict[str, list[str]]) -> bool:
        offered = None
        auth = headers.get("authorization", "")
        if auth.lower().startswith("bearer "):
            offered = auth[7:].strip()
        offered = offered or headers.get("x-secret-key") or (query.get("token") or [None])[0]
        return bool(offered) and hmac.compare_digest(offered.encode(), self.config.token.encode())

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = "%s:%s" % (writer.get_extra_info("peername") or ("?", "?"))[:2]
        try:
            request_line = (await asyncio.wait_for(reader.readline(), 15)).decode("latin-1").strip()
            headers: dict[str, str] = {}
            while True:
                line = (await asyncio.wait_for(reader.readline(), 15)).decode("latin-1")
                if line in ("\r\n", "\n", ""):
                    break
                name, _, value = line.partition(":")
                headers[name.strip().lower()] = value.strip()
        except (asyncio.TimeoutError, ConnectionError, asyncio.IncompleteReadError):
            writer.close()
            return
        parts = request_line.split(" ")
        if len(parts) < 2:
            writer.close()
            return
        verb, target = parts[0], parts[1]
        url = urlsplit(target)
        query = parse_qs(url.query)
        path = url.path.rstrip("/") or "/"

        if verb == "GET" and path == "/health":
            return await self._reply(writer, 200, {"ok": True, "version": VERSION})
        if not self.authorized(headers, query):
            log.info("%s: refused (no or wrong token) for %s", peer, path)
            return await self._reply(writer, 401, {"error": "unauthorized"})
        if verb == "GET" and path == "/agents":
            return await self._reply(writer, 200, {"version": VERSION, "agents": [
                {"id": a.config.id, "name": a.config.name, "running": a.running, "cwd": a.config.folder}
                for a in self.agents.values()]})
        if verb == "GET" and (path == "/acp" or path.startswith("/acp/")):
            ident = path[5:] if path.startswith("/acp/") else (query.get("agent") or [None])[0]
            agent = self.agents.get(ident) if ident else next(iter(self.agents.values()), None)
            if agent is None:
                return await self._reply(writer, 404, {"error": f"no agent {ident!r}"})
            key = headers.get("sec-websocket-key")
            if headers.get("upgrade", "").lower() != "websocket" or not key:
                return await self._reply(writer, 426, {"error": "WebSocket upgrade required"})
            accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
            response = ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Accept: {accept}\r\n")
            if "acp" in headers.get("sec-websocket-protocol", ""):
                response += "Sec-WebSocket-Protocol: acp\r\n"
            writer.write((response + "\r\n").encode())
            await writer.drain()
            log.info("%s joined %s", peer, agent.config.id)
            await Connection(WebSocket(reader, writer), agent, peer).run()
            return
        await self._reply(writer, 404, {"error": "not found"})

    async def _reply(self, writer: asyncio.StreamWriter, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        reason = {200: "OK", 401: "Unauthorized", 404: "Not Found", 426: "Upgrade Required"}.get(status, "")
        writer.write(f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\n"
                     f"Content-Length: {len(data)}\r\nConnection: close\r\n\r\n".encode() + data)
        try:
            await writer.drain()
        finally:
            writer.close()

    async def serve(self) -> None:
        host, port = self.config.host_port
        context = None
        if self.config.tls_cert and self.config.tls_key:
            context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
            context.load_cert_chain(Path(self.config.tls_cert).expanduser(), Path(self.config.tls_key).expanduser())
        server = await asyncio.start_server(self.handle, host, port, ssl=context, limit=MAX_MESSAGE)
        names = ", ".join(f"{a.config.id} ({' '.join(a.config.command)})" for a in self.agents.values()) or "none"
        log.info("Redde bridge %s on %s://%s:%d, agents: %s", VERSION, "wss" if context else "ws", host, port, names)
        async with server:
            await server.serve_forever()


def setup_address(config: Config, host_name: str | None = None) -> str:
    """The bridge's address as a phone reaches it: `host_name` when given (`--host`: a Tailscale
    name, which reaches it away from home too), else its .local name when it listens everywhere."""
    host, port = config.host_port
    scheme = "wss" if config.tls_cert else "ws"
    if host_name:
        host = host_name.strip().rstrip(".")
    elif host in ("0.0.0.0", "::", ""):
        host = socket.gethostname().split(".")[0] + ".local"
    if ":" in host:
        host = f"[{host}]"
    return f"{scheme}://{host}:{port}"


def setup_link(config: Config, agent: "AgentConfig | None", host_name: str | None = None) -> str:
    """Redde's setup link for this bridge and one of its agents (the app's SetupCode): opened on
    the phone, or scanned as a QR code, it fills in the connection. It holds the token: share it
    only with your own devices. The parameters ride after the "#", which a browser never sends."""
    from urllib.parse import quote
    fields = [("name", socket.gethostname().split(".")[0]), ("bridge", setup_address(config, host_name)),
              ("bridge-token", config.token)]
    if agent is not None:
        fields.append(("agent", agent.id))
    fields += [("use", "acp"), ("v", "1")]
    return "https://redde.goosehouse.org/connect#" + "&".join(f"{k}={quote(v, safe='/:~@')}" for k, v in fields)


def print_setup(config: Config, agent_id: str | None = None, host_name: str | None = None) -> None:
    agents = [a for a in config.agents if agent_id in (None, a.id)]
    if agent_id and not agents:
        raise SystemExit(f"No agent {agent_id!r} in the config.")
    print("In Redde: Settings → Connection → Set up connection… → Other agent (ACP)\n")
    print(f"  Address  {setup_address(config, host_name)}")
    print(f"  Token    {config.token}")
    print("  Agents   " + (", ".join(f"{a.name} ({a.id})" for a in config.agents) or "none: add one to the config"))
    print("\nOr open a setup link on the phone (it holds the token: keep it to your own devices):\n")
    for agent in agents or [None]:
        print(f"  {agent.name if agent else 'Bridge'}: {setup_link(config, agent, host_name)}")
    first = (agents or [None])[0]
    qrencode = shutil.which("qrencode")
    if qrencode and sys.stdout.isatty():
        print(f"\nScan with the iPhone's Camera, or Redde's Scan a setup code"
              + (f" ({first.name}; --agent <id> for another)" if first and len(agents) > 1 else "") + ":\n")
        subprocess.run([qrencode, "-t", "ansiutf8", "-m", "2", setup_link(config, first, host_name)], check=False)
    elif sys.stdout.isatty():
        print("\n(Install qrencode to see it as a QR code here: brew install qrencode / apt install qrencode.)")


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve ACP agents to Redde.")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--listen", help="host:port, overriding the config")
    parser.add_argument("--print-setup", action="store_true", help="print the address, token and setup link for Redde, then exit")
    parser.add_argument("--agent", help="with --print-setup: the agent the setup link and QR code are for")
    parser.add_argument("--host", help="with --print-setup: the name the phone reaches this machine by, such as its "
                                       "Tailscale name (machine.tailnet.ts.net), which works away from home too")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    config = load_config(args.config)
    if args.listen:
        config.listen = args.listen
    if args.print_setup:
        print_setup(config, args.agent, args.host)
        return
    try:
        asyncio.run(Bridge(config).serve())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

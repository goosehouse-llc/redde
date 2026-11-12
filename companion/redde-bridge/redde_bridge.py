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
- the working folder filled in when the phone names none.

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
import sys
import time
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

VERSION = "0.1.0"
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
                  tls_cert=raw.get("tls_cert"), tls_key=raw.get("tls_key"))


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


class Agent:
    """One ACP agent, started on first use and shared by every connection to it."""

    def __init__(self, config: AgentConfig):
        self.config = config
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
                "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
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
        if session.loading is not None:
            # A load's replay: the asking connection's alone, and not part of any turn.
            await session.loading.send_message({"jsonrpc": "2.0", "method": "session/update", "params": params})
            return
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
            result["_meta"] = meta
            return result
        if method in ("session/new", "session/load", "session/resume"):
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
            sid = sid or (result or {}).get("sessionId")
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
        try:
            result = await agent.request("session/prompt", params)
            stop = (result or {}).get("stopReason")
            return result
        except AgentError as error:
            stop = "error"
            raise error
        finally:
            session.running = False
            session.last_stop = stop
            ended = {"sessionId": sid, "stopReason": stop, "seq": session.seq}
            await agent.broadcast(session, "_redde/turn_ended", ended)


_NO_REPLY = object()


# MARK: - HTTP front door

class Bridge:
    def __init__(self, config: Config):
        self.config = config
        self.agents = {a.id: Agent(a) for a in config.agents}

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


def print_setup(config: Config) -> None:
    host, port = config.host_port
    scheme = "wss" if config.tls_cert else "ws"
    shown = socket.gethostname() if host in ("0.0.0.0", "::", "") else host
    print("In Redde: Settings → Servers → Add → Other agent (ACP)\n")
    print(f"  Address  {scheme}://{shown}:{port}")
    print(f"  Token    {config.token}")
    print("  Agents   " + (", ".join(f"{a.name} ({a.id})" for a in config.agents) or "none: add one to the config"))


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve ACP agents to Redde.")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--listen", help="host:port, overriding the config")
    parser.add_argument("--print-setup", action="store_true", help="print the address and token for Redde, then exit")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    config = load_config(args.config)
    if args.listen:
        config.listen = args.listen
    if args.print_setup:
        print_setup(config)
        return
    try:
        asyncio.run(Bridge(config).serve())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

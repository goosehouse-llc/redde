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

Standard library only, Python 3.9 or later. See README.md and docs/acp.md.

    python3 redde_bridge.py                 # serve (writes a config and a token the first time)
    python3 redde_bridge.py --print-setup   # what to type into Redde
    python3 redde_bridge.py --install       # run it as a service that starts with the computer
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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import redde_push  # noqa: E402  (beside this file)
import redde_qr  # noqa: E402
import redde_codex  # noqa: E402

VERSION = "0.7.0"
PROTOCOL_VERSION = 1
DEFAULT_CONFIG = Path(os.environ.get("REDDE_BRIDGE_CONFIG", "~/.config/redde-bridge/config.toml")).expanduser()
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_MESSAGE = 64 * 1024 * 1024        # a prompt with photos, a long history replayed
PING_EVERY = 20.0
LOG_LIMIT = 4000                      # updates kept per session for catch-up (one turn's worth)
BUSY = -32002                         # ACP's "resource not found" range; used here for "busy"

log = logging.getLogger("redde-bridge")


# MARK: - Config

def read_toml(text: str) -> dict:
    """The config's TOML. Python 3.11 has `tomllib`; before it (macOS still ships 3.9), a reader
    for what a config holds: tables, keys, strings, numbers, booleans, arrays and inline tables."""
    try:
        import tomllib
        return tomllib.loads(text)
    except ImportError:
        return _TomlReader(text).read()


class _TomlReader:
    def __init__(self, text: str):
        self.s, self.i = text, 0

    def fail(self, why: str) -> SystemExit:
        line = self.s.count("\n", 0, self.i) + 1
        return SystemExit(f"config line {line}: {why}")

    def space(self, newlines: bool = False) -> None:
        while self.i < len(self.s):
            c = self.s[self.i]
            if c in " \t\r" or (newlines and c == "\n"):
                self.i += 1
            elif c == "#":
                while self.i < len(self.s) and self.s[self.i] != "\n":
                    self.i += 1
            else:
                return

    def read(self) -> dict:
        root: dict = {}
        table = root
        while True:
            self.space(newlines=True)
            if self.i >= len(self.s):
                return root
            if self.s[self.i] == "[":
                self.i += 1
                table = root
                for part in self.key():
                    table = table.setdefault(part, {})
                self.space()
                if self.s[self.i:self.i + 1] != "]":
                    raise self.fail("expected ]")
                self.i += 1
            else:
                self.pair(table)
            self.space()
            if self.i < len(self.s) and self.s[self.i] != "\n":
                raise self.fail("expected the end of the line")

    def key(self) -> list:
        parts = []
        while True:
            self.space()
            c = self.s[self.i:self.i + 1]
            if c in ('"', "'"):
                parts.append(self.string())
            else:
                start = self.i
                while self.i < len(self.s) and (self.s[self.i].isalnum() or self.s[self.i] in "_-"):
                    self.i += 1
                if start == self.i:
                    raise self.fail("expected a key")
                parts.append(self.s[start:self.i])
            self.space()
            if self.s[self.i:self.i + 1] != ".":
                return parts
            self.i += 1

    def pair(self, table: dict) -> None:
        *path, last = self.key()
        for part in path:
            table = table.setdefault(part, {})
        self.space()
        if self.s[self.i:self.i + 1] != "=":
            raise self.fail("expected =")
        self.i += 1
        self.space()
        table[last] = self.value()

    def string(self) -> str:
        quote = self.s[self.i]
        end = self.i + 1
        if quote == "'":
            close = self.s.index("'", end)
            self.i = close + 1
            return self.s[end:close]
        while self.s[end] != '"':
            end += 2 if self.s[end] == "\\" else 1
        text = json.loads(self.s[self.i:end + 1])
        self.i = end + 1
        return text

    def value(self):
        c = self.s[self.i:self.i + 1]
        if c in ('"', "'"):
            return self.string()
        if c == "[":
            self.i += 1
            items = []
            while True:
                self.space(newlines=True)
                if self.i >= len(self.s):
                    raise self.fail("an array isn't closed")
                if self.s[self.i:self.i + 1] == "]":
                    self.i += 1
                    return items
                items.append(self.value())
                self.space(newlines=True)
                if self.s[self.i:self.i + 1] == ",":
                    self.i += 1
        if c == "{":
            self.i += 1
            table: dict = {}
            while True:
                self.space()
                if self.i >= len(self.s) or self.s[self.i] == "\n":
                    raise self.fail("an inline table isn't closed")
                if self.s[self.i:self.i + 1] == "}":
                    self.i += 1
                    return table
                self.pair(table)
                self.space()
                if self.s[self.i:self.i + 1] == ",":
                    self.i += 1
        start = self.i
        while self.i < len(self.s) and self.s[self.i] not in " \t\r\n,]}#":
            self.i += 1
        word = self.s[start:self.i]
        if word in ("true", "false"):
            return word == "true"
        try:
            return int(word.replace("_", ""))
        except ValueError:
            try:
                return float(word.replace("_", ""))
            except ValueError:
                raise self.fail(f"can't read {word!r}") from None


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
    #: The name a phone reaches this computer by, for setup links (`--install` puts the
    #: Tailscale name here). None: the .local name.
    host: str | None = None
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
    raw = read_toml(path.read_text())
    agents = [AgentConfig(id=ident, name=a.get("name", ident), command=list(a["command"]),
                          cwd=a.get("cwd", "~"), env=dict(a.get("env", {})))
              for ident, a in (raw.get("agents") or {}).items()]
    if not raw.get("token"):
        raise SystemExit(f"{path}: no token")
    return Config(listen=raw.get("listen", "0.0.0.0:8765"), token=raw["token"], agents=agents,
                  tls_cert=raw.get("tls_cert"), tls_key=raw.get("tls_key"), host=raw.get("host"),
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
        # Codex's plan limits: codex-acp doesn't pass them on, so they're read from Codex itself
        # after turns and sent to every device (`_redde/limits`). None for other agents.
        self.limits = redde_codex.Limits.for_agent(config.command, config.env, self.broadcast_all)

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
        """A notification about a session to the devices paired through this agent: a phone with Redde in front
        doesn't show it, and one with Redde in the background drops it for its own banner."""
        if self.pusher is None:
            return
        title = session.title or _prompt_text(session.prompt) or self.config.name
        sent = self.pusher.notify(redde_push.note(kind, session.id, body, title, self.config.name), self.config.id)
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
    def __init__(self, ws: WebSocket, agent: Agent, peer: str, bridge: "Bridge | None" = None):
        self.ws, self.agent, self.peer, self.bridge = ws, agent, peer, bridge
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
            # Said here too, so a failure the phone shows can be found in the log.
            log.warning("%s: %s failed for %s: %s", self.agent.config.id, method, self.peer, json.dumps(error.error)[:500])
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
                             "cwd": agent.config.folder, "attach": True,
                             # How it runs, for the app's Bridge section and its Update button.
                             "service": self.bridge.service if self.bridge else None,
                             "updatable": bool(self.bridge and self.bridge.service)}
            if agent.commands is not None:
                meta["redde"]["commands"] = agent.commands
            if agent.limits is not None:
                if agent.limits.last is not None:
                    meta["redde"]["limits"] = agent.limits.last
                agent.limits.poke()
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
            return {"output": await asyncio.to_thread(agent.pusher.command, str(params.get("command") or ""), agent.config.id)}
        if method == "_redde/agents":
            return {"agents": [{"id": agent.config.id, "name": agent.config.name, "running": agent.running}]}
        if method == "_redde/update":
            return await self._update()
        # Everything else goes to the agent as it is: set_config_option, set_mode, authenticate…
        if rid is None:
            await agent.notify(method, params)
            return _NO_REPLY
        return await agent.request(method, params)

    async def _update(self) -> dict:
        """`_redde/update`: the bridge fetches its newest files from where the installer gets them,
        checks they run, puts them in place and restarts, by its service bringing it back. Only an
        installed bridge (`--install`), and only between turns: a restart ends every agent."""
        bridge = self.bridge
        if bridge is None or not bridge.service:
            raise AgentError({"code": -32601, "message": "This bridge isn't installed as a service, so it can't update "
                              "itself. Run the installer again on the computer.", "data": {"command": INSTALL_COMMAND}})
        if any(s.running for a in bridge.agents.values() for s in a.sessions.values()):
            raise AgentError({"code": BUSY, "message": "A reply is under way. Update once it's done."})
        if bridge.updating:
            raise AgentError({"code": BUSY, "message": "The bridge is already updating."})
        bridge.updating = True
        try:
            latest = await asyncio.to_thread(update_files, UPDATE_BASE, INSTALL_DIR)
        except UpdateError as error:
            raise AgentError({"code": -32603, "message": str(error), "data": {"command": INSTALL_COMMAND}})
        finally:
            bridge.updating = False
        if latest is None:
            return {"updated": False, "version": VERSION}
        log.info("updated %s → %s; restarting", VERSION, latest)
        # After the reply is on its way.
        asyncio.get_running_loop().call_later(1.0, bridge.restart)
        return {"updated": True, "from": VERSION, "version": latest}

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
            if agent.limits is not None:
                agent.limits.poke()
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
        #: "launchd" or "systemd" when this is the installed bridge, run by its service.
        self.service = service_kind()
        self.updating = False

    def restart(self) -> None:
        """Ends the agents and the bridge; the service starts the bridge again, with its new files."""
        for agent in self.agents.values():
            if agent.running:
                agent.proc.terminate()
        logging.shutdown()
        os._exit(0)

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
            return await self._reply(writer, 200, {"version": VERSION, "service": self.service, "updatable": bool(self.service), "agents": [
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
            await Connection(WebSocket(reader, writer), agent, peer, self).run()
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
    host_name = host_name or config.host
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
    # Named for its agent ("Codex"), so two agents on one bridge aren't two servers called the same;
    # the bridge's own link is named for the machine.
    name = agent.name if agent is not None and agent.name else socket.gethostname().split(".")[0]
    fields = [("name", name), ("bridge", setup_address(config, host_name)),
              ("bridge-token", config.token)]
    if agent is not None:
        fields.append(("agent", agent.id))
    fields += [("use", "acp"), ("v", "1")]
    return "https://redde.goosehouse.org/connect#" + "&".join(f"{k}={quote(v, safe='/:~@')}" for k, v in fields)


def print_setup(config: Config, agent_id: str | None = None, host_name: str | None = None) -> None:
    agents = [a for a in config.agents if agent_id in (None, a.id)]
    if agent_id and not agents:
        raise SystemExit(f"No agent {agent_id!r} in the config.")
    print("In Redde: Settings › Connection › Set up connection… › Claude Code, Codex and others (ACP)\n")
    print(f"  Address  {setup_address(config, host_name)}")
    print(f"  Token    {config.token}")
    print("  Agents   " + (", ".join(f"{a.name} ({a.id})" for a in config.agents) or "none: add one to the config"))
    print("\nOr open a setup link on the phone (it holds the token: keep it to your own devices):\n")
    for agent in agents or [None]:
        print(f"  {agent.name if agent else 'Bridge'}: {setup_link(config, agent, host_name)}")
    first = (agents or [None])[0]
    if sys.stdout.isatty():
        print(f"\nScan with the iPhone's Camera, or Redde's Scan a setup code"
              + (f" ({first.name}; --agent <id> for another)" if first and len(agents) > 1 else "") + ":\n")
        print(redde_qr.terminal(setup_link(config, first, host_name)))


# MARK: - Install

#: The service's name: launchd's label on a Mac; the systemd unit is its last part.
SERVICE = os.environ.get("REDDE_BRIDGE_SERVICE", "com.goosehouse.redde-bridge")
#: Where `--install` puts the bridge's files, so the service doesn't depend on a download or a checkout.
INSTALL_DIR = Path(os.environ.get("REDDE_BRIDGE_HOME", "~/.local/share/redde-bridge")).expanduser()
FILES = ("redde_bridge.py", "redde_push.py", "redde_qr.py", "redde_codex.py")
#: Where the installer and `_redde/update` get the files (install.sh's BASE).
UPDATE_BASE = os.environ.get("REDDE_BRIDGE_BASE",
                             "https://raw.githubusercontent.com/goosehouse-llc/redde/main/companion/redde-bridge").rstrip("/")
INSTALL_COMMAND = ("curl -fsSL https://raw.githubusercontent.com/goosehouse-llc/redde/main/companion/redde-bridge/install.sh | sh")


def service_kind() -> str | None:
    """"launchd" or "systemd" when this is the installed bridge (its files in INSTALL_DIR, its
    service set up), which can update itself and be brought back; None when run by hand."""
    try:
        if Path(__file__).resolve().parent != INSTALL_DIR.resolve() or not service_path().exists():
            return None
    except OSError:
        return None
    return "launchd" if sys.platform == "darwin" else "systemd"


class UpdateError(Exception):
    pass


def _version_tuple(text: str) -> tuple:
    return tuple(int(p) if p.isdigit() else 0 for p in text.split("."))


def update_files(base: str, target: Path, current: str = VERSION, timeout: float = 30) -> str | None:
    """Fetches the newest bridge from `base` and, when it's newer than `current`, puts its files in
    `target`, keeping the old ones in `target/previous`. Returns the new version, or None when
    there's nothing newer. Nothing changes unless every file came and the new bridge runs here."""
    import ast
    import re
    import urllib.request

    def fetch(name: str) -> bytes:
        try:
            with urllib.request.urlopen(f"{base}/{name}", timeout=timeout) as reply:
                data = reply.read(4 * 1024 * 1024 + 1)
        except (OSError, ValueError) as error:
            raise UpdateError(f"Couldn't download {name}: {error}") from None
        if len(data) > 4 * 1024 * 1024:
            raise UpdateError(f"{name} is too big to be the bridge")
        return data

    main = fetch("redde_bridge.py")
    text = main.decode("utf-8", errors="replace")
    found = re.search(r'^VERSION = "([0-9][0-9A-Za-z.\-]*)"', text, re.M)
    if not found:
        raise UpdateError("The download isn't the Redde bridge")
    latest = found.group(1)
    if _version_tuple(latest) <= _version_tuple(current):
        return None
    # The new bridge's own list, in case it has a file more.
    names = FILES
    listed = re.search(r"^FILES = (\(.*?\))$", text, re.M)
    if listed:
        try:
            names = tuple(ast.literal_eval(listed.group(1)))
        except (ValueError, SyntaxError):
            raise UpdateError("The download's file list can't be read") from None
    if "redde_bridge.py" not in names or not all(re.fullmatch(r"[a-z_]+\.py", n) for n in names):
        raise UpdateError("The download's file list isn't one this bridge takes")

    staging = target / ".update"
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    try:
        for name in names:
            (staging / name).write_bytes(main if name == "redde_bridge.py" else fetch(name))
        # It has to start on this Python: one that needs a newer one stays out.
        try:
            ran = subprocess.run([sys.executable, str(staging / "redde_bridge.py"), "--version"],
                                 capture_output=True, text=True, timeout=60, cwd=str(staging))
        except (OSError, subprocess.SubprocessError) as error:
            raise UpdateError(f"The new bridge didn't run: {error}") from None
        if ran.returncode != 0 or ran.stdout.strip() != latest:
            said = (ran.stderr or ran.stdout).strip().splitlines()
            raise UpdateError(f"The new bridge {latest} didn't run on Python {sys.version.split()[0]}"
                              + (f": {said[-1]}" if said else ""))
        previous = target / "previous"
        previous.mkdir(exist_ok=True)
        for name in names:
            if (target / name).exists():
                shutil.copy2(target / name, previous / name)
        for name in names:
            os.replace(staging / name, target / name)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return latest


def tailscale_name() -> str | None:
    """This computer's Tailscale name (machine.tailnet.ts.net), which a phone on the tailnet
    reaches at home and away, when Tailscale is running here."""
    for cli in (shutil.which("tailscale"), "/Applications/Tailscale.app/Contents/MacOS/Tailscale"):
        if not cli or not Path(cli).exists():
            continue
        try:
            out = subprocess.run([cli, "status", "--json"], capture_output=True, text=True, timeout=10)
            status = json.loads(out.stdout)
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
        name = (status.get("Self") or {}).get("DNSName", "").rstrip(".")
        if status.get("BackendState") == "Running" and name:
            return name
    return None


def remember_host(path: Path, host: str) -> None:
    """Puts `host = "…"` in the config, after `listen` (a top-level key must come before the tables)."""
    lines = path.read_text().split("\n")
    line = f"host = {json.dumps(host)}   # the name Redde reaches this computer by, in setup links"
    at = next((i + 1 for i, l in enumerate(lines) if l.strip().startswith("listen")), 0)
    lines.insert(at, line)
    path.write_text("\n".join(lines))


def service_path() -> Path:
    if sys.platform == "darwin":
        return Path(f"~/Library/LaunchAgents/{SERVICE}.plist").expanduser()
    return Path(f"~/.config/systemd/user/{SERVICE.rsplit('.', 1)[-1]}.service").expanduser()


def service_path_variable() -> str:
    """PATH for the service: this shell's, so it finds the agents (npx, claude, codex…) where you
    do, and the usual places, since a service starts with almost none."""
    extra = ["/opt/homebrew/bin", "/usr/local/bin", str(Path("~/.local/bin").expanduser()),
             "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    seen: list[str] = []
    for part in os.environ.get("PATH", "").split(os.pathsep) + extra:
        if part and part not in seen:
            seen.append(part)
    return os.pathsep.join(seen)


def launch_agent(program: list[str], log_file: Path) -> str:
    from xml.sax.saxutils import escape
    args = "".join(f"\n    <string>{escape(a)}</string>" for a in program)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{escape(SERVICE)}</string>
  <key>ProgramArguments</key><array>{args}
  </array>
  <key>WorkingDirectory</key><string>{escape(str(INSTALL_DIR))}</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>{escape(service_path_variable())}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>{escape(str(log_file))}</string>
  <key>StandardErrorPath</key><string>{escape(str(log_file))}</string>
</dict></plist>
"""


def systemd_unit(program: list[str]) -> str:
    def quote(arg: str) -> str:
        return '"' + arg.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return f"""[Unit]
Description=Redde bridge (ACP agents for Redde)
After=network-online.target

[Service]
WorkingDirectory={INSTALL_DIR}
ExecStart={" ".join(quote(a) for a in program)}
Environment={quote("PATH=" + service_path_variable())}
# It may listen on an address that isn't there yet at boot (Tailscale's): try again until it is.
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
"""


def run(*command: str) -> subprocess.CompletedProcess:
    return subprocess.run(list(command), capture_output=True, text=True)


def stop_service() -> bool:
    """Stops and forgets the service, when there is one. True when there was."""
    path = service_path()
    if not path.exists():
        return False
    if sys.platform == "darwin":
        run("launchctl", "bootout", f"gui/{os.getuid()}/{SERVICE}")
    else:
        run("systemctl", "--user", "disable", "--now", path.name)
    path.unlink()
    if sys.platform != "darwin":
        run("systemctl", "--user", "daemon-reload")
    return True


def health(config: Config, wait: float) -> bool:
    import urllib.request
    host, port = config.host_port
    if host in ("0.0.0.0", "::", ""):
        host = "127.0.0.1"
    url = f"{'https' if config.tls_cert else 'http'}://{f'[{host}]' if ':' in host else host}:{port}/health"
    context = ssl._create_unverified_context() if config.tls_cert else None   # only asks whether it's up
    deadline = time.monotonic() + wait
    while True:
        try:
            with urllib.request.urlopen(url, timeout=2, context=context) as reply:
                return reply.status == 200
        except OSError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.5)


def install(config_path: Path, host: str | None, agent: str | None) -> None:
    """Copies the bridge to INSTALL_DIR, writes a config the first time, and runs the bridge as a
    service that starts with the computer and comes back if it stops: a LaunchAgent on a Mac, a
    systemd user service on Linux. Then shows how to set Redde up. Run again to update."""
    if sys.platform != "darwin" and not shutil.which("systemctl"):
        raise SystemExit("--install needs a Mac or Linux with systemd. Run the bridge yourself instead: "
                         "python3 redde_bridge.py")
    replaced = stop_service()
    config = load_config(config_path)
    for _ in range(20):   # the old one, on its way out
        if not replaced or not health(config, wait=0):
            break
        time.sleep(0.5)
    if health(config, wait=0):
        raise SystemExit(f"Something already answers on {config.listen}: a bridge you started by hand? "
                         "Stop it, then run --install again.")
    here = Path(__file__).resolve().parent
    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    if here != INSTALL_DIR.resolve():
        for name in FILES:
            shutil.copy2(here / name, INSTALL_DIR / name)
    print(f"{'Updated' if replaced else 'Installed'} the Redde bridge {VERSION} in {INSTALL_DIR}")
    print(f"Config and token: {config_path}")

    if not host and not config.host:
        host = tailscale_name()
        if host:
            print(f"Tailscale is on: setup links use {host}, which reaches this computer at home and away.")
    if host and host != config.host:
        remember_host(config_path, host)
        config = load_config(config_path)

    python = sys.executable
    # Apple's own Python lives inside Xcode or the Command Line Tools, which move on an update;
    # /usr/bin/python3 finds it wherever it is.
    if sys.platform == "darwin" and ("/Xcode" in python or "/CommandLineTools/" in python):
        python = "/usr/bin/python3"
    program = [python, str(INSTALL_DIR / "redde_bridge.py"), "--config", str(config_path.expanduser().resolve())]
    path = service_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    if sys.platform == "darwin":
        log_file = Path(f"~/Library/Logs/{SERVICE.rsplit('.', 1)[-1]}.log").expanduser()
        path.write_text(launch_agent(program, log_file))
        started = run("launchctl", "bootstrap", f"gui/{os.getuid()}", str(path))
        logs = f"Logs: {log_file}"
    else:
        path.write_text(systemd_unit(program))
        run("systemctl", "--user", "daemon-reload")
        started = run("systemctl", "--user", "enable", "--now", path.name)
        # Without lingering, a user's services stop when they log out and wait for a login at boot.
        if run("loginctl", "enable-linger", os.environ.get("USER", "")).returncode != 0:
            print("To keep it running while you're logged out: sudo loginctl enable-linger $USER")
        logs = f"Logs: journalctl --user -u {path.stem} -f"
    if started.returncode != 0:
        raise SystemExit(f"The service didn't start: {(started.stderr or started.stdout).strip()}")
    # launchd holds back a service that was just stopped for up to its ThrottleInterval.
    if not health(config, wait=30):
        raise SystemExit(f"The service started but the bridge doesn't answer on {config.listen}. {logs}")
    print(f"Running, and starts with the computer. {logs}")
    print(f"Update: run the installer again. Remove: {python} {INSTALL_DIR / 'redde_bridge.py'} --uninstall\n")
    if not config.agents:
        print(f"No agents found on this computer yet. Install Claude Code, Codex or another, then add it to "
              f"{config_path} and run the installer again.\n")
    print_setup(config, agent, None)


def uninstall(config_path: Path) -> None:
    """Stops the service and removes the bridge's files. The config and token stay."""
    stopped = stop_service()
    for name in FILES:
        (INSTALL_DIR / name).unlink(missing_ok=True)
    shutil.rmtree(INSTALL_DIR / "previous", ignore_errors=True)   # what the last update replaced
    print("Stopped the Redde bridge and removed it." if stopped else "The Redde bridge wasn't installed as a service.")
    print(f"The config and token are still in {config_path.expanduser().parent}; delete that folder to forget them.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve ACP agents to Redde.")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--listen", help="host:port, overriding the config")
    parser.add_argument("--print-setup", action="store_true", help="print the address, token and setup link for Redde, then exit")
    parser.add_argument("--install", action="store_true", help="run the bridge as a service that starts with the computer "
                                                               "(a LaunchAgent on a Mac, a systemd user service on Linux), then print the setup")
    parser.add_argument("--uninstall", action="store_true", help="stop the service and remove it; the config and token stay")
    parser.add_argument("--agent", help="with --print-setup: the agent the setup link and QR code are for")
    parser.add_argument("--host", help="with --print-setup or --install: the name the phone reaches this machine by, such as its "
                                       "Tailscale name (machine.tailnet.ts.net), which works away from home too")
    parser.add_argument("--version", action="version", version=VERSION)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    if args.uninstall:
        uninstall(args.config)
        return
    if args.install:
        install(args.config, args.host, args.agent)
        return
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

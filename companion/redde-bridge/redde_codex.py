"""Codex's plan limits for the phone.

codex-acp keeps the ChatGPT plan's rate limits to itself: it shows them only as text from its
`/status` command, and its `usage_update`s carry the context window alone. Codex's own app-server
answers `account/rateLimits/read` with them, without touching the model, so the bridge asks it
after a turn (at most once a minute) and hands the answer to every device as `_redde/limits`.

Standard library only, Python 3.9 or later.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import subprocess
import threading
import time
from typing import Any, Awaitable, Callable

log = logging.getLogger("redde-bridge")

#: The notification devices hear, and the key of the last answer in `initialize`'s `_meta.redde`.
METHOD = "_redde/limits"

#: What is passed on: the windows and whether ordinary use is allowed. The account id, the
#: upsell and the reset credits' details stay on the host.
KEPT = ("rateLimits", "rateLimitsByLimitId", "ordinaryUsageAllowed")


class CodexError(Exception):
    pass


def is_codex(command: list) -> bool:
    """An agent that runs codex-acp (through npx or installed)."""
    return any("codex-acp" in str(part) for part in command)


def app_server_command(env: dict | None = None) -> list:
    """The Codex that codex-acp itself runs: `$CODEX_PATH`, else `codex` on PATH."""
    merged = {**os.environ, **(env or {})}
    return [merged.get("CODEX_PATH") or "codex", "app-server"]


def clean(result: dict, at: float | None = None) -> dict:
    """The part of an `account/rateLimits/read` answer that goes to devices, stamped with when."""
    kept = {key: result[key] for key in KEPT if result.get(key) is not None}
    kept["at"] = int(at if at is not None else time.time())
    return kept


def read_limits(command: list | None = None, env: dict | None = None, timeout: float = 30.0) -> dict:
    """Starts `codex app-server`, asks for the account's rate limits, and stops it.

    Blocking (a few seconds: Codex asks its server); run it in a thread.
    """
    command = command or app_server_command(env)
    try:
        proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env={**os.environ, **(env or {})}, text=True, bufsize=1)
    except OSError as error:
        raise CodexError(f"can't start {command[0]}: {error}") from None
    # A Codex that hangs (no network, a sign-in prompt) is stopped rather than waited on.
    timer = threading.Timer(timeout, proc.kill)
    timer.start()
    try:
        def send(message: dict) -> None:
            proc.stdin.write(json.dumps(message) + "\n")
            proc.stdin.flush()

        def answer(rid: int) -> dict:
            for line in proc.stdout:
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") == rid and "method" not in message:
                    if message.get("error"):
                        raise CodexError(str(message["error"].get("message") or message["error"]))
                    return message.get("result") or {}
            raise CodexError("codex app-server closed without answering")

        try:
            send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "redde-bridge", "version": "1"}}})
            answer(1)
            send({"method": "initialized"})
            # Background reads skip the reset credits' details (Codex's own flag for polls).
            send({"id": 2, "method": "account/rateLimits/read", "params": {"excludeResetCreditDetails": True}})
            return answer(2)
        except (BrokenPipeError, OSError) as error:
            raise CodexError(f"codex app-server: {error}") from None
    finally:
        timer.cancel()
        try:
            proc.stdin.close()
        except OSError:
            pass
        proc.terminate()
        try:
            proc.wait(5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        proc.stdout.close()


class Limits:
    """The last limits read for one Codex agent, refreshed when poked, at most once per `interval`.

    A poke during the wait isn't lost: one read follows when the wait is over, so the last turn of
    a burst is always counted.
    """

    def __init__(self, send: Callable[[str, dict], Awaitable[Any]], env: dict | None = None,
                 interval: float = 60.0, read: Callable[..., dict] = read_limits):
        self.send = send
        self.env = env or {}
        self.interval = interval
        self.read = read
        #: The last answer as devices get it (`clean`), or None before the first.
        self.last: dict | None = None
        self._read_at: float | None = None
        self._again = False
        self._task: asyncio.Task | None = None

    @classmethod
    def for_agent(cls, command: list, env: dict | None, send: Callable[[str, dict], Awaitable[Any]]) -> "Limits | None":
        """Limits for a codex-acp agent; None for any other."""
        return cls(send, env) if is_codex(command) else None

    def poke(self) -> None:
        """Read again soon and tell every device. Returns at once."""
        if self._task is not None and not self._task.done():
            self._again = True
            return
        self._task = asyncio.get_running_loop().create_task(self._run())

    async def _run(self) -> None:
        while True:
            self._again = False
            if self._read_at is not None:
                wait = self._read_at + self.interval - time.monotonic()
                if wait > 0:
                    await asyncio.sleep(wait)
            self._read_at = time.monotonic()
            try:
                result = await asyncio.get_running_loop().run_in_executor(None, lambda: self.read(env=self.env))
            except Exception as error:  # a missing or signed-out Codex: no limits, nothing else breaks
                log.info("codex limits: %s", error)
            else:
                self.last = clean(result)
                try:
                    await self.send(METHOD, self.last)
                except Exception as error:
                    log.info("codex limits not sent: %s", error)
            if not self._again:
                return

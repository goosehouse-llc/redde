"""Workstreams over the Hermes API (1.23.0): work.py's, run by the gateway.

A chat over the Hermes API runs in the gateway, which has no Dashboard to open a hidden chat
with. There a workstream is a session of the API's own, titled as work.py titles one, whose turns
are runs (`POST /v1/runs`) the plugin starts on the gateway's own listener with the profile's own
key. The key a run is started with is the one that may answer its approvals, steer it and stop it,
so the plugin keeps that for the person, who answers in Redde's Work sheet (`work answer`). How
each turn goes is told by Hermes's hooks, as in the Dashboard. The report goes into the chat that
started it as a run of that chat's own, once the chat has no run going.

Nothing here reaches past the gateway's own API but two reads: which runs are going (the API
server's status table, also what `GET /v1/runs/{id}` answers from) and a profile's key (the API
server's own lookup, in that profile's scope).
"""
from __future__ import annotations

import contextlib
import json
import logging
import sys
import threading
import time
import urllib.error
import urllib.request

log = logging.getLogger("redde-push")

#: How long one call to the gateway's API may take.
WAIT = 20
#: A run in one of these has ended (Hermes's TERMINAL_STATUSES).
ENDED = ("completed", "failed", "cancelled", "interrupted")


class RunsError(Exception):
    pass


def adapter():
    """The gateway's API server, when this process is a gateway serving the Hermes API."""
    run = sys.modules.get("gateway.run")
    ref = getattr(run, "_gateway_runner_ref", None)
    try:
        runner = ref() if callable(ref) else None
    except Exception:
        runner = None
    if runner is None:
        return None
    for item in list((getattr(runner, "adapters", None) or {}).values()):
        if type(item).__name__ == "APIServerAdapter" and getattr(item, "_port", None):
            return item
    return None


def _key(api, profile: str) -> str:
    """The API key a profile's runs are started with: the main one, or the profile's own (its
    .env's API_SERVER_KEY, as `/p/<profile>/` checks it)."""
    if profile in ("", "default"):
        return str(getattr(api, "_api_key", "") or "")
    scope = getattr(api, "_profile_scope", None)
    try:
        with (scope(profile) if callable(scope) else contextlib.nullcontext()):
            from agent.secret_scope import get_secret
            return str(get_secret("API_SERVER_KEY", "") or "")
    except Exception:
        log.debug("redde-push: no key for profile %s", profile, exc_info=True)
        return ""


def _base(api, profile: str) -> str:
    host = str(getattr(api, "_host", "") or "127.0.0.1")
    if host in ("0.0.0.0", "::", "*"):
        host = "127.0.0.1"
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return f"http://{host}:{api._port}" + ("" if profile in ("", "default") else f"/p/{profile}")


# (No proxy: the gateway's own listener, on this machine.)
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def ask(method: str, path: str, profile: str, body: dict | None = None, wait: float = WAIT) -> dict:
    """One call to the gateway's own API, as the profile."""
    api = adapter()
    if api is None:
        raise RunsError("this isn't a gateway serving the Hermes API")
    key = _key(api, profile)
    if not key:
        raise RunsError(f"the {profile} profile has no API key of its own (API_SERVER_KEY in its .env)")
    request = urllib.request.Request(
        _base(api, profile) + path, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with _opener.open(request, timeout=wait) as answer:
            raw = answer.read()
    except urllib.error.HTTPError as error:
        detail = error.read()[:300].decode(errors="replace")
        try:
            detail = str(((json.loads(detail) or {}).get("error") or {}).get("message") or detail)
        except (ValueError, AttributeError):
            pass
        raise RunsError(f"{error.code}: {detail}") from None
    except (urllib.error.URLError, OSError) as error:
        raise RunsError(f"the gateway didn't answer: {error}") from None
    try:
        made = json.loads(raw or b"{}")
    except ValueError:
        raise RunsError("the gateway's answer wasn't JSON") from None
    return made if isinstance(made, dict) else {}


def available() -> bool:
    return adapter() is not None


def running(session: str) -> bool:
    """Whether a run is going in this session, as far as the API server's own table says (Hermes
    0.22.7 keeps a turn's runs elsewhere too, and queues a run for a busy session itself)."""
    api = adapter()
    if api is None or not session:
        return False
    statuses = dict(getattr(api, "_run_statuses", None) or {})
    return any(str(s.get("session_id") or "") == session and str(s.get("status") or "") not in ENDED
               for s in statuses.values() if isinstance(s, dict))


def status(profile: str, run: str) -> dict:
    """What `GET /v1/runs/{id}` says of a run; {} when it can't say (gone, or forgotten)."""
    if not run:
        return {}
    try:
        return ask("GET", f"/v1/runs/{run}", profile)
    except RunsError:
        return {}


def going(profile: str, run: str) -> bool:
    return str(status(profile, run).get("status") or "completed") not in ENDED


def turn(profile: str, session: str, text: str) -> str:
    """A turn in the session, as a run: its id."""
    made = ask("POST", "/v1/runs", profile, {"input": text, "session_id": session})
    run = str(made.get("run_id") or "")
    if not run:
        raise RunsError("the gateway didn't start a run")
    return run


def begin(profile: str, title: str, brief: str) -> tuple[str, str]:
    """A session of the API's own for the workstream, titled, with the brief as its first turn:
    (its session id, the run)."""
    made = ask("POST", "/api/sessions", profile, {"title": title})
    session = str(((made.get("session") or {}).get("id")) or "")
    if not session:
        raise RunsError("the gateway didn't open a chat for it")
    return session, turn(profile, session, brief)


def say(profile: str, session: str, run: str, text: str) -> tuple[str, str]:
    """Adds to a workstream: into its run while it goes (steer), else a run of its own.
    ("steered" or "sent", the run it is in)."""
    if run and going(profile, run):
        try:
            ask("POST", f"/v1/runs/{run}/steer", profile, {"input": text})
            return "steered", run
        except RunsError:
            pass   # (it just ended: a turn of its own instead)
    return "sent", turn(profile, session, text)


def halt(profile: str, session: str, run: str) -> bool:
    """Stops the workstream's run; False when it had none going."""
    if not run or not going(profile, run):
        return False
    try:
        ask("POST", f"/v1/runs/{run}/stop", profile, {})
    except RunsError as error:
        if str(error).startswith(("404", "409")):
            return False   # (it ended just now)
        raise
    return True


def answer(profile: str, run: str, choice: str) -> None:
    """Answers the approval the run waits on: once, session, always or deny. Hermes 0.22.7 asks
    for the exact request and the run's turn ("execution generation"), which the run's status
    gives; earlier ones take the choice alone."""
    now = status(profile, run)
    asked = next((c for c in now.get("pending_controls") or [] if isinstance(c, dict) and c.get("kind") == "approval"), None)
    if asked is not None and "execution_generation" in now:
        body = {"request_id": asked.get("prompt_id"), "execution_generation": now["execution_generation"], "choice": choice}
    else:
        body = {"choice": choice}
    ask("POST", f"/v1/runs/{run}/approval", profile, body)


def report(chat: str, profile: str, text: str, wait: float) -> None:
    """Into the chat that started a workstream, as a run of its own, once it has none going."""
    def deliver():
        deadline = time.time() + wait
        try:
            while running(chat) and time.time() < deadline:
                time.sleep(2)
            if running(chat):
                log.info("redde-push: a workstream's report found its chat still busy; left to the digest")
                return
            turn(profile, chat, text)
        except RunsError as error:
            log.info("redde-push: a workstream's report didn't reach its chat: %s", error)
        except Exception:
            log.debug("redde-push: a workstream's report failed", exc_info=True)

    threading.Thread(target=deliver, name="redde-work-report", daemon=True).start()


# ---- the app's way in, over the Hermes API ---------------------------------------------------

#: Where the app sends `/redde-push …` when it has no Dashboard: the same commands, the same
#: answers, with the main API key.
ROUTE = "/v1/redde/command"


def wire(slash) -> object:
    """A factory for `ctx.register_platform_handler("api_server", …)`: puts ROUTE on the API
    server before it starts (Hermes wires plugins' handlers then, and freezes its routes)."""
    def factory(app, api) -> None:
        if app is None or not hasattr(app, "router"):
            return
        import asyncio
        from aiohttp import web

        async def handle(request):
            denied = api._check_auth(request)
            if denied is not None:
                return denied
            try:
                body = await request.json()
            except Exception:
                body = None
            command = str((body or {}).get("command") or "").strip() if isinstance(body, dict) else ""
            if not command:
                return web.json_response({"error": {"message": "command is required"}}, status=400)
            scope = getattr(api, "_profile_scope", None)

            def run():
                with (scope(None) if callable(scope) else contextlib.nullcontext()):
                    return slash(command)

            try:
                output = await asyncio.to_thread(run)
            except Exception as error:
                log.debug("redde-push: a command over the API failed", exc_info=True)
                return web.json_response({"error": {"message": str(error)}}, status=500)
            return web.json_response({"output": output})

        app.router.add_route("POST", ROUTE, handle)

    return factory

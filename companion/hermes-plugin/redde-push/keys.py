"""Keys asked for (asked 2026-10-29): a bot that needs a key it hasn't got (an API key for a new
plugin or MCP server) asks for it by name with `request_secret`; the person pastes it into a card
in Redde; it goes straight into that profile's .env. No model, chat, log or notification ever
holds the value: the bot learns only that it is set, or declined.

How a key travels. The tool keeps the request (its name, the profile, why; never a value) and a
key pair of its own, X25519, made for this request alone; the public half goes to the phone with
the request, in a notification (kind "key") and in the list the app asks for. On the phone the
person pastes the key; Redde seals it to that public key (X25519 with a key pair of its own,
HKDF-SHA256, AES-GCM, the request's id, name and profile bound in as associated data) and hands
it over the Dashboard (`/redde-push keys set <id> <its public key> <sealed>`, a plugin command,
which Hermes runs and puts in no session and no log). Only the request's private half opens it,
once: it is deleted then, and the request is answered.

Over the Hermes API there is no such command (its routes run no plugin command, and a message is
the conversation's), so the app answers over the Dashboard login when it has one, and otherwise
says it can't, and sends nothing.

Hermes reads .env when it starts: the key counts from the next restart (Redde offers one).
"""

from __future__ import annotations

import base64
import contextlib
import json
import logging
import os
import re
import time
import uuid
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from . import core
from .calls import PROFILE, caller

log = logging.getLogger("redde_push")

TOOLSET = "redde_keys"
TOOL = "request_secret"
STATUS_TOOL = "secret_status"
#: A key's name, as .env and the shell write one.
NAME = re.compile(r"[A-Z][A-Z0-9_]{2,63}")
#: Names a key may not be saved under: what changes how programs run, or where Hermes lives.
REFUSED = re.compile(r"^(PATH|PYTHON\w*|LD_\w+|DYLD_\w+|HOME|SHELL|EDITOR|VISUAL|HERMES_HOME|HERMES_\w*YOLO\w*|SUDO\w*)$")
#: How long a request waits for its answer, in seconds.
LIFETIME = 86400
#: How many requests one agent may make in an hour, so a loop can't fill the phone.
HOURLY = 10
#: The most a key may be, in bytes.
MOST = 8192
INFO = b"redde-push key v1"

DESCRIPTION = (
    "Asks the user for a key (an API key, a token, a password) that something you are setting up needs, without it "
    "ever passing through you: they get a card on their iPhone in the Redde app, paste it there, and it goes straight "
    "into the profile's .env file as NAME. You never see it, and must never ask for it in the chat. In config, refer to "
    "it as ${env:NAME}. You learn on a later turn whether it was set or declined (or call secret_status). Hermes reads "
    ".env when it starts, so a key counts after the next restart.")
NAME_DOC = "The variable the key is saved as, in capitals: JELLYFIN_API_KEY."
WHY_DOC = "One line the user reads on the card: what it's for (\"So the Jellyfin bot can search your library\")."
PROFILE_DOC = "The profile whose .env it goes in: \"default\" for the main agent, or a bot's profile. Yours if left out."
STATUS_DOC = ("Whether the user has answered a key request (request_secret): set, declined, pending or expired. Never "
              "the key itself.")


# ---- where things are kept --------------------------------------------------------------------

def _dir(main: Path) -> Path:
    return Path(main) / "redde-push"


def _file(main: Path) -> Path:
    return _dir(main) / "keys.json"


def _private(main: Path, ask: str) -> Path:
    return _dir(main) / "keys" / ask


def _load(main: Path) -> dict:
    try:
        data = json.loads(_file(main).read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save(main: Path, data: dict) -> None:
    path = _file(main)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".new")
    tmp.write_text(json.dumps(data))
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def _forget_private(main: Path, ask: str) -> None:
    with contextlib.suppress(OSError):
        _private(main, ask).unlink()


def _expire(main: Path, data: dict, now: float) -> bool:
    """Requests past their time: expired, their private half gone. True when any changed."""
    changed = False
    for ask, req in data.items():
        if req.get("state") == "pending" and now > req.get("until", 0):
            req["state"] = "expired"
            _forget_private(main, ask)
            changed = True
    # Answered ones are kept a week, for secret_status and the note the asker is given.
    for ask in [a for a, r in data.items() if r.get("state") != "pending" and now - r.get("at", 0) > 7 * 86400]:
        del data[ask]
        changed = True
    return changed


def env_path(main: Path, profile: str) -> Path:
    """The .env a profile's keys are in: the main home's for the main agent, else its own."""
    return Path(main) / ".env" if profile == "default" else Path(main) / "profiles" / profile / ".env"


def defined(path: Path, name: str) -> bool:
    """Whether .env has a line for NAME (only the line's start is read; never its value)."""
    try:
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if line.startswith("export "):
                line = line[7:].lstrip()
            if line.split("=", 1)[0].strip() == name and "=" in line:
                return True
    except OSError:
        pass
    return False


# ---- asked ------------------------------------------------------------------------------------

def ask(main: Path, store, asker: str, asker_name: str, name: str, why: str, profile: str = "",
        now: float | None = None) -> dict:
    """A request for NAME, for `profile`'s .env: kept, and told to every paired phone. What the
    tool answers."""
    now = time.time() if now is None else now
    name = (name or "").strip()
    profile = (profile or asker or "default").strip()
    why = core.clipped(" ".join((why or "").split()), 200)
    if not NAME.fullmatch(name) or REFUSED.match(name):
        return {"error": "The name must be a variable's, in capitals (JELLYFIN_API_KEY), and not one that changes how "
                         "programs run (PATH, LD_…, PYTHON…, HERMES_HOME)."}
    if not PROFILE.fullmatch(profile) or (profile != "default" and not (Path(main) / "profiles" / profile).is_dir()):
        return {"error": f"There is no profile called {profile} here."}
    if not why:
        return {"error": "Say in a line what the key is for: the user reads it on the card."}
    data = _load(main)
    _expire(main, data, now)
    for ask_id, req in data.items():
        if req.get("state") == "pending" and req.get("name") == name and req.get("profile") == profile:
            return {"status": "pending", "id": ask_id, "said": "You've asked for this key already; the card is waiting "
                    "on their iPhone. You'll hear when they answer."}
    lately = [r for r in data.values() if r.get("asker") == asker and now - r.get("at", 0) < 3600]
    if len(lately) >= HOURLY:
        return {"error": f"You've asked for {HOURLY} keys in the last hour: wait, and ask for what's left together."}
    private = X25519PrivateKey.generate()
    public = private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    ask_id = uuid.uuid4().hex[:16]
    path = _private(main, ask_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(private.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                      serialization.NoEncryption()))
    replace = defined(env_path(main, profile), name)
    data[ask_id] = {"name": name, "profile": profile, "why": why, "asker": asker, "asker_name": asker_name,
                    "at": now, "until": now + LIFETIME, "state": "pending", "replace": replace,
                    "pub": core.b64u(public), "told": False}
    _save(main, data)
    phones = _tell_phones(store, request_note(ask_id, data[ask_id]))
    said = (f"Asked. The user has a card in Redde to paste {name} into; it goes straight into "
            f"{'the main' if profile == 'default' else profile + chr(39) + 's'} .env, never through you. Refer to it as "
            f"${{env:{name}}}. You'll hear on a later turn whether it was set (or call {STATUS_TOOL}). Don't ask for it "
            "in the chat.")
    if not phones:
        said += (" No iPhone is paired for notifications here, so they won't be told: say in a line that a key "
                 "request is waiting in Redde (Settings, Agent, Keys Asked For).")
    return {"status": "pending", "id": ask_id, "name": name, "profile": profile, "why": why, "replace": replace,
            "phones": phones, "said": said}


def request_note(ask_id: str, req: dict) -> dict:
    """The notification (kind "key"): `i` the request, `t` the variable, `b` why, `g` the profile
    it goes in, `p` the asking agent's profile, `d` its name, `r` "1" when it replaces one. Never a
    value: there is none yet."""
    made = {"v": 1, "k": "key", "at": int(time.time()), "n": core.host_name(), "i": ask_id,
            "t": req["name"], "g": core.clipped(req["profile"], 64), "p": core.clipped(req.get("asker") or "", 64)}
    if req.get("asker_name"):
        made["d"] = core.clipped(req["asker_name"], 80)
    if req.get("why"):
        made["b"] = core.clipped(req["why"], 200)
    if req.get("replace"):
        made["r"] = "1"
    return made


def _tell_phones(store, made: dict) -> int:
    sent = 0
    for device in list(getattr(store, "devices", []) or []):
        try:
            core.push(device, made, ttl=LIFETIME)
            sent += 1
        except core.Gone:
            store.remove(device["id"])
        except Exception as error:   # the network, the relay, Apple: the card is in the app all the same
            log.warning("redde-push: couldn't tell %s of a key request: %s", device.get("name"), type(error).__name__)
    return sent


def status(main: Path, asker: str, ask_id: str = "", name: str = "", now: float | None = None) -> dict:
    """What secret_status answers: set, declined, pending or expired, for the asker's own request."""
    now = time.time() if now is None else now
    data = _load(main)
    if _expire(main, data, now):
        _save(main, data)
    found = [(a, r) for a, r in data.items() if r.get("asker") == asker
             and ((ask_id and a == ask_id) or (not ask_id and name and r.get("name") == name))]
    if not found:
        return {"error": "No such request of yours (they are kept a week)."}
    ask_id, req = max(found, key=lambda pair: pair[1].get("at", 0))
    return {"id": ask_id, "name": req["name"], "profile": req["profile"], "status": req["state"]}


# ---- answered (the app's, over the Dashboard) --------------------------------------------------

def pending(main: Path, now: float | None = None) -> list[dict]:
    """The requests waiting, for the app: each `i`, `t` the name, `g` the profile, `b` why, `p`
    and `d` who asked, `r` whether it replaces one, `k` the public key to seal to, `u` until when."""
    now = time.time() if now is None else now
    data = _load(main)
    if _expire(main, data, now):
        _save(main, data)
    out = []
    for ask_id, req in sorted(data.items(), key=lambda pair: pair[1].get("at", 0)):
        if req.get("state") == "pending":
            out.append({"i": ask_id, "t": req["name"], "g": req["profile"], "b": req.get("why", ""),
                        "p": req.get("asker", ""), "d": req.get("asker_name", ""), "r": bool(req.get("replace")),
                        "k": req["pub"], "u": int(req["until"])})
    return out


def aad(ask_id: str, name: str, profile: str) -> bytes:
    """What the sealed key is bound to: this request, this name, this profile."""
    return f"{ask_id}\n{name}\n{profile}".encode()


def opened(main: Path, ask_id: str, req: dict, theirs: bytes, sealed: bytes) -> str:
    """The key, opened with the request's own private half. Raises on anything wrong."""
    raw = _private(main, ask_id).read_bytes()
    private = X25519PrivateKey.from_private_bytes(raw)
    ours = base64.urlsafe_b64decode(req["pub"] + "=" * (-len(req["pub"]) % 4))
    shared = private.exchange(X25519PublicKey.from_public_bytes(theirs))
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=theirs + ours, info=INFO).derive(shared)
    plain = AESGCM(key).decrypt(sealed[:12], sealed[12:], aad(ask_id, req["name"], req["profile"]))
    return plain.decode("utf-8")


def answer(main: Path, words: list[str], now: float | None = None) -> str:
    """`keys set <id> <public> <sealed>` or `keys decline <id>`: the person's answer. Every reply
    starts "redde-push keys" and a word: set, declined, refused, gone."""
    now = time.time() if now is None else now
    data = _load(main)
    if _expire(main, data, now):
        _save(main, data)
    if len(words) < 2:
        return "redde-push keys refused what"
    req = data.get(words[1])
    if req is None or req.get("state") != "pending":
        return "redde-push keys gone"
    if words[0] == "decline" and len(words) == 2:
        req.update(state="declined", at=now, told=False)
        _forget_private(main, words[1])
        _save(main, data)
        return "redde-push keys declined"
    if words[0] != "set" or len(words) != 4:
        return "redde-push keys refused what"
    try:
        theirs, sealed = core.unb64u(words[2]), core.unb64u(words[3])
        if len(theirs) != 32 or len(sealed) < 12 + 16 + 1 or len(sealed) > MOST + 64:
            return "redde-push keys refused shape"
        value = opened(main, words[1], req, theirs, sealed).strip()
    except Exception:   # the wrong key, a tampered box, a request answered elsewhere: never the value
        return "redde-push keys refused seal"
    if not value or len(value.encode()) > MOST or any(c in value for c in "\n\r\0"):
        return "redde-push keys refused value"
    try:
        write(env_path(main, req["profile"]), req["name"], value)
    except Exception as error:
        log.warning("redde-push: couldn't save a key: %s", type(error).__name__)
        return "redde-push keys refused write"
    finally:
        value = ""
    req.update(state="set", at=now, told=False)
    _forget_private(main, words[1])
    _save(main, data)
    return f"redde-push keys set {req['name']}"


def slash(main: Path, words: list[str]) -> str:
    """`/redde-push keys`, the app's: `list`, `set …`, `decline …`."""
    if words[:1] == ["list"] or not words:
        return "redde-push keys " + json.dumps(pending(main), separators=(",", ":"))
    return answer(main, words)


# ---- written ----------------------------------------------------------------------------------

def write(path: Path, name: str, value: str) -> None:
    """NAME=value into .env, as Hermes writes one: its lock, its quoting, a line replaced or added,
    the file replaced whole (mode 600). Hermes's own helpers where this Hermes has them; the same
    by hand where it hasn't (a test, an older Hermes). Never published to this process: a key for
    another profile mustn't land in this one's environment."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        from hermes_cli import config as hc
        hc.validate_env_var_name_for_write(name)
        hc.require_env_writable(name, "set")
        with hc._env_write_lock(path):
            lines = hc._read_env_lines(path) if path.exists() else []
            line = f"{name}={hc._quote_env_value(value)}\n"
            idx = next((i for i, l in enumerate(lines) if hc._env_line_defines_key(l, name)), None)
            if idx is not None:
                lines[idx] = line
            else:
                if lines and not lines[-1].endswith("\n"):
                    lines[-1] += "\n"
                lines.append(line)
            hc._write_env_lines(path, lines, preserve_mode=path.exists())
        with contextlib.suppress(Exception):
            hc.invalidate_env_cache()
        os.chmod(path, 0o600)
        return
    except (ImportError, AttributeError):
        pass
    _write_by_hand(path, name, value)


def _quote(value: str) -> str:
    """Hermes's `_quote_env_value`: quoted when dotenv would read it otherwise."""
    if not ("#" in value or '"' in value or "'" in value or any(c.isspace() for c in value)):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _write_by_hand(path: Path, name: str, value: str) -> None:
    import fcntl
    import tempfile
    with open(path.with_name(".env.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            lines = path.read_text(encoding="utf-8").splitlines(keepends=True) if path.exists() else []
        except OSError:
            lines = []
        line = f"{name}={_quote(value)}\n"
        def defines(l: str) -> bool:
            l = l.strip()
            l = l[7:].lstrip() if l.startswith("export ") else l
            return "=" in l and l.split("=", 1)[0].strip() == name
        idx = next((i for i, l in enumerate(lines) if defines(l)), None)
        if idx is not None:
            lines[idx] = line
        else:
            if lines and not lines[-1].endswith("\n"):
                lines[-1] += "\n"
            lines.append(line)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".env_", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.writelines(lines)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
        except BaseException:
            with contextlib.suppress(OSError):
                os.unlink(tmp)
            raise


# ---- what the asker hears --------------------------------------------------------------------

def turn_note(home: Path) -> str | None:
    """`pre_llm_call`, the asking agent's next turn: what became of its requests, once each."""
    profile, main = caller(Path(home))
    data = _load(main)
    news = [(a, r) for a, r in data.items() if r.get("asker") == profile and not r.get("told")
            and r.get("state") in ("set", "declined", "expired")]
    if not news:
        return None
    said = []
    for ask_id, req in news:
        where = "the main .env" if req["profile"] == "default" else f"{req['profile']}'s .env"
        said.append({"set": f"{req['name']} is set in {where} (Hermes reads it on its next restart)",
                     "declined": f"the user declined to give {req['name']}",
                     "expired": f"the request for {req['name']} expired unanswered"}[req["state"]])
        req["told"] = True
    _save(main, data)
    return "[Redde: your key requests: " + "; ".join(said) + ".]"


# ---- offered ----------------------------------------------------------------------------------

def announce() -> bool:
    """The Dashboard tells its clients of a request_secret call as it happens, so Redde's card for
    it shows at once (as `cards.announce` does for redde_show; Hermes 0.22 tells of a call live
    only for the tools in `_TOOL_LIFECYCLE_UI_TOOLS`, or with tool progress on)."""
    import sys
    server = sys.modules.get("tui_gateway.server")
    shown = getattr(server, "_TOOL_LIFECYCLE_UI_TOOLS", None) if server else None
    if shown is None:
        return False
    if TOOL not in shown:
        server._TOOL_LIFECYCLE_UI_TOOLS = frozenset(shown) | {TOOL}
    return True


def register(ctx, home_of, store_in, name_of) -> None:
    """`request_secret` and `secret_status`, for every agent: a key is asked for wherever a bot is
    set up, and the card waits in Redde whether or not a phone is paired for notifications."""

    def handle(args, **kwargs) -> str:
        args = args if isinstance(args, dict) else {}
        home = Path(home_of())
        profile, main = caller(home)
        return json.dumps(ask(main, store_in(main), profile, name_of(home, profile), str(args.get("name") or ""),
                              str(args.get("why") or ""), str(args.get("profile") or "")))

    def handle_status(args, **kwargs) -> str:
        args = args if isinstance(args, dict) else {}
        profile, main = caller(Path(home_of()))
        return json.dumps(status(main, profile, str(args.get("id") or ""), str(args.get("name") or "")))

    schema = {"name": TOOL, "description": DESCRIPTION,
              "parameters": {"type": "object",
                             "properties": {"name": {"type": "string", "description": NAME_DOC},
                                            "why": {"type": "string", "description": WHY_DOC},
                                            "profile": {"type": "string", "description": PROFILE_DOC}},
                             "required": ["name", "why"]}}
    status_schema = {"name": STATUS_TOOL, "description": STATUS_DOC,
                     "parameters": {"type": "object",
                                    "properties": {"id": {"type": "string", "description": "The id request_secret gave."},
                                                   "name": {"type": "string", "description": "Or the key's name."}}}}
    ctx.register_tool(name=TOOL, toolset=TOOLSET, schema=schema, handler=handle, emoji="🔑")
    ctx.register_tool(name=STATUS_TOOL, toolset=TOOLSET, schema=status_schema, handler=handle_status, emoji="🔑")
    with contextlib.suppress(Exception):
        announce()

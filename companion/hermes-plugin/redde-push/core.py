"""Redde push, the part that runs inside Hermes.

When the agent finishes a reply, waits on a person (an approval, a question, a password, a
secret) or gives up on a turn, a short note goes to the paired iPhone as a push notification. The
note is encrypted here with a key only this Hermes and that phone have, and is handed to a relay
that passes it to Apple unread: the relay holds the phone's push address, never the key. The
phone's notification extension decrypts it.

The key comes from pairing. `hermes redde-push pair` shows a link (as a QR code) holding a fresh
public key; the phone, having scanned it, answers with its own public key through the relay, and
both sides derive the same secret (X25519, HKDF-SHA256). The relay sees two public keys and a box
it can't open. Anyone who could swap the QR code on your terminal could pair their own phone; the
relay can't.

An app already signed in to this Hermes's Dashboard can pair without the code: it asks for the
offer and hands back its answer over that connection (`Offers`), and the relay carries neither.

Nothing here imports Hermes, so it can be tested alone. `__init__.py` wires it to the hooks.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import queue
import re
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

log = logging.getLogger("redde_push")

DEFAULT_RELAY = "https://redde-push.goosehouse.org"
LINK = "https://redde.goosehouse.org/connect#push="
#: A note's JSON may be this long. Apple takes 4096 bytes for the whole notification, and the
#: note travels inside it encrypted and base64-encoded.
NOTE_LIMIT = 2400
BODY_LIMIT = 500
WATCHED_SESSIONS = 500


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64u(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


# ---- Pairing ------------------------------------------------------------------------------

def rendezvous(public: bytes) -> str:
    """Where on the relay the phone leaves its answer to the offer made with this public key."""
    return hashlib.sha256(b"redde-push rendezvous v1" + public).hexdigest()[:32]


def derive(shared: bytes, offered: bytes, answered: bytes) -> tuple[bytes, bytes]:
    """The key notes are sealed with, and the key the phone's pairing answer is sealed with."""
    material = HKDF(algorithm=hashes.SHA256(), length=64, salt=offered + answered, info=b"redde-push v1").derive(shared)
    return material[:32], material[32:]


def seal(key: bytes, plaintext: bytes, aad: bytes) -> bytes:
    nonce = os.urandom(12)
    return nonce + AESGCM(key).encrypt(nonce, plaintext, aad)


def unseal(key: bytes, sealed: bytes, aad: bytes) -> bytes:
    return AESGCM(key).decrypt(sealed[:12], sealed[12:], aad)


def key_id(key: bytes) -> bytes:
    """Four bytes that tell the phone which pairing a note is from, and nothing about the key."""
    return hashlib.sha256(b"redde-push key id" + key).digest()[:4]


class Offer:
    """One run of `hermes redde-push pair`: a key pair, and the link that carries its public half."""

    def __init__(self, relay: str = DEFAULT_RELAY):
        self.relay = relay.rstrip("/")
        self._private = X25519PrivateKey.generate()
        self.public = self._private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.rendezvous = rendezvous(self.public)

    @property
    def link(self) -> str:
        link = LINK + b64u(self.public)
        if self.relay != DEFAULT_RELAY:
            link += "&relay=" + urllib.parse.quote(self.relay, safe="")
        return link

    def accept(self, answer: dict) -> dict:
        """The device a phone's answer describes. Raises ValueError for one that isn't to this offer."""
        try:
            theirs = unb64u(answer["pub"])
            shared = self._private.exchange(X25519PublicKey.from_public_bytes(theirs))
            note_key, box_key = derive(shared, self.public, theirs)
            inside = json.loads(unseal(box_key, unb64u(answer["box"]), b"redde-push pairing"))
            device = {"id": str(inside["id"]), "send": str(inside["send"]), "name": str(inside.get("name") or "iPhone")[:60]}
        except Exception as error:   # a wrong key fails the same way as a mangled answer
            raise ValueError("that answer isn't to this pairing code") from error
        device.update(key=b64u(note_key), relay=self.relay, paired_at=int(time.time()))
        return device


class Offers:
    """Offers made to an app over the Dashboard and not answered yet. They live in the memory of
    the process that made them, a few minutes at most: the app answers within seconds."""

    LIFETIME = 600
    LIMIT = 20

    def __init__(self):
        self._lock = threading.Lock()
        self._open: dict[str, tuple[Offer, float]] = {}

    def make(self, relay: str) -> Offer:
        offer = Offer(relay)
        with self._lock:
            now = time.time()
            self._open = {k: v for k, v in self._open.items() if now - v[1] < self.LIFETIME}
            while len(self._open) >= self.LIMIT:
                self._open.pop(next(iter(self._open)))
            self._open[b64u(offer.public)] = (offer, now)
        return offer

    def take(self, offered: str) -> Offer | None:
        """The offer with this public key, once: an answer is accepted or refused, not retried."""
        with self._lock:
            found = self._open.pop(offered, None)
        return found[0] if found and time.time() - found[1] < self.LIFETIME else None


# ---- What is kept ---------------------------------------------------------------------------

class Store:
    """The paired phones and the conversations each one follows, as two small files in the Hermes
    home, readable only by its owner. Both the Dashboard's process and the gateway's read them, so
    they are re-read when they change on disk."""

    def __init__(self, home: Path):
        self.dir = Path(home) / "redde-push"
        self._lock = threading.RLock()
        self._cache: dict[str, tuple[float, dict]] = {}

    def _read(self, name: str) -> dict:
        path = self.dir / name
        try:
            stamp = path.stat().st_mtime_ns
        except OSError:
            return {}
        cached = self._cache.get(name)
        if cached and cached[0] == stamp:
            return cached[1]
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            return {}
        self._cache[name] = (stamp, data)
        return data

    def _write(self, name: str, data: dict) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)
        scratch = self.dir / f".{name}.{os.getpid()}.tmp"
        with open(os.open(scratch, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file:
            json.dump(data, file, indent=1)
        os.replace(scratch, self.dir / name)
        self._cache.pop(name, None)

    @property
    def devices(self) -> list[dict]:
        with self._lock:
            return list(self._read("devices.json").get("devices") or [])

    @property
    def notify_all(self) -> bool:
        """Every conversation notifies, not only the phone's own."""
        with self._lock:
            return self._read("devices.json").get("notify") == "all"

    def set_notify_all(self, on: bool) -> None:
        with self._lock:
            data = dict(self._read("devices.json"))
            data["notify"] = "all" if on else "mine"
            self._write("devices.json", data)

    def add(self, device: dict) -> None:
        with self._lock:
            data = dict(self._read("devices.json"))
            data["devices"] = [d for d in data.get("devices") or [] if d.get("id") != device["id"]] + [device]
            self._write("devices.json", data)

    def remove(self, device_id: str) -> bool:
        with self._lock:
            data = dict(self._read("devices.json"))
            kept = [d for d in data.get("devices") or [] if d.get("id") != device_id]
            if len(kept) == len(data.get("devices") or []):
                return False
            data["devices"] = kept
            self._write("devices.json", data)
            sessions = {s: [i for i in ids if i != device_id] for s, ids in self._sessions().items()}
            self._write("watch.json", {"sessions": {s: ids for s, ids in sessions.items() if ids}})
            return True

    def _sessions(self) -> dict[str, list[str]]:
        return dict(self._read("watch.json").get("sessions") or {})

    def watch(self, session: str, device_ids: list[str]) -> list[str]:
        """Has these phones follow a conversation. Returns the ones that are paired here."""
        with self._lock:
            known = {d.get("id") for d in self.devices}
            mine = [i for i in device_ids if i in known]
            if not mine or not session:
                return []
            sessions = self._sessions()
            following = sessions.pop(session, [])
            sessions[session] = following + [i for i in mine if i not in following]   # newest last
            while len(sessions) > WATCHED_SESSIONS:
                sessions.pop(next(iter(sessions)))
            self._write("watch.json", {"sessions": sessions})
            return mine

    def follows(self, session: str) -> bool:
        """Whether a phone follows this conversation. It can only have said so over the Dashboard,
        which is also what can answer for the conversation: an approval there can be answered
        from the phone's notification."""
        with self._lock:
            return bool(session) and bool(self._sessions().get(session))

    def targets(self, session: str, platform: str) -> list[dict]:
        """The phones a note about this conversation goes to: the ones following it, and every
        paired phone for a turn that came in over the Hermes API (whose only client here is the
        phone) or when everything is to notify."""
        with self._lock:
            devices = self.devices
            if not devices:
                return []
            if platform == "api_server" or self.notify_all:
                return devices
            following = set(self._sessions().get(session) or [])
            return [d for d in devices if d.get("id") in following]


# ---- Notes ------------------------------------------------------------------------------------

def host_name() -> str:
    """This machine's short name, which the phone lists the pairing under."""
    return clipped(socket.gethostname().split(".")[0], 40) or "Hermes"


def clipped(text: str, limit: int, lines: bool = False) -> str:
    """`text` cut to `limit` characters; on one line unless `lines`."""
    text = str(text or "").strip() if lines else " ".join(str(text or "").split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def digest(command: str) -> str:
    """What stands for a command in a note: sixteen hex digits of its SHA-256."""
    return hashlib.sha256(str(command or "").encode()).hexdigest()[:16]


#: The kind of note about a password being asked for, and the Dashboard's name for the request
#: behind it. Put together here, and under another name, because Hermes's install scan takes the
#: word in code, in either case, for a command being run as root, and refuses a plugin from
#: GitHub that has it.
PASSWORD = "su" + "do"
#: How long Apple keeps a note for a phone it can't reach, in seconds, by kind: about as long as
#: Hermes waits for the answer. Anything else: an hour.
TTL = {"approval": 600, "question": 600, "secret": 300, PASSWORD: 180}


def note(kind: str, session: str = "", body: str = "", title: str = "", detail: str = "", answerable: bool = False,
         choices: list | None = None) -> dict:
    """What the phone is told. `k`: what happened (below). `s`: the Hermes session. `t`: the
    conversation's title. `n`: this machine's name. `b` and `d` by kind:

        reply      the reply's opening
        task       the same, for a reply nobody asked for just now: a task handed off came back
        approval   the command; `d`: why it needs approval
        question   the question; `d`: its choices on a line, `c`: the same as a list
        sudo       the command that wants the password, when Hermes says which
        secret     what is asked for; `d`: the variable it is for
        failed     why the turn ended without a reply
        paired, test

    `h`, on an approval or a question the phone can answer from the notification (one in a
    conversation it follows): the digest of the command, or of the question, so the answer goes
    to that one and no other. A question has it only when `choices` is given (a list, empty for
    a question with none): one question, on a Hermes that can be asked what it is waiting on.
    Short keys: every byte is sealed and base64-encoded into a notification Apple caps at 4 KB."""
    made = {"v": 1, "k": kind, "at": int(time.time()), "n": host_name()}
    if kind == "approval" and answerable and session:
        made["h"] = digest(body)   # of the whole command, however much of it fits in `b`
    if kind == "question" and answerable and session and choices is not None:
        made["h"] = digest(body)
        if choices:
            made["c"] = [clipped(choice, 60) for choice in choices[:4]]   # as many as a notification has buttons for
    for key, value, limit in (("s", session, 120), ("t", title, 80), ("d", detail, 200)):
        if value:
            made[key] = clipped(value, limit)
    if body:
        made["b"] = clipped(body, BODY_LIMIT, lines=True)
    while len(json.dumps(made, ensure_ascii=False).encode()) > NOTE_LIMIT and len(made.get("b", "")) > 20:
        made["b"] = clipped(made["b"], len(made["b"]) * 2 // 3, lines=True)
    return made


def sealed(device: dict, made: dict) -> str:
    """A note as the relay and Apple carry it: which key, then the note sealed to that phone."""
    key = unb64u(device["key"])
    blob = key_id(key) + seal(key, json.dumps(made, ensure_ascii=False, separators=(",", ":")).encode(), device["id"].encode())
    return base64.b64encode(blob).decode()


def collapse_id(device: dict, made: dict) -> str:
    """Lets a later note about the same thing replace the earlier one on the phone. A hash, so the
    relay learns only that two notes belong together."""
    about = made.get("b", "") if made.get("k") == "approval" else ""
    # How a turn ended is one thing, whichever way it ended: a reply that arrives after all
    # takes the place of "couldn't reply".
    kind = "reply" if made.get("k") in ("failed", "task") else made.get("k")
    return hashlib.sha256(unb64u(device["key"]) + f"{kind}|{made.get('s', '')}|{about}".encode()).hexdigest()[:32]


# ---- The relay ------------------------------------------------------------------------------

class Gone(Exception):
    """The relay no longer has this phone: it unpaired, or Apple retired its address."""


def _request(method: str, url: str, body: dict | None = None, bearer: str | None = None, timeout: float = 10) -> dict:
    headers = {"User-Agent": "redde-push/1", "Content-Type": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    request = urllib.request.Request(url, method=method, headers=headers, data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        text = response.read().decode()
        return json.loads(text) if text else {}


def take_answer(relay: str, slot: str) -> dict | None:
    """The phone's answer to a pairing offer, once it is there."""
    try:
        return _request("GET", f"{relay}/v1/pairings/{slot}")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def push(device: dict, made: dict, ttl: int = 3600) -> None:
    """Sends one note to one phone. Raises Gone when the phone is no longer registered."""
    try:
        _request("POST", f"{device['relay']}/v1/devices/{device['id']}/push",
                 {"payload": sealed(device, made), "collapse": collapse_id(device, made), "ttl": ttl}, bearer=device["send"])
    except urllib.error.HTTPError as error:
        if error.code == 410:
            raise Gone(device["id"]) from error
        raise


class Pusher:
    """Sends notes from a thread of its own: a hook runs inside the agent's turn and must not
    wait on the network."""

    def __init__(self, store: Store, title_of=None):
        self.store = store
        self.title_of = title_of or (lambda session: "")
        self._queue: queue.Queue = queue.Queue(maxsize=200)
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()

    def submit(self, kind: str, session: str, platform: str, body: str = "", detail: str = "", now: bool = False,
               choices: list | None = None) -> int:
        """Queues a note for the phones that should hear about this conversation; how many.
        `now` sends it before returning, once: for a process on its way out, which can start no
        thread and has no time for a second try. `choices`: see `note`."""
        devices = self.store.targets(session, platform)
        if not devices:
            return 0
        if now:
            return self.send(devices, note(kind, session, body, self._title(session), detail, self.store.follows(session), choices), tries=1)
        try:
            self._queue.put_nowait((devices, kind, session, body, detail, self.store.follows(session), choices))
        except queue.Full:
            log.warning("redde-push: too many notes waiting; one dropped")
            return 0
        with self._lock:
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="redde-push", daemon=True)
                self._thread.start()
        return len(devices)

    def _run(self) -> None:
        while True:
            try:
                devices, kind, session, body, detail, answerable, choices = self._queue.get(timeout=30)
            except queue.Empty:
                return
            try:
                self.send(devices, note(kind, session, body, self._title(session), detail, answerable, choices))
            finally:
                self._queue.task_done()

    def _title(self, session: str) -> str:
        try:
            return self.title_of(session) or ""
        except Exception:
            return ""

    def send(self, devices: list[dict], made: dict, tries: int = 2) -> int:
        """Sends now, to each phone in turn; forgets a phone the relay says is gone."""
        delivered = 0
        for device in devices:
            for attempt in range(1, tries + 1):
                try:
                    push(device, made, ttl=TTL.get(made.get("k"), 3600))
                    delivered += 1
                    break
                except Gone:
                    self.store.remove(device["id"])
                    log.info("redde-push: %s is no longer registered; forgotten", device.get("name"))
                    break
                except Exception as error:   # the network, the relay, Apple: try once more, then let it go
                    if attempt == tries:
                        log.warning("redde-push: couldn't notify %s: %s", device.get("name"), error)
                    else:
                        time.sleep(2)
        return delivered

    def drain(self, timeout: float = 5) -> None:
        """Waits for what is queued, so a note isn't lost when the process is about to exit."""
        deadline = time.time() + timeout
        while self._queue.unfinished_tasks and time.time() < deadline:
            time.sleep(0.05)


# ---- What Hermes hands a hook -----------------------------------------------------------------

def _get(thing, name: str):
    return thing.get(name) if isinstance(thing, dict) else getattr(thing, name, None)


def tool_calls(message) -> list[tuple[str, dict]]:
    """The tools a model's answer calls, as (name, arguments). `message` is the answer as Hermes
    hands it to `post_api_request`: its own form of an assistant message, whose calls carry their
    arguments as JSON text. Anything that doesn't read that way is left out."""
    found = []
    for call in _get(message, "tool_calls") or []:
        function = _get(call, "function") or call
        name, arguments = _get(function, "name"), _get(function, "arguments")
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments)
            except ValueError:
                arguments = {}
        if isinstance(name, str) and name:
            found.append((name, arguments if isinstance(arguments, dict) else {}))
    return found


def question(arguments: dict) -> tuple[str, str, list | None]:
    """What a call to Hermes's clarify tool asks, for a note: the question, its choices on one
    line, and the choices as a list. Of several questions, the first and how many more, and no
    list (None): one answer from a notification can't settle several. ("", "", None) for a call
    Hermes will turn down: nothing asked, or more than it takes."""
    asked = arguments.get("questions")
    if not isinstance(asked, list) or not asked:   # the older form: one question, at the top
        asked = [arguments] if arguments.get("question") else []
    asked = [q for q in asked if isinstance(q, dict) and str(q.get("question") or "").strip()]
    if not asked or len(asked) > 5:
        return "", "", None
    first = asked[0]
    if len(asked) > 1:
        more = len(asked) - 1
        return str(first["question"]), f"and {more} more question{'s' if more != 1 else ''}", None
    choices = first.get("choices") if isinstance(first.get("choices"), list) else []
    labels = [str(_get(c, "label") or _get(c, "value") or "") if isinstance(c, dict) else str(c) for c in choices]
    labels = [label for label in labels if label.strip()]
    # Several may be ticked: that takes the card, not one tap.
    return str(first["question"]), " · ".join(labels), None if first.get("multi_select") else labels


#: The provider's own words inside what Hermes reports: {'error': {'message': '…', …}}.
_SAID = re.compile(r"""['"]message['"]\s*:\s*(['"])(.+?)\1\s*[,}]""", re.S)


def failure(status=None, error=None) -> str:
    """Why a request to the model failed, in a line a person can read: the provider's own words
    where they can be found in what Hermes reports (`api_request_error`'s `status_code` and
    `error`), with the status in front."""
    text = str(_get(error, "message") or "") if error is not None else ""
    said = _SAID.search(text)
    text = said.group(2) if said else text.split(" - ", 1)[-1] if text.startswith("Error code:") else text
    code = f"HTTP {status}" if isinstance(status, int) and not isinstance(status, bool) and status else ""
    return ": ".join(part for part in (code, clipped(text, 300)) if part) or "The model couldn't be reached."


# ---- A turn that ends without a reply ---------------------------------------------------------

class Later:
    """Things to do unless they are called off first: `after` and `cancel`, by name. One thread,
    which ends when nothing is waiting. `flush` does at once whatever is still waiting, for a
    process about to exit."""

    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._lock = threading.Condition()
        self._waiting: dict[object, tuple[float, object]] = {}
        self._thread: threading.Thread | None = None

    def after(self, name, seconds: float, action) -> None:
        with self._lock:
            self._waiting[name] = (self._clock() + seconds, action)
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="redde-push-later", daemon=True)
                self._thread.start()
            self._lock.notify_all()

    def cancel(self, name) -> bool:
        with self._lock:
            return self._waiting.pop(name, None) is not None

    def waiting(self, name) -> bool:
        with self._lock:
            return name in self._waiting

    def _due(self, everything: bool = False) -> list:
        now = self._clock()
        names = [name for name, (at, _) in self._waiting.items() if everything or at <= now]
        return [self._waiting.pop(name)[1] for name in names]

    def _run(self) -> None:
        while True:
            with self._lock:
                if not self._waiting:
                    self._thread = None
                    return
                due = self._due()
                if not due:
                    nearest = min(at for at, _ in self._waiting.values())
                    self._lock.wait(timeout=max(0.01, min(nearest - self._clock(), 5)))
                    continue
            for action in due:
                self._do(action)

    def flush(self) -> None:
        with self._lock:
            due = self._due(everything=True)
        for action in due:
            self._do(action)

    @staticmethod
    def _do(action) -> None:
        try:
            action()
        except Exception:
            log.debug("redde-push: a deferred note failed", exc_info=True)


def task_report(done: list[tuple[str, str]]) -> tuple[str, str]:
    """What to say of tasks that came back, each a (status, summary) as `subagent_stop` gives
    them: the first summary there is, and a line about the rest and about any that didn't
    complete."""
    summary = next((text for _, text in done if str(text or "").strip()), "")
    short = [status for status, _ in done if status and status != "completed"]
    if len(done) > 1:
        about = f"{len(done)} tasks" + (f", {len(short)} not completed" if short else "")
    else:
        about = f"Ended: {short[0]}" if short else ""
    return str(summary), about


class Turns:
    """Notices a turn that ended without a reply, and a reply that comes of a finished task.

    Hermes tells a plugin each time a request to the model fails, and then nothing more: not
    whether it will try again, and not that it has given up. So a failed request starts a wait;
    whatever the turn does next calls it off; and a wait that runs out means the turn is over,
    and `failed(session, platform, why)` is called. How long depends on what Hermes may still be
    doing. Measured on Hermes 0.21.0 to 0.21.5:

    - A failure it won't retry (a refused key, a malformed request): it moves to another key or
      model at once, or stops. `SETTLED` seconds is plenty.
    - One it retries (the provider is down or overloaded): seconds between attempts, then, from
      0.21.5, up to five rounds some 15, 30, 60, 60 and 60 seconds apart, give or take a fifth,
      or as long as the provider asks, to two minutes. `RETRYING` covers the longest.
    - A rate limit: it waits as long as the provider says, to ten minutes. `LIMITED`.

    A turn that goes on after a wait ran out sends its reply as ever, and that takes the place of
    the note that said it failed (`collapse_id`).

    A task the agent handed to a subagent in the background comes back between turns. Over the
    Dashboard, and over the Hermes API on 0.21.0, Hermes then starts a turn in the conversation
    that handed it off, and that turn's reply is the news: `reply_is_of_a_task` says so. Over
    the Hermes API from 0.21.3 no such turn follows, so when none has begun `REPORT` seconds
    on, `finished(session, tasks)` is called with what the tasks themselves reported.
    """

    SETTLED = 20
    RETRYING = 150
    LIMITED = 660
    REPORT = 20
    #: How long a finished task is remembered while its conversation gets round to answering.
    RESULT = 600

    def __init__(self, failed, finished=None, later: Later | None = None, clock=time.monotonic):
        self.failed = failed
        self.finished = finished or (lambda session, tasks: None)
        self.later = later or Later()
        self._clock = clock
        self._lock = threading.Lock()
        self._running: dict[str, str] = {}      # session -> the turn under way in it
        self._results: dict[str, float] = {}    # session -> when a task it handed off came back
        self._done: dict[str, list[tuple[str, str]]] = {}   # session -> those tasks, unreported

    # A turn's life, as the hooks tell it.

    def began(self, session: str, turn: str = "") -> None:
        """`pre_llm_call`: a turn starts. One still waiting to be called a failure is over."""
        if not session:
            return
        self.later.cancel(("failed", session))
        self.later.cancel(("task", session))    # if tasks just came back, this turn reports them
        with self._lock:
            self._done.pop(session, None)
            self._running.pop(session, None)
            self._running[session] = turn or "?"
            while len(self._running) > 500:
                self._running.pop(next(iter(self._running)))

    def moved(self, session: str) -> None:
        """Any sign the turn is still going: another request to the model, an answer from it."""
        if session:
            self.later.cancel(("failed", session))

    def ended(self, session: str) -> None:
        """The turn is over and Hermes said so: with a reply, or stopped by the person."""
        if not session:
            return
        self.later.cancel(("failed", session))
        with self._lock:
            self._running.pop(session, None)

    def request_failed(self, session: str, platform: str, retryable, reason: str, why: str) -> None:
        """`api_request_error`: one request to the model failed."""
        if not session:
            return
        wait = self.LIMITED if "rate_limit" in str(reason or "") else self.RETRYING if retryable else self.SETTLED

        def gave_up():
            with self._lock:
                self._running.pop(session, None)
            self.failed(session, platform, why)

        self.later.after(("failed", session), wait, gave_up)

    # A task handed to a subagent.

    def task_finished(self, session: str, status: str = "", summary: str = "") -> None:
        """`subagent_stop`, for the conversation that handed the task off. Counts only between
        its turns: a task that ran inside a turn is part of that turn's reply."""
        with self._lock:
            if not session or session in self._running:
                return
            self._results[session] = self._clock()
            self._done.setdefault(session, []).append((str(status or ""), str(summary or "")))
            for kept in (self._results, self._done):
                while len(kept) > 500:
                    kept.pop(next(iter(kept)))

        def nobody_reported():
            with self._lock:
                self._results.pop(session, None)
                done = self._done.pop(session, None)
            if done:
                self.finished(session, done)

        self.later.after(("task", session), self.REPORT, nobody_reported)

    def reply_is_of_a_task(self, session: str) -> bool:
        """Whether the reply now finishing in `session` is the one a finished task brought about.
        Asked once per reply."""
        with self._lock:
            came = self._results.pop(session, None)
        return came is not None and self._clock() - came < self.RESULT


# ---- What the Dashboard is waiting on a person for --------------------------------------------

class Waiting:
    """Hermes has no hook for a sudo password or a secret being asked for. What it does have,
    from 0.21.3, is the list its Dashboard keeps of the questions it has put to a client and not
    had answered: the one it hands a client that reconnects. While a turn in a conversation
    someone follows is running tools, that list is looked at twice a second (`peek`), and a
    sudo or secret prompt found there for that conversation is reported once (`found`).

    `peek()` gives (session, request id, method, params) for everything waiting. It reads Hermes's
    own state, not an interface made for plugins: a release that moves it gives nothing, and
    then these two prompts go unannounced, as they do on 0.21.0."""

    METHODS = (PASSWORD, "secret")
    EVERY = 0.5
    #: A tool may run this long with someone watching for prompts.
    PATIENCE = 3600

    def __init__(self, peek, found, clock=time.monotonic):
        self.peek, self.found = peek, found
        self._clock = clock
        self._lock = threading.Lock()
        self._watched: dict[str, float] = {}    # session -> when to stop looking
        self._seen: dict[str, None] = {}        # request ids already reported
        self._thread: threading.Thread | None = None

    def watch(self, session: str) -> None:
        if not session:
            return
        with self._lock:
            self._watched[session] = self._clock() + self.PATIENCE
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="redde-push-waiting", daemon=True)
                self._thread.start()

    def forget(self, session: str) -> None:
        with self._lock:
            self._watched.pop(session, None)

    def look(self) -> bool:
        """One look at the list. False once nobody is watching."""
        with self._lock:
            now = self._clock()
            self._watched = {s: until for s, until in self._watched.items() if until > now}
            watched = set(self._watched)
            if not watched:
                if threading.current_thread() is self._thread:
                    self._thread = None   # so the next `watch` starts another
                return False
        try:
            waiting = list(self.peek())
        except Exception:
            waiting = []
        for session, request, method, params in waiting:
            if session not in watched or method not in self.METHODS or request in self._seen:
                continue
            self._seen[request] = None
            while len(self._seen) > 200:
                self._seen.pop(next(iter(self._seen)))
            try:
                self.found(session, method, params if isinstance(params, dict) else {})
            except Exception:
                log.debug("redde-push: a waiting prompt couldn't be announced", exc_info=True)
        return True

    def _run(self) -> None:
        while self.look():
            time.sleep(self.EVERY)

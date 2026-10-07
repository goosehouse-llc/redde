"""Redde push, the part that runs inside Hermes.

When the agent finishes a reply or stops for an approval, a short note goes to the paired iPhone
as a push notification. The note is encrypted here with a key only this Hermes and that phone
have, and is handed to a relay that passes it to Apple unread: the relay holds the phone's push
address, never the key. The phone's notification extension decrypts it.

The key comes from pairing. `hermes redde-push pair` shows a link (as a QR code) holding a fresh
public key; the phone, having scanned it, answers with its own public key through the relay, and
both sides derive the same secret (X25519, HKDF-SHA256). The relay sees two public keys and a box
it can't open. Anyone who could swap the QR code on your terminal could pair their own phone; the
relay can't.

Nothing here imports Hermes, so it can be tested alone. `__init__.py` wires it to the hooks.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import queue
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

def clipped(text: str, limit: int, lines: bool = False) -> str:
    """`text` cut to `limit` characters; on one line unless `lines`."""
    text = str(text or "").strip() if lines else " ".join(str(text or "").split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def digest(command: str) -> str:
    """What stands for a command in a note: sixteen hex digits of its SHA-256."""
    return hashlib.sha256(str(command or "").encode()).hexdigest()[:16]


def note(kind: str, session: str = "", body: str = "", title: str = "", detail: str = "", answerable: bool = False) -> dict:
    """What the phone is told. `k`: reply, approval, paired or test. `s`: the Hermes session.
    `b`: the reply's opening or the command. `t`: the conversation's title. `d`: why the command
    needs approval. `n`: this machine's name. `h`, on an approval the phone can answer from the
    notification (one in a conversation it follows): the command's digest, so its answer goes to
    that command and no other. Short keys: every byte is sealed and base64-encoded into a
    notification Apple caps at 4 KB."""
    made = {"v": 1, "k": kind, "at": int(time.time()), "n": clipped(socket.gethostname().split(".")[0], 40)}
    if kind == "approval" and answerable and session:
        made["h"] = digest(body)   # of the whole command, however much of it fits in `b`
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
    return hashlib.sha256(unb64u(device["key"]) + f"{made.get('k')}|{made.get('s', '')}|{about}".encode()).hexdigest()[:32]


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

    def submit(self, kind: str, session: str, platform: str, body: str = "", detail: str = "") -> int:
        """Queues a note for the phones that should hear about this conversation; how many."""
        devices = self.store.targets(session, platform)
        if not devices:
            return 0
        try:
            self._queue.put_nowait((devices, kind, session, body, detail, self.store.follows(session)))
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
                devices, kind, session, body, detail, answerable = self._queue.get(timeout=30)
            except queue.Empty:
                return
            try:
                title = ""
                try:
                    title = self.title_of(session) or ""
                except Exception:
                    pass
                self.send(devices, note(kind, session, body, title, detail, answerable))
            finally:
                self._queue.task_done()

    def send(self, devices: list[dict], made: dict) -> int:
        """Sends now, to each phone in turn; forgets a phone the relay says is gone."""
        delivered = 0
        for device in devices:
            for attempt in (1, 2):
                try:
                    push(device, made, ttl=600 if made.get("k") == "approval" else 3600)
                    delivered += 1
                    break
                except Gone:
                    self.store.remove(device["id"])
                    log.info("redde-push: %s is no longer registered; forgotten", device.get("name"))
                    break
                except Exception as error:   # the network, the relay, Apple: try once more, then let it go
                    if attempt == 2:
                        log.warning("redde-push: couldn't notify %s: %s", device.get("name"), error)
                    else:
                        time.sleep(2)
        return delivered

    def drain(self, timeout: float = 5) -> None:
        """Waits for what is queued, so a note isn't lost when the process is about to exit."""
        deadline = time.time() + timeout
        while self._queue.unfinished_tasks and time.time() < deadline:
            time.sleep(0.05)

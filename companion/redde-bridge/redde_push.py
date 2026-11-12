"""Notifications from the Redde bridge when Redde is closed: a reply is ready, an agent waits for
an approval, a turn failed.

The same scheme as Redde's Hermes plugin (docs/push.md): the phone and this bridge agree on a key
(X25519, then HKDF-SHA256), each note is sealed with AES-256-GCM, and the relay that hands it to
Apple carries ciphertext only. Pairing goes over the bridge's own WebSocket, the way the plugin's
one-tap pairing goes over the Dashboard: the app asks for an offer and hands back its answer
(`_redde/push`), so the relay never sees either half.

Standard library only, like the bridge, so the crypto is here too, written from RFC 7748 (X25519),
RFC 5869 (HKDF) and NIST SP 800-38D (GCM), and checked against their test vectors
(tests/test_push.py) and against the app's CryptoKit. Notes are a few hundred bytes; speed doesn't
matter, and nothing secret depends on timing an observer could see.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
import os
import socket
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_RELAY = "https://redde-push.goosehouse.org"
NOTE_LIMIT = 2400
BODY_LIMIT = 500
OFFER_LIFETIME = 600

log = logging.getLogger("redde-bridge")


# MARK: - X25519 (RFC 7748)

_P = 2**255 - 19
_A24 = 121665


def x25519(scalar: bytes, u: bytes) -> bytes:
    k = bytearray(scalar)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    n = int.from_bytes(k, "little")
    x1 = int.from_bytes(u, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        bit = (n >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b = (x2 + z2) % _P, (x2 - z2) % _P
        aa, bb = a * a % _P, b * b % _P
        e = (aa - bb) % _P
        c, d = (x3 + z3) % _P, (x3 - z3) % _P
        da, cb = d * a % _P, c * b % _P
        x3, z3 = (da + cb) ** 2 % _P, x1 * (da - cb) ** 2 % _P
        x2, z2 = aa * bb % _P, e * (aa + _A24 * e) % _P
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, _P - 2, _P) % _P).to_bytes(32, "little")


def x25519_public(private: bytes) -> bytes:
    return x25519(private, (9).to_bytes(32, "little"))


# MARK: - HKDF-SHA256 (RFC 5869)

def hkdf(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, block, counter = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:length]


# MARK: - AES-256-GCM (FIPS 197, SP 800-38D)

def _sbox() -> list[int]:
    box, p, q = [0] * 256, 1, 1
    box[0] = 0x63
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)   # p * 3 in GF(2^8)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09                                          # q / 3
        x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
        box[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            return box


_SBOX = _sbox()


def _xtime(a: int) -> int:
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _expand(key: bytes) -> list[list[int]]:
    words = [list(key[i:i + 4]) for i in range(0, 32, 4)]
    rcon = 1
    for i in range(8, 60):
        w = list(words[i - 1])
        if i % 8 == 0:
            w = [_SBOX[b] for b in w[1:] + w[:1]]
            w[0] ^= rcon
            rcon = _xtime(rcon)
        elif i % 8 == 4:
            w = [_SBOX[b] for b in w]
        words.append([a ^ b for a, b in zip(words[i - 8], w)])
    return [sum(words[r * 4:r * 4 + 4], []) for r in range(15)]


def _encrypt_block(rounds: list[list[int]], block: bytes) -> bytes:
    s = [b ^ k for b, k in zip(block, rounds[0])]
    for r in range(1, 15):
        s = [_SBOX[b] for b in s]
        s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]          # ShiftRows (column-major state)
        if r != 14:
            mixed = []
            for c in range(4):
                a = s[4 * c:4 * c + 4]
                t = a[0] ^ a[1] ^ a[2] ^ a[3]
                mixed += [a[i] ^ t ^ _xtime(a[i] ^ a[(i + 1) % 4]) for i in range(4)]
            s = mixed
        s = [b ^ k for b, k in zip(s, rounds[r])]
    return bytes(s)


_R = 0xE1 << 120


def _gmul(x: int, y: int) -> int:
    z, v = 0, y
    for i in range(127, -1, -1):
        if (x >> i) & 1:
            z ^= v
        v = (v >> 1) ^ _R if v & 1 else v >> 1
    return z


def _ghash(h: int, aad: bytes, text: bytes) -> int:
    y = 0
    for data in (aad, text):
        for i in range(0, len(data), 16):
            y = _gmul(y ^ int.from_bytes(data[i:i + 16].ljust(16, b"\0"), "big"), h)
    lengths = (len(aad) * 8).to_bytes(8, "big") + (len(text) * 8).to_bytes(8, "big")
    return _gmul(y ^ int.from_bytes(lengths, "big"), h)


def _ctr(rounds: list[list[int]], j0: bytes, data: bytes) -> bytes:
    out = bytearray()
    counter = int.from_bytes(j0[12:], "big")
    for i in range(0, len(data), 16):
        counter = (counter + 1) & 0xFFFFFFFF
        stream = _encrypt_block(rounds, j0[:12] + counter.to_bytes(4, "big"))
        out += bytes(a ^ b for a, b in zip(data[i:i + 16], stream))
    return bytes(out)


def gcm_encrypt(key: bytes, nonce: bytes, plaintext: bytes, aad: bytes) -> bytes:
    """Ciphertext followed by the 16-byte tag."""
    rounds = _expand(key)
    h = int.from_bytes(_encrypt_block(rounds, bytes(16)), "big")
    j0 = nonce + b"\0\0\0\1"
    ciphertext = _ctr(rounds, j0, plaintext)
    tag = int.from_bytes(_encrypt_block(rounds, j0), "big") ^ _ghash(h, aad, ciphertext)
    return ciphertext + tag.to_bytes(16, "big")


def gcm_decrypt(key: bytes, nonce: bytes, sealed: bytes, aad: bytes) -> bytes:
    if len(sealed) < 16:
        raise ValueError("too short")
    rounds = _expand(key)
    ciphertext, tag = sealed[:-16], sealed[-16:]
    h = int.from_bytes(_encrypt_block(rounds, bytes(16)), "big")
    j0 = nonce + b"\0\0\0\1"
    expected = int.from_bytes(_encrypt_block(rounds, j0), "big") ^ _ghash(h, aad, ciphertext)
    if not hmac.compare_digest(expected.to_bytes(16, "big"), tag):
        raise ValueError("doesn't open")
    return _ctr(rounds, j0, ciphertext)


# MARK: - The scheme (docs/push.md, "Wire formats")

def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64u(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def derive(shared: bytes, offered: bytes, answered: bytes) -> tuple[bytes, bytes]:
    """The note key and the key the phone's answer is sealed with."""
    material = hkdf(shared, offered + answered, b"redde-push v1", 64)
    return material[:32], material[32:]


def seal(key: bytes, plaintext: bytes, aad: bytes) -> bytes:
    nonce = os.urandom(12)
    return nonce + gcm_encrypt(key, nonce, plaintext, aad)


def unseal(key: bytes, sealed: bytes, aad: bytes) -> bytes:
    return gcm_decrypt(key, sealed[:12], sealed[12:], aad)


def key_id(key: bytes) -> bytes:
    return hashlib.sha256(b"redde-push key id" + key).digest()[:4]


def host_name() -> str:
    return clipped(socket.gethostname().split(".")[0], 40) or "Redde bridge"


def clipped(text: str, limit: int, lines: bool = False) -> str:
    text = str(text or "").strip() if lines else " ".join(str(text or "").split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def note(kind: str, session: str = "", body: str = "", title: str = "", detail: str = "") -> dict:
    """What the phone is told, in the plugin's short keys: `k` reply, approval, failed, paired or
    test; `s` the session; `t` the chat's title; `b` the reply's opening, the tool that waits, or
    why the turn failed; `d` the agent; `n` this machine."""
    made = {"v": 1, "k": kind, "at": int(time.time()), "n": host_name()}
    for key, value, limit in (("s", session, 120), ("t", title, 80), ("d", detail, 200)):
        if value:
            made[key] = clipped(value, limit)
    if body:
        made["b"] = clipped(body, BODY_LIMIT, lines=True)
    while len(json.dumps(made, ensure_ascii=False).encode()) > NOTE_LIMIT and len(made.get("b", "")) > 20:
        made["b"] = clipped(made["b"], len(made["b"]) * 2 // 3, lines=True)
    return made


def sealed_note(device: dict, made: dict) -> str:
    key = unb64u(device["key"])
    blob = key_id(key) + seal(key, json.dumps(made, ensure_ascii=False, separators=(",", ":")).encode(), device["id"].encode())
    return base64.b64encode(blob).decode()


def collapse_id(device: dict, made: dict) -> str:
    """A later note about the same thing replaces the earlier one: how a turn ended is one thing."""
    about = made.get("b", "") if made.get("k") == "approval" else ""
    kind = "reply" if made.get("k") == "failed" else made.get("k")
    return hashlib.sha256(unb64u(device["key"]) + f"{kind}|{made.get('s', '')}|{about}".encode()).hexdigest()[:32]


class Gone(Exception):
    """The relay no longer has this device: it unpaired, or Apple retired its address."""


def _request(method: str, url: str, body: dict | None = None, bearer: str | None = None, timeout: float = 10) -> dict:
    # Cloudflare turns away Python's own User-Agent on the relay's zone.
    headers = {"User-Agent": "redde-bridge/1", "Content-Type": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    request = urllib.request.Request(url, method=method, headers=headers,
                                     data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        text = response.read().decode()
        return json.loads(text) if text else {}


def send(device: dict, made: dict, ttl: int = 3600) -> None:
    body = {"payload": sealed_note(device, made), "ttl": ttl, "collapse": collapse_id(device, made)}
    try:
        _request("POST", f"{device['relay']}/v1/devices/{device['id']}/push", body, bearer=device["send"])
    except urllib.error.HTTPError as error:
        if error.code == 410:
            raise Gone(device["id"]) from error
        raise


# MARK: - Pairing and sending

class Pusher:
    """The devices paired with this bridge (`push.json` beside the config, readable only by its
    owner), the offers made and not yet answered, and a thread that sends notes."""

    def __init__(self, path: Path, relay: str = DEFAULT_RELAY, sender=send):
        self.path = path
        self.relay = relay.rstrip("/")
        self.sender = sender
        self._offers: dict[str, tuple[bytes, float]] = {}
        self._lock = threading.Lock()

    # The store

    def devices(self) -> list[dict]:
        try:
            return list(json.loads(self.path.read_text()).get("devices") or [])
        except (OSError, ValueError):
            return []

    def _save(self, devices: list[dict]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps({"devices": devices}, indent=1))
        temporary.chmod(0o600)
        temporary.replace(self.path)

    def _forget(self, device_id: str) -> None:
        with self._lock:
            self._save([d for d in self.devices() if d.get("id") != device_id])

    # The app's commands, in the plugin's words (PushService.pairDirectly reads them)

    def command(self, text: str) -> str:
        words = str(text or "").split()
        if words[:1] == ["offer"]:
            private = os.urandom(32)
            public = x25519_public(private)
            now = time.time()
            with self._lock:
                self._offers = {k: v for k, v in self._offers.items() if now - v[1] < OFFER_LIFETIME}
                self._offers[b64u(public)] = (private, now)
            return f"redde-push offer {b64u(public)} {self.relay}"
        if words[:1] == ["accept"] and len(words) == 4:
            return self._accept(*words[1:])
        if words[:1] == ["test"]:
            return f"redde-push sent to {self.notify(note('test', body='Notifications from this bridge reach this device.'))} device(s)"
        if words[:1] == ["list"]:
            return "\n".join(f"{d.get('name', '?')} ({d.get('kind', 'iphone')})" for d in self.devices()) or "no devices"
        return "redde-push: the bridge knows offer, accept, test and list"

    def _accept(self, offered: str, theirs: str, box: str) -> str:
        with self._lock:
            found = self._offers.pop(offered, None)
        if not found or time.time() - found[1] > OFFER_LIFETIME:
            return "redde-push refused: that offer has run out"
        private = found[0]
        try:
            their_key = unb64u(theirs)
            note_key, box_key = derive(x25519(private, their_key), unb64u(offered), their_key)
            inside = json.loads(unseal(box_key, unb64u(box), b"redde-push pairing"))
            device = {"id": str(inside["id"]), "send": str(inside["send"]),
                      "name": clipped(inside.get("name") or "iPhone", 60), "kind": str(inside.get("kind") or "iphone"),
                      "key": b64u(note_key), "relay": self.relay, "paired_at": int(time.time())}
        except Exception:   # a wrong key fails the same way as a mangled answer
            return "redde-push refused: that answer isn't to this offer"
        with self._lock:
            self._save([d for d in self.devices() if d.get("id") != device["id"]] + [device])
        log.info("paired %s (%s) for notifications", device["name"], device["kind"])
        # `d` "bridge": the phone words it for agents rather than a Hermes.
        threading.Thread(target=self._send_all, args=([device], note("paired", detail="bridge")), daemon=True).start()
        return f"redde-push paired {host_name()}"

    def notify(self, made: dict) -> int:
        """Sends a note to every paired device, from a thread: how many it goes to."""
        devices = self.devices()
        if devices:
            threading.Thread(target=self._send_all, args=(devices, made), daemon=True).start()
        return len(devices)

    def _send_all(self, devices: list[dict], made: dict) -> None:
        for device in devices:
            for attempt in range(2):
                try:
                    self.sender(device, made)
                    break
                except Gone:
                    log.info("%s unpaired; forgetting it", device.get("name"))
                    self._forget(device["id"])
                    break
                except Exception as error:   # the network: try once more, then let it go
                    if attempt:
                        log.warning("couldn't notify %s: %s", device.get("name"), error)
                    else:
                        time.sleep(2)

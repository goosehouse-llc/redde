"""The bridge's notifications: its crypto against the published test vectors, and a pairing the way
the app makes one (PushSeal.answer)."""
import base64
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import redde_push as push  # noqa: E402

h = bytes.fromhex


class Vectors(unittest.TestCase):
    def test_x25519_rfc7748(self):
        self.assertEqual(push.x25519(h("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
                                     h("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")),
                         h("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"))
        alice = h("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        bob = h("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        self.assertEqual(push.x25519_public(alice), h("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"))
        self.assertEqual(push.x25519_public(bob), h("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"))
        shared = h("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
        self.assertEqual(push.x25519(alice, push.x25519_public(bob)), shared)
        self.assertEqual(push.x25519(bob, push.x25519_public(alice)), shared)

    def test_hkdf_rfc5869_case1(self):
        okm = push.hkdf(h("0b" * 22), h("000102030405060708090a0b0c"), h("f0f1f2f3f4f5f6f7f8f9"), 42)
        self.assertEqual(okm, h("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"))

    def test_aes256_fips197(self):
        rounds = push._expand(h("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        self.assertEqual(push._encrypt_block(rounds, h("00112233445566778899aabbccddeeff")),
                         h("8ea2b7ca516745bfeafc49904b496089"))

    def test_gcm_nist(self):
        # GCM spec test cases 13, 14 and 16 (AES-256).
        self.assertEqual(push.gcm_encrypt(bytes(32), bytes(12), b"", b""), h("530f8afbc74536b9a963b4f1c4cb738b"))
        self.assertEqual(push.gcm_encrypt(bytes(32), bytes(12), bytes(16), b""),
                         h("cea7403d4d606b6e074ec5d3baf39d18" "d0d1c8a799996bf0265b98b5d48ab919"))
        key = h("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
        plain = h("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
        aad = h("feedfacedeadbeeffeedfacedeadbeefabaddad2")
        nonce = h("cafebabefacedbaddecaf888")
        sealed = push.gcm_encrypt(key, nonce, plain, aad)
        self.assertEqual(sealed, h("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662"
                                   "76fc6ece0f4e1768cddf8853bb2d551b"))
        self.assertEqual(push.gcm_decrypt(key, nonce, sealed, aad), plain)
        with self.assertRaises(ValueError):
            push.gcm_decrypt(key, nonce, sealed, aad + b"x")


class Pairing(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.sent = []
        self.pusher = push.Pusher(Path(self.dir.name) / "push.json", sender=lambda device, made: self.sent.append((device, made)))

    def tearDown(self):
        self.dir.cleanup()

    def answer(self, offered: str, inside: dict) -> tuple[str, str, bytes]:
        """What the app hands back (PushSeal.answer): its public key, and its relay id and secret
        sealed under the box key."""
        private = os.urandom(32)
        public = push.x25519_public(private)
        note_key, box_key = push.derive(push.x25519(private, push.unb64u(offered)), push.unb64u(offered), public)
        box = push.seal(box_key, json.dumps(inside).encode(), b"redde-push pairing")
        return push.b64u(public), push.b64u(box), note_key

    def wait_for_sent(self, count):
        deadline = time.time() + 5
        while len(self.sent) < count and time.time() < deadline:
            time.sleep(0.02)

    def test_offer_accept_and_a_note_that_opens(self):
        words = self.pusher.command("offer").split()
        self.assertEqual(words[:2], ["redde-push", "offer"])
        self.assertEqual(words[3], push.DEFAULT_RELAY)
        pub, box, note_key = self.answer(words[2], {"id": "dev1", "send": "secret", "name": "Marta", "kind": "iphone"})
        reply = self.pusher.command(f"accept {words[2]} {pub} {box}")
        self.assertTrue(reply.startswith("redde-push paired "), reply)
        self.assertEqual([d["name"] for d in self.pusher.devices()], ["Marta"])
        self.assertEqual(oct(self.pusher.path.stat().st_mode & 0o777), "0o600")
        self.wait_for_sent(1)
        self.assertEqual(self.sent[0][1]["k"], "paired")

        # A note sealed for the device opens with the key the app derived, for that device only.
        device = self.pusher.devices()[0]
        blob = base64.b64decode(push.sealed_note(device, push.note("reply", "sess", "Done.", "A chat")))
        self.assertEqual(blob[:4], push.key_id(note_key))
        made = json.loads(push.unseal(note_key, blob[4:], b"dev1"))
        self.assertEqual((made["k"], made["s"], made["b"], made["t"]), ("reply", "sess", "Done.", "A chat"))
        with self.assertRaises(ValueError):
            push.unseal(note_key, blob[4:], b"dev2")

    def test_each_agent_notifies_the_phones_paired_through_it(self):
        """Claude Code and Codex on one bridge: a phone paired through each connection hears each
        agent once, and a tap opens it with the connection it came through. A pairing from before
        pairings named their agent still hears every agent."""
        def pair(device_id, agent):
            offered = self.pusher.command("offer", agent).split()[2]
            pub, box, _ = self.answer(offered, {"id": device_id, "send": "s", "name": device_id})
            self.assertTrue(self.pusher.command(f"accept {offered} {pub} {box}", agent).startswith("redde-push paired"))
        pair("claude-pairing", "claude")
        pair("codex-pairing", "codex")
        self.pusher.command("offer")   # an old app's offer, through no agent
        self.pusher._save(self.pusher.devices() + [{"id": "old", "send": "s", "name": "old", "key": push.b64u(os.urandom(32))}])
        self.wait_for_sent(2)
        self.sent.clear()

        self.assertEqual(self.pusher.notify(push.note("reply", "s1", "Done."), "codex"), 2)
        self.wait_for_sent(2)
        self.assertEqual(sorted(d["id"] for d, _ in self.sent), ["codex-pairing", "old"])
        self.assertEqual([d["name"] for d in self.pusher.devices("claude")], ["claude-pairing", "old"])
        self.assertEqual(len(self.pusher.devices()), 3)
        self.assertIn("2 device(s)", self.pusher.command("test", "claude"))

    def test_an_offer_is_answered_once(self):
        offered = self.pusher.command("offer").split()[2]
        pub, box, _ = self.answer(offered, {"id": "d", "send": "s", "name": "x"})
        self.assertTrue(self.pusher.command(f"accept {offered} {pub} {box}").startswith("redde-push paired"))
        self.assertTrue(self.pusher.command(f"accept {offered} {pub} {box}").startswith("redde-push refused"))

    def test_a_wrong_answer_is_refused(self):
        offered = self.pusher.command("offer").split()[2]
        other = push.b64u(push.x25519_public(os.urandom(32)))
        pub, box, _ = self.answer(other, {"id": "d", "send": "s"})
        self.assertTrue(self.pusher.command(f"accept {offered} {pub} {box}").startswith("redde-push refused"))
        self.assertEqual(self.pusher.devices(), [])

    def test_a_device_the_relay_no_longer_has_is_forgotten(self):
        offered = self.pusher.command("offer").split()[2]
        pub, box, _ = self.answer(offered, {"id": "d", "send": "s"})

        def gone(device, made):
            raise push.Gone(device["id"])
        self.pusher.sender = gone
        self.pusher.command(f"accept {offered} {pub} {box}")
        deadline = time.time() + 5
        while self.pusher.devices() and time.time() < deadline:
            time.sleep(0.02)
        self.assertEqual(self.pusher.devices(), [])

    def test_notes_are_short(self):
        made = push.note("reply", "s" * 300, "word " * 2000, "t" * 300)
        self.assertLessEqual(len(made["s"]), 120)
        self.assertLessEqual(len(made["t"]), 80)
        self.assertLessEqual(len(made["b"]), push.BODY_LIMIT)


if __name__ == "__main__":
    unittest.main()

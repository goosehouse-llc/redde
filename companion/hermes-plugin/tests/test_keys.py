"""python -m unittest discover -s companion/hermes-plugin/tests

Keys a bot asks for (redde-push/keys.py): the request kept without a value, told to each paired
phone without one, answered only with the key sealed to that request, written into the right
profile's .env (mode 600, a line replaced, never twice), and the asker told only set or declined."""
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from test_calls import Relay, paired, plugin, read

core, keys = plugin.core, plugin.keys

VALUE = "jf-" + "Zq8rT2vW6yB0nD4hK7mP1sX5"


def sealed_for(listed: dict, value: str, aad_profile: str | None = None) -> tuple[str, str]:
    """What Redde sends: its public key, and the value sealed to the request's (PushSeal.sealKey)."""
    mine = X25519PrivateKey.generate()
    my_pub = mine.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    theirs = core.unb64u(listed["k"])
    shared = mine.exchange(X25519PublicKey.from_public_bytes(theirs))
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=my_pub + theirs, info=b"redde-push key v1").derive(shared)
    nonce = os.urandom(12)
    box = nonce + AESGCM(key).encrypt(nonce, value.encode(), keys.aad(listed["i"], listed["t"], aad_profile or listed["g"]))
    return core.b64u(my_pub), core.b64u(box)


class KeysTests(unittest.TestCase):
    def setUp(self):
        self.relay = Relay()
        self.addCleanup(self.relay.close)
        self.main = Path(tempfile.mkdtemp())
        (self.main / "profiles" / "jellyfin").mkdir(parents=True)
        self.store = core.Store(self.main)

    def ask(self, name="JELLYFIN_API_KEY", profile="jellyfin", asker="claude", now=None):
        return keys.ask(self.main, self.store, asker, "Coder", name, "So the Jellyfin bot can search your library", profile, now=now)

    def listed(self):
        return json.loads(keys.slash(self.main, ["list"]).removeprefix("redde-push keys "))

    def test_a_request_reaches_each_phone_with_no_value_and_waits(self):
        key = paired(self.store, self.relay.url, "dev-marta")
        said = self.ask()
        self.assertEqual((said["status"], said["phones"]), ("pending", 1), said)
        self.assertIn("${env:JELLYFIN_API_KEY}", said["said"])
        made = read(key, "dev-marta", self.relay.pushes[0]["payload"])
        self.assertEqual((made["k"], made["t"], made["g"], made["p"], made["d"]), ("key", "JELLYFIN_API_KEY", "jellyfin", "claude", "Coder"))
        self.assertEqual(made["i"], said["id"])
        listed = self.listed()
        self.assertEqual([(l["i"], l["t"], l["g"], l["r"]) for l in listed], [(said["id"], "JELLYFIN_API_KEY", "jellyfin", False)])
        self.assertEqual(len(core.unb64u(listed[0]["k"])), 32)
        private = keys._private(self.main, said["id"])
        self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o600)
        self.assertEqual(self.ask()["id"], said["id"], "asked again: the same request, not a second card")

    def test_the_sealed_key_goes_into_the_profiles_env_and_nowhere_else(self):
        said = self.ask()
        env = self.main / "profiles" / "jellyfin" / ".env"
        env.write_text("# jellyfin\nJELLYFIN_URL=http://jf.local:8096")
        listed = self.listed()[0]
        reply = keys.slash(self.main, ["set", listed["i"], *sealed_for(listed, "  " + VALUE + "\n")])
        self.assertEqual(reply, "redde-push keys set JELLYFIN_API_KEY")
        self.assertEqual(env.read_text(), f"# jellyfin\nJELLYFIN_URL=http://jf.local:8096\nJELLYFIN_API_KEY={VALUE}\n")
        self.assertEqual(stat.S_IMODE(env.stat().st_mode), 0o600)
        self.assertFalse((self.main / ".env").exists(), "the main .env untouched")
        self.assertFalse(keys._private(self.main, said["id"]).exists(), "the request's private half is gone")
        for f in (self.main / "redde-push").rglob("*"):
            if f.is_file():
                self.assertNotIn(VALUE, f.read_text(errors="ignore"), f"{f} holds the value")
        self.assertEqual(keys.slash(self.main, ["set", listed["i"], *sealed_for(listed, VALUE)]), "redde-push keys gone",
                         "answered once")
        self.assertEqual(self.listed(), [])

    def test_a_key_already_there_is_replaced_not_added_twice(self):
        env = self.main / "profiles" / "jellyfin" / ".env"
        env.write_text("export JELLYFIN_API_KEY=old-one-0000000000\nOTHER=1\n")
        said = self.ask()
        self.assertTrue(said["replace"])
        listed = self.listed()[0]
        self.assertTrue(listed["r"])
        keys.slash(self.main, ["set", listed["i"], *sealed_for(listed, "with space and # hash")])
        self.assertEqual(env.read_text(), 'JELLYFIN_API_KEY="with space and # hash"\nOTHER=1\n')

    def test_a_box_for_another_request_or_profile_is_refused_and_nothing_is_written(self):
        said = self.ask()
        listed = self.listed()[0]
        self.assertEqual(keys.slash(self.main, ["set", listed["i"], *sealed_for(listed, VALUE, aad_profile="default")]),
                         "redde-push keys refused seal")
        pub, box = sealed_for(listed, VALUE)
        tampered = core.b64u(core.unb64u(box)[:-1] + bytes([core.unb64u(box)[-1] ^ 1]))
        self.assertEqual(keys.slash(self.main, ["set", listed["i"], pub, tampered]), "redde-push keys refused seal")
        self.assertEqual(keys.slash(self.main, ["set", "nosuchrequest00", pub, box]), "redde-push keys gone")
        self.assertEqual(keys.slash(self.main, ["set", listed["i"], *sealed_for(listed, "two\nlines")]), "redde-push keys refused value")
        self.assertFalse((self.main / "profiles" / "jellyfin" / ".env").exists())
        self.assertEqual(keys.status(self.main, "claude", said["id"])["status"], "pending", "still waiting for a good answer")

    def test_the_asker_learns_set_or_declined_once_and_never_the_value(self):
        claude = self.main / "profiles" / "claude"
        claude.mkdir()
        first = self.ask()
        second = self.ask(name="TAVILY_API_KEY", profile="default")
        listed = {l["t"]: l for l in self.listed()}
        keys.slash(self.main, ["set", listed["JELLYFIN_API_KEY"]["i"], *sealed_for(listed["JELLYFIN_API_KEY"], VALUE)])
        self.assertEqual(keys.slash(self.main, ["decline", second["id"]]), "redde-push keys declined")
        note = keys.turn_note(claude)
        self.assertIn("JELLYFIN_API_KEY is set in jellyfin's .env", note)
        self.assertIn("declined to give TAVILY_API_KEY", note)
        self.assertNotIn(VALUE, note)
        self.assertIsNone(keys.turn_note(claude), "said once")
        self.assertIsNone(keys.turn_note(self.main), "the main agent asked for none")
        self.assertEqual(keys.status(self.main, "claude", first["id"])["status"], "set")
        self.assertEqual(keys.status(self.main, "claude", name="TAVILY_API_KEY")["status"], "declined")
        self.assertIn("error", keys.status(self.main, "default", first["id"]), "another agent's request isn't told")

    def test_names_profiles_and_how_often(self):
        for bad in ("lower_case", "PATH", "LD_PRELOAD", "PYTHONPATH", "HERMES_HOME", "X"):
            self.assertIn("error", self.ask(name=bad), bad)
        self.assertIn("error", self.ask(profile="nosuchbot"))
        self.assertIn("error", self.ask(profile="../etc"))
        self.assertIn("error", keys.ask(self.main, self.store, "claude", "Coder", "GOOD_KEY", "  ", "jellyfin"))
        import time
        start = time.time()
        for n in range(keys.HOURLY):
            self.assertEqual(self.ask(name=f"KEY_{n:02d}", now=start + n)["status"], "pending")
        self.assertIn("error", self.ask(name="ONE_MORE", now=start + 100))

    def test_a_request_expires_and_its_private_half_with_it(self):
        said = self.ask(now=1000)
        self.assertEqual(keys.pending(self.main, now=1000 + keys.LIFETIME + 1), [])
        self.assertFalse(keys._private(self.main, said["id"]).exists())
        self.assertEqual(keys.status(self.main, "claude", said["id"], now=1000 + keys.LIFETIME + 2)["status"], "expired")

    def test_the_writer_without_hermes_writes_the_same_lines(self):
        env = self.main / ".env"
        env.write_text("export JELLYFIN_API_KEY=old\nOTHER=1")
        keys._write_by_hand(env, "JELLYFIN_API_KEY", "new value #x")
        keys._write_by_hand(env, "SECOND_KEY", "plain")
        self.assertEqual(env.read_text(), 'JELLYFIN_API_KEY="new value #x"\nOTHER=1\nSECOND_KEY=plain\n')
        self.assertEqual(stat.S_IMODE(env.stat().st_mode), 0o600)

    def test_no_phone_paired_the_bot_is_told_to_say_so(self):
        said = self.ask()
        self.assertEqual(said["phones"], 0)
        self.assertIn("Keys Asked For", said["said"])


if __name__ == "__main__":
    unittest.main()

"""Notifications cleared on one device, cleared on the others (1.33.0):
python -m unittest discover -s companion/hermes-plugin/tests"""
import importlib.util
import json
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent / "redde-push"
if "redde_push" not in sys.modules:
    spec = importlib.util.spec_from_file_location("redde_push", HERE / "__init__.py", submodule_search_locations=[str(HERE)])
    plugin = importlib.util.module_from_spec(spec)
    sys.modules["redde_push"] = plugin
    spec.loader.exec_module(plugin)
plugin = sys.modules["redde_push"]
core = plugin.core


class ClearedTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.store = core.Store(Path(self.home.name))
        self.store.add({"id": "phone", "name": "Marta"})
        self.store.add({"id": "pad", "name": "GoosePad", "kind": "ipad"})
        self.store.add({"id": "mac", "name": "Paloma", "kind": "mac"})

    def tearDown(self):
        self.home.cleanup()

    def test_a_note_has_one_id_on_every_device(self):
        bodies = []
        with mock.patch.object(core, "_request", lambda method, url, body=None, bearer=None, timeout=10: bodies.append(body) or {}), \
                mock.patch.object(core, "sealed", lambda device, made: json.dumps(made)):
            made = core.note("reply", "chat-1", body="Your evening wrap-up.")
            for device in ({"id": "phone", "relay": "r", "send": "s", "key": core.b64u(b"k" * 32)}, {"id": "pad", "relay": "r", "send": "s", "key": core.b64u(b"j" * 32)}):
                core.push(device, made)
        ids = [json.loads(b["payload"])["m"] for b in bodies]
        self.assertTrue(core.NOTE_ID.match(ids[0]))
        self.assertEqual(ids[0], ids[1], "the same id on both")
        self.assertTrue(all("collapse" in b and "kind" not in b for b in bodies))

    def test_a_clear_is_a_silent_push_with_no_id_of_its_own(self):
        bodies = []
        with mock.patch.object(core, "_request", lambda method, url, body=None, bearer=None, timeout=10: bodies.append(body) or {}), \
                mock.patch.object(core, "sealed", lambda device, made: json.dumps(made)):
            core.push({"id": "pad", "relay": "r", "send": "s"}, core.clear_note(["0123456789ab"]))
        self.assertEqual(bodies[0]["kind"], "clear")
        self.assertNotIn("collapse", bodies[0])
        sent = json.loads(bodies[0]["payload"])
        self.assertEqual((sent["k"], sent["b"]), ("clear", "0123456789ab"))
        self.assertNotIn("m", sent)

    def test_cleared_notes_are_kept_once_and_for_two_days(self):
        self.assertEqual(self.store.add_cleared(["aaaaaaaaaaaa", "bbbbbbbbbbbb"], now=1000), ["aaaaaaaaaaaa", "bbbbbbbbbbbb"])
        self.assertEqual(self.store.add_cleared(["bbbbbbbbbbbb", "cccccccccccc"], now=1010), ["cccccccccccc"], "a second device's clear is no news")
        self.assertEqual(self.store.cleared_since(1005, now=1020), ["cccccccccccc"])
        self.assertEqual(self.store.cleared_since(0, now=1020), ["aaaaaaaaaaaa", "bbbbbbbbbbbb", "cccccccccccc"])
        self.assertEqual(self.store.cleared_since(0, now=1010 + core.Store.CLEARED_FOR), [], "two days on, forgotten")

    def test_at_most_so_many_are_kept(self):
        many = [f"{n:012x}" for n in range(core.Store.CLEARED_AT_MOST + 20)]
        for n, note in enumerate(many):
            self.store.add_cleared([note], now=1000 + n)
        kept = self.store.cleared_since(0, now=1000 + len(many))
        self.assertEqual(len(kept), core.Store.CLEARED_AT_MOST)
        self.assertEqual(kept[-1], many[-1], "the newest kept")

    def test_a_clear_goes_everywhere_even_where_no_one_is(self):
        self.store.set_here(["mac"], 10**10)
        self.assertEqual(len(self.store.where_you_are(self.store.devices, "clear")), 3)

    def run_slash(self, command):
        sent = []
        done = threading.Event()

        def send(devices, made, tries=2):
            sent.append(([d["id"] for d in devices], made))
            done.set()
            return len(devices)

        plugin._store, plugin._pusher = self.store, core.Pusher(self.store)
        try:
            with mock.patch.object(plugin._pusher, "send", send):
                answer = plugin._slash(command)
                done.wait(2)
        finally:
            plugin._store, plugin._pusher = None, None
        return answer, sent

    def test_cleared_on_the_phone_the_others_are_told(self):
        answer, sent = self.run_slash("cleared phone aaaaaaaaaaaa,not-an-id,bbbbbbbbbbbb")
        self.assertEqual(answer, "redde-push cleared 2 2")
        self.assertEqual(sent[0][0], ["pad", "mac"], "every device but the one it was cleared on")
        self.assertEqual(sent[0][1]["k"], "clear")
        self.assertEqual(sent[0][1]["b"], "aaaaaaaaaaaa,bbbbbbbbbbbb")

    def test_cleared_again_nobody_is_told_twice(self):
        self.run_slash("cleared phone aaaaaaaaaaaa")
        answer, sent = self.run_slash("cleared pad aaaaaaaaaaaa")
        self.assertEqual(answer, "redde-push cleared 0 0")
        self.assertEqual(sent, [])

    def test_a_device_back_asks_what_was_cleared(self):
        self.run_slash("cleared phone aaaaaaaaaaaa")
        answer, _ = self.run_slash("cleared since 0")
        word, verb, now, notes = answer.split()
        self.assertEqual((word, verb, notes), ("redde-push", "cleared-since", "aaaaaaaaaaaa"))
        self.assertTrue(now.isdigit())
        self.assertEqual(self.run_slash(f"cleared since {int(now) + 5}")[0].split()[-1], "-", "nothing since")


if __name__ == "__main__":
    unittest.main()

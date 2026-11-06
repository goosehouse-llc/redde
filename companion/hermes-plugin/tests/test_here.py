"""Notifications where you are (1.19.0): python -m unittest discover -s companion/hermes-plugin/tests"""
import importlib.util
import sys
import tempfile
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


class WhereYouAreTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.store = core.Store(Path(self.home.name))
        self.store.add({"id": "phone", "name": "Marta"})
        self.store.add({"id": "mac", "name": "Paloma", "kind": "mac"})
        self.store.add({"id": "pad", "name": "GoosePad", "kind": "ipad"})

    def tearDown(self):
        self.home.cleanup()

    def ids(self, devices):
        return [d["id"] for d in devices]

    def test_with_none_in_use_every_device_hears(self):
        self.assertEqual(self.ids(self.store.where_you_are(self.store.devices, "reply", now=1000)), ["phone", "mac", "pad"])

    def test_at_the_mac_only_the_mac_hears(self):
        self.store.set_here(["mac"], 1300, now=1000)
        self.assertEqual(self.ids(self.store.where_you_are(self.store.devices, "reply", now=1100)), ["mac"])
        self.assertEqual(self.ids(self.store.where_you_are(self.store.devices, "approval", now=1100)), ["mac"])

    def test_in_use_runs_out_and_zero_ends_it(self):
        self.store.set_here(["mac"], 1300, now=1000)
        self.assertEqual(self.store.here(now=1301), set(), "it stopped saying so")
        self.store.set_here(["mac"], 1300, now=1000)
        self.store.set_here(["mac"], 0, now=1010)
        self.assertEqual(self.ids(self.store.where_you_are(self.store.devices, "reply", now=1020)), ["phone", "mac", "pad"])

    def test_a_long_until_is_cut_to_the_most(self):
        self.store.set_here(["phone"], 10**10, now=1000)
        self.assertIn("phone", self.store.here(now=1000 + core.Store.HERE_AT_MOST - 1))
        self.assertNotIn("phone", self.store.here(now=1000 + core.Store.HERE_AT_MOST + 1))

    def test_two_in_use_both_hear(self):
        self.store.set_here(["mac", "phone"], 1300, now=1000)
        self.assertEqual(self.ids(self.store.where_you_are(self.store.devices, "reply", now=1100)), ["phone", "mac"])

    def test_some_notes_go_everywhere_whatever_is_in_use(self):
        self.store.set_here(["mac"], 1300, now=1000)
        for kind in ("widget", "leave", "paired", "test", "call"):
            self.assertEqual(len(self.store.where_you_are(self.store.devices, kind, now=1100)), 3, kind)

    def test_a_chat_muted_on_the_mac_in_use_stays_quiet(self):
        self.store.watch("chat-1", ["phone", "mac"])
        self.store.set_mutes(["mac"], {"s:chat-1": 0})
        self.store.set_here(["mac"], 1300, now=1000)
        targets = self.store.targets("chat-1", "desktop")
        self.assertEqual(self.store.where_you_are(targets, "reply", now=1100), [], "the phone doesn't take the Mac's place")

    def test_an_unpaired_device_is_not_kept(self):
        self.assertEqual(self.store.set_here(["stranger"], 1300, now=1000), [])
        self.assertEqual(self.store.here(now=1100), set())

    def test_the_sender_leaves_out_devices_not_in_use(self):
        pushed = []
        with mock.patch.object(core, "push", lambda device, made, ttl=3600, call=False: pushed.append(device["id"])):
            pusher = core.Pusher(self.store)
            self.store.set_here(["phone"], 10**10)
            self.assertEqual(pusher.send(self.store.devices, core.note("reply", "chat-1", body="Done.")), 1)
            self.assertEqual(pushed, ["phone"])

    def test_the_app_says_it_is_in_use(self):
        plugin._store, plugin._pusher = self.store, core.Pusher(self.store)
        try:
            self.assertEqual(plugin._slash("here mac,elsewhere 99999999999"), "redde-push here 1")
            self.assertEqual(self.store.here(), {"mac"})
            self.assertEqual(plugin._slash("here mac 0"), "redde-push here 1")
            self.assertEqual(self.store.here(), set())
        finally:
            plugin._store, plugin._pusher = None, None


if __name__ == "__main__":
    unittest.main()

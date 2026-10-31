"""python -m unittest discover -s companion/hermes-plugin/tests

Leave-By Alerts' traffic re-check (redde-push/leave.py): the app's wakes kept per device (all of
them, each time: a moved one replaces its old time, a gone one goes), sent at their time to that
one device only, once, and forgotten; a late one, an unpaired device's, a cancelled one: never."""
import json
import tempfile
import time
import unittest
from pathlib import Path

from test_calls import Relay, paired, plugin, read

core, leave = plugin.core, plugin.leave

DENTIST = "a1b2c3d4e5f60718"
LUNCH = "0f1e2d3c4b5a6978"


def listed(*wakes) -> str:
    """What the app sends: base64url JSON of (id, title, when)."""
    return core.b64u(json.dumps([{"i": i, "t": t, "w": w} for i, t, w in wakes]).encode())


class LeaveTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.relay = Relay()
        self.addCleanup(self.relay.close)
        self.store = core.Store(Path(self.home.name))
        self.phone_key = paired(self.store, self.relay.url, "phone-1")
        self.mac_key = paired(self.store, self.relay.url, "mac-1", kind="mac")
        self.now = time.time()
        self.sent = []

    def capture(self, devices, made):
        self.sent.append(([d["id"] for d in devices], made))
        return len(devices)

    def test_a_wake_goes_at_its_time_to_the_one_device_that_asked_and_once(self):
        said = leave.slash(self.store, ["set", "phone-1", listed((DENTIST, "Dentist", self.now + 600))])
        self.assertEqual(said, "redde-push leave 1 1")
        self.assertEqual(leave.send_due(self.store, self.capture, now=self.now), 0, "not yet")
        self.assertEqual(leave.send_due(self.store, self.capture, now=self.now + 630), 1)
        devices, made = self.sent[0]
        self.assertEqual(devices, ["phone-1"], "the device that set it, not every paired one")
        self.assertEqual((made["k"], made["i"], made["t"]), ("leave", DENTIST, "Dentist"))
        self.assertEqual(set(made) - {"v", "k", "at", "n", "i", "t"}, set(), "nothing but the id and the title")
        self.assertEqual(leave.send_due(self.store, self.capture, now=self.now + 700), 0, "sent once, then forgotten")
        self.assertEqual(self.store.leave_wakes(), {})

    def test_sealed_for_that_device_alone_through_the_relay(self):
        leave.slash(self.store, ["set", "mac-1", listed((DENTIST, "Dentist", self.now - 5))])
        pusher = core.Pusher(self.store)
        self.assertEqual(leave.send_due(self.store, pusher.send), 1)
        self.assertEqual(len(self.relay.pushes), 1)
        push = self.relay.pushes[0]
        self.assertEqual(push["path"], "/v1/devices/mac-1/push")
        self.assertEqual(push["ttl"], 900, "a late re-check is no use")
        made = read(self.mac_key, "mac-1", push["payload"])
        self.assertEqual((made["k"], made["i"], made["t"]), ("leave", DENTIST, "Dentist"))

    def test_a_moved_alert_replaces_its_wake_and_a_gone_one_is_cancelled(self):
        leave.slash(self.store, ["set", "phone-1", listed((DENTIST, "Dentist", self.now + 600), (LUNCH, "Lunch", self.now + 3600))])
        # The traffic moved the dentist; lunch was deleted from the calendar.
        leave.slash(self.store, ["set", "phone-1", listed((DENTIST, "Dentist", self.now + 300))])
        self.assertEqual([w["w"] for w in self.store.leave_wakes()["phone-1"]], [int(self.now + 300)])
        leave.send_due(self.store, self.capture, now=self.now + 330)
        leave.send_due(self.store, self.capture, now=self.now + 630)
        leave.send_due(self.store, self.capture, now=self.now + 3630)
        self.assertEqual([m["i"] for _, m in self.sent], [DENTIST], "lunch is never sent; the dentist once, at its new time")

    def test_cancel_takes_them_all_and_leaves_other_devices_alone(self):
        leave.slash(self.store, ["set", "phone-1", listed((DENTIST, "Dentist", self.now + 600))])
        leave.slash(self.store, ["set", "mac-1", listed((DENTIST, "Dentist", self.now + 600))])
        self.assertEqual(leave.slash(self.store, ["cancel", "phone-1"]), "redde-push leave 1 0")
        leave.send_due(self.store, self.capture, now=self.now + 700)
        self.assertEqual([d for d, _ in self.sent], [["mac-1"]])
        self.assertEqual(leave.slash(self.store, ["set", "mac-1", "-"]), "redde-push leave 1 0", "an empty list cancels too")

    def test_a_device_not_paired_here_is_told_so_and_nothing_is_kept(self):
        self.assertEqual(leave.slash(self.store, ["set", "someone-else", listed((DENTIST, "Dentist", self.now + 600))]), "redde-push leave 0 0")
        self.assertEqual(self.store.leave_wakes(), {})

    def test_an_unpaired_device_is_woken_for_nothing_more(self):
        leave.slash(self.store, ["set", "phone-1,mac-1", listed((DENTIST, "Dentist", self.now + 600))])
        self.store.remove("phone-1")
        self.assertNotIn("phone-1", self.store.leave_wakes())
        leave.send_due(self.store, self.capture, now=self.now + 700)
        self.assertEqual([d for d, _ in self.sent], [["mac-1"]])

    def test_a_late_wake_is_let_go_unsent(self):
        leave.slash(self.store, ["set", "phone-1", listed((DENTIST, "Dentist", self.now + 60), (LUNCH, "Lunch", self.now + 7200))])
        self.assertEqual(leave.send_due(self.store, self.capture, now=self.now + 60 + 16 * 60), 0, "Hermes was down: its leaving time has come")
        self.assertEqual([w["i"] for w in self.store.leave_wakes()["phone-1"]], [LUNCH], "and it is forgotten")
        mine, kept = leave.set_wakes(self.store, ["phone-1"], leave.parse(listed((DENTIST, "Dentist", self.now - 3 * 3600))), now=self.now)
        self.assertEqual((mine, kept), (["phone-1"], 0), "hours gone: not kept at all")

    def test_what_is_kept_is_capped_checked_and_one_an_alert(self):
        many = [(f"{n:016x}", f"Event {n}", self.now + 600 + n) for n in range(45)]
        self.assertEqual(leave.slash(self.store, ["set", "phone-1", listed(*reversed(many))]), "redde-push leave 1 30")
        self.assertEqual([w["i"] for w in self.store.leave_wakes()["phone-1"]][:2], [f"{0:016x}", f"{1:016x}"], "the soonest thirty")
        wakes = leave.parse(listed((DENTIST, "x" * 300, self.now), ("not an id", "Lunch", self.now), (DENTIST, "Dentist", self.now + 60)))
        self.assertEqual(len(wakes), 1, "an id that isn't one is dropped; the same alert twice is one")
        self.assertEqual(wakes[0]["t"], "Dentist")
        self.assertIsNone(leave.parse("not base64 json"))
        self.assertTrue(leave.slash(self.store, ["set", "phone-1", "@@@"]).startswith("redde-push refused"))

    def test_two_processes_send_each_wake_once(self):
        leave.slash(self.store, ["set", "phone-1", listed((DENTIST, "Dentist", self.now))])
        other = core.Store(Path(self.home.name))
        with self.store.rooms_lock("leave"):
            self.assertEqual(leave.due(other, now=self.now + 30), [], "another holds the lock: nothing")
        self.assertEqual(len(leave.due(other, now=self.now + 30)), 1)
        self.assertEqual(leave.due(self.store, now=self.now + 60), [])

    def test_the_slash_command_reaches_it_in_the_main_home(self):
        original = plugin._home
        plugin._home = lambda: Path(self.home.name)   # (never the real ~/.hermes)
        plugin._store = plugin._pusher = plugin._rooms = plugin._routines = None
        try:
            self.assertEqual(plugin._slash("leave set phone-1 " + listed((DENTIST, "Dentist", self.now + 600))), "redde-push leave 1 1")
            self.assertTrue(plugin._slash("leave").startswith("redde-push: leave set"))
            self.assertEqual([w["i"] for w in core.Store(Path(self.home.name)).leave_wakes()["phone-1"]], [DENTIST])
        finally:
            plugin._home = original
            if plugin._routines is not None:
                plugin._routines.store = core.Store(Path(self.home.name) / "gone")   # (its thread, if started, finds no phones)
            plugin._store = plugin._pusher = plugin._rooms = plugin._routines = None

    def test_a_later_check_takes_the_earlier_ones_place(self):
        self.assertEqual(core.collapse_id({"key": core.b64u(b"k" * 32)}, core.leave_note(DENTIST, "Dentist")),
                         core.collapse_id({"key": core.b64u(b"k" * 32)}, core.leave_note(DENTIST, "Dentist, moved")),
                         "a later check of the same alert takes the earlier's place")


if __name__ == "__main__":
    unittest.main()

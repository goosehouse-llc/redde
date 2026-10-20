"""Group chat notes (`rooms.py`): python -m unittest discover -s companion/hermes-plugin/tests"""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "redde-push"
if "redde_push" not in sys.modules:
    spec = importlib.util.spec_from_file_location("redde_push", HERE / "__init__.py", submodule_search_locations=[str(HERE)])
    plugin = importlib.util.module_from_spec(spec)
    sys.modules["redde_push"] = plugin
    spec.loader.exec_module(plugin)
plugin = sys.modules["redde_push"]
core, rooms = plugin.core, plugin.rooms


class FakeRooms:
    """A Hermes with group chats: their logs, and what its room service says each waits on."""

    def __init__(self):
        self.log = {"room-a": [], "room-b": []}
        self.pending: dict[str, list] | None = {"room-a": [], "room-b": []}

    def say(self, room, kind, member=None, text=""):
        seq = len(self.log[room]) + 1
        actor = {"kind": "member", "id": member} if member else {"kind": "user"}
        payload = {"text": text, **({"member_id": member} if member else {})}
        self.log[room].append({"seq": seq, "kind": kind, "actor": actor, "payload": payload})

    def rooms(self):
        names = {"room-a": "Weekend hike", "room-b": "Garage project"}
        return {r: {"name": names[r], "members": {"scout": "Scout", "writer": "Quill"}, "latest": len(events)}
                for r, events in self.log.items()}

    def events(self, room, since):
        return [e for e in self.log[room] if e["seq"] > since], len(self.log[room])

    def waits(self, room):
        return None if self.pending is None else list(self.pending[room])


class RoomsTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.store = core.Store(Path(self.home.name))
        self.store.add({"id": "phone-1", "name": "Marta"})
        self.store.add({"id": "phone-2", "name": "GoosePad"})
        self.hermes = FakeRooms()
        self.sent = []
        self.watch = rooms.Rooms(self.store, self.capture, source=self.hermes)

    def tearDown(self):
        self.home.cleanup()

    def capture(self, devices, made):
        self.sent.append(([d["id"] for d in devices], made))
        return len(devices)

    def test_a_bots_message_notifies_the_phones_following_its_room_once(self):
        self.hermes.say("room-a", "message.member", "scout", "Before anyone followed.")
        self.store.follow_rooms(["phone-1"], ["room-a"])
        self.assertEqual(self.watch.look(), 0, "what it said before isn't news")
        self.hermes.say("room-a", "message.user", text="@scout is Falls Loop open?")
        self.hermes.say("room-a", "message.member", "scout", "Yes, and muddy past the bridge.")
        self.hermes.say("room-b", "message.member", "writer", "Not followed.")
        self.assertEqual(self.watch.look(), 1)
        devices, made = self.sent[0]
        self.assertEqual(devices, ["phone-1"])
        self.assertEqual((made["k"], made["g"], made["t"], made["d"], made["b"]),
                         ("group", "room-a", "Weekend hike", "Scout", "Yes, and muddy past the bridge."))
        self.assertEqual(self.watch.look(), 0, "said once")

    def test_two_processes_reading_send_each_message_once(self):
        self.store.follow_rooms(["phone-1"], ["room-a"])
        other = rooms.Rooms(core.Store(Path(self.home.name)), self.capture, source=self.hermes)
        self.watch.look()
        self.hermes.say("room-a", "message.member", "writer", "Saturday at eight.")
        self.assertEqual(other.look() + self.watch.look(), 1)
        # One reading while the other holds the lock leaves it.
        with self.store.rooms_lock() as held:
            self.assertTrue(held)
            self.hermes.say("room-a", "message.member", "writer", "Bring layers.")
            self.assertEqual(other.look(), 0)
        self.assertEqual(other.look(), 1)

    def test_a_command_waiting_for_approval_is_announced_once_until_it_is_asked_again(self):
        self.store.follow_rooms(["phone-1", "phone-2"], ["room-a"])
        self.watch.look()
        asked = {"kind": "approval", "member_id": "scout", "task_id": "t1", "execution_generation": 1, "request_id": "r1",
                 "approval": {"command": "rm -rf build", "description": "recursive delete"}}
        self.hermes.pending["room-a"] = [asked]
        self.assertEqual(self.watch.look(), 2, "both phones")
        made = self.sent[0][1]
        self.assertEqual((made["k"], made["w"], made["d"], made["b"], made["r"], made["h"]),
                         ("group_wait", "approval", "Scout", "rm -rf build", "recursive delete", core.digest("rm -rf build")))
        self.assertEqual(self.watch.look(), 0, "still the same one")
        self.hermes.pending["room-a"] = []
        self.watch.look()
        self.hermes.pending["room-a"] = [dict(asked, request_id="r2")]
        self.assertEqual(self.watch.look(), 2, "asked again")

    def test_a_turn_to_retry_carries_its_task(self):
        self.store.follow_rooms(["phone-1"], ["room-b"])
        self.watch.look()
        self.hermes.pending["room-b"] = [{"kind": "retry", "task_id": "t9"}]
        self.watch.look()
        made = self.sent[-1][1]
        self.assertEqual((made["k"], made["w"], made["x"], made["t"]), ("group_wait", "retry", "t9", "Garage project"))

    def test_a_process_running_no_rooms_reads_messages_and_forgets_no_waits(self):
        self.store.follow_rooms(["phone-1"], ["room-a"])
        self.hermes.pending["room-a"] = [{"kind": "retry", "task_id": "t1"}]
        self.watch.look()
        self.assertEqual(len(self.sent), 1)
        self.hermes.pending = None   # (another process: it can't say what the room waits on)
        self.hermes.say("room-a", "message.member", "scout", "Retried it myself.")
        self.watch.look()
        self.assertEqual([m["k"] for _, m in self.sent], ["group_wait", "group"])
        self.assertIn("room-a|retry|t1", self.store.room_waits(), "not taken for answered")

    def test_a_phone_follows_the_rooms_it_last_listed(self):
        self.store.follow_rooms(["phone-1"], ["room-a", "room-b"])
        self.store.follow_rooms(["phone-2"], ["room-a"])
        self.store.follow_rooms(["phone-1"], ["room-b"])   # it muted room-a
        self.assertEqual(self.store.rooms_followed(), {"room-a": ["phone-2"], "room-b": ["phone-1"]})
        self.assertEqual(self.store.follow_rooms(["someone-else"], ["room-a"]), [], "only phones paired here")
        self.store.remove("phone-2")
        self.assertEqual(self.store.rooms_followed(), {"room-b": ["phone-1"]})

    def test_the_app_says_which_rooms_over_the_dashboard(self):
        class Started:
            count = 0
            def start(self): Started.count += 1
        class Watching:
            store = self.store
            def start(self): pass
        plugin._store = self.store
        plugin._pusher = core.Pusher(self.store)
        plugin._rooms = Started()
        plugin._routines = Watching()
        try:
            self.assertEqual(plugin._slash("rooms phone-1,phone-9 room-a,room-b"), "redde-push following 1")
            self.assertEqual(self.store.rooms_followed(), {"room-a": ["phone-1"], "room-b": ["phone-1"]})
            self.assertEqual(Started.count, 1, "this process reads them from now on")
            self.assertEqual(plugin._slash("rooms phone-1"), "redde-push following 1")
            self.assertEqual(self.store.rooms_followed(), {}, "none: every one muted")
        finally:
            plugin._store = plugin._pusher = plugin._rooms = plugin._routines = None

    def test_a_phone_that_muted_a_room_hears_nothing_from_it(self):
        self.store.follow_rooms(["phone-1", "phone-2"], ["room-a"])
        self.store.set_mutes(["phone-1"], {"g:room-a": 0})
        self.watch.look()
        self.hermes.say("room-a", "message.member", "scout", "Only phone-2 hears this.")
        self.watch.look()
        self.assertEqual([devices for devices, _ in self.sent], [["phone-2"]])

    def test_a_mute_runs_out_and_a_new_list_replaces_the_old(self):
        self.store.set_mutes(["phone-1"], {"s:chat-1": 2000, "g:room-a": 0})
        self.assertTrue(self.store.muted("phone-1", "s:chat-1", now=1000))
        self.assertFalse(self.store.muted("phone-1", "s:chat-1", now=3000), "ran out")
        self.assertTrue(self.store.muted("phone-1", "g:room-a", now=10**12), "until the phone says otherwise")
        self.assertFalse(self.store.muted("phone-2", "g:room-a"))
        self.store.set_mutes(["phone-1"], {})
        self.assertFalse(self.store.muted("phone-1", "g:room-a"), "all of it, each time")

    def test_a_muted_conversation_is_left_out_of_its_targets(self):
        self.store.watch("chat-1", ["phone-1", "phone-2"])
        self.store.set_mutes(["phone-2"], {"s:chat-1": 0})
        self.assertEqual([d["id"] for d in self.store.targets("chat-1", "desktop")], ["phone-1"])
        self.assertEqual([d["id"] for d in self.store.targets("chat-1", "api_server")], ["phone-1"])

    def test_the_app_says_what_it_muted(self):
        plugin._store = self.store
        try:
            self.assertEqual(plugin._slash("mutes phone-1 s:chat-1=0,g:redde-abc=1791330000"), "redde-push muted 1")
            self.assertTrue(self.store.muted("phone-1", "s:chat-1"))
            self.assertTrue(self.store.muted("phone-1", "g:redde-abc", now=1791329999))
            self.assertEqual(plugin._slash("mutes phone-1"), "redde-push muted 1")
            self.assertFalse(self.store.muted("phone-1", "s:chat-1"), "none muted now")
        finally:
            plugin._store = None

    def test_each_message_and_each_wait_keeps_its_own_notification(self):
        device = {"id": "phone-1", "key": core.b64u(b"k" * 32)}
        one = core.room_note("group", "room-a", "Weekend hike", body="Yes.", detail="Scout")
        two = core.room_note("group", "room-a", "Weekend hike", body="No.", detail="Quill")
        self.assertNotEqual(core.collapse_id(device, one), core.collapse_id(device, two))
        asked = core.room_note("group_wait", "room-a", "Weekend hike", body="rm -rf build", waits="approval")
        retry = core.room_note("group_wait", "room-a", "Weekend hike", waits="retry", task="t1")
        self.assertNotEqual(core.collapse_id(device, asked), core.collapse_id(device, retry))
        self.assertNotIn("h", retry)


if __name__ == "__main__":
    unittest.main()

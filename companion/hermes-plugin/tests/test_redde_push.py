"""python -m unittest discover -s companion/hermes-plugin/tests  (needs `cryptography`, which
Hermes's own Python has).

Beside the plugin, not inside it: what is in the plugin's folder is what `hermes plugins install`
copies and scans, and the loopback addresses these tests use trip the scan."""
import base64
import importlib.util
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

HERE = Path(__file__).resolve().parent.parent / "redde-push"
spec = importlib.util.spec_from_file_location("redde_push", HERE / "__init__.py", submodule_search_locations=[str(HERE)])
plugin = importlib.util.module_from_spec(spec)
sys.modules["redde_push"] = plugin
spec.loader.exec_module(plugin)
core, qr = plugin.core, plugin.qr


class Phone:
    """What Redde does with a pairing link, for the tests."""

    def __init__(self, link, device_id="dev-1234567890abcdef", send="send-key", name="Test phone"):
        self.device_id = device_id
        offered = core.unb64u(link.split("#push=")[1].split("&")[0])
        private = X25519PrivateKey.generate()
        self.public = private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
        shared = private.exchange(X25519PublicKey.from_public_bytes(offered))
        self.note_key, box_key = core.derive(shared, offered, self.public)
        inside = json.dumps({"id": device_id, "send": send, "name": name}).encode()
        self.answer = {"pub": core.b64u(self.public), "box": core.b64u(core.seal(box_key, inside, b"redde-push pairing"))}
        self.slot = core.rendezvous(offered)

    def read(self, payload):
        blob = base64.b64decode(payload)
        assert blob[:4] == core.key_id(self.note_key)
        return json.loads(core.unseal(self.note_key, blob[4:], self.device_id.encode()))


class Relay:
    """A relay on loopback that records what it is sent."""

    def __init__(self, status=202):
        relay = self
        self.pushes, self.status, self.answers = [], status, {}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _reply(self, status, body=None):
                data = json.dumps(body).encode() if body is not None else b""
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                answer = relay.answers.pop(self.path.rsplit("/", 1)[1], None)
                self._reply(200, answer) if answer else self._reply(404, {"error": "nothing yet"})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                relay.pushes.append({"path": self.path, "bearer": self.headers.get("Authorization"), **body})
                self._reply(relay.status, {"apns": 200} if relay.status == 202 else {"error": "gone"})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class PairingTests(unittest.TestCase):
    def test_both_sides_reach_the_same_key_and_the_relay_address_rides_only_when_it_differs(self):
        offer = core.Offer()
        self.assertTrue(offer.link.startswith("https://redde.goosehouse.org/connect#push="))
        self.assertNotIn("relay=", offer.link)
        phone = Phone(offer.link)
        self.assertEqual(phone.slot, offer.rendezvous)
        device = offer.accept(phone.answer)
        self.assertEqual(core.unb64u(device["key"]), phone.note_key)
        self.assertEqual((device["id"], device["send"], device["name"]), ("dev-1234567890abcdef", "send-key", "Test phone"))
        self.assertEqual(device["relay"], core.DEFAULT_RELAY)
        other = core.Offer("http://127.0.0.1:18980/")
        self.assertTrue(other.link.endswith("&relay=http%3A%2F%2F127.0.0.1%3A18980"))

    def test_an_answer_to_another_offer_is_refused(self):
        offer, other = core.Offer(), core.Offer()
        with self.assertRaises(ValueError):
            offer.accept(Phone(other.link).answer)
        with self.assertRaises(ValueError):
            offer.accept({"pub": "AAAA", "box": "AAAA"})
        with self.assertRaises(ValueError):
            offer.accept({})

    def test_the_link_fits_a_qr_code_and_the_code_is_square(self):
        for offer in (core.Offer(), core.Offer("http://127.0.0.1:18980")):
            grid = qr.matrix(offer.link.encode())
            self.assertTrue(all(len(row) == len(grid) for row in grid))
            self.assertIn(len(grid), (37, 41))
        with self.assertRaises(ValueError):
            qr.matrix(b"x" * 135)
        # The three finder patterns: a dark 3x3 inside a light ring inside a dark ring.
        grid = qr.matrix(b"hello")
        size = len(grid)
        for top, left in ((0, 0), (0, size - 7), (size - 7, 0)):
            self.assertTrue(all(grid[top][left + i] and grid[top + 6][left + i] for i in range(7)))
            self.assertTrue(all(not grid[top + 1][left + i] for i in range(1, 6)))
            self.assertTrue(all(grid[top + 2 + j][left + 2 + i] for i in range(3) for j in range(3)))


class NoteTests(unittest.TestCase):
    def setUp(self):
        self.offer = core.Offer()
        self.phone = Phone(self.offer.link)
        self.device = self.offer.accept(self.phone.answer)

    def test_a_note_is_readable_by_the_phone_and_by_nobody_holding_less(self):
        made = core.note("reply", "20261006_1", "The build is green.\n\nAll 381 tests pass.", title="Nightly build")
        payload = core.sealed(self.device, made)
        self.assertEqual(self.phone.read(payload), made)
        self.assertEqual(made["b"], "The build is green.\n\nAll 381 tests pass.", "a reply keeps its lines")
        self.assertNotIn(b"build", base64.b64decode(payload))
        stranger = Phone(core.Offer().link)
        with self.assertRaises(Exception):
            json.loads(core.unseal(stranger.note_key, base64.b64decode(payload)[4:], b"dev-1234567890abcdef"))
        with self.assertRaises(Exception):   # sealed to this device: another device's id won't open it
            core.unseal(self.phone.note_key, base64.b64decode(payload)[4:], b"another-device")
        self.assertNotEqual(core.sealed(self.device, made), payload, "a fresh nonce every time")

    def test_a_long_reply_is_cut_to_fit_a_notification(self):
        made = core.note("reply", "s", "é" * 5000, title="t" * 300, detail="d" * 900)
        self.assertLessEqual(len(json.dumps(made, ensure_ascii=False).encode()), core.NOTE_LIMIT)
        self.assertLessEqual(len(made["b"]), core.BODY_LIMIT)
        self.assertTrue(made["b"].endswith("…") and made["t"].endswith("…"))
        self.assertLessEqual(len(core.sealed(self.device, made)), 3600, "what the relay accepts")
        emoji = core.note("reply", "s", "🎉" * 5000)
        self.assertLessEqual(len(core.sealed(self.device, emoji)), 3600)

    def test_notes_about_the_same_thing_share_a_collapse_id_that_says_nothing(self):
        first = core.collapse_id(self.device, core.note("reply", "s1", "one"))
        self.assertEqual(first, core.collapse_id(self.device, core.note("reply", "s1", "two")))
        self.assertNotEqual(first, core.collapse_id(self.device, core.note("reply", "s2", "one")))
        self.assertNotEqual(core.collapse_id(self.device, core.note("approval", "s1", "rm -rf a")),
                            core.collapse_id(self.device, core.note("approval", "s1", "rm -rf b")))
        self.assertRegex(first, r"^[0-9a-f]{32}$")
        self.assertNotIn("s1", first)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.store = core.Store(self.home)
        self.a = {"id": "device-a", "send": "sa", "key": core.b64u(b"a" * 32), "name": "A", "relay": "http://relay.test"}
        self.b = {"id": "device-b", "send": "sb", "key": core.b64u(b"b" * 32), "name": "B", "relay": "http://relay.test"}

    def test_files_are_private_and_shared_between_processes(self):
        self.store.add(self.a)
        folder = self.home / "redde-push"
        self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
        self.assertEqual((folder / "devices.json").stat().st_mode & 0o777, 0o600)
        other = core.Store(self.home)                       # the gateway's process beside the Dashboard's
        self.assertEqual([d["id"] for d in other.devices], ["device-a"])
        self.store.add(self.b)
        self.assertEqual([d["id"] for d in other.devices], ["device-a", "device-b"])
        self.store.add({**self.a, "name": "A again"})        # paired again: replaced, not doubled
        self.assertEqual([d["name"] for d in other.devices], ["B", "A again"])

    def test_only_the_conversations_a_phone_follows_notify_it(self):
        self.store.add(self.a)
        self.store.add(self.b)
        self.assertEqual(self.store.targets("s1", "tui"), [])
        self.assertEqual(self.store.watch("s1", ["device-a", "a-stranger"]), ["device-a"])
        self.assertEqual([d["id"] for d in self.store.targets("s1", "tui")], ["device-a"])
        self.assertEqual(self.store.targets("s2", "tui"), [])
        self.store.watch("s1", ["device-b"])
        self.assertEqual([d["id"] for d in self.store.targets("s1", "tui")], ["device-a", "device-b"])
        self.assertEqual(self.store.watch("s3", ["a-stranger"]), [])
        self.assertEqual(self.store.targets("s3", "tui"), [])

    def test_a_turn_over_the_hermes_api_notifies_every_phone(self):
        self.store.add(self.a)
        self.store.add(self.b)
        self.assertEqual(len(self.store.targets("api_1", "api_server")), 2)
        self.assertEqual(self.store.targets("x", "cli"), [])
        self.store.set_notify_all(True)
        self.assertEqual(len(self.store.targets("x", "cli")), 2)
        self.store.set_notify_all(False)
        self.assertEqual(self.store.targets("x", "cli"), [])
        self.assertEqual(len(self.store.devices), 2, "the setting doesn't touch the phones")

    def test_a_removed_phone_follows_nothing(self):
        self.store.add(self.a)
        self.store.add(self.b)
        self.store.watch("s1", ["device-a", "device-b"])
        self.assertTrue(self.store.remove("device-a"))
        self.assertFalse(self.store.remove("device-a"))
        self.assertEqual([d["id"] for d in self.store.targets("s1", "tui")], ["device-b"])
        self.assertEqual(json.loads((self.home / "redde-push" / "watch.json").read_text()), {"sessions": {"s1": ["device-b"]}})

    def test_the_oldest_conversations_are_forgotten_first(self):
        self.store.add(self.a)
        for i in range(core.WATCHED_SESSIONS + 5):
            self.store.watch(f"s{i}", ["device-a"])
        self.store.watch("s7", ["device-a"])                 # followed again: newest
        self.assertEqual(self.store.targets("s0", "tui"), [])
        self.assertEqual(len(self.store.targets("s7", "tui")), 1)
        self.assertEqual(len(self.store.targets(f"s{core.WATCHED_SESSIONS + 4}", "tui")), 1)


class SendingTests(unittest.TestCase):
    def setUp(self):
        self.relay = Relay()
        self.addCleanup(self.relay.close)
        self.store = core.Store(Path(tempfile.mkdtemp()))
        self.offer = core.Offer(self.relay.url)
        self.phone = Phone(self.offer.link)
        self.store.add(self.offer.accept(self.phone.answer))
        self.pusher = core.Pusher(self.store, title_of=lambda session: f"Title of {session}")

    def test_a_reply_reaches_the_relay_sealed_with_the_phone_s_secret_as_bearer(self):
        self.assertEqual(self.pusher.submit("reply", "api_7", "api_server", body="Done: 3 files changed."), 1)
        self.pusher.drain()
        self.assertEqual(len(self.relay.pushes), 1)
        sent = self.relay.pushes[0]
        self.assertEqual(sent["path"], "/v1/devices/dev-1234567890abcdef/push")
        self.assertEqual(sent["bearer"], "Bearer send-key")
        self.assertNotIn("Done", json.dumps(sent))
        made = self.phone.read(sent["payload"])
        self.assertEqual((made["k"], made["s"], made["b"], made["t"]), ("reply", "api_7", "Done: 3 files changed.", "Title of api_7"))

    def test_nothing_is_sent_about_a_conversation_no_phone_follows(self):
        self.assertEqual(self.pusher.submit("reply", "desk-session", "tui", body="hello"), 0)
        self.pusher.drain()
        self.assertEqual(self.relay.pushes, [])

    def test_a_phone_the_relay_no_longer_has_is_forgotten(self):
        self.relay.status = 410
        self.pusher.submit("approval", "api_7", "api_server", body="rm -rf build")
        self.pusher.drain()
        self.assertEqual(self.store.devices, [])

    def test_the_plugin_takes_the_phone_s_answer_from_the_relay(self):
        self.assertIsNone(core.take_answer(self.relay.url, self.offer.rendezvous))
        self.relay.answers[self.offer.rendezvous] = self.phone.answer
        self.assertEqual(core.take_answer(self.relay.url, self.offer.rendezvous), self.phone.answer)


class HookTests(unittest.TestCase):
    """The functions Hermes calls, with the payloads stock Hermes 0.21 hands them."""

    def setUp(self):
        self.relay = Relay()
        self.addCleanup(self.relay.close)
        store = core.Store(Path(tempfile.mkdtemp()))
        offer = core.Offer(self.relay.url)
        self.phone = Phone(offer.link)
        store.add(offer.accept(self.phone.answer))
        plugin._store, plugin._pusher = store, core.Pusher(store)
        plugin._platforms.clear()
        self.addCleanup(lambda: setattr(plugin, "_store", None))

    def sent(self):
        plugin._pusher.drain()
        return [self.phone.read(p["payload"]) for p in self.relay.pushes]

    def test_the_app_follows_a_dashboard_conversation_and_hears_its_reply_and_approval(self):
        self.assertEqual(plugin._slash("status"), "redde-push paired 1")
        plugin._remember_platform(session_id="20261006_1", platform="tui", model="alpha")
        plugin._on_reply(session_id="20261006_1", assistant_response="Not yet followed.", platform="tui")
        self.assertEqual(self.sent(), [])
        self.assertEqual(plugin._slash("watch 20261006_1 dev-1234567890abcdef,someone-else"), "redde-push watching 1")
        plugin._on_approval(command="rm -rf build", description="recursive delete", session_id="20261006_1", surface="smart")
        self.assertEqual(self.sent(), [], "a model is asked first; nobody is waiting on a person yet")
        plugin._on_approval(command="rm -rf build", description="recursive delete", session_id="20261006_1", surface="gateway", turn_id="t")
        plugin._on_reply(session_id="20261006_1", assistant_response="Removed the build folder.", platform="tui", conversation_history=[])
        notes = self.sent()
        self.assertEqual([(n["k"], n["b"]) for n in notes], [("approval", "rm -rf build"), ("reply", "Removed the build folder.")])
        self.assertEqual(notes[0]["d"], "recursive delete")

    def test_an_api_turn_s_approval_notifies_though_the_hook_isn_t_told_the_platform(self):
        plugin._remember_platform(session_id="api_9", platform="api_server")
        plugin._on_approval(command="git push --force", description="force push", session_key="api_9", session_id="api_9", surface="gateway")
        self.assertEqual([(n["k"], n["s"]) for n in self.sent()], [("approval", "api_9")])

    def test_an_empty_reply_and_a_hook_called_oddly_send_nothing_and_raise_nothing(self):
        plugin._on_reply(session_id="api_9", assistant_response="   ", platform="api_server")
        plugin._on_reply(session_id="api_9", assistant_response=None, platform="api_server")
        plugin._on_reply()
        plugin._on_approval()
        self.assertEqual(self.sent(), [])
        self.assertIn("for the Redde app", plugin._slash(""))
        self.assertIn("for the Redde app", plugin._slash("watch only-two"))


if __name__ == "__main__":
    unittest.main()

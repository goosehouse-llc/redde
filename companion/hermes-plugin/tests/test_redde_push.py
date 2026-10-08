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

    def test_an_approval_the_phone_can_answer_names_its_command_by_digest(self):
        long = "rm -rf " + "a/very/long/path/" * 60
        made = core.note("approval", "20261007_1", long, detail="recursive delete", answerable=True)
        self.assertEqual(made["h"], core.digest(long), "of the whole command, though only its start fits")
        self.assertTrue(made["b"].endswith("…"))
        self.assertRegex(made["h"], r"^[0-9a-f]{16}$")
        # The app's `PushNote.digest` gives the same for these (EchoTests/PushTests.swift).
        self.assertEqual(core.digest("rm -rf build"), "17f69ae2697b61fd")
        self.assertEqual(core.digest('echo "héllo" && rm -rf ~/tmp'), "3d490b0dae41032b")
        self.assertNotIn("h", core.note("approval", "api_1", "rm -rf build"), "not when it can't be answered from the notification")
        self.assertNotIn("h", core.note("approval", "", "rm -rf build", answerable=True))
        self.assertNotIn("h", core.note("reply", "20261007_1", "Done.", answerable=True))

    def test_notes_about_the_same_thing_share_a_collapse_id_that_says_nothing(self):
        first = core.collapse_id(self.device, core.note("reply", "s1", "one"))
        self.assertEqual(first, core.collapse_id(self.device, core.note("reply", "s1", "two")))
        self.assertNotEqual(first, core.collapse_id(self.device, core.note("reply", "s2", "one")))
        self.assertNotEqual(core.collapse_id(self.device, core.note("approval", "s1", "rm -rf a")),
                            core.collapse_id(self.device, core.note("approval", "s1", "rm -rf b")))
        self.assertRegex(first, r"^[0-9a-f]{32}$")
        self.assertNotIn("s1", first)
        # However a turn ended, a later note about it takes the earlier one's place: a reply that
        # arrives after all replaces "couldn't reply".
        self.assertEqual(first, core.collapse_id(self.device, core.note("failed", "s1", "HTTP 500")))
        self.assertEqual(first, core.collapse_id(self.device, core.note("task", "s1", "Done.")))
        self.assertNotEqual(first, core.collapse_id(self.device, core.note("question", "s1", "Which?")))
        self.assertNotEqual(core.collapse_id(self.device, core.note("sudo", "s1")), core.collapse_id(self.device, core.note("secret", "s1")))

    def test_a_note_about_someone_being_waited_on_carries_what_is_asked(self):
        made = core.note("question", "20261007_1", "Which branch should I deploy?", title="Release", detail="main · release")
        self.assertEqual((made["k"], made["b"], made["d"], made["t"]), ("question", "Which branch should I deploy?", "main · release", "Release"))
        self.assertNotIn("h", made)
        # One the phone can answer from the notification names the question by its digest, the
        # way an approval names its command, and brings the choices as buttons to make.
        answerable = core.note("question", "20261007_1", "Which branch should I deploy?", detail="main · release", answerable=True, choices=["main", "release"])
        self.assertEqual((answerable["h"], answerable["c"]), (core.digest("Which branch should I deploy?"), ["main", "release"]))
        # The app's `PushNote.digest` gives the same for this (EchoTests/PushTests.swift).
        self.assertEqual(answerable["h"], "54e912433ad05e6b")
        open_question = core.note("question", "20261007_1", "What should it be called?", answerable=True, choices=[])
        self.assertIn("h", open_question)
        self.assertNotIn("c", open_question, "no choices: a typed answer")
        self.assertEqual(len(core.note("question", "s", "Which?", answerable=True, choices=list("abcdefg"))["c"]), 4, "as many as a notification has buttons for")
        for unanswerable in (core.note("question", "20261007_1", "Which?", answerable=True),                      # several questions, or a Hermes that keeps no list
                             core.note("question", "20261007_1", "Which?", choices=["a"]),                      # nobody follows it
                             core.note("question", "", "Which?", answerable=True, choices=["a"])):
            self.assertNotIn("h", unanswerable)
            self.assertNotIn("c", unanswerable)
        self.assertNotIn("b", core.note("sudo", "20261007_1"), "Hermes 0.21.3 doesn't say which command")
        self.assertEqual(self.phone.read(core.sealed(self.device, made)), made)
        # Apple keeps a note about as long as Hermes waits for the answer.
        self.assertEqual((core.TTL["sudo"], core.TTL["secret"], core.TTL["approval"]), (180, 300, 600))
        self.assertNotIn("reply", core.TTL)


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
        self.assertTrue(self.store.follows("s1"))
        self.assertFalse(self.store.follows("s2") or self.store.follows("s3") or self.store.follows(""))

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


class Answer:
    """A model's answer as Hermes hands it to `post_api_request`: its own type, whose tool calls
    carry their arguments as JSON text (seen on 0.21.0, 0.21.3 and 0.21.5)."""

    class Call:
        def __init__(self, name, arguments):
            self.id, self.type = "call_1", "function"
            self.function = type("Function", (), {"name": name, "arguments": json.dumps(arguments)})()

    def __init__(self, *calls, content=None):
        self.role, self.content = "assistant", content
        self.tool_calls = [Answer.Call(name, arguments) for name, arguments in calls] or None


class ReadingTests(unittest.TestCase):
    """What the plugin makes of what Hermes hands its hooks."""

    def test_the_tools_an_answer_calls(self):
        answer = Answer(("clarify", {"questions": [{"question": "Which?"}]}), ("terminal", {"command": "sudo true"}))
        self.assertEqual(core.tool_calls(answer), [("clarify", {"questions": [{"question": "Which?"}]}), ("terminal", {"command": "sudo true"})])
        self.assertEqual(core.tool_calls(Answer(content="Done.")), [])
        self.assertEqual(core.tool_calls(None), [])
        # As plain dictionaries too, and nothing is made of what doesn't read as a call.
        loose = {"tool_calls": [{"function": {"name": "clarify", "arguments": {"question": "Sure?"}}}, {"function": {"name": "x", "arguments": "{not json"}},
                                {"function": {"arguments": "{}"}}, "nonsense"]}
        self.assertEqual(core.tool_calls(loose), [("clarify", {"question": "Sure?"}), ("x", {})])

    def test_a_question_and_its_choices(self):
        ask = core.question
        self.assertEqual(ask({"questions": [{"question": "Which branch should I deploy?", "choices": ["main", "release"]}]}),
                         ("Which branch should I deploy?", "main · release", ["main", "release"]))
        self.assertEqual(ask({"question": "Go ahead?"}), ("Go ahead?", "", []), "the older form, one question at the top")
        self.assertEqual(ask({"question": "Go ahead?", "choices": [{"label": "Yes"}, {"label": "No"}]}), ("Go ahead?", "Yes · No", ["Yes", "No"]))
        # Several questions, or one where several choices may be ticked: one answer can't settle
        # those, so there is no list of choices to answer from.
        self.assertEqual(ask({"questions": [{"question": "One?"}, {"question": "Two?"}, {"question": "Three?"}]}), ("One?", "and 2 more questions", None))
        self.assertEqual(ask({"questions": [{"question": "One?"}, {"question": "Two?"}]}), ("One?", "and 1 more question", None))
        self.assertEqual(ask({"questions": [{"question": "Which?", "choices": ["a", "b"], "multi_select": True}]}), ("Which?", "a · b", None))
        # Calls Hermes turns down without asking anyone: nothing to announce.
        self.assertEqual(ask({}), ("", "", None))
        self.assertEqual(ask({"questions": [{"question": "  "}]}), ("", "", None))
        self.assertEqual(ask({"questions": [{"question": f"q{i}"} for i in range(6)]}), ("", "", None))
        self.assertEqual(ask({"questions": "which?"}), ("", "", None))

    def test_why_a_request_failed_in_the_provider_s_words(self):
        said = {"type": "AuthenticationError", "message": "Error code: 401 - {'error': {'message': 'Incorrect API key provided.', 'type': 'invalid_request_error', 'code': 'invalid_api_key'}}"}
        self.assertEqual(core.failure(401, said), "HTTP 401: Incorrect API key provided.")
        quota = {"message": """Error code: 429 - {'error': {'message': "You've exceeded your quota.", 'type': 'insufficient_quota'}}"""}
        self.assertEqual(core.failure(429, quota), "HTTP 429: You've exceeded your quota.")
        self.assertEqual(core.failure(500, {"message": "Error code: 500 - Internal Server Error"}), "HTTP 500: Internal Server Error")
        self.assertEqual(core.failure(None, {"message": "Connection error."}), "Connection error.")
        self.assertEqual(core.failure(), "The model couldn't be reached.")
        self.assertLessEqual(len(core.failure(500, {"message": "x" * 5000})), 320)

    def test_what_is_said_of_tasks_that_came_back(self):
        self.assertEqual(core.task_report([("completed", "Counted 12 files.")]), ("Counted 12 files.", ""))
        self.assertEqual(core.task_report([("timeout", "")]), ("", "Ended: timeout"))
        self.assertEqual(core.task_report([("completed", ""), ("failed", "No network."), ("completed", "Fine.")]), ("No network.", "3 tasks, 1 not completed"))
        self.assertEqual(core.task_report([("completed", "a"), ("completed", "b")]), ("a", "2 tasks"))


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class Held(core.Later):
    """A `Later` no thread runs: the test says when time has passed."""

    def after(self, name, seconds, action):
        with self._lock:
            self._waiting[name] = (self._clock() + seconds, action)

    def pass_(self, seconds):
        self._clock.now += seconds
        with self._lock:
            due = self._due()
        for action in due:
            action()


class TurnTests(unittest.TestCase):
    """A turn that ends without a reply, told from the little Hermes says."""

    def setUp(self):
        self.clock = Clock()
        self.failed, self.finished = [], []
        self.turns = core.Turns(failed=lambda *a: self.failed.append(a), finished=lambda *a: self.finished.append(a),
                                later=Held(self.clock), clock=self.clock)
        self.later = self.turns.later

    def test_a_request_that_is_refused_and_then_silence_is_a_failed_turn(self):
        self.turns.began("s1", "t1")
        self.turns.request_failed("s1", "desktop", False, "auth", "HTTP 401: Incorrect API key provided.")
        self.later.pass_(core.Turns.SETTLED - 1)
        self.assertEqual(self.failed, [], "Hermes may still be moving to another key or model")
        self.later.pass_(2)
        self.assertEqual(self.failed, [("s1", "desktop", "HTTP 401: Incorrect API key provided.")])
        self.later.pass_(1000)
        self.assertEqual(len(self.failed), 1, "said once")

    def test_a_turn_that_is_still_trying_is_not_called_failed(self):
        # Hermes 0.21.5 with its provider down: three attempts seconds apart, then five rounds of
        # them up to 72 seconds apart, and only then does it give up.
        self.turns.began("s1", "t1")
        for pause in (2, 5, 17, 2, 5, 33, 2, 5, 72, 2, 5, 70, 2, 5, 66, 2, 5):
            self.turns.request_failed("s1", "api_server", True, "server_error", "HTTP 500: The server had an error.")
            self.later.pass_(pause)
            self.turns.moved("s1")          # pre_api_request: the next attempt
        self.assertEqual(self.failed, [])
        self.turns.request_failed("s1", "api_server", True, "server_error", "HTTP 500: The server had an error.")
        self.later.pass_(core.Turns.RETRYING + 1)
        self.assertEqual(self.failed, [("s1", "api_server", "HTTP 500: The server had an error.")])

    def test_a_rate_limit_is_given_as_long_as_hermes_waits_for_one(self):
        self.turns.request_failed("s1", "desktop", True, "rate_limit", "HTTP 429: Slow down.")
        self.later.pass_(core.Turns.RETRYING + 60)
        self.assertEqual(self.failed, [])
        self.later.pass_(core.Turns.LIMITED)
        self.assertEqual(len(self.failed), 1)

    def test_a_reply_a_stop_or_a_new_turn_calls_it_off(self):
        for call_off in (lambda: self.turns.ended("s1"), lambda: self.turns.began("s1", "t2"), lambda: self.turns.moved("s1")):
            self.turns.request_failed("s1", "desktop", False, "auth", "HTTP 401")
            call_off()
            self.later.pass_(1000)
        self.turns.request_failed("s2", "desktop", False, "auth", "HTTP 401")
        self.turns.ended("s1")              # another conversation's turn ending says nothing about this one
        self.later.pass_(1000)
        self.assertEqual(self.failed, [("s2", "desktop", "HTTP 401")])

    def test_what_is_still_waiting_when_the_process_leaves_is_said_then(self):
        self.turns.request_failed("s1", "cli", True, "server_error", "HTTP 500")
        self.later.flush()
        self.assertEqual(self.failed, [("s1", "cli", "HTTP 500")])

    def test_a_task_that_comes_back_between_turns_makes_the_next_reply_its_news(self):
        self.turns.began("s1", "t1")
        self.turns.task_finished("s1", "completed", "inside the turn")
        self.turns.ended("s1")
        self.assertFalse(self.turns.reply_is_of_a_task("s1"), "a task that ran inside a turn is part of that turn's reply")
        self.turns.task_finished("s1", "completed", "Counted 12 files.")     # in the background, after the turn
        self.turns.began("s1", "t2")                                          # Hermes starts the turn that reports it
        self.assertTrue(self.turns.reply_is_of_a_task("s1"))
        self.assertFalse(self.turns.reply_is_of_a_task("s1"), "that one reply, not the next")
        self.later.pass_(1000)
        self.assertEqual(self.finished, [], "the reply was the news")

    def test_a_task_no_turn_reports_is_reported_by_its_own_summary(self):
        # Over the Hermes API from 0.21.3: the task comes back and nothing follows.
        self.turns.task_finished("api_1", "completed", "Counted 12 files.")
        self.turns.task_finished("api_1", "timeout", "")
        self.later.pass_(core.Turns.REPORT - 1)
        self.assertEqual(self.finished, [])
        self.later.pass_(2)
        self.assertEqual(self.finished, [("api_1", [("completed", "Counted 12 files."), ("timeout", "")])])
        self.assertFalse(self.turns.reply_is_of_a_task("api_1"), "said; the person's next question gets an ordinary reply")
        self.turns.task_finished("api_1", "completed", "old")
        self.clock.now += core.Turns.RESULT + 1
        self.assertFalse(self.turns.reply_is_of_a_task("api_1"), "nor does one from long ago count")


class LaterTests(unittest.TestCase):
    def test_it_does_things_when_their_time_comes_unless_called_off(self):
        import time
        later, done = core.Later(), []
        later.after("a", 0.05, lambda: done.append("a"))
        later.after("b", 0.05, lambda: done.append("b"))
        later.after("c", 30, lambda: done.append("c"))
        self.assertTrue(later.cancel("b"))
        self.assertFalse(later.cancel("b"))
        later.after("a", 0.1, lambda: done.append("a again"))    # the same name: put off, not doubled
        for _ in range(100):
            if done:
                break
            time.sleep(0.02)
        self.assertEqual(done, ["a again"])
        self.assertTrue(later.waiting("c"))
        later.after("d", 30, lambda: 1 / 0)
        later.flush()                                            # one that fails doesn't stop the rest
        self.assertEqual(sorted(done), ["a again", "c"])
        self.assertFalse(later.waiting("c"))


class WaitingTests(unittest.TestCase):
    """A sudo password or a secret being asked for, found in the Dashboard's own list."""

    def setUp(self):
        self.clock = Clock()
        self.open, self.found = [], []
        self.waiting = core.Waiting(peek=lambda: list(self.open), found=lambda *a: self.found.append(a), clock=self.clock)
        self.waiting._thread = object()      # no thread: the test looks

    def test_only_the_two_prompts_no_hook_tells_of_and_each_once(self):
        self.waiting._watched["s1"] = self.clock.now + 60
        self.open = [("s1", "srq-1", "approval", {"command": "rm -rf build"}), ("s1", "srq-2", "clarify", {})]
        self.assertTrue(self.waiting.look())
        self.assertEqual(self.found, [], "approvals and questions have hooks of their own")
        self.open.append(("s1", "srq-3", "sudo", {"command": "sudo true"}))
        self.open.append(("s2", "srq-4", "secret", {"prompt": "Token", "env_var": "TOKEN"}))
        self.waiting.look()
        self.waiting.look()
        self.assertEqual(self.found, [("s1", "sudo", {"command": "sudo true"})], "once, and not for a conversation nobody watches")
        self.waiting._watched["s2"] = self.clock.now + 60
        self.waiting.look()
        self.assertEqual(self.found[1:], [("s2", "secret", {"prompt": "Token", "env_var": "TOKEN"})])

    def test_it_stops_looking_when_the_tools_are_done_or_after_long_enough(self):
        self.waiting._watched["s1"] = self.clock.now + 60
        self.waiting.forget("s1")
        self.assertFalse(self.waiting.look())
        self.waiting._watched["s1"] = self.clock.now + 60
        self.clock.now += 61
        self.open = [("s1", "srq-1", "sudo", {})]
        self.assertFalse(self.waiting.look())
        self.assertEqual(self.found, [])

    def test_a_list_that_cannot_be_read_announces_nothing_and_breaks_nothing(self):
        def broken():
            raise AttributeError("moved in a later Hermes")
        self.waiting.peek = broken
        self.waiting._watched["s1"] = self.clock.now + 60
        self.assertTrue(self.waiting.look())
        self.assertEqual(self.found, [])

    def test_watching_starts_a_thread_that_ends_with_the_watch(self):
        import time
        waiting = core.Waiting(peek=lambda: [("s1", "srq-1", "sudo", {})], found=lambda *a: self.found.append(a))
        waiting.EVERY = 0.01
        waiting.watch("s1")
        for _ in range(100):
            if self.found:
                break
            time.sleep(0.01)
        self.assertEqual(self.found, [("s1", "sudo", {})])
        waiting.forget("s1")
        for _ in range(100):
            if waiting._thread is None:
                break
            time.sleep(0.01)
        self.assertIsNone(waiting._thread)
        self.found.clear()
        waiting.peek = lambda: [("s1", "srq-2", "secret", {})]
        waiting.watch("s1")                                       # and starts again
        for _ in range(100):
            if self.found:
                break
            time.sleep(0.01)
        self.assertEqual(self.found, [("s1", "secret", {})])
        waiting.forget("s1")


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
        plugin._replied.clear()
        self.clock = Clock()
        self.later = Held(self.clock)
        self.open = []
        plugin._turns = core.Turns(failed=plugin._failed, finished=plugin._tasks_came_back, later=self.later, clock=self.clock)
        plugin._waiting = core.Waiting(peek=lambda: list(self.open), found=plugin._asked_for, clock=self.clock)
        plugin._waiting._thread = object()   # no thread: the test looks
        self.addCleanup(lambda: [setattr(plugin, name, None) for name in ("_store", "_turns", "_waiting")])

    def sent(self):
        plugin._pusher.drain()
        return [self.phone.read(p["payload"]) for p in self.relay.pushes]

    def test_the_app_follows_a_dashboard_conversation_and_hears_its_reply_and_approval(self):
        self.assertEqual(plugin._slash("status"), "redde-push status 1")
        # A conversation the app starts over the Dashboard runs on the platform "desktop".
        plugin._remember_platform(session_id="20261006_1", platform="desktop", model="alpha")
        plugin._on_reply(session_id="20261006_1", assistant_response="Not yet followed.", platform="desktop")
        self.assertEqual(self.sent(), [])
        self.assertEqual(plugin._slash("watch 20261006_1 dev-1234567890abcdef,someone-else"), "redde-push watching 1")
        plugin._on_approval(command="rm -rf build", description="recursive delete", session_id="20261006_1", surface="smart")
        self.assertEqual(self.sent(), [], "a model is asked first; nobody is waiting on a person yet")
        plugin._on_approval(command="rm -rf build", description="recursive delete", session_id="20261006_1", surface="gateway", turn_id="t")
        plugin._on_reply(session_id="20261006_1", assistant_response="Removed the build folder.", platform="desktop", conversation_history=[])
        notes = self.sent()
        self.assertEqual([(n["k"], n["b"]) for n in notes], [("approval", "rm -rf build"), ("reply", "Removed the build folder.")])
        self.assertEqual(notes[0]["d"], "recursive delete")
        self.assertEqual(notes[0]["h"], "17f69ae2697b61fd", "an approval in a followed conversation can be answered from the notification")

    def test_an_api_turn_s_approval_notifies_though_the_hook_isn_t_told_the_platform(self):
        plugin._remember_platform(session_id="api_9", platform="api_server")
        plugin._on_approval(command="git push --force", description="force push", session_key="api_9", session_id="api_9", surface="gateway")
        notes = self.sent()
        self.assertEqual([(n["k"], n["s"]) for n in notes], [("approval", "api_9")])
        self.assertNotIn("h", notes[0], "nobody follows it, so the Dashboard can't answer for it: no buttons")

    def test_an_app_on_the_dashboard_pairs_without_a_code(self):
        words = plugin._slash("offer").split()
        self.assertEqual(words[:2], ["redde-push", "offer"])
        offered, relay = words[2], words[3]
        self.assertEqual(relay, core.DEFAULT_RELAY, "the app is told which relay this Hermes uses")
        phone = Phone("#push=" + offered, device_id="dev-onetap-0001", send="tap-key", name="Tapped phone")
        # (This phone is registered at the test's relay, so that is where its first note has to go.)
        plugin._offers._open[offered][0].relay = self.relay.url
        reply = plugin._slash(f"accept {offered} {phone.answer['pub']} {phone.answer['box']}")
        self.assertEqual(reply, f"redde-push paired {core.host_name()}")
        paired = [d for d in plugin._store.devices if d["id"] == "dev-onetap-0001"]
        self.assertEqual(len(paired), 1)
        self.assertEqual((paired[0]["send"], paired[0]["name"], core.unb64u(paired[0]["key"])), ("tap-key", "Tapped phone", phone.note_key))
        for _ in range(100):                                   # its first note goes out behind the reply
            if any(p["path"].endswith("dev-onetap-0001/push") for p in self.relay.pushes):
                break
            import time; time.sleep(0.05)
        sent = [p for p in self.relay.pushes if p["path"].endswith("dev-onetap-0001/push")]
        self.assertEqual(len(sent), 1)
        self.assertEqual(phone.read(sent[0]["payload"])["k"], "paired")
        self.assertEqual(sent[0]["bearer"], "Bearer tap-key")
        # An offer is answered once.
        self.assertEqual(plugin._slash(f"accept {offered} {phone.answer['pub']} {phone.answer['box']}"), "redde-push refused: that offer has expired")

    def test_an_answer_to_another_offer_or_a_stale_one_pairs_nothing(self):
        before = len(plugin._store.devices)
        first, second = plugin._slash("offer").split()[2], plugin._slash("offer").split()[2]
        stranger = Phone("#push=" + second)
        self.assertEqual(plugin._slash(f"accept {first} {stranger.answer['pub']} {stranger.answer['box']}"),
                         "redde-push refused: that answer isn't to this offer")
        self.assertEqual(plugin._slash("accept nothing-offered AAAA AAAA"), "redde-push refused: that offer has expired")
        offered = plugin._slash("offer").split()[2]
        made = plugin._offers._open[offered]
        plugin._offers._open[offered] = (made[0], made[1] - core.Offers.LIFETIME - 1)   # ten minutes on
        phone = Phone("#push=" + offered)
        self.assertEqual(plugin._slash(f"accept {offered} {phone.answer['pub']} {phone.answer['box']}"), "redde-push refused: that offer has expired")
        self.assertEqual(len(plugin._store.devices), before)
        for _ in range(core.Offers.LIMIT + 5):                  # offers nobody answers don't pile up
            plugin._slash("offer")
        self.assertLessEqual(len(plugin._offers._open), core.Offers.LIMIT)

    def follow(self, session, platform="desktop"):
        plugin._remember_platform(session_id=session, platform=platform)
        self.assertEqual(plugin._slash(f"watch {session} dev-1234567890abcdef"), "redde-push watching 1")

    def test_a_question_the_agent_asks_reaches_the_phone_as_it_is_asked(self):
        self.follow("20261007_1")
        plugin._on_turn(session_id="20261007_1", platform="desktop", turn_id="t1", user_message="deploy")
        plugin._on_request(session_id="20261007_1", platform="desktop", turn_id="t1", retry_count=0)
        answer = Answer(("clarify", {"questions": [{"question": "Which branch should I deploy?", "choices": ["main", "release"]}]}))
        plugin._on_answer(session_id="20261007_1", platform="desktop", turn_id="t1", finish_reason="tool_calls", assistant_message=answer)
        notes = self.sent()
        self.assertEqual([(n["k"], n["s"], n["b"], n["d"]) for n in notes], [("question", "20261007_1", "Which branch should I deploy?", "main · release")])
        self.assertNotIn("h", notes[0], "this Hermes keeps no list of what it waits on (0.21.0): the answer couldn't be delivered")
        # On one that does (0.21.3 and later) the same question can be answered from the notification.
        sys.modules["tui_gateway.server_requests"] = type(sys)("tui_gateway.server_requests")
        self.addCleanup(lambda: sys.modules.pop("tui_gateway.server_requests", None))
        plugin._on_answer(session_id="20261007_1", platform="desktop", turn_id="t1", finish_reason="tool_calls", assistant_message=answer)
        again = self.sent()[1]
        self.assertEqual((again["h"], again["c"]), (core.digest("Which branch should I deploy?"), ["main", "release"]))
        several = Answer(("clarify", {"questions": [{"question": "One?"}, {"question": "Two?"}]}))
        plugin._on_answer(session_id="20261007_1", platform="desktop", assistant_message=several)
        self.assertNotIn("h", self.sent()[2], "several questions take the card")
        # A call Hermes will turn down asks nobody anything; nor does a subagent's, which has nobody to ask.
        plugin._on_answer(session_id="20261007_1", platform="desktop", assistant_message=Answer(("clarify", {"questions": []})))
        plugin._on_answer(session_id="child_1", platform="subagent", assistant_message=Answer(("clarify", {"question": "Sure?"})))
        plugin._on_answer(session_id="20261007_1", platform="desktop", assistant_message=Answer(content="No question here."))
        self.assertEqual(len(self.sent()), 3)

    def test_a_question_in_a_conversation_nobody_follows_stays_at_the_desk(self):
        plugin._on_answer(session_id="desk_1", platform="tui", assistant_message=Answer(("clarify", {"question": "Sure?"})))
        self.assertEqual(self.sent(), [])
        self.assertEqual(plugin._waiting._watched, {}, "and nobody looks for prompts there")

    def test_a_sudo_password_or_a_secret_asked_for_while_tools_run_reaches_the_phone(self):
        self.follow("20261007_1")
        plugin._on_answer(session_id="20261007_1", platform="desktop", assistant_message=Answer(("terminal", {"command": "sudo true"})))
        self.assertIn("20261007_1", plugin._waiting._watched, "tools are about to run: the Dashboard's list is watched")
        plugin._waiting.look()
        self.assertEqual(self.sent(), [], "nothing is asked yet (a cached password, a rule in sudoers: no prompt at all)")
        self.open = [("20261007_1", "srq-1", "sudo", {"command": "sudo true"})]
        plugin._waiting.look()
        plugin._waiting.look()
        self.open = [("20261007_1", "srq-2", "secret", {"prompt": "Enter the lab token", "env_var": "LAB_SECRET_TOKEN", "metadata": {"skill_name": "lab-secret"}})]
        plugin._waiting.look()
        notes = self.sent()
        self.assertEqual([(n["k"], n.get("b"), n.get("d")) for n in notes],
                         [("sudo", "sudo true", None), ("secret", "Enter the lab token", "LAB_SECRET_TOKEN")])
        # The next request to the model means the tools are done.
        plugin._on_request(session_id="20261007_1", platform="desktop")
        self.assertEqual(plugin._waiting._watched, {})
        # Over the Hermes API nothing can be put to a client, so there is nothing to watch.
        plugin._on_answer(session_id="api_9", platform="api_server", assistant_message=Answer(("terminal", {"command": "sudo true"})))
        self.assertEqual(plugin._waiting._watched, {})

    def test_the_dashboard_s_list_is_read_by_the_session_hermes_stores(self):
        self.assertEqual(plugin._peek(), [], "a process without the Dashboard has no list")
        request = type("ServerRequest", (), {"sid": "51e15338", "id": "srq-d82f0eea2a8b", "method": "sudo", "params": {"command": "sudo true"}})()
        other = type("ServerRequest", (), {"sid": "gone", "id": "srq-x", "method": "secret", "params": {}})()
        agent = type("Agent", (), {"session_id": "20261007_192346_dc4038"})()
        requests = type(sys)("tui_gateway.server_requests")
        requests._open = {"srq-d82f0eea2a8b": request, "srq-x": other}
        server = type(sys)("tui_gateway.server")
        server._sessions = {"51e15338": {"agent": agent, "session_key": "20261007_192346_dc4038"}}
        sys.modules.update({"tui_gateway.server_requests": requests, "tui_gateway.server": server})
        self.addCleanup(lambda: [sys.modules.pop(name, None) for name in ("tui_gateway.server_requests", "tui_gateway.server")])
        self.assertEqual(plugin._peek(), [("20261007_192346_dc4038", "srq-d82f0eea2a8b", "sudo", {"command": "sudo true"})])
        # After Hermes compresses a long conversation the agent's session has a new id: both are given.
        agent.session_id = "20261007_200000_aaaaaa"
        self.assertEqual([found[0] for found in plugin._peek()], ["20261007_200000_aaaaaa", "20261007_192346_dc4038"])
        del requests._open                                  # a Hermes that keeps it elsewhere
        self.assertEqual(plugin._peek(), [])

    def test_a_turn_that_gives_up_without_a_reply_says_so(self):
        # What Hermes 0.21.5 fires for a refused key, over the Hermes API: the error, and nothing after.
        plugin._on_turn(session_id="api_9", platform="api_server", turn_id="t1")
        plugin._on_request(session_id="api_9", platform="api_server", turn_id="t1", retry_count=0)
        plugin._on_request_error(session_id="api_9", platform="api_server", turn_id="t1", retry_count=0, max_retries=3, retryable=False, reason="auth", status_code=401,
                                 error={"type": "AuthenticationError", "message": "Error code: 401 - {'error': {'message': 'Incorrect API key provided.', 'type': 'invalid_request_error'}}"})
        self.assertEqual(self.sent(), [])
        self.later.pass_(core.Turns.SETTLED + 1)
        notes = self.sent()
        self.assertEqual([(n["k"], n["s"], n["b"]) for n in notes], [("failed", "api_9", "HTTP 401: Incorrect API key provided.")])

    def test_a_hermes_shut_down_while_a_turn_was_failing_says_so_on_its_way_out(self):
        # Someone restarts a Hermes whose provider is down: nothing will run later to say it.
        plugin._on_request_error(session_id="api_9", platform="api_server", retryable=True, reason="server_error", status_code=500, error={"message": "Error code: 500 - down"})
        self.addCleanup(lambda: setattr(plugin, "_leaving", False))
        plugin._leave()
        self.assertEqual([(self.phone.read(p["payload"])["k"], self.phone.read(p["payload"])["b"]) for p in self.relay.pushes], [("failed", "HTTP 500: down")],
                         "sent before the exit handler returned")
        self.assertIsNone(plugin._pusher._thread, "and with no thread: a process on its way out can't start one")

    def test_a_turn_that_recovers_says_only_its_reply(self):
        plugin._on_turn(session_id="api_9", platform="api_server", turn_id="t1")
        plugin._on_request_error(session_id="api_9", platform="api_server", turn_id="t1", retryable=True, reason="server_error", status_code=500, error={"message": "Error code: 500 - down"})
        self.later.pass_(5)
        plugin._on_request(session_id="api_9", platform="api_server", turn_id="t1", retry_count=1)
        plugin._on_answer(session_id="api_9", platform="api_server", turn_id="t1", assistant_message=Answer(content="Back."))
        plugin._on_reply(session_id="api_9", platform="api_server", turn_id="t1", assistant_response="Back.")
        plugin._on_turn_end(session_id="api_9", platform="api_server", turn_id="t1", completed=True, failed=False, interrupted=False)
        self.later.pass_(1000)
        self.assertEqual([(n["k"], n["b"]) for n in self.sent()], [("reply", "Back.")])

    def test_a_stopped_turn_and_a_failing_one_nobody_follows_say_nothing(self):
        self.follow("20261007_1")
        plugin._on_request_error(session_id="20261007_1", platform="desktop", retryable=True, reason="server_error", status_code=500, error={"message": "down"})
        plugin._on_stopped(session_key="20261007_1", platform="tui", reason="user_stop")
        plugin._on_request_error(session_id="desk_1", platform="tui", retryable=False, reason="auth", status_code=401, error={"message": "no"})
        plugin._on_request_error(session_id="child_1", platform="subagent", retryable=False, reason="auth", status_code=401, error={"message": "no"})
        # The Dashboard closing a session it no longer needs is not a turn ending.
        plugin._on_turn_end(session_id="20261007_1", platform="desktop", completed=False, interrupted=True)
        self.later.pass_(1000)
        self.assertEqual(self.sent(), [])

    def test_a_turn_hermes_calls_failed_is_announced_once(self):
        # With a few words about what went wrong: those were the reply, and have gone.
        plugin._on_reply(session_id="api_9", platform="api_server", turn_id="t1", assistant_response="I apologize, but I encountered repeated errors.")
        plugin._on_turn_end(session_id="api_9", platform="api_server", turn_id="t1", completed=False, failed=True, turn_exit_reason="repeated_errors")
        # With none: the failure itself is the news.
        plugin._on_turn_end(session_id="api_9", platform="api_server", turn_id="t2", completed=False, failed=True, turn_exit_reason="session_persistence_failed")
        plugin._on_turn_end(session_id="api_9", platform="api_server", turn_id="t3", completed=False, failed=False, interrupted=True, turn_exit_reason="interrupted_by_user")
        self.assertEqual([(n["k"], n["b"]) for n in self.sent()],
                         [("reply", "I apologize, but I encountered repeated errors."), ("failed", "The turn ended with an error (session persistence failed).")])

    def test_a_task_handed_off_comes_back_as_the_reply_hermes_then_gives(self):
        # Over the Dashboard (0.21.5): the turn that handed it off ends, the task finishes, and
        # Hermes starts a turn of its own to say what came of it.
        self.follow("20261007_1")
        plugin._on_turn(session_id="20261007_1", platform="desktop", turn_id="t1")
        plugin._on_reply(session_id="20261007_1", platform="desktop", turn_id="t1", assistant_response="On it.")
        plugin._on_turn_end(session_id="20261007_1", platform="desktop", turn_id="t1", completed=True, failed=False)
        plugin._on_turn(session_id="child_1", platform="subagent", turn_id="c1", parent_session_id="20261007_1")
        plugin._on_reply(session_id="child_1", platform="subagent", turn_id="c1", assistant_response="12 files.")
        plugin._on_task_done(parent_session_id="20261007_1", child_session_id="child_1", child_status="completed", child_summary="12 files.", duration_ms=90)
        plugin._on_turn(session_id="20261007_1", platform="desktop", turn_id="t2", user_message="[ASYNC DELEGATION BATCH COMPLETE]")
        plugin._on_reply(session_id="20261007_1", platform="desktop", turn_id="t2", assistant_response="The count is in: 12 files.")
        plugin._on_turn(session_id="20261007_1", platform="desktop", turn_id="t3", user_message="thanks")
        plugin._on_reply(session_id="20261007_1", platform="desktop", turn_id="t3", assistant_response="Any time.")
        self.later.pass_(1000)
        self.assertEqual([(n["k"], n["b"]) for n in self.sent()], [("reply", "On it."), ("task", "The count is in: 12 files."), ("reply", "Any time.")])

    def test_a_task_no_turn_reports_comes_back_in_its_own_words(self):
        # Over the Hermes API (0.21.3 and later): the task finishes and nothing follows.
        plugin._on_turn(session_id="api_9", platform="api_server", turn_id="t1")
        plugin._on_reply(session_id="api_9", platform="api_server", turn_id="t1", assistant_response="On it.")
        plugin._on_task_done(parent_session_id="api_9", child_session_id="child_1", child_status="completed", child_summary="12 files.")
        self.later.pass_(core.Turns.REPORT + 1)
        notes = self.sent()
        self.assertEqual([(n["k"], n["s"], n["b"]) for n in notes], [("reply", "api_9", "On it."), ("task", "api_9", "12 files.")])
        self.assertNotIn("d", notes[1])
        plugin._on_task_done(parent_session_id="api_9", child_status="timeout", child_summary=None)
        self.later.pass_(core.Turns.REPORT + 1)
        self.assertEqual([(n["b"], n["d"]) for n in self.sent()[2:]], [("The task has finished.", "Ended: timeout")])
        # A task a subagent handed on comes back to that subagent, and to nobody's phone.
        plugin._store.set_notify_all(True)
        plugin._on_turn(session_id="child_1", platform="subagent", turn_id="c1", parent_session_id="api_9")
        plugin._on_reply(session_id="child_1", platform="subagent", turn_id="c1", assistant_response="Handing this on.")
        plugin._on_task_done(parent_session_id="child_1", child_session_id="grandchild_1", child_status="completed", child_summary="Deep.")
        self.later.pass_(core.Turns.REPORT + 1)
        self.assertEqual(len(self.sent()), 3)

    def test_an_empty_reply_and_a_hook_called_oddly_send_nothing_and_raise_nothing(self):
        plugin._on_reply(session_id="api_9", assistant_response="   ", platform="api_server")
        plugin._on_reply(session_id="api_9", assistant_response=None, platform="api_server")
        plugin._on_reply()
        plugin._on_approval()
        for hook in (plugin._on_turn, plugin._on_request, plugin._on_answer, plugin._on_request_error, plugin._on_turn_end, plugin._on_stopped, plugin._on_task_done):
            hook()
            hook(session_id=None, platform=None, assistant_message=object(), error="text", telemetry_schema_version=3)
        plugin._on_answer(session_id="api_9", platform="api_server", assistant_message={"tool_calls": "nonsense"})
        self.later.pass_(1000)
        self.assertEqual(self.sent(), [])
        self.assertIn("for the Redde app", plugin._slash(""))
        self.assertIn("for the Redde app", plugin._slash("watch only-two"))


if __name__ == "__main__":
    unittest.main()

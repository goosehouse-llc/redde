"""python -m unittest discover -s companion/hermes-plugin/tests

Calls from the agent (redde-push/calls.py): which agents may ring which phone, what the relay is
handed for a call, and the limits on how often."""
import base64
import importlib.util
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

HERE = Path(__file__).resolve().parent.parent / "redde-push"
if "redde_push" in sys.modules:
    plugin = sys.modules["redde_push"]
else:
    spec = importlib.util.spec_from_file_location("redde_push", HERE / "__init__.py", submodule_search_locations=[str(HERE)])
    plugin = importlib.util.module_from_spec(spec)
    sys.modules["redde_push"] = plugin
    spec.loader.exec_module(plugin)
core, calls = plugin.core, plugin.calls


class Relay:
    """A relay on loopback that records what it is sent, and answers a call as told: 202, 409 for
    a phone with no address for calls, 410 for one it no longer has."""

    def __init__(self):
        relay = self
        self.pushes, self.status = [], 202

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                relay.pushes.append({"path": self.path, "bearer": self.headers.get("Authorization"), **body})
                data = json.dumps({"apns": 200} if relay.status == 202 else {"error": "no"}).encode()
                self.send_response(relay.status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def paired(store, relay, device_id):
    """Pairs a phone with the store as `hermes redde-push pair` does; its note key, to read with."""
    offer = core.Offer(relay)
    offered = core.unb64u(offer.link.split("#push=")[1].split("&")[0])
    private = X25519PrivateKey.generate()
    public = private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    note_key, box_key = core.derive(private.exchange(X25519PublicKey.from_public_bytes(offered)), offered, public)
    inside = json.dumps({"id": device_id, "send": f"send-{device_id}", "name": device_id}).encode()
    store.add(offer.accept({"pub": core.b64u(public), "box": core.b64u(core.seal(box_key, inside, b"redde-push pairing"))}))
    return note_key


def read(note_key, device_id, payload):
    blob = base64.b64decode(payload)
    return json.loads(core.unseal(note_key, blob[4:], device_id.encode()))


class CallTests(unittest.TestCase):
    def setUp(self):
        self.relay = Relay()
        self.addCleanup(self.relay.close)
        self.main = Path(tempfile.mkdtemp())
        self.store = core.Store(self.main)
        self.key = paired(self.store, self.relay.url, "dev-marta")
        self.other = paired(self.store, self.relay.url, "dev-pad")

    def test_a_profile_s_home_is_that_agent_and_the_main_home_keeps_the_phones(self):
        self.assertEqual(calls.caller(self.main / "profiles" / "ops"), ("ops", self.main))
        self.assertEqual(calls.caller(self.main), ("default", self.main))

    def test_the_phone_says_which_agents_may_call_it(self):
        self.assertEqual(calls.slash(self.store, ["dev-marta,someone-else", "ops,default,../etc"]), "redde-push calls 1")
        self.assertEqual([d["id"] for d in self.store.call_takers("ops")], ["dev-marta"])
        self.assertEqual(self.store.callers(), {"dev-marta": ["ops", "default"]}, "a name no profile can have is left out")
        self.assertEqual(self.store.call_takers("scout"), [])
        calls.slash(self.store, ["dev-pad", "ops"])
        self.assertEqual([d["id"] for d in self.store.call_takers("ops")], ["dev-marta", "dev-pad"])
        self.assertEqual(calls.slash(self.store, ["dev-marta", "none"]), "redde-push calls 1")
        self.assertEqual([d["id"] for d in self.store.call_takers("ops")], ["dev-pad"])
        self.store.remove("dev-pad")
        self.assertEqual(self.store.callers(), {}, "a phone that is gone takes no calls")
        self.assertEqual(calls.slash(self.store, ["dev-marta"]), "redde-push calls: this command is for the Redde app.")

    def test_a_call_goes_to_the_relay_as_a_call_sealed_like_any_note(self):
        calls.slash(self.store, ["dev-marta", "ops"])
        said = calls.ring(self.store, "ops", "Home", "The garage door is open.", session="20261026_1")
        self.assertEqual(said["phones"], 1, said)
        self.assertEqual(len(self.relay.pushes), 1, "only the phone that takes calls from Home")
        sent = self.relay.pushes[0]
        self.assertEqual((sent["path"], sent["bearer"]), ("/v1/devices/dev-marta/push", "Bearer send-dev-marta"))
        self.assertEqual((sent["kind"], sent["ttl"]), ("call", 60))
        self.assertNotIn("collapse", sent, "a call replaces nothing")
        self.assertNotIn("garage", json.dumps(sent))
        made = read(self.key, "dev-marta", sent["payload"])
        self.assertEqual((made["k"], made["p"], made["d"], made["b"], made["s"]),
                         ("call", "ops", "Home", "The garage door is open.", "20261026_1"))
        self.assertRegex(made["i"], r"^[0-9a-f]{16}$")

    def test_no_line_or_no_phone_rings_nothing(self):
        self.assertIn("hasn't let you call", calls.ring(self.store, "ops", "Home", "Hello.")["error"])
        calls.slash(self.store, ["dev-marta", "ops"])
        self.assertIn("\"line\" is missing", calls.ring(self.store, "ops", "Home", "   ")["error"])
        self.assertEqual(self.relay.pushes, [])

    def test_one_call_in_five_minutes_from_each_agent(self):
        calls.slash(self.store, ["dev-marta", "ops,default"])
        self.assertIn("ringing", calls.ring(self.store, "ops", "Home", "First.", now=1000))
        said = calls.ring(self.store, "ops", "Home", "Again.", now=1100)
        self.assertIn("about 3 minutes", said["error"])
        self.assertIn("ringing", calls.ring(self.store, "default", "Hermes", "Another agent may.", now=1100))
        self.assertIn("ringing", calls.ring(self.store, "ops", "Home", "Five minutes on.", now=1300))
        self.assertEqual(len(self.relay.pushes), 3)

    def test_after_a_call_the_person_answered_the_agent_may_call_again_in_a_minute(self):
        import time
        calls.slash(self.store, ["dev-marta", "ops"])
        now = time.time()
        self.assertIn("ringing", calls.ring(self.store, "ops", "Home", "First.", now=now))
        call = read(self.key, "dev-marta", self.relay.pushes[-1]["payload"])["i"]
        self.assertEqual(calls.slash(self.store, ["answered", "0123456789abcdef"]), "redde-push calls unknown")
        self.assertEqual(calls.slash(self.store, ["answered", call]), "redde-push calls answered")
        self.assertIn("about 1 minute", calls.ring(self.store, "ops", "Home", "Too soon.", now=now + 30)["error"])
        self.assertIn("ringing", calls.ring(self.store, "ops", "Home", "Hung up by mistake?", now=now + 61))
        self.assertIn("about 5 minutes", calls.ring(self.store, "ops", "Home", "Not answered yet.", now=now + 62)["error"],
                      "the call after it wasn't answered: five minutes again")

    def test_calls_kept_before_answers_were_counted_still_read(self):
        self.store._write("calls.json", {"made": [["ops", 1000.0]]})
        self.assertEqual(self.store.calls_made(now=1001), [("ops", 1000.0, "", False)])

    def test_twenty_calls_a_day_from_all_of_them(self):
        calls.slash(self.store, ["dev-marta", ",".join(f"bot{n}" for n in range(21))])
        for n in range(20):
            self.assertIn("ringing", calls.ring(self.store, f"bot{n}", "A bot", "Hi.", now=10_000 + n * 60))
        said = calls.ring(self.store, "bot20", "A bot", "One too many.", now=10_000 + 20 * 60)
        self.assertIn("call again in about", said["error"])
        self.assertIn("ringing", calls.ring(self.store, "bot20", "A bot", "A day after the first.", now=10_000 + 86_401))

    def test_a_phone_with_no_address_for_calls_is_said_so_and_the_call_doesn_t_count(self):
        calls.slash(self.store, ["dev-marta", "ops"])
        self.relay.status = 409
        self.assertIn("isn't ready for calls", calls.ring(self.store, "ops", "Home", "Hello.", now=1000)["error"])
        self.assertEqual(len(self.store.devices), 2, "the phone stays paired for notes")
        self.relay.status = 202
        self.assertIn("ringing", calls.ring(self.store, "ops", "Home", "Hello.", now=1001), "no wait after a call that never rang")

    def test_a_phone_the_relay_no_longer_has_is_forgotten(self):
        calls.slash(self.store, ["dev-marta", "ops"])
        self.relay.status = 410
        self.assertIn("didn't go through", calls.ring(self.store, "ops", "Home", "Hello.")["error"])
        self.assertEqual([d["id"] for d in self.store.devices], ["dev-pad"])

    def test_a_note_still_goes_as_a_note(self):
        core.push(self.store.devices[0], core.note("reply", "s1", body="Done."))
        sent = self.relay.pushes[0]
        self.assertNotIn("kind", sent)
        self.assertIn("collapse", sent)


class NoteTests(unittest.TestCase):
    """Asked to call, the turn is told how (Hermes 0.22 keeps a plugin's tools behind its search)."""

    def setUp(self):
        self.relay = Relay()
        self.addCleanup(self.relay.close)
        self.main = Path(tempfile.mkdtemp())
        self.store = core.Store(self.main)
        paired(self.store, self.relay.url, "dev-marta")
        self.store_in = lambda main: self.store

    def test_a_message_asking_to_be_called_carries_the_note_for_an_agent_that_may_call(self):
        home = self.main / "profiles" / "ops"
        self.assertIsNone(calls.turn_note(home, self.store_in, "Call me when the laundry is done"), "not allowed yet")
        calls.slash(self.store, ["dev-marta", "ops"])
        for asked in ("Call me when the laundry is done", "use your call_user tool", "At 7, ring me to wake me up",
                      [{"type": "text", "text": "give me a call in a minute"}]):
            self.assertEqual(calls.turn_note(home, self.store_in, asked), calls.NOTE, asked)
        for other in ("What do you call this?", "I'll call the plumber", "Turn off the lights", None):
            self.assertIsNone(calls.turn_note(home, self.store_in, other), other)
        self.assertIsNone(calls.turn_note(self.main, self.store_in, "Call me"), "the main agent isn't let")


class Context:
    """What Hermes hands a plugin to register with, keeping the tools."""

    def __init__(self):
        self.tools = {}

    def register_tool(self, name, toolset, schema, handler, check_fn=None, emoji=""):
        self.tools[name] = {"toolset": toolset, "schema": schema, "handler": handler, "check": check_fn}


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.relay = Relay()
        self.addCleanup(self.relay.close)
        self.main = Path(tempfile.mkdtemp())
        self.store = core.Store(self.main)
        self.key = paired(self.store, self.relay.url, "dev-marta")
        self.home = self.main / "profiles" / "ops"
        self.home.mkdir(parents=True)
        self.ctx = Context()
        calls.register(self.ctx, lambda: self.home, lambda main: self.store if main == self.main else core.Store(main))
        self.tool = self.ctx.tools["call_user"]

    def test_offered_once_calls_are_on_and_refused_at_ring_to_an_agent_not_let(self):
        """Hermes fixes a chat's tools as it starts: an agent let call after its chat opened must
        find the tool there already (Home, 2026-10-26). Who may call is held when it rings."""
        self.assertEqual(self.tool["toolset"], "redde_calls")
        self.assertEqual(self.tool["schema"]["parameters"]["required"], ["line"])
        self.assertFalse(self.tool["check"](), "calls off for everyone: no tool")
        calls.slash(self.store, ["dev-marta", "scout"])
        self.assertTrue(self.tool["check"](), "on for someone: listed for every agent")
        said = json.loads(self.tool["handler"]({"line": "Hello."}, session_id="s"))
        self.assertIn("hasn't let you call", said["error"])
        self.assertEqual(self.relay.pushes, [])
        calls.slash(self.store, ["dev-marta", "none"])
        self.assertFalse(self.tool["check"]())

    def test_the_tool_rings_as_the_profile_calling_from_its_conversation(self):
        calls.slash(self.store, ["dev-marta", "ops"])
        said = json.loads(self.tool["handler"]({"line": "Your laundry is done."}, session_id="20261026_9"))
        self.assertEqual(said["phones"], 1, said)
        made = read(self.key, "dev-marta", self.relay.pushes[0]["payload"])
        self.assertEqual((made["p"], made["d"], made["b"], made["s"]), ("ops", "ops", "Your laundry is done.", "20261026_9"),
                         "with no Bot Mode title, the bot goes by its profile's name; the phone has its own for it")


if __name__ == "__main__":
    unittest.main()

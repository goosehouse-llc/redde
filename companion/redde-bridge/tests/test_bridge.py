"""The bridge in front of a scripted agent (fake_agent.py), driven by small WebSocket clients.

    python3 -m unittest discover -s companion/redde-bridge/tests -v
"""
import asyncio
import base64
import json
import os
import socket
import struct
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import redde_bridge as rb  # noqa: E402

TOKEN = "test-token"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Client:
    """A phone: a WebSocket to the bridge, requests by id, everything else kept in order."""

    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.next_id = 0
        self.replies: dict = {}
        self.heard: list = []
        self.changed = asyncio.Event()
        self.task = asyncio.create_task(self._read())

    @classmethod
    async def open(cls, port, agent="fake", token=TOKEN):
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        key = base64.b64encode(os.urandom(16)).decode()
        writer.write((f"GET /acp/{agent} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {token}\r\n\r\n").encode())
        status = await reader.readline()
        while (await reader.readline()) not in (b"\r\n", b""):
            pass
        if b"101" not in status:
            writer.close()
            raise PermissionError(status.decode().strip())
        return cls(reader, writer)

    async def _read(self):
        try:
            while True:
                head = await self.reader.readexactly(2)
                length = head[1] & 0x7F
                if length == 126:
                    length = struct.unpack("!H", await self.reader.readexactly(2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", await self.reader.readexactly(8))[0]
                data = await self.reader.readexactly(length)
                if head[0] & 0x0F != 1:
                    continue
                message = json.loads(data)
                if "method" not in message and message.get("id") in self.replies:
                    self.replies[message["id"]].set_result(message)
                else:
                    self.heard.append(message)
                self.changed.set()
        except (asyncio.IncompleteReadError, ConnectionError):
            pass

    def send(self, message):
        data = json.dumps(message).encode()
        mask = os.urandom(4)
        n = len(data)
        head = struct.pack("!BB", 0x81, 0x80 | n) if n < 126 else struct.pack("!BBH", 0x81, 0x80 | 126, n) if n < 65536 else struct.pack("!BBQ", 0x81, 0x80 | 127, n)
        self.writer.write(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    async def call(self, method, params=None, timeout=10):
        self.next_id += 1
        rid = self.next_id
        future = asyncio.get_running_loop().create_future()
        self.replies[rid] = future
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
        return await asyncio.wait_for(future, timeout)

    async def wait_for(self, test, timeout=10):
        async def loop():
            while True:
                found = next((m for m in self.heard if test(m)), None)
                if found:
                    return found
                self.changed.clear()
                await self.changed.wait()
        return await asyncio.wait_for(loop(), timeout)

    def texts(self, sid):
        return "".join(m["params"]["update"]["content"]["text"] for m in self.heard
                       if m.get("method") == "session/update" and m["params"]["sessionId"] == sid
                       and m["params"]["update"].get("sessionUpdate") == "agent_message_chunk")

    def close(self):
        self.writer.close()


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.log = Path(self.dir.name) / "agent.log"
        self.port = free_port()
        agent = rb.AgentConfig(id="fake", name="Fake", command=[sys.executable, str(HERE / "fake_agent.py")],
                               cwd=self.dir.name, env={"FAKE_AGENT_LOG": str(self.log)})
        self.bridge = rb.Bridge(rb.Config(listen=f"127.0.0.1:{self.port}", token=TOKEN, agents=[agent]))
        self.server = asyncio.create_task(self.bridge.serve())
        for _ in range(50):
            try:
                _, w = await asyncio.open_connection("127.0.0.1", self.port)
                w.close()
                break
            except OSError:
                await asyncio.sleep(0.05)
        self.clients = []

    async def asyncTearDown(self):
        for c in self.clients:
            c.close()
        agent = self.bridge.agents["fake"]
        if agent.running:
            agent.proc.kill()
            await agent.proc.wait()
        self.server.cancel()
        self.dir.cleanup()

    async def client(self):
        c = await Client.open(self.port)
        self.clients.append(c)
        await c.call("initialize", {"protocolVersion": 1})
        return c

    def agent_calls(self, method):
        if not self.log.exists():
            return []
        return [json.loads(l)["params"] for l in self.log.read_text().splitlines() if json.loads(l)["method"] == method]

    async def test_wrong_token_is_refused(self):
        with self.assertRaises(PermissionError):
            await Client.open(self.port, token="nope")

    async def test_initialize_says_it_is_the_bridge(self):
        c = await Client.open(self.port)
        self.clients.append(c)
        reply = await c.call("initialize", {"protocolVersion": 1})
        self.assertEqual(reply["result"]["agentInfo"]["name"], "fake")
        self.assertEqual(reply["result"]["_meta"]["redde"]["agent"], "fake")
        # A second device doesn't start the agent again.
        await (await self.client()).call("initialize", {"protocolVersion": 1})
        self.assertEqual(len(self.agent_calls("initialize")), 1)

    async def test_a_turn_streams_and_ends(self):
        c = await self.client()
        sid = (await c.call("session/new", {"cwd": ""}))["result"]["sessionId"]
        self.assertEqual(self.agent_calls("session/new")[0]["cwd"], self.dir.name)   # filled in
        reply = await c.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "hi"}]})
        self.assertEqual(reply["result"]["stopReason"], "end_turn")
        self.assertEqual(c.texts(sid), "echo: hi")
        update = next(m for m in c.heard if m.get("method") == "session/update")
        self.assertEqual(update["params"]["_meta"]["redde"]["seq"], 1)
        await c.wait_for(lambda m: m.get("method") == "_redde/turn_ended")

    async def test_a_turn_goes_on_without_the_phone_and_is_caught_up(self):
        a = await self.client()
        sid = (await a.call("session/new", {}))["result"]["sessionId"]
        a.send({"jsonrpc": "2.0", "id": 99, "method": "session/prompt", "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "slow"}]}})
        await a.wait_for(lambda m: m.get("method") == "session/update")
        a.close()
        b = await self.client()
        joined = (await b.call("_redde/attach", {"sessionId": sid}))["result"]
        self.assertTrue(joined["running"])
        self.assertEqual(joined["prompt"][0]["text"], "slow")
        self.assertTrue(joined["updates"][0]["update"]["content"]["text"].startswith("one"))
        # A load while it runs is refused rather than mixed into the turn.
        busy = await b.call("session/load", {"sessionId": sid})
        self.assertEqual(busy["error"]["code"], rb.BUSY)
        ended = await b.wait_for(lambda m: m.get("method") == "_redde/turn_ended")
        self.assertEqual(ended["params"]["stopReason"], "end_turn")
        heard = "".join(u["update"]["content"]["text"] for u in joined["updates"]) + b.texts(sid)
        self.assertEqual(heard, "one two three")

    async def test_two_devices_hear_one_session_and_the_first_answer_wins(self):
        a, b = await self.client(), await self.client()
        sid = (await a.call("session/new", {}))["result"]["sessionId"]
        await b.call("_redde/attach", {"sessionId": sid})
        a.send({"jsonrpc": "2.0", "id": 50, "method": "session/prompt", "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "ask"}]}})
        ask_a = await a.wait_for(lambda m: m.get("method") == "session/request_permission")
        ask_b = await b.wait_for(lambda m: m.get("method") == "session/request_permission")
        self.assertEqual(ask_a["id"], ask_b["id"])
        b.send({"jsonrpc": "2.0", "id": ask_b["id"], "result": {"outcome": {"outcome": "selected", "optionId": "deny"}}})
        await a.wait_for(lambda m: m.get("method") == "_redde/request_resolved")
        a.send({"jsonrpc": "2.0", "id": ask_a["id"], "result": {"outcome": {"outcome": "selected", "optionId": "allow_once"}}})   # too late
        await a.wait_for(lambda m: m.get("method") == "_redde/turn_ended")
        self.assertEqual(a.texts(sid), "picked deny")
        self.assertEqual(b.texts(sid), "picked deny")

    async def test_a_waiting_question_is_given_to_a_device_that_attaches(self):
        a = await self.client()
        sid = (await a.call("session/new", {}))["result"]["sessionId"]
        a.send({"jsonrpc": "2.0", "id": 51, "method": "session/prompt", "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "ask"}]}})
        await a.wait_for(lambda m: m.get("method") == "session/request_permission")
        a.close()
        b = await self.client()
        joined = (await b.call("_redde/attach", {"sessionId": sid}))["result"]
        self.assertEqual(len(joined["requests"]), 1)
        ask = joined["requests"][0]
        b.send({"jsonrpc": "2.0", "id": ask["id"], "result": {"outcome": {"outcome": "selected", "optionId": "allow_once"}}})
        await b.wait_for(lambda m: m.get("method") == "_redde/turn_ended")
        self.assertEqual(b.texts(sid), "picked allow_once")

    async def test_history_goes_to_the_asking_device_only(self):
        a, b = await self.client(), await self.client()
        sid = (await a.call("session/new", {}))["result"]["sessionId"]
        await a.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "hi"}]})
        await b.call("_redde/attach", {"sessionId": sid})
        before = len(b.heard)
        a.heard.clear()
        await a.call("session/load", {"sessionId": sid})
        kinds = [m["params"]["update"]["sessionUpdate"] for m in a.heard if m.get("method") == "session/update"]
        self.assertEqual(kinds, ["user_message_chunk", "agent_message_chunk"])
        self.assertEqual(len(b.heard), before)

    async def test_after_a_restart_a_session_is_resumed_before_its_prompt(self):
        a = await self.client()
        sid = (await a.call("session/new", {}))["result"]["sessionId"]
        agent = self.bridge.agents["fake"]
        agent.loaded.discard(sid)   # as after the agent started again
        await a.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "again"}]})
        self.assertEqual([p["sessionId"] for p in self.agent_calls("session/resume")], [sid])

    async def test_paired_devices_hear_of_approvals_and_replies(self):
        pusher = rb.redde_push.Pusher(Path(self.dir.name) / "push.json")
        sent = []
        pusher.sender = lambda device, made: sent.append(made)
        pusher._save([{"id": "dev", "send": "s", "name": "Phone", "key": rb.redde_push.b64u(os.urandom(32)),
                       "relay": "https://relay.invalid"}])
        self.bridge.agents["fake"].pusher = pusher
        c = await self.client()
        offer = (await c.call("_redde/push", {"command": "offer"}))["result"]["output"].split()
        self.assertEqual(offer[:2], ["redde-push", "offer"])
        sid = (await c.call("session/new", {}))["result"]["sessionId"]
        c.send({"jsonrpc": "2.0", "id": 70, "method": "session/prompt", "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "ask first"}]}})
        ask = await c.wait_for(lambda m: m.get("method") == "session/request_permission")
        c.send({"jsonrpc": "2.0", "id": ask["id"], "result": {"outcome": {"outcome": "selected", "optionId": "allow_once"}}})
        await c.wait_for(lambda m: m.get("method") == "_redde/turn_ended")
        for _ in range(100):
            if len(sent) >= 2:
                break
            await asyncio.sleep(0.02)
        self.assertEqual([m["k"] for m in sent], ["approval", "reply"])
        self.assertEqual(sent[0]["b"], "terminal: rm -rf x")
        self.assertEqual(sent[0]["t"], "ask first")   # the agent named it nothing: the prompt's words
        self.assertEqual(sent[0]["d"], "Fake")
        self.assertEqual((sent[1]["s"], sent[1]["b"]), (sid, "picked allow_once"))

    async def test_agents_are_listed_over_http(self):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
        writer.write(f"GET /agents HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {TOKEN}\r\n\r\n".encode())
        body = (await reader.read()).split(b"\r\n\r\n", 1)[1]
        writer.close()
        self.assertEqual(json.loads(body)["agents"][0]["id"], "fake")


if __name__ == "__main__":
    unittest.main()


class SetupLinkTests(unittest.TestCase):
    """The link `--print-setup` prints, in the form the app's SetupCode reads."""

    def test_link_carries_the_bridge_its_token_and_agent(self):
        from urllib.parse import parse_qsl, urlsplit
        agent = rb.AgentConfig(id="claude", name="Claude Code", command=["true"])
        config = rb.Config(listen="0.0.0.0:8767", token="t0k-_x", agents=[agent])
        link = rb.setup_link(config, agent)
        parts = urlsplit(link)
        self.assertEqual((parts.scheme, parts.netloc, parts.path, parts.query), ("https", "redde.goosehouse.org", "/connect", ""))
        fields = dict(parse_qsl(parts.fragment))
        self.assertTrue(fields["bridge"].startswith("ws://") and fields["bridge"].endswith(".local:8767"))
        self.assertEqual((fields["bridge-token"], fields["agent"], fields["use"], fields["v"]), ("t0k-_x", "claude", "acp", "1"))

    def test_a_named_host_and_tls_are_kept(self):
        config = rb.Config(listen="100.64.0.5:8767", token="t", agents=[], tls_cert="c.pem", tls_key="k.pem")
        self.assertEqual(rb.setup_address(config), "wss://100.64.0.5:8767")

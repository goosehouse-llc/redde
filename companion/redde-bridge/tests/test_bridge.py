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

    async def test_an_agent_that_keeps_no_names_is_named_by_the_bridge(self):
        # Codex lists its chats but keeps no names (no `sessionCapabilities.title`): the bridge does.
        c = await self.client()
        caps = (await c.call("initialize", {"protocolVersion": 1}))["result"]["agentCapabilities"]
        self.assertIn("title", caps["sessionCapabilities"])
        sid = (await c.call("session/new", {}))["result"]["sessionId"]
        self.assertEqual((await c.call("session/set_title", {"sessionId": sid, "title": "Login page"}))["result"], {})
        rows = (await c.call("session/list"))["result"]["sessions"]
        self.assertEqual({r["sessionId"]: r.get("title") for r in rows}[sid], "Login page")
        self.assertNotIn("session/set_title", self.log.read_text(), "the agent isn't asked")

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

    async def test_a_form_is_asked_of_every_device_and_answered_once(self):
        a, b = await self.client(), await self.client()
        sid = (await a.call("session/new", {}))["result"]["sessionId"]
        init = self.agent_calls("initialize")
        self.assertEqual(init[0]["clientCapabilities"]["elicitation"], {"form": {}})
        await b.call("_redde/attach", {"sessionId": sid})
        a.send({"jsonrpc": "2.0", "id": 52, "method": "session/prompt", "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "question"}]}})
        ask_a = await a.wait_for(lambda m: m.get("method") == "elicitation/create")
        ask_b = await b.wait_for(lambda m: m.get("method") == "elicitation/create")
        self.assertEqual(ask_a["id"], ask_b["id"])
        a.send({"jsonrpc": "2.0", "id": ask_a["id"], "result": {"action": "accept", "content": {"question_0": "Blue"}}})
        await b.wait_for(lambda m: m.get("method") == "_redde/request_resolved")
        await a.wait_for(lambda m: m.get("method") == "_redde/turn_ended")
        self.assertEqual(a.texts(sid), 'accept {"question_0": "Blue"}')

    async def test_a_new_device_is_told_the_agents_commands(self):
        a = await self.client()
        sid = (await a.call("session/new", {}))["result"]["sessionId"]
        await a.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "commands"}]})
        b = await self.client()
        init = (await b.call("initialize", {"protocolVersion": 1}))["result"]
        self.assertEqual([c["name"] for c in init["_meta"]["redde"]["commands"]], ["compact", "review"])

    async def test_a_fork_is_followed_as_the_new_session(self):
        a = await self.client()
        sid = (await a.call("session/new", {}))["result"]["sessionId"]
        fork = (await a.call("session/fork", {"sessionId": sid, "cwd": "/elsewhere"}))["result"]["sessionId"]
        self.assertNotEqual(fork, sid)
        agent = self.bridge.agents["fake"]
        self.assertIn(fork, agent.loaded)   # open in the agent already: no resume before its prompt
        self.assertEqual(agent.sessions[fork].cwd, "/elsewhere")
        await a.call("session/prompt", {"sessionId": fork, "prompt": [{"type": "text", "text": "hi"}]})
        self.assertEqual(self.agent_calls("session/resume"), [])
        self.assertEqual(a.texts(fork), "echo: hi")

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

    async def test_a_bridge_run_by_hand_says_so_and_wont_update_itself(self):
        c = await Client.open(self.port)
        self.clients.append(c)
        redde = (await c.call("initialize", {"protocolVersion": 1}))["result"]["_meta"]["redde"]
        self.assertEqual(redde["bridge"], rb.VERSION)
        self.assertFalse(redde["updatable"])
        self.assertIsNone(redde["service"])
        refused = (await c.call("_redde/update"))["error"]
        self.assertIn("installer", refused["message"])
        self.assertIn("install.sh", refused["data"]["command"])

    async def test_an_installed_bridge_updates_between_turns_and_restarts(self):
        source, home = Path(self.dir.name) / "source", Path(self.dir.name) / "home"
        make_bridge_files(source, "99.0.0")
        make_bridge_files(home, rb.VERSION)
        restarts = []
        self.bridge.service, self.bridge.restart = "launchd", lambda: restarts.append(1)
        saved = rb.UPDATE_BASE, rb.INSTALL_DIR
        rb.UPDATE_BASE, rb.INSTALL_DIR = source.as_uri(), home
        try:
            c = await self.client()
            sid = (await c.call("session/new", {}))["result"]["sessionId"]
            c.send({"jsonrpc": "2.0", "id": 98, "method": "session/prompt", "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "slow"}]}})
            await c.wait_for(lambda m: m.get("method") == "session/update")
            busy = await c.call("_redde/update")
            self.assertEqual(busy["error"]["code"], rb.BUSY)
            await c.wait_for(lambda m: m.get("method") == "_redde/turn_ended")
            done = (await c.call("_redde/update", timeout=60))["result"]
            self.assertEqual((done["updated"], done["from"], done["version"]), (True, rb.VERSION, "99.0.0"))
            self.assertIn('VERSION = "99.0.0"', (home / "redde_bridge.py").read_text())
            await asyncio.sleep(1.3)
            self.assertEqual(restarts, [1])
        finally:
            rb.UPDATE_BASE, rb.INSTALL_DIR = saved


class ChatListTests(unittest.IsolatedAsyncioTestCase):
    """An agent that keeps no list of its chats (Gemini CLI): the bridge keeps it."""

    async def asyncSetUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.port = free_port()
        self.state = Path(self.dir.name) / "state"
        agent = rb.AgentConfig(id="gem", name="Gem", command=[sys.executable, str(HERE / "fake_agent.py")],
                               cwd=self.dir.name, env={"FAKE_AGENT_LISTS": "0"})
        self.bridge = rb.Bridge(rb.Config(listen=f"127.0.0.1:{self.port}", token=TOKEN, agents=[agent], state_dir=self.state))
        self.server = asyncio.create_task(self.bridge.serve())
        for _ in range(50):
            try:
                _, w = await asyncio.open_connection("127.0.0.1", self.port)
                w.close()
                break
            except OSError:
                await asyncio.sleep(0.05)
        self.c = await Client.open(self.port, agent="gem")

    async def asyncTearDown(self):
        self.c.close()
        agent = self.bridge.agents["gem"]
        if agent.running:
            agent.proc.kill()
            await agent.proc.wait()
        self.server.cancel()
        self.dir.cleanup()

    async def test_chats_are_listed_named_and_remembered(self):
        caps = (await self.c.call("initialize", {"protocolVersion": 1}))["result"]["agentCapabilities"]
        self.assertIn("list", caps["sessionCapabilities"])
        self.assertIn("title", caps["sessionCapabilities"])
        first = (await self.c.call("session/new", {}))["result"]["sessionId"]
        second = (await self.c.call("session/new", {}))["result"]["sessionId"]
        await asyncio.sleep(0.01)
        await self.c.call("session/prompt", {"sessionId": first, "prompt": [{"type": "text", "text": "fix the login page"}]})
        rows = (await self.c.call("session/list"))["result"]["sessions"]
        self.assertEqual([r["sessionId"] for r in rows], [first, second])   # the one used last first
        self.assertEqual(rows[0]["title"], "fix the login page")
        self.assertEqual(rows[0]["cwd"], self.dir.name)
        # Named here, and kept for the next start of the bridge.
        self.assertEqual((await self.c.call("session/set_title", {"sessionId": second, "title": "Notes"}))["result"], {})
        again = rb.ChatIndex(self.state / "chats-gem.json").page()["sessions"]
        self.assertEqual({r["sessionId"]: r.get("title") for r in again}, {first: "fix the login page", second: "Notes"})


def make_bridge_files(folder: Path, version: str, change=None):
    """The bridge's files, as `version`, in `folder`; `change` edits redde_bridge.py's text."""
    folder.mkdir(parents=True, exist_ok=True)
    for name in rb.FILES:
        text = (HERE.parent / name).read_text()
        if name == "redde_bridge.py":
            text = text.replace(f'VERSION = "{rb.VERSION}"', f'VERSION = "{version}"', 1)
            text = change(text) if change else text
        (folder / name).write_text(text)


class UpdateTests(unittest.TestCase):
    """`update_files`: what `_redde/update` puts in place, from a folder standing in for GitHub."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.source, self.home = Path(self.dir.name) / "source", Path(self.dir.name) / "home"
        make_bridge_files(self.home, rb.VERSION)

    def tearDown(self):
        self.dir.cleanup()

    def installed(self):
        return (self.home / "redde_bridge.py").read_text()

    def test_a_newer_bridge_goes_in_and_the_old_one_is_kept(self):
        make_bridge_files(self.source, "99.1.0")
        self.assertEqual(rb.update_files(self.source.as_uri(), self.home), "99.1.0")
        self.assertIn('VERSION = "99.1.0"', self.installed())
        self.assertIn(f'VERSION = "{rb.VERSION}"', (self.home / "previous" / "redde_bridge.py").read_text())
        self.assertFalse((self.home / ".update").exists())

    def test_the_same_or_an_older_bridge_changes_nothing(self):
        make_bridge_files(self.source, rb.VERSION)
        self.assertIsNone(rb.update_files(self.source.as_uri(), self.home))
        make_bridge_files(self.source, "0.1.0")
        self.assertIsNone(rb.update_files(self.source.as_uri(), self.home))
        self.assertFalse((self.home / "previous").exists())

    def test_a_bridge_that_doesnt_run_here_stays_out(self):
        make_bridge_files(self.source, "99.2.0", change=lambda t: t + "\nthis isn't python\n")
        with self.assertRaises(rb.UpdateError):
            rb.update_files(self.source.as_uri(), self.home)
        self.assertIn(f'VERSION = "{rb.VERSION}"', self.installed())

    def test_a_missing_file_stops_the_update(self):
        make_bridge_files(self.source, "99.3.0")
        (self.source / "redde_qr.py").unlink()
        with self.assertRaises(rb.UpdateError):
            rb.update_files(self.source.as_uri(), self.home)
        self.assertIn(f'VERSION = "{rb.VERSION}"', self.installed())

    def test_a_file_list_reaching_outside_the_folder_is_refused(self):
        make_bridge_files(self.source, "99.4.0", change=lambda t: t.replace(
            'FILES = ("redde_bridge.py",', 'FILES = ("../evil.py", "redde_bridge.py",', 1))
        with self.assertRaises(rb.UpdateError):
            rb.update_files(self.source.as_uri(), self.home)
        self.assertFalse((Path(self.dir.name) / "evil.py").exists())

    def test_something_that_isnt_the_bridge_is_refused(self):
        self.source.mkdir()
        (self.source / "redde_bridge.py").write_text("<html>Not found</html>")
        with self.assertRaises(rb.UpdateError):
            rb.update_files(self.source.as_uri(), self.home)


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
        # Named for the agent: Claude Code and Codex on one bridge are two servers with their own names.
        self.assertEqual(fields["name"], "Claude Code")
        self.assertNotIn("Claude", dict(parse_qsl(urlsplit(rb.setup_link(config, None)).fragment))["name"])

    def test_a_named_host_and_tls_are_kept(self):
        config = rb.Config(listen="100.64.0.5:8767", token="t", agents=[], tls_cert="c.pem", tls_key="k.pem")
        self.assertEqual(rb.setup_address(config), "wss://100.64.0.5:8767")

    def test_a_tailscale_name_can_stand_for_the_machine(self):
        config = rb.Config(listen="0.0.0.0:8767", token="t", agents=[])
        self.assertEqual(rb.setup_address(config, "mac.tail1234.ts.net."), "ws://mac.tail1234.ts.net:8767")
        self.assertIn("bridge=ws://mac.tail1234.ts.net:8767", rb.setup_link(config, None, "mac.tail1234.ts.net"))

    def test_a_host_in_the_config_is_the_links_address(self):
        config = rb.Config(listen="0.0.0.0:8767", token="t", agents=[], host="mac.tail1234.ts.net")
        self.assertEqual(rb.setup_address(config), "ws://mac.tail1234.ts.net:8767")
        # --host still wins over it.
        self.assertEqual(rb.setup_address(config, "other.example"), "ws://other.example:8767")


class ConfigTests(unittest.TestCase):
    """The config is read the same with or without `tomllib` (Python 3.9 on a Mac has none)."""

    SAMPLE = '''# Redde bridge
listen = "0.0.0.0:8765"
token = "a\\"b"   # a comment
port_like = 8_765
ratio = 0.5
on = true

[agents.claude]
name = 'Claude Code'
command = [
  "npx", "-y",   # split over lines
  "@agentclientprotocol/claude-agent-acp",
]
cwd = "~/Projects"
env = { SOME_SETTING = "value", "quoted key" = "x" }

[agents."my.agent"]
name = "Mine"
command = ["mine"]
'''

    def test_the_fallback_reads_what_tomllib_reads(self):
        read = rb._TomlReader(self.SAMPLE).read()
        self.assertEqual(read["token"], 'a"b')
        self.assertEqual((read["port_like"], read["ratio"], read["on"]), (8765, 0.5, True))
        self.assertEqual(read["agents"]["claude"]["command"], ["npx", "-y", "@agentclientprotocol/claude-agent-acp"])
        self.assertEqual(read["agents"]["claude"]["env"], {"SOME_SETTING": "value", "quoted key": "x"})
        self.assertEqual(read["agents"]["my.agent"]["name"], "Mine")
        try:
            import tomllib
        except ImportError:
            return
        self.assertEqual(read, tomllib.loads(self.SAMPLE))
        first = rb.first_config()
        self.assertEqual(rb._TomlReader(first).read(), tomllib.loads(first))

    def test_a_mistake_names_its_line(self):
        with self.assertRaises(SystemExit) as caught:
            rb._TomlReader('listen = "x"\ntoken "y"\n').read()
        self.assertIn("line 2", str(caught.exception))

    def test_the_host_goes_before_the_tables(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "config.toml"
            path.write_text('listen = "0.0.0.0:8765"\ntoken = "t"\n\n[agents.a]\ncommand = ["a"]\n')
            rb.remember_host(path, "mac.tail1234.ts.net")
            config = rb.load_config(path)
            self.assertEqual(config.host, "mac.tail1234.ts.net")
            self.assertEqual(config.agents[0].command, ["a"])


class ServiceTests(unittest.TestCase):
    """What `--install` writes for the service."""

    def test_the_launch_agent_runs_the_bridge_with_this_shells_path(self):
        plist = rb.launch_agent(["/usr/bin/python3", "/x/redde_bridge.py", "--config", "/c & d/config.toml"], Path("/l.log"))
        import plistlib
        data = plistlib.loads(plist.encode())
        self.assertEqual(data["ProgramArguments"][-1], "/c & d/config.toml")
        self.assertTrue(data["KeepAlive"] and data["RunAtLoad"])
        self.assertIn("/opt/homebrew/bin", data["EnvironmentVariables"]["PATH"].split(":"))

    def test_the_systemd_unit_quotes_its_command(self):
        unit = rb.systemd_unit(["/usr/bin/python3", "/x y/redde_bridge.py"])
        self.assertIn('ExecStart="/usr/bin/python3" "/x y/redde_bridge.py"', unit)
        self.assertIn("Restart=always", unit)


class QRTests(unittest.TestCase):
    """The setup link's QR code (`redde_qr`). Decoding is checked by hand with a phone and Apple's
    Vision; these keep its structure right."""

    def test_the_smallest_version_that_holds_the_text(self):
        import redde_qr
        self.assertEqual(len(redde_qr.matrix("x" * 14)), 21)   # version 1-M holds 14 bytes
        self.assertEqual(len(redde_qr.matrix("x" * 15)), 25)
        link = rb.setup_link(rb.Config(listen="0.0.0.0:8765", token="t" * 43, agents=[], host="studio.tail1234.ts.net"), None)
        self.assertLessEqual(len(redde_qr.matrix(link)), 57)   # version 10 at most: small enough to scan off a screen

    def test_finders_timing_and_format_are_in_place(self):
        import redde_qr
        grid = redde_qr.matrix("https://redde.goosehouse.org/connect")
        n = len(grid)
        for x0, y0 in ((0, 0), (n - 7, 0), (0, n - 7)):
            ring = [grid[y0][x0 + i] for i in range(7)]
            self.assertEqual(ring, [True] * 7)
            self.assertFalse(grid[y0 + 1][x0 + 1])
            self.assertTrue(grid[y0 + 3][x0 + 3])
        self.assertEqual([grid[6][x] for x in range(8, n - 8)], [x % 2 == 0 for x in range(8, n - 8)])
        self.assertTrue(grid[n - 8][8])   # the dark module
        # Format bits: level M, a mask, and a valid BCH code, read both copies.
        first = [grid[8][x] for x in (0, 1, 2, 3, 4, 5, 7)] + [grid[8][8], grid[7][8]] + [grid[y][8] for y in (5, 4, 3, 2, 1, 0)]
        bits = sum(1 << (14 - i) for i, dark in enumerate(first) if dark) ^ 0x5412
        self.assertEqual(bits >> 13, 0)   # M
        rem = bits >> 10
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        self.assertEqual(bits & 0x3FF, rem & 0x3FF)

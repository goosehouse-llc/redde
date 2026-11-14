"""Agents from the ACP registry (redde_registry.py): read, added to a running bridge, removed.

    python3 -m unittest discover -s companion/redde-bridge/tests -v
"""
import asyncio
import hashlib
import io
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import redde_bridge as rb  # noqa: E402
import redde_registry as rr  # noqa: E402
from test_bridge import TOKEN, Client, free_port  # noqa: E402


def a_zip() -> bytes:
    """An agent download: a program that runs the scripted agent."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as z:
        info = zipfile.ZipInfo("dist/fake-agent")
        info.external_attr = 0o755 << 16
        z.writestr(info, f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_agent.py"}" "$@"\n')
    return buffer.getvalue()


ZIP = a_zip()


def registry(here: str) -> dict:
    return {"version": "1.0.0", "agents": [
        {"id": "pi-acp", "name": "pi ACP", "version": "0.0.34", "description": "ACP adapter for pi coding agent",
         "license": "MIT", "distribution": {"npx": {"package": "pi-acp@0.0.34"}}},
        {"id": "boxed-acp", "name": "Boxed", "version": "2.0.0", "description": "A downloaded agent",
         "distribution": {"binary": {here: {"archive": "https://downloads.test/boxed.zip", "cmd": "./dist/fake-agent",
                                            "args": ["acp"], "sha256": hashlib.sha256(ZIP).hexdigest()}}}},
        {"id": "faraway", "name": "Far Away", "version": "1.0",
         "distribution": {"binary": {"plan9-mips": {"archive": "https://downloads.test/x.zip", "cmd": "./x"}}}},
    ]}


class FakeReply(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def fake_open(body: bytes):
    def opener(url, timeout):
        return FakeReply(body)
    return opener


class ParseTests(unittest.TestCase):
    def test_each_agent_says_how_this_computer_runs_it(self):
        with mock.patch.object(rr.shutil, "which", lambda name: "/usr/bin/" + name):
            entries = {e.id: e for e in rr.parse(registry("darwin-aarch64"), here="darwin-aarch64")}
        self.assertEqual(entries["pi-acp"].command, ["npx", "-y", "pi-acp@0.0.34"])
        self.assertEqual(entries["pi-acp"].name, "Pi")
        self.assertEqual(entries["pi-acp"].bridge_id, "pi")
        self.assertEqual(entries["boxed-acp"].kind, "binary")
        self.assertEqual(entries["faraway"].kind, "", "nothing for this computer")

    def test_openclaw_is_offered_beside_the_registry(self):
        entries = {e.id: e for e in rr.parse(registry("darwin-aarch64"), here="darwin-aarch64")}
        claw = entries["openclaw"]
        self.assertEqual((claw.kind, claw.command, claw.bridge_id), ("local", ["openclaw", "acp"], "openclaw"))
        self.assertEqual(claw.needs[0], "openclaw")
        # Once the registry has it, the registry's is the one.
        listed = registry("darwin-aarch64")
        listed["agents"].append({"id": "openclaw", "name": "OpenClaw", "version": "9.9",
                                 "distribution": {"npx": {"package": "openclaw@9.9", "args": ["acp"]}}})
        with mock.patch.object(rr.shutil, "which", lambda name: "/usr/bin/" + name):
            ours = [e for e in rr.parse(listed, here="darwin-aarch64") if e.id == "openclaw"]
        self.assertEqual([e.kind for e in ours], ["npx"])

    def test_without_npx_an_npm_agent_cant_run(self):
        with mock.patch.object(rr.shutil, "which", lambda name: None):
            entries = {e.id: e for e in rr.parse(registry("darwin-aarch64"), here="darwin-aarch64")}
        self.assertEqual(entries["pi-acp"].kind, "")

    def test_agents_added_by_hand_count_as_installed(self):
        agents = [rb.AgentConfig(id="claude", name="Claude Code", command=["npx", "-y", "@agentclientprotocol/claude-agent-acp@0.106.0"]),
                  rb.AgentConfig(id="antigravity", name="Antigravity", command=["/x/agy", "acp"])]
        found = rr.installed_ids(agents)
        self.assertIn("claude-acp", found)
        self.assertIn("antigravity-acp", found)
        self.assertNotIn("pi-acp", found)


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.entry = rr.parse(registry(rr.platform_key()))[1]

    def test_a_download_is_checked_and_unpacked(self):
        with mock.patch.object(rr, "_open", fake_open(ZIP)):
            command = rr.download(self.entry, self.dir)
        self.assertEqual(command[1:], ["acp"])
        self.assertTrue(Path(command[0]).is_file())
        self.assertTrue(Path(command[0]).stat().st_mode & 0o100, "runnable")

    def test_a_download_that_doesnt_match_the_checksum_is_refused(self):
        with mock.patch.object(rr, "_open", fake_open(ZIP + b"tampered")):
            with self.assertRaises(rr.RegistryError):
                rr.download(self.entry, self.dir)
        self.assertFalse(any(self.dir.rglob("fake-agent")))

    def test_nothing_is_unpacked_outside_its_folder(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as z:
            z.writestr("../../escaped", "x")
        archive = self.dir / "bad.zip"
        archive.write_bytes(buffer.getvalue())
        with self.assertRaises(rr.RegistryError):
            rr.unpack(archive, self.dir / "in")
        self.assertFalse((self.dir.parent / "escaped").exists())


class ConfigTests(unittest.TestCase):
    def test_an_added_agent_is_read_back_and_removed_cleanly(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "config.toml"
            original = 'listen = "0.0.0.0:8767"\ntoken = "t"\n\n[agents.claude]\nname = "Claude Code"\ncommand = ["claude"]\ncwd = "~"\n'
            path.write_text(original)
            rr.add_to_config(path, "pi", rr.table("pi", "Pi", ["npx", "-y", "pi-acp@0.0.34"], "~/Projects", {"A": "b"},
                                                  "Added from the ACP registry (pi-acp 0.0.34)."))
            config = rb.load_config(path)
            pi = next(a for a in config.agents if a.id == "pi")
            self.assertEqual(pi.command, ["npx", "-y", "pi-acp@0.0.34"])
            self.assertEqual(pi.env, {"A": "b"})
            with self.assertRaises(rr.RegistryError):
                rr.add_to_config(path, "pi", "")
            self.assertTrue(rr.remove_from_config(path, "pi"))
            self.assertEqual(path.read_text().rstrip("\n"), original.rstrip("\n"))
            self.assertFalse(rr.remove_from_config(path, "pi"))


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    """Added from the phone, the agent is served at once; removed, it's gone."""

    async def asyncSetUp(self):
        self.dir = tempfile.TemporaryDirectory()
        folder = Path(self.dir.name)
        self.path = folder / "config.toml"
        self.path.write_text(f'listen = "127.0.0.1:0"\ntoken = "{TOKEN}"\n\n[agents.fake]\nname = "Fake"\n'
                             f'command = ["{sys.executable}", "{HERE / "fake_agent.py"}"]\ncwd = "{folder}"\n')
        config = rb.load_config(self.path)
        self.port = free_port()
        config.listen = f"127.0.0.1:{self.port}"
        self.bridge = rb.Bridge(config)
        self.patches = [mock.patch.object(rr, "fetch", lambda *a, **k: rr.parse(registry(rr.platform_key()))),
                        mock.patch.object(rr, "_open", fake_open(ZIP))]
        for p in self.patches:
            p.start()
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
        for agent in list(self.bridge.agents.values()):
            if agent.running:
                agent.proc.kill()
                await agent.proc.wait()
        self.server.cancel()
        for p in self.patches:
            p.stop()
        self.dir.cleanup()

    async def client(self, agent="fake"):
        c = await Client.open(self.port, agent=agent)
        self.clients.append(c)
        return c

    async def test_an_agent_added_from_the_phone_is_served_at_once(self):
        c = await self.client()
        hello = await c.call("initialize", {"protocolVersion": 1})
        self.assertTrue(hello["result"]["_meta"]["redde"]["manages"])
        listed = (await c.call("_redde/registry"))["result"]
        boxed = next(a for a in listed["agents"] if a["id"] == "boxed-acp")
        self.assertFalse(boxed["installed"])
        self.assertIn("downloads.test", boxed["runs"])

        added = (await c.call("_redde/add_agent", {"id": "boxed-acp"}))["result"]
        self.assertEqual(added["agent"]["id"], "boxed")
        self.assertIn("[agents.boxed]", self.path.read_text())
        listed = (await c.call("_redde/registry"))["result"]
        self.assertTrue(next(a for a in listed["agents"] if a["id"] == "boxed-acp")["installed"])
        again = await c.call("_redde/add_agent", {"id": "boxed-acp"})
        self.assertIn("already", again["error"]["message"])

        # The new agent answers on its own socket, without a restart.
        boxed_client = await self.client("boxed")
        reply = await boxed_client.call("initialize", {"protocolVersion": 1})
        self.assertEqual(reply["result"]["_meta"]["redde"]["agent"], "boxed")
        boxed_client.close()
        self.clients.remove(boxed_client)

        # Not the one this socket is on; then another.
        refused = await c.call("_redde/remove_agent", {"id": "fake"})
        self.assertIn("another agent", refused["error"]["message"])
        removed = await c.call("_redde/remove_agent", {"id": "boxed"})
        self.assertEqual(removed["result"], {"removed": "boxed"})
        self.assertNotIn("boxed", self.bridge.agents)
        self.assertNotIn("[agents.boxed]", self.path.read_text())
        self.assertEqual([a.id for a in rb.load_config(self.path).agents], ["fake"])

    async def test_openclaw_is_added_where_it_is_installed(self):
        c = await self.client()
        await c.call("initialize", {"protocolVersion": 1})
        real = shutil.which
        with mock.patch.object(rb.shutil, "which", lambda name: "/opt/claw/bin/openclaw" if name == "openclaw" else real(name)):
            added = (await c.call("_redde/add_agent", {"id": "openclaw"}))["result"]
        self.assertEqual(added["agent"]["id"], "openclaw")
        text = self.path.read_text()
        self.assertIn('command = ["/opt/claw/bin/openclaw", "acp"]', text)
        self.assertIn("not in the ACP registry", text)
        await c.call("_redde/remove_agent", {"id": "openclaw"})
        self.assertNotIn("openclaw", self.path.read_text())

    async def test_an_agent_the_registry_doesnt_have_isnt_added(self):
        c = await self.client()
        await c.call("initialize", {"protocolVersion": 1})
        reply = await c.call("_redde/add_agent", {"id": "nope"})
        self.assertIn("no agent", reply["error"]["message"])
        reply = await c.call("_redde/add_agent", {"id": "faraway"})
        self.assertIn("nothing for this computer", reply["error"]["message"])


if __name__ == "__main__":
    unittest.main()

"""Codex's plan limits, read through a stand-in `codex app-server` (fake_codex.py).

    python3 -m unittest discover -s companion/redde-bridge/tests -v
"""
from __future__ import annotations

import asyncio
import sys
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import redde_codex as rc  # noqa: E402

FAKE = [sys.executable, str(HERE / "fake_codex.py")]


class ReadTests(unittest.TestCase):
    def test_the_limits_are_read_and_the_account_stays_home(self):
        result = rc.read_limits(FAKE)
        self.assertEqual(result["rateLimits"]["primary"]["windowDurationMins"], 43200)
        sent = rc.clean(result, at=1794550000)
        self.assertEqual(sent["at"], 1794550000)
        self.assertEqual(sent["rateLimitsByLimitId"]["codex"]["primary"]["usedPercent"], 1)
        self.assertTrue(sent["ordinaryUsageAllowed"])
        for private in ("accountId", "rateLimitUpsell", "rateLimitResetCredits"):
            self.assertNotIn(private, sent)

    def test_an_error_from_codex_is_raised(self):
        with self.assertRaisesRegex(rc.CodexError, "not signed in"):
            rc.read_limits(FAKE, env={"FAKE_CODEX": "fail"})

    def test_a_codex_that_hangs_is_stopped(self):
        started = time.monotonic()
        with self.assertRaises(rc.CodexError):
            rc.read_limits(FAKE, env={"FAKE_CODEX": "hang"}, timeout=1)
        self.assertLess(time.monotonic() - started, 10)

    def test_a_missing_codex_is_an_error_not_a_crash(self):
        with self.assertRaises(rc.CodexError):
            rc.read_limits(["/nonexistent/codex", "app-server"])

    def test_only_codex_agents_get_limits(self):
        self.assertTrue(rc.is_codex(["npx", "-y", "@agentclientprotocol/codex-acp@2.6.0"]))
        self.assertTrue(rc.is_codex(["codex-acp"]))
        self.assertFalse(rc.is_codex(["npx", "-y", "@agentclientprotocol/claude-agent-acp"]))
        self.assertIsNone(rc.Limits.for_agent(["hermes", "acp"], None, None))

    def test_codex_path_is_the_one_codex_acp_uses(self):
        self.assertEqual(rc.app_server_command({"CODEX_PATH": "/opt/codex"}), ["/opt/codex", "app-server"])


class PokeTests(unittest.IsolatedAsyncioTestCase):
    async def test_pokes_are_spaced_and_the_last_one_is_kept(self):
        heard: list = []
        reads: list = []

        async def send(method, params):
            heard.append((method, params))

        def read(env=None):
            reads.append(time.monotonic())
            return {"rateLimits": {"primary": {"usedPercent": len(reads)}}, "accountId": "x"}

        limits = rc.Limits(send, interval=0.3, read=read)
        limits.poke()
        await asyncio.sleep(0.05)
        limits.poke()  # during the wait: one more read after it, not two
        limits.poke()
        await asyncio.sleep(0.6)
        self.assertEqual(len(reads), 2)
        self.assertGreaterEqual(reads[1] - reads[0], 0.25)
        self.assertEqual([m for m, _ in heard], [rc.METHOD, rc.METHOD])
        self.assertEqual(limits.last["rateLimits"]["primary"]["usedPercent"], 2)
        self.assertNotIn("accountId", limits.last)

    async def test_a_failed_read_sends_nothing(self):
        heard: list = []

        async def send(method, params):
            heard.append(method)

        def read(env=None):
            raise rc.CodexError("signed out")

        limits = rc.Limits(send, read=read)
        limits.poke()
        await asyncio.sleep(0.1)
        self.assertEqual(heard, [])
        self.assertIsNone(limits.last)


if __name__ == "__main__":
    unittest.main()

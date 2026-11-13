"""What the bots wait on the person for (`waiting.py`): python -m unittest discover -s companion/hermes-plugin/tests"""
import json
import tempfile
import time
import unittest
from pathlib import Path

from test_routines import plugin

waiting = plugin.waiting


class WaitingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "profiles" / "claude").mkdir(parents=True)
        (self.root / "profiles" / "writer").mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def test_every_profiles_waits_newest_first(self):
        now = time.time()
        waiting.write(self.root / "profiles" / "claude", [
            {"id": "steps/abc", "title": "Waiting on your approval", "detail": "Server steps: systemctl restart x", "word": "go", "at": now - 60},
            {"id": "change/abc", "title": "Waiting on your approval", "detail": "Claude's change is ready", "word": "put it in", "at": now - 10}])
        waiting.write(self.root, [{"id": "card/t_1", "title": "Coder needs your OK", "at": now - 30}])
        said = waiting.slash(self.root, [])
        self.assertTrue(said.startswith("redde-push waiting "))
        listed = json.loads(said[len("redde-push waiting "):])["waiting"]
        self.assertEqual([(w["profile"], w["id"]) for w in listed],
                         [("claude", "change/abc"), ("default", "card/t_1"), ("claude", "steps/abc")])
        self.assertEqual(listed[0]["word"], "put it in")
        self.assertEqual(listed[1]["word"], "go")   # (none given: "go")

    def test_answered_or_old_or_broken_waits_are_left_out(self):
        home = self.root / "profiles" / "claude"
        waiting.write(home, [{"id": "a", "title": "Old", "at": time.time() - 8 * 86_400},
                             {"title": "No id", "at": time.time()}, "nonsense"])
        (self.root / "profiles" / "writer" / waiting.FILE).write_text("{not json")
        self.assertEqual(waiting.listing(self.root), [])
        waiting.write(home, [])
        self.assertEqual(waiting.listing(self.root), [])
        self.assertEqual(oct((home / waiting.FILE).stat().st_mode & 0o777), "0o600")


if __name__ == "__main__":
    unittest.main()

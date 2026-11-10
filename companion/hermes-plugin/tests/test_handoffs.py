"""handoffs.keep: a message_agent hand-off is marked to outlive its chat's close; nothing else is."""
import importlib.util
import pathlib
import types
import unittest

spec = importlib.util.spec_from_file_location(
    "handoffs", pathlib.Path(__file__).resolve().parent.parent / "redde-push" / "handoffs.py")
handoffs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handoffs)


def process(command, persist=False):
    return types.SimpleNamespace(command=command, persist_on_release=persist)


class KeepTests(unittest.TestCase):
    def setUp(self):
        self.delivery = process("/venv/bin/python /opt/hermes/tools/bot_mode_dm.py --run-delivery desktop /tmp/dm.json hermes -p watcher")
        self.waiter = process("'/venv/bin/python' '/opt/hermes/tools/bot_mode_dm.py' --wait-reply /root env-1")
        self.job = process("npm run dev")
        self.registry = types.SimpleNamespace(_running={"a": self.delivery, "b": self.waiter, "c": self.job})

    def test_message_agent_keeps_its_deliveries(self):
        self.assertEqual(handoffs.keep("message_agent", self.registry), 2)
        self.assertTrue(self.delivery.persist_on_release and self.waiter.persist_on_release)
        self.assertFalse(self.job.persist_on_release)

    def test_other_tools_change_nothing(self):
        self.assertEqual(handoffs.keep("terminal", self.registry), 0)
        self.assertFalse(self.delivery.persist_on_release)

    def test_marked_once(self):
        handoffs.keep("message_agent", self.registry)
        self.assertEqual(handoffs.keep("message_agent", self.registry), 0)

    def test_no_registry_is_quiet(self):
        self.assertEqual(handoffs.keep("message_agent", types.SimpleNamespace()), 0)


if __name__ == "__main__":
    unittest.main()

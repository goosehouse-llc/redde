"""asks.gate: a bot's message_agent hand-off is held for the person (Hermes's approval gate) while
Ask Me First is on; a withdrawal and every other tool pass; `asks off` lets hand-offs through."""
import importlib.util
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("asks", pathlib.Path(__file__).resolve().parent.parent / "redde-push" / "asks.py")
asks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asks)


class AsksTests(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp())

    def test_a_hand_off_asks_first_saying_whom_and_what(self):
        held = asks.gate(self.root, "default", "message_agent",
                         {"target": "code", "message": "Count the Swift files in\n  Echo/Views.", "expecting": "a number"})
        self.assertEqual(held["action"], "approve")
        self.assertEqual(held["message"], "Ask @code: Count the Swift files in Echo/Views. (wants back: a number)")
        self.assertEqual(held["rule_key"], "redde_ask:default>code")

    def test_several_at_once_are_named_and_a_long_ask_is_cut(self):
        held = asks.gate(self.root, "scout", "message_agent", {"target": "writer, @code", "message": "x" * 2000})
        self.assertTrue(held["message"].startswith("Ask @writer, @code: xxx"))
        self.assertLessEqual(len(held["message"]), len("Ask @writer, @code: ") + asks.MOST)
        self.assertEqual(held["rule_key"], "redde_ask:scout>code,writer")

    def test_a_withdrawal_and_other_tools_pass(self):
        self.assertIsNone(asks.gate(self.root, "default", "message_agent", {"target": "code", "cancel": "d-1"}))
        self.assertIsNone(asks.gate(self.root, "default", "terminal", {"command": "ls"}))

    def test_off_lets_hand_offs_through_and_on_holds_them_again(self):
        self.assertEqual(asks.slash(self.root, []), "redde-push asks on")
        self.assertEqual(asks.slash(self.root, ["off"]), "redde-push asks off")
        self.assertIsNone(asks.gate(self.root, "default", "message_agent", {"target": "code", "message": "hi"}))
        self.assertEqual(asks.slash(self.root, ["on"]), "redde-push asks on")
        self.assertIsNotNone(asks.gate(self.root, "default", "message_agent", {"target": "code", "message": "hi"}))

    def test_a_bad_file_means_on(self):
        (self.root / "redde-push").mkdir()
        (self.root / "redde-push" / "asks.json").write_text("{not json")
        self.assertTrue(asks.on(self.root))


if __name__ == "__main__":
    unittest.main()

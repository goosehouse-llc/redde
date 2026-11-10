"""What the app says with a message (`turnnote.py`): python -m unittest discover -s companion/hermes-plugin/tests"""
import base64
import tempfile
import unittest
from pathlib import Path

from test_routines import plugin

turnnote = plugin.turnnote

NOTE = "(Reply in Dutch (Nederlands).)\n\n(The user is near Thornton Park, Orlando, FL (28.542, -81.367). Use it for places.)"


def b64(text):
    return base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")


class TurnNoteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_note_goes_with_its_message_once(self):
        asked = "coffee near me"
        self.assertEqual(turnnote.slash(self.home, ["s1", turnnote.mark(asked), b64(NOTE)]), "redde-push turn kept")
        self.assertEqual(turnnote.take(self.home, "s1", asked), NOTE)
        self.assertIsNone(turnnote.take(self.home, "s1", asked))
        self.assertFalse(turnnote.path(self.home).exists())   # nothing is left lying about

    def test_the_mark_is_the_words_whatever_the_blank_lines(self):
        self.assertEqual(turnnote.mark("coffee\n\n near  me "), turnnote.mark("coffee near me"))
        self.assertEqual(turnnote.mark({"content": [{"type": "text", "text": "coffee near me"}, {"type": "image_url"}]}),
                         turnnote.mark("coffee near me"))
        self.assertNotEqual(turnnote.mark("coffee near me"), turnnote.mark("coffee near you"))
        # The phone's own (TurnNotesTests): the two must agree.
        self.assertEqual(turnnote.mark("coffee near me"), "4ee9728ebb77bbbb")

    def test_a_message_queued_behind_another_turn_keeps_its_own(self):
        turnnote.keep(self.home, "s1", turnnote.mark("coffee near me"), "(near Orlando)", now=1_000)
        turnnote.keep(self.home, "s1", turnnote.mark("and in Dutch"), "(Reply in Dutch.)", now=1_001)
        self.assertEqual(turnnote.take(self.home, "s1", "and in Dutch", now=1_002), "(Reply in Dutch.)")
        self.assertEqual(turnnote.take(self.home, "s1", "coffee near me", now=1_003), "(near Orlando)")

    def test_another_sessions_turn_takes_nothing(self):
        turnnote.keep(self.home, "s1", turnnote.mark("coffee near me"), "(near Orlando)", now=1_000)
        self.assertIsNone(turnnote.take(self.home, "s2", "what's the time", now=1_001))
        self.assertEqual(turnnote.take(self.home, "s1", "coffee near me", now=1_002), "(near Orlando)")

    def test_a_conversation_given_a_new_id_still_finds_it(self):
        turnnote.keep(self.home, "s1", turnnote.mark("coffee near me"), "(near Orlando)", now=1_000)
        self.assertEqual(turnnote.take(self.home, "s1-summed-up", "coffee near me", now=1_001), "(near Orlando)")

    def test_words_changed_on_the_way_take_the_sessions_recent_note(self):
        turnnote.keep(self.home, "s1", turnnote.mark("look @image:/tmp/a.png"), "(Use US units.)", now=1_000)
        self.assertEqual(turnnote.take(self.home, "s1", "look [picture]", now=1_000 + turnnote.UNMARKED_FOR - 1), "(Use US units.)")
        turnnote.keep(self.home, "s1", turnnote.mark("look @image:/tmp/a.png"), "(Use US units.)", now=1_000)
        self.assertIsNone(turnnote.take(self.home, "s1", "look [picture]", now=1_000 + turnnote.UNMARKED_FOR + 1))

    def test_an_old_note_is_dropped(self):
        turnnote.keep(self.home, "s1", turnnote.mark("coffee near me"), "(near Orlando)", now=1_000)
        self.assertIsNone(turnnote.take(self.home, "s1", "coffee near me", now=1_000 + turnnote.KEPT_FOR + 1))
        self.assertFalse(turnnote.path(self.home).exists())

    def test_a_message_sent_again_has_one_note(self):
        turnnote.keep(self.home, "s1", turnnote.mark("coffee near me"), "(near Orlando)", now=1_000)
        self.assertEqual(turnnote.keep(self.home, "s1", turnnote.mark("coffee near me"), "(near Tampa)", now=1_100), 1)
        self.assertEqual(turnnote.take(self.home, "s1", "coffee near me", now=1_101), "(near Tampa)")

    def test_only_so_many_wait(self):
        for n in range(turnnote.AT_MOST + 5):
            turnnote.keep(self.home, "s1", turnnote.mark(f"message {n}"), f"note {n}", now=1_000 + n)
        self.assertIsNone(turnnote.take(self.home, "elsewhere", "message 0", now=2_000))
        self.assertEqual(turnnote.take(self.home, "elsewhere", "message 5", now=2_000), "note 5")

    def test_what_isnt_the_apps_is_refused(self):
        mark = turnnote.mark("x")
        self.assertTrue(turnnote.slash(self.home, ["s1", mark]).startswith("redde-push turn: this command"))
        self.assertTrue(turnnote.slash(self.home, ["s1", "not-a-mark", b64("x")]).startswith("redde-push turn: this command"))
        self.assertTrue(turnnote.slash(self.home, ["../s1", mark, b64("x")]).startswith("redde-push turn: this command"))
        self.assertEqual(turnnote.slash(self.home, ["s1", mark, "_w"]), "redde-push turn refused: unreadable")
        self.assertEqual(turnnote.slash(self.home, ["s1", mark, b64(" ")]), "redde-push turn refused: empty or too long")
        self.assertEqual(turnnote.slash(self.home, ["s1", mark, b64("x" * (turnnote.LONGEST + 1))]), "redde-push turn refused: empty or too long")
        self.assertFalse(turnnote.path(self.home).exists())

    def test_the_file_is_the_persons_alone(self):
        turnnote.keep(self.home, "s1", turnnote.mark("coffee near me"), "(near Orlando)", now=1_000)
        self.assertEqual(turnnote.path(self.home).stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()

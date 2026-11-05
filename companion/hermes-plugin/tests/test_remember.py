"""Remember that… / Forget that… (`remember.py`): python -m unittest discover -s companion/hermes-plugin/tests"""
import unittest

from test_routines import plugin

remember = plugin.remember


class RememberTests(unittest.TestCase):
    def test_asking_to_remember_gets_the_note(self):
        for said in ("Remember that I'm vegetarian", "remember: my sister is Ana", "Please remember my wife's birthday is May 3",
                     "Don't forget that I take my coffee black", "Keep in mind that we have a dog", "Remember that: the gate code changed",
                     "Sol, remember I hate cilantro", "Can you remember that I work from home on Fridays?",
                     "ok remember this: I prefer metric"):
            self.assertEqual(remember.turn_note(said), remember.REMEMBER_NOTE, said)

    def test_asking_to_forget_gets_the_note(self):
        for said in ("Forget that I live in Lisbon", "forget my old address", "Please forget what I said about the job",
                     "Stop remembering my ex's name", "Remove the note about the dentist from your memory",
                     "forget: I'm allergic to cats", "forget everything about the old car"):
            self.assertEqual(remember.turn_note(said), remember.FORGET_NOTE, said)

    def test_other_messages_get_nothing(self):
        for said in ("Remember to buy milk", "remind me to call mom", "Do you remember when we went to Porto?",
                     "remember when the server crashed?", "forget it", "Forget it.", "What's the weather?",
                     "I can't remember the password", "never mind, forget about it", "Remember how to bake bread?",
                     "[Redde: something]", ""):
            self.assertIsNone(remember.turn_note(said), said)

    def test_scheduled_runs_and_bots_rooms_get_nothing(self):
        for platform in ("cron", "subagent", "bot_room"):
            self.assertIsNone(remember.turn_note("Remember that I'm vegetarian", platform))
        self.assertEqual(remember.turn_note([{"type": "text", "text": "remember that I'm left-handed"}]), remember.REMEMBER_NOTE)

    def test_the_notes_stay_short(self):
        self.assertLess(len(remember.REMEMBER_NOTE), 450)
        self.assertLess(len(remember.FORGET_NOTE), 450)


if __name__ == "__main__":
    unittest.main()

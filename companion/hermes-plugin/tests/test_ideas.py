"""python -m unittest discover -s companion/hermes-plugin/tests

Ideas from the agent (redde-push/ideas.py): what each paired phone is sent, sealed like any note,
what is kept of each idea, and how often one agent may send them."""
import json
import tempfile
import unittest
from pathlib import Path

from test_calls import Relay, paired, plugin, read

core, ideas = plugin.core, plugin.ideas


class IdeasTests(unittest.TestCase):
    def setUp(self):
        self.relay = Relay()
        self.addCleanup(self.relay.close)
        self.main = Path(tempfile.mkdtemp())
        self.store = core.Store(self.main)

    def offered(self):
        return [{"title": "Book the vet for Pickles", "why": "His jab is due Friday",
                 "request": "Book Pickles in at the vet on Thursday afternoon and add it to my calendar"},
                {"title": "", "request": "Order more coffee beans"},
                {"title": "No request, so left out"}]

    def test_ideas_go_to_every_paired_phone_sealed_like_any_note(self):
        key = paired(self.store, self.relay.url, "dev-marta")
        paired(self.store, self.relay.url, "dev-pad")
        said = ideas.offer(self.store, self.main, "default", "Sol", self.offered(), now=1000)
        self.assertEqual(said["phones"], 2, said)
        sent = self.relay.pushes[0]
        self.assertEqual(sent.get("ttl"), 43200)
        self.assertNotEqual(sent.get("kind"), "call", "an ordinary notification, not a call")
        self.assertNotIn("Pickles", json.dumps(sent), "the relay sees nothing of them")
        made = read(key, "dev-marta", sent["payload"])
        self.assertEqual((made["k"], made["p"], made["d"]), ("ideas", "default", "Sol"))
        self.assertEqual(made["y"], [{"t": "Book the vet for Pickles", "r": "Book Pickles in at the vet on Thursday afternoon and add it to my calendar", "w": "His jab is due Friday"},
                                     {"t": "Order more coffee beans", "r": "Order more coffee beans"}],
                         "a heading from the request when none is given; one without a request left out")
        self.assertRegex(made["i"], r"^[0-9a-f]{16}$")

    def test_nothing_to_send_or_no_phone_sends_nothing(self):
        self.assertIn("No ideas", ideas.offer(self.store, self.main, "default", "Sol", [{"title": "x"}])["error"])
        self.assertIn("No iPhone", ideas.offer(self.store, self.main, "default", "Sol", self.offered())["error"])
        self.assertEqual(self.relay.pushes, [])

    def test_at_most_five_and_ten_times_an_hour_from_each_agent(self):
        paired(self.store, self.relay.url, "dev-marta")
        many = [{"title": f"Idea {n}", "request": f"Do thing {n}"} for n in range(8)]
        self.assertEqual(len(ideas.cleaned(many)), 5)
        for n in range(ideas.HOURLY):
            self.assertIn("sent", ideas.offer(self.store, self.main, "ops", "Home", many, now=1000 + n))
        self.assertIn("10 times", ideas.offer(self.store, self.main, "ops", "Home", many, now=1100)["error"])
        self.assertIn("sent", ideas.offer(self.store, self.main, "default", "Sol", many, now=1100), "another agent may")
        self.assertIn("sent", ideas.offer(self.store, self.main, "ops", "Home", many, now=1000 + 3601), "an hour on")

    def test_a_long_offer_is_cut_to_fit_a_notification(self):
        long = [{"title": "T" * 60, "why": "W" * 120, "request": "R" * 300} for _ in range(5)]
        made = core.ideas_note("default", "Sol", ideas.cleaned(long), "0123456789abcdef")
        self.assertLessEqual(len(json.dumps(made, ensure_ascii=False).encode()), core.NOTE_LIMIT)
        self.assertGreaterEqual(len(made["y"]), 1)


if __name__ == "__main__":
    unittest.main()

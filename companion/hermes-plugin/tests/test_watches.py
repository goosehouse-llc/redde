"""Watches and follow-ups (`watches.py`, `followups.py`): python -m unittest discover -s companion/hermes-plugin/tests"""
import json
import time
import unittest
from datetime import datetime, timedelta, timezone

from test_routines import RoutinesTests, plugin

core, routines, watches, followups = plugin.core, plugin.routines, plugin.watches, plugin.followups

ASKED = "[redde-watch:w1] Watch: the price of the blue kettle on example.com. Check it now with your tools."


class WatchTests(RoutinesTests):
    """On the same stand-in store as a bot's schedules."""

    def watch_job(self, last=None, status="ok", error=None):
        return self.job("default", last=last, deliver="local", status=status, error=error, name="[redde-watch:w1] Blue kettle price")

    def test_a_change_is_sent_and_nothing_new_is_not(self):
        home = self.watch_job(last="2026-10-28T07:00:00")
        self.watch.look()
        self.output(home, "# Cron Job\n\n## Response\n\nNOTHING NEW")
        self.watch_job(last="2026-10-28T08:00:00")
        self.assertEqual(self.watch.look(), 0, "nothing new: nothing said")
        self.output(home, "# Cron Job\n\n## Response\n\nIt dropped to $39 (was $49).")
        self.watch_job(last="2026-10-28T09:00:00")
        self.assertEqual(self.watch.look(), 1)
        made = self.sent[0][1]
        self.assertEqual((made["k"], made["t"], made["i"], made["b"]), ("watch", "Blue kettle price", "w1", "It dropped to $39 (was $49)."))

    def test_a_watch_that_couldnt_look_says_why(self):
        self.watch_job(last="2026-10-28T07:00:00")
        self.watch.look()
        self.watch_job(last="2026-10-28T08:00:00", status="error", error="The page didn't load")
        self.watch.look()
        self.assertEqual(self.sent[0][1]["w"], "failed")

    def test_each_look_is_told_what_it_said_last_time(self):
        home = self.watch_job(last="2026-10-28T07:00:00")
        stores = routines.Stores(self.root)
        self.assertIn("first look", watches.turn_note(home, stores, ASKED))
        self.output(home, "## Response\n\nIt's $49.")
        time.sleep(0.01)
        self.output(home, "## Response\n\nNOTHING NEW.")
        note = watches.turn_note(home, stores, ASKED)
        self.assertIn("It's $49.", note, "the last thing it had to say, past the quiet runs")
        self.assertIsNone(watches.turn_note(home, stores, "What's the weather?"))

    def test_quiet_answers(self):
        for answer in ("NOTHING NEW", "Nothing new.", "**NOTHING NEW**"):
            self.assertTrue(watches.quiet(answer), answer)
        self.assertFalse(watches.quiet("Nothing new on the kettle, but the toaster dropped to $20."[:0] + "The toaster dropped."))


class FollowUpTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        from pathlib import Path
        self.root = Path(tempfile.mkdtemp())
        self.store = core.Store(self.root)
        self.made = []

    def make(self, prompt, schedule, name=None, deliver=None):
        self.made.append({"prompt": prompt, "schedule": schedule, "name": name, "deliver": deliver})

    def test_a_loose_end_is_noticed_only_where_a_follow_up_can_reach_a_phone(self):
        said = "I'll call the plumber tomorrow about the leak"
        self.assertIsNone(followups.turn_note(self.root, lambda _: self.store, said), "no phone paired")
        self.store.add({"id": "phone-1", "name": "Marta"})
        self.assertIn("follow_up_later", followups.turn_note(self.root, lambda _: self.store, said))
        self.assertIsNone(followups.turn_note(self.root, lambda _: self.store, "What's the capital of France?"))
        self.assertIsNone(followups.turn_note(self.root, lambda _: self.store, said, platform="cron"), "not in a scheduled run")

    def test_a_follow_up_is_a_job_that_runs_once_and_offers_it_back(self):
        now = datetime(2026, 10, 28, 20, 0, tzinfo=timezone.utc)
        said = followups.set_up(self.root, "Call the plumber", "2026-10-29T09:00:00-04:00",
                                "Find the plumber's number and remind me to call", make=self.make, now=now)
        self.assertIn("idea card", said["set"])
        job = self.made[0]
        self.assertEqual(job["schedule"], "2026-10-29T09:00-04:00", "a timestamp: Hermes runs it once")
        self.assertTrue(job["name"].startswith("[redde-followup:") and job["name"].endswith("] Call the plumber"))
        self.assertEqual(job["deliver"], "local")
        self.assertIn("suggest_to_user", job["prompt"])
        self.assertIn("Find the plumber's number", job["prompt"])

    def test_a_bad_time_is_refused(self):
        now = datetime(2026, 10, 28, 20, 0, tzinfo=timezone.utc)
        for when, why in (("tomorrow", "date and time"), ("2026-10-29T09:00:00", "UTC offset"),
                          ("2026-10-27T09:00:00-04:00", "past"), ("2027-03-01T09:00:00-04:00", "60 days")):
            self.assertIn(why, followups.set_up(self.root, "Call", when, "", make=self.make, now=now)["error"], when)
        self.assertEqual(self.made, [])


if __name__ == "__main__":
    unittest.main()


class NotifyJobTests(RoutinesTests):
    """A job the agent made with Redde's notify tag sends each run's answer (asked 2026-10-28)."""

    def test_a_tagged_jobs_answer_is_sent(self):
        home = self.job("default", last="2026-10-28T09:00:00", deliver="origin", name="[redde-notify] Daily meeting brief")
        self.watch.look()
        self.output(home, "## Response\n\nThree meetings today; the 11:00 clashes with lunch.")
        self.job("default", last="2026-10-29T09:00:00", deliver="origin", name="[redde-notify] Daily meeting brief")
        self.assertEqual(self.watch.look(), 1)
        made = self.sent[0][1]
        self.assertEqual((made["k"], made["t"]), ("routine", "Daily meeting brief"))
        self.assertIn("clashes with lunch", made["b"])

    def test_sol_is_told_how_when_asked_for_something_on_a_schedule(self):
        said = "Every morning at 9, brief me on today's meetings"
        self.assertIn("[redde-notify]", routines.turn_note(self.root, lambda _: self.store, said))
        self.assertIsNone(routines.turn_note(self.root, lambda _: self.store, "What's on today?"))
        self.assertIsNone(routines.turn_note(self.root, lambda _: self.store, said, platform="cron"))


class HeadsUpTests(RoutinesTests):
    """Heads-ups before events (`headsup.py`, asked 2026-10-28)."""

    def setUp(self):
        super().setUp()
        self.made = []

    def make(self, prompt, schedule, name=None, deliver=None):
        self.made.append({"prompt": prompt, "schedule": schedule, "name": name, "deliver": deliver})

    def test_a_heads_up_runs_once_before_the_event_and_is_a_briefing(self):
        headsup = plugin.headsup
        now = datetime(2026, 10, 29, 10, 0, tzinfo=timezone.utc)
        said = headsup.set_up(self.root, "Dentist", "2026-10-29T14:30:00-04:00", 20, "Dr. Lee, Main St; insurance card",
                              make=self.make, now=now)
        self.assertIn("14:10", said["set"])
        job = self.made[0]
        self.assertEqual(job["schedule"], "2026-10-29T14:10-04:00")
        self.assertEqual(job["name"], "[redde-notify] Heads-up: Dentist")
        self.assertIn("insurance card", job["prompt"])
        self.assertIn("cancelled or moved", job["prompt"])

    def test_the_lead_is_kept_within_bounds_and_not_in_the_past(self):
        headsup = plugin.headsup
        now = datetime(2026, 10, 29, 18, 20, tzinfo=timezone.utc)
        headsup.set_up(self.root, "Call", "2026-10-29T14:30:00-04:00", 500, make=self.make, now=now)
        at = datetime.fromisoformat(self.made[0]["schedule"])
        self.assertEqual(at, now + timedelta(minutes=1), "two hours ahead at most, and never before now")
        headsup.set_up(self.root, "Call", "2026-10-29T16:00:00-04:00", 1, make=self.make, now=now)
        self.assertEqual(datetime.fromisoformat(self.made[1]["schedule"]), datetime(2026, 10, 29, 15, 55, tzinfo=timezone(timedelta(hours=-4))),
                         "five minutes at least")

    def test_a_briefing_is_marked_for_the_phone_to_keep(self):
        home = self.job("default", last="2026-10-28T21:00:00", deliver="local", name="[redde-notify] Evening wrap-up")
        self.watch.look()
        self.output(home, "## Response\n\nDone: the vet booked. Waiting on you: one approval.")
        self.job("default", last="2026-10-29T21:00:00", deliver="local", name="[redde-notify] Evening wrap-up")
        self.assertEqual(self.watch.look(), 1)
        made = self.sent[0][1]
        self.assertEqual((made["k"], made["t"], made["x"]), ("routine", "Evening wrap-up", "brief"))
        self.assertTrue(made["i"])


class HandOffTests(RoutinesTests):
    """A watch handed to another agent (asked 2026-10-28, "bots that bring each other in")."""

    def test_silent_is_quiet_too(self):
        self.assertTrue(watches.quiet("[SILENT]"))
        self.assertTrue(watches.quiet("  [silent] "))
        self.assertFalse(watches.quiet("The garage door is open."))

    def test_a_handed_off_watch_is_told_to_answer_silent(self):
        home = self.job("ops", last=None, deliver="bot-chat:default", name="[redde-watch:w2] Garage door at night")
        note = watches.turn_note(home, routines.Stores(self.root), "[redde-watch:w2] Watch, for the user: the garage door.")
        self.assertIn("[SILENT]", note)
        self.assertIn("handed to", note)

    def test_a_handed_off_watch_that_saw_nothing_sends_nothing(self):
        home = self.job("ops", last="2026-10-28T22:00:00", deliver="bot-chat:default", name="[redde-watch:w2] Garage door")
        self.watch.look()
        self.output(home, "## Response\n\n[SILENT]")
        self.job("ops", last="2026-10-28T22:15:00", deliver="bot-chat:default", name="[redde-watch:w2] Garage door")
        self.assertEqual(self.watch.look(), 0)
        self.output(home, "## Response\n\nThe garage door has been open since 22:10.")
        self.job("ops", last="2026-10-28T22:30:00", deliver="bot-chat:default", name="[redde-watch:w2] Garage door")
        self.assertEqual(self.watch.look(), 1, "a change still reaches the phone, as the agent takes it on")


class AgentWatchTests(RoutinesTests):
    """Watches the agent sets itself (asked 2026-10-28)."""

    def setUp(self):
        super().setUp()
        self.made = []

    def make(self, prompt, schedule, name=None, deliver=None, repeat=None):
        self.made.append({"prompt": prompt, "schedule": schedule, "name": name, "deliver": deliver, "repeat": repeat})

    def test_a_watch_the_agent_sets_is_one_the_app_lists_and_it_stops(self):
        said = watches.set_up(self.root, "the reply from Ana about the lease", "4h", 3, make=self.make)
        self.assertIn("3 days", said["set"])
        job = self.made[0]
        self.assertTrue(job["name"].startswith("[redde-watch:") and job["name"].endswith("] the reply from Ana about the lease"))
        self.assertEqual((job["schedule"], job["repeat"], job["deliver"]), ("0 */4 * * *", 18, "local"))
        self.assertIn("NOTHING NEW", job["prompt"])
        self.assertEqual(watches.watch_id(job["prompt"]), watches.watch_id(job["name"]))

    def test_odd_asks_are_made_sensible(self):
        watches.set_up(self.root, "x", "every minute", 400, make=self.make)
        self.assertEqual((self.made[0]["schedule"], self.made[0]["repeat"]), ("0 * * * *", 24 * 30))
        self.assertIn("error", watches.set_up(self.root, " ", make=self.make))

    def test_asked_to_be_told_when_something_happens(self):
        for said in ("Let me know when Ana replies", "Can you keep an eye on the price of that kettle?", "tell me if the PR gets merged"):
            self.assertIn("keep_an_eye_on", watches.ask_note(self.root, lambda _: self.store, said) or "", said)
        self.assertIsNone(watches.ask_note(self.root, lambda _: self.store, "What's the weather?"))

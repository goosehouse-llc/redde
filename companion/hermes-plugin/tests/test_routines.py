"""A bot's schedules (`routines.py`): python -m unittest discover -s companion/hermes-plugin/tests"""
import importlib.util
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "redde-push"
if "redde_push" not in sys.modules:
    spec = importlib.util.spec_from_file_location("redde_push", HERE / "__init__.py", submodule_search_locations=[str(HERE)])
    plugin = importlib.util.module_from_spec(spec)
    sys.modules["redde_push"] = plugin
    spec.loader.exec_module(plugin)
plugin = sys.modules["redde_push"]
core, routines = plugin.core, plugin.routines


class RoutinesTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.root = Path(self.home.name)
        self.store = core.Store(self.root)
        self.store.add({"id": "phone-1", "name": "Marta"})
        self.sent = []
        self.watch = routines.Routines(self.store, self.capture, routines.Stores(self.root))

    def tearDown(self):
        self.home.cleanup()

    def capture(self, devices, made):
        self.sent.append(([d["id"] for d in devices], made))
        return len(devices)

    def job(self, profile, last=None, deliver="bot-chat:scout", status="ok", error=None, name="[bot:scout] What to wear"):
        home = self.root if profile == "default" else self.root / "profiles" / profile
        (home / "cron").mkdir(parents=True, exist_ok=True)
        job = {"id": "job1", "name": name, "deliver": deliver, "last_run_at": last, "last_status": status, "last_error": error}
        (home / "cron" / "jobs.json").write_text(json.dumps({"jobs": [job]}))
        return home

    def output(self, home, text):
        folder = home / "cron" / "output" / "job1"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"{time.time_ns()}.md").write_text(text)

    def test_a_run_of_a_bots_schedule_is_announced_once_with_its_answer(self):
        home = self.job("scout", last="2026-10-20T07:00:00")
        self.assertEqual(self.watch.look(), 0, "first seen: what ran before isn't news")
        self.output(home, "# Cron Job: What to wear\n\n## Prompt\n\nWhat should I wear?\n\n## Response\n\nA light jacket: 14 degrees and dry.")
        self.job("scout", last="2026-10-21T07:00:00")
        self.assertEqual(self.watch.look(), 1)
        devices, made = self.sent[0]
        self.assertEqual(devices, ["phone-1"])
        self.assertEqual((made["k"], made["p"], made["t"], made["b"]), ("routine", "scout", "What to wear", "A light jacket: 14 degrees and dry."))
        self.assertEqual(made["d"], "scout", "no title kept for it: its profile")
        self.assertEqual(self.watch.look(), 0, "said once")

    def test_a_run_that_failed_says_why(self):
        self.job("scout", last="2026-10-20T07:00:00")
        self.watch.look()
        self.job("scout", last="2026-10-21T07:00:00", status="error", error="No LLM provider configured")
        self.watch.look()
        made = self.sent[0][1]
        self.assertEqual(made["w"], "failed")
        self.assertIn("No LLM provider configured", made["b"])

    def test_other_jobs_are_left_alone_and_a_muted_bot_says_nothing(self):
        self.job("default", last="2026-10-20T07:00:00", deliver="local", name="Backups")
        self.job("scout", last="2026-10-20T07:00:00")
        self.watch.look()
        self.job("default", last="2026-10-21T07:00:00", deliver="local", name="Backups")
        self.store.set_mutes(["phone-1"], {"b:scout": 0})
        self.job("scout", last="2026-10-21T07:00:00")
        self.watch.look()
        self.assertEqual(self.sent, [], "a job that doesn't answer in a bot's chat, and a muted bot")

    def test_a_job_the_phone_hides_sends_nothing(self):
        self.notify_run("Built at 9.")
        self.sent.clear()
        self.store.set_mutes(["phone-1"], {routines.job_mute("default", "job1"): 0})
        home = self.job("default", last="2026-11-01T21:00:00", deliver="local", name="[redde-notify] Evening wrap-up")
        self.output(home, "# Cron Job\n\n## Response\n\nThe build is green.")
        self.watch.look()
        self.assertEqual(self.sent, [], "Don't Show on that job's card")
        self.store.set_mutes(["phone-1"], {routines.job_mute("default", "job2"): 0})
        self.job("default", last="2026-11-02T21:00:00", deliver="local", name="[redde-notify] Evening wrap-up")
        self.watch.look()
        self.assertEqual(len(self.sent), 1, "another job's mute leaves this one alone")

    def test_a_run_hermes_recorded_as_quiet_sends_nothing(self):
        """Issue 55: script jobs' and gated jobs' quiet records have no "## Response": the whole file
        came back as the answer, and a note with the job's header went out."""
        for record in ("# Cron Job: Backups\n\n**Status:** silent (wakeAgent=false)\n",
                       "# Cron Job: Backups\n\n**Status:** silent (empty output)\n",
                       "# Cron Job: Backups\n\n**Status:** no_change (agent run suppressed)\n",
                       "# Cron Job: Backups\n\nScript gate returned `wakeAgent=false`, agent skipped.\n"):
            self.assertTrue(routines.quiet_record(record), record)
            self.sent.clear()
            self.assertEqual(self.notify_run_record(record), [], record)
        self.assertFalse(routines.quiet_record("# Cron Job: Backups\n\n**Status:** script failed\n\nNo disk."))
        self.assertEqual(len(self.notify_run_record("# Cron Job: Backups\n\n**Status:** script failed\n\nNo disk.")), 1,
                         "a record that isn't quiet still goes")

    def notify_run_record(self, record):
        home = self.job("default", last="2026-10-30T21:00:00", deliver="local", name="[redde-notify] Backups")
        self.watch.look()
        self.sent.clear()
        self.output(home, record)
        self.job("default", last=f"2026-10-31T21:{len(record) % 60:02d}:00", deliver="local", name="[redde-notify] Backups")
        self.watch.look()
        return self.sent

    def test_two_processes_reading_send_each_run_once(self):
        self.job("scout", last="2026-10-20T07:00:00")
        other = routines.Routines(core.Store(self.root), self.capture, routines.Stores(self.root))
        self.watch.look()
        self.job("scout", last="2026-10-21T07:00:00")
        self.assertEqual(other.look() + self.watch.look(), 1)

    def test_each_run_keeps_its_own_notification(self):
        device = {"id": "phone-1", "key": core.b64u(b"k" * 32)}
        one = core.routine_note("scout", "Scout", "What to wear", "A jacket.")
        two = dict(one, at=one["at"] + 86400)
        self.assertNotEqual(core.collapse_id(device, one), core.collapse_id(device, two))
        self.assertEqual(routines.untagged("[bot:scout] What to wear"), "What to wear")

    def morning(self, last, answer=None, status="ok", error=None):
        home = self.job("default", last=last, deliver="local", name="[redde] Morning ideas", status=status, error=error)
        if answer is not None:
            self.output(home, "# Cron Job: Morning ideas\n\n## Response\n\n" + answer)
        return home

    def test_morning_ideas_written_out_instead_of_offered_still_come_as_cards(self):
        self.morning("2026-10-28T07:30:00")
        self.watch.look()
        self.morning("2026-10-29T07:30:00", "Here are a few:\n\nIDEA: Book the vet | His jab is due Friday | Book Pickles in at the vet on Thursday\n"
                                            "- **IDEA:** Call the plumber | The tap still drips | Call the plumber about the kitchen tap")
        self.assertEqual(self.watch.look(), 1)
        made = self.sent[0][1]
        self.assertEqual(made["k"], "ideas")
        self.assertEqual([(i["t"], i.get("w"), i["r"]) for i in made["y"]],
                         [("Book the vet", "His jab is due Friday", "Book Pickles in at the vet on Thursday"),
                          ("Call the plumber", "The tap still drips", "Call the plumber about the kitchen tap")])
        self.assertTrue(plugin.ideas.sent_lately(self.root, "default", time.time()), "counted like the tool's")

    def test_morning_ideas_offered_with_the_tool_arent_sent_twice(self):
        self.morning("2026-10-28T07:30:00")
        self.watch.look()
        plugin.ideas.remember(self.root, "default", time.time())
        self.morning("2026-10-29T07:30:00", "IDEA: Book the vet | Due Friday | Book the vet")
        self.assertEqual(self.watch.look(), 0)

    def test_morning_ideas_with_no_cards_says_what_it_said_or_why_it_failed(self):
        self.morning("2026-10-27T07:30:00")
        self.watch.look()
        self.morning("2026-10-28T07:30:00", "Your day looks clear; I'd suggest checking the board later.")
        self.morning("2026-10-29T07:30:00", status="error", error="tool_search failed")
        self.watch.look()
        made = self.sent[0][1]
        self.assertEqual((made["k"], made["x"], made["t"], made["w"]), ("routine", "brief", "Morning ideas", "failed"))
        self.assertIn("tool_search failed", made["b"])

    def test_morning_ideas_that_found_nothing_say_nothing(self):
        self.morning("2026-10-28T07:30:00")
        self.watch.look()
        self.morning("2026-10-29T07:30:00", "NOTHING NEW")
        self.assertEqual(self.watch.look(), 0)

    def test_a_briefing_keeps_its_whole_week(self):
        week = "The week.\n" + "\n".join(f"## Day {d}\n- 9:00 AM Something on day {d}\n- 1:00 PM Another thing" for d in range(7))
        made = core.routine_note("default", "Sol", "Week ahead", week, brief="job1")
        self.assertEqual(made["b"], week, "a briefing isn't cut at 500 like a schedule's line")
        self.assertLessEqual(len(core.json.dumps(made, ensure_ascii=False).encode()), core.NOTE_LIMIT)

    # 2026-10-31: quiet evenings came as "Nothing to report. [SILENT]", and briefings began with the
    # model's own "Now let me compile the morning meeting brief." and a rule.
    def notify_run(self, answer):
        home = self.job("default", last="2026-10-30T21:00:00", deliver="local", name="[redde-notify] Evening wrap-up")
        self.watch.look()
        self.output(home, "# Cron Job\n\n## Response\n\n" + answer)
        self.job("default", last="2026-10-31T21:00:00", deliver="local", name="[redde-notify] Evening wrap-up")
        self.watch.look()
        return self.sent

    def test_silent_after_words_of_its_own_says_nothing(self):
        self.assertEqual(self.notify_run("A quiet day, nothing to report.\n\n[SILENT]"), [])

    def test_a_cron_failure_is_a_failure(self):
        made = self.notify_run("[CRON_FAILURE]\nCalendar unavailable: list_events: 401")[0][1]
        self.assertEqual(made["w"], "failed")
        self.assertIn("Calendar unavailable", made["b"])

    def test_the_models_narration_ahead_of_a_briefing_is_left_out(self):
        made = self.notify_run("No Zoom link on the Bowling event. Now let me compile the brief.\n\n---\n\n## Today\n\n| Time | Title |")[0][1]
        self.assertTrue(made["b"].startswith("## Today"), made["b"])

    def test_leading_talk_without_a_rule_is_left_out_but_findings_stay(self):
        said, silent, failed = routines.settle("I have all the information needed. Here's the notification:\n\n**Standup** at 4 PM, Zoom.")
        self.assertEqual((said, silent, failed), ("**Standup** at 4 PM, Zoom.", False, False))
        kept = "The appointment is live, 5 to 7 PM. Here's the heads-up:\n\nBring your ID."
        self.assertEqual(routines.settle(kept)[0], kept, "a paragraph with a finding in it stays")
        whole = "Today was a quiet one.\n\nNothing else."
        self.assertEqual(routines.settle(whole)[0], whole)

    def test_a_paragraph_that_ends_by_announcing_the_report_is_left_out(self):
        # 2026-11-08, a Strata watch.
        said = routines.settle("These are session logs, not a prior milestone record. I have enough. Let me report the "
                               "findings.\n\nNone of the four trigger milestones has been reached.\n\n**Status: no release yet.**")[0]
        self.assertTrue(said.startswith("None of the four"), said)
        self.assertEqual(routines.settle("Time to compose the notification.\n\nYour parcel is here.")[0], "Your parcel is here.")
        self.assertEqual(routines.settle("Both follow-ups set. Here is the evening wrap-up:\n\n**Done** — the vet.")[0],
                         "**Done** — the vet.")
        for kept in ("Let me know if you'd like me to send a reminder.\n\nThe vet is Thursday.",
                     "Let me report the findings."):
            self.assertEqual(routines.settle(kept)[0], kept, kept)

    def test_a_long_answer_is_asked_to_open_in_bold_and_list_its_points(self):
        self.assertIn("all in bold", routines.CRON_NOTE)
        self.assertIn("numbered list", routines.CRON_NOTE)

    def test_an_answer_that_only_says_nothing_changed_is_quiet(self):
        for said in ("No change.", "**No changes.**", "Nothing new", "No updates since the last check.",
                     "Checked all four sources; Qwen3.6 still doesn't run on the Mac engine.\n\nNo change."):
            self.assertEqual(routines.settle(said), ("", True, False), said)
        for said in ("No change to the other items, but the camera is $89 now.", "Price dropped to $89.\n\nNo change elsewhere?",
                     "Today was a quiet one.\n\nNothing else."):
            self.assertFalse(routines.settle(said)[1], said)
        self.assertEqual(self.notify_run("Checked the docs.\n\nNo change."), [], "a [redde-notify] run that found nothing sends nothing")

    def test_a_job_made_for_the_phone_is_told_to_stay_quiet_with_no_news(self):
        self.assertIn("exactly [SILENT]", routines.NOTE)
        self.assertIn("never \"No change\"", routines.NOTE)

    def test_a_scheduled_run_is_told_its_answer_goes_to_the_phone(self):
        store_in = lambda _: self.store
        note = routines.cron_note(self.root, store_in, "cron")
        self.assertIn("exactly [SILENT]", note or "")
        self.assertIsNone(routines.cron_note(self.root, store_in, "api_server"))


if __name__ == "__main__":
    unittest.main()

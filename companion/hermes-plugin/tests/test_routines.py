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


if __name__ == "__main__":
    unittest.main()

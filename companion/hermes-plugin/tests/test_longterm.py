"""Long-term memory for an import (`longterm.py`): python -m unittest discover -s companion/hermes-plugin/tests"""
import json
import unittest
from datetime import date

from test_routines import plugin

longterm = plugin.longterm


class Calls:
    def __init__(self, answer='{"ok": true}'):
        self.made = []
        self.answer = answer

    def __call__(self, name, args):
        self.made.append((name, args))
        return self.answer


class LongTermTests(unittest.TestCase):
    def test_the_provider_comes_first(self):
        said = longterm.stores({"memory": {"provider": "honcho"}}, ["mcp__basic_memory__write_note"])
        self.assertEqual(said["best"], {"kind": "provider", "name": "Honcho", "provider": "honcho"})
        self.assertEqual(said["servers"][0]["name"], "Basic Memory")
        self.assertEqual(longterm.stores({"memory": {"provider": "qdrant-memory"}}, [])["best"]["name"], "Qdrant Memory")
        self.assertEqual(longterm.stores({"memory": {"provider": "some-new-one"}}, [])["best"]["name"], "Some New One")

    def test_then_a_memory_server_then_nothing(self):
        names = ["mcp__memory__create_entities", "mcp__memory__add_observations", "mcp__basic_memory__bm_write_note", "web_search"]
        said = longterm.stores({"memory": {"provider": ""}}, names)
        self.assertEqual(said["best"], {"kind": "basic-memory", "name": "Basic Memory", "server": "basic_memory"}, "Basic Memory first")
        self.assertEqual(longterm.stores({}, ["mcp__memory__create_entities"])["best"]["name"], "Memory Graph")
        self.assertIsNone(longterm.stores({}, ["mcp__github__create_issue", "memory"])["best"])

    def test_basic_memory_gets_one_note_in_imported(self):
        calls = Calls()
        said = longterm.save({"server": "basic_memory", "items": ["Vegetarian", " Lives in Lisbon ", "vegetarian", ""], "source": "claude"},
                             ["mcp__basic_memory__write_note"], calls, today=date(2026, 11, 3))
        self.assertEqual(said, {"stored": 2, "store": "Basic Memory", "where": "imported/claude/Imported from Claude (2026-11-03)"})
        name, args = calls.made[0]
        self.assertEqual(name, "mcp__basic_memory__write_note")
        self.assertEqual(args, {"title": "Imported from Claude (2026-11-03)", "content": "- Vegetarian\n- Lives in Lisbon", "folder": "imported/claude"})

    def test_basic_memory_1_0_names_its_folder_directory(self):
        calls = Calls()
        schema = lambda _: {"parameters": {"properties": {"title": {}, "content": {}, "directory": {}, "tags": {}}}}
        longterm.save({"items": ["x"], "source": "chatgpt"}, ["mcp__bm__bm_write_note"], calls, schema, today=date(2026, 1, 2))
        name, args = calls.made[0]
        self.assertEqual(name, "mcp__bm__bm_write_note")
        self.assertEqual(args["directory"], "imported/chatgpt")
        self.assertNotIn("folder", args)
        self.assertEqual(args["tags"], ["imported", "chatgpt"])
        self.assertIn("ChatGPT", args["title"])

    def test_notes_are_notes_of_their_own_in_their_folders(self):
        calls = Calls()
        said = longterm.save({"items": ["Vegetarian"], "source": "claude",
                              "notes": [{"title": "Person: Dana Ruiz", "content": "Waters the plants.", "folder": "people"},
                                        {"title": "Ideas", "content": "x" * 30_000, "folder": ""},
                                        {"title": "", "content": "no title"}]},
                             ["mcp__basic_memory__write_note"], calls, today=date(2026, 11, 3))
        self.assertEqual(said["stored"], 3)
        self.assertEqual([c[1]["folder"] for c in calls.made], ["imported/claude", "imported/claude/people", "imported/claude"])
        self.assertEqual(calls.made[1][1]["title"], "Person: Dana Ruiz")
        self.assertEqual(len(calls.made[2][1]["content"]), longterm.LONGEST_NOTE)
        only = Calls()
        self.assertEqual(longterm.save({"notes": [{"title": "T", "content": "C"}]}, ["mcp__m__write_note"], only)["stored"], 1)
        graph = Calls()
        longterm.save({"notes": [{"title": "Area: Health", "content": "Runs Tuesdays"}]}, ["mcp__memory__create_entities"], graph)
        self.assertEqual(graph.made[1][1]["observations"][0]["contents"], ["Area: Health: Runs Tuesdays"])

    def test_the_memory_graph_gets_observations_on_the_person(self):
        calls = Calls()
        said = longterm.save({"items": ["Vegetarian"]}, ["mcp__memory__create_entities"], calls)
        self.assertEqual(said["stored"], 1)
        self.assertEqual([c[0] for c in calls.made], ["mcp__memory__create_entities", "mcp__memory__add_observations"])
        self.assertEqual(calls.made[1][1], {"observations": [{"entityName": "User", "contents": ["Vegetarian"]}]})

    def test_failures_and_nothing_loaded_are_said(self):
        self.assertEqual(longterm.save({"items": ["x"]}, [], Calls())["error"], "not_loaded")
        self.assertEqual(longterm.save({"items": []}, ["mcp__m__write_note"], Calls())["error"], "no_items")
        self.assertEqual(longterm.save({"items": ["x"]}, ["mcp__m__write_note"], Calls('{"error": "disk full"}')),
                         {"error": "failed", "message": "disk full"})

        def boom(name, args):
            raise RuntimeError("server down")
        self.assertEqual(longterm.save({"items": ["x"]}, ["mcp__m__write_note"], boom)["message"], "server down")

    def test_items_are_capped(self):
        calls = Calls()
        longterm.save({"items": [f"fact {i} " + "x" * 700 for i in range(80)]}, ["mcp__m__write_note"], calls)
        lines = calls.made[0][1]["content"].split("\n")
        self.assertEqual(len(lines), longterm.MOST_ITEMS)
        self.assertLessEqual(max(len(l) for l in lines), longterm.LONGEST_ITEM + 2)

    def test_the_command_answers_json(self):
        said = longterm.slash(["stores"], "memory stores", {"memory": {"provider": "mem0"}}, [], Calls(), lambda _: None)
        self.assertTrue(said.startswith("redde-push memory "))
        self.assertEqual(json.loads(said.split(" ", 2)[2])["best"]["name"], "Mem0")
        raw = 'memory save {"items": ["I like tea"], "source": "claude"}'
        said = longterm.slash(["save"] + raw.split()[2:], raw, {}, ["mcp__basic_memory__write_note"], Calls(), lambda _: None)
        self.assertEqual(json.loads(said.split(" ", 2)[2])["stored"], 1)
        self.assertEqual(json.loads(longterm.slash(["save", "{nope"], "memory save {nope", {}, [], Calls(), lambda _: None).split(" ", 2)[2])["error"], "bad_request")

    def test_the_note_is_only_for_the_apps_message(self):
        note = longterm.turn_note("Save to long-term memory:\n- Vegetarian", config={"memory": {"provider": "honcho"}})
        self.assertIn("(Honcho)", note)
        self.assertIn("not the built-in memory tool", note)
        self.assertIsNone(longterm.turn_note("save this to memory please"))
        self.assertIsNone(longterm.turn_note("Save to long-term memory: x", platform="cron"))
        # The app's message isn't "remember that…", so it doesn't also get the USER.md note.
        self.assertIsNone(plugin.remember.turn_note("Save to long-term memory:\n- Vegetarian"))


if __name__ == "__main__":
    unittest.main()

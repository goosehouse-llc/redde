"""python -m unittest discover -s companion/hermes-plugin/tests

Phone tools (redde-push/device.py): a call from the agent waits for the phone's answer, which
comes back through the plugin's command; and the agent is offered only what the phone turned on.
The phone here is a few lines of this file."""
import base64
import importlib.util
import json
import re
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "redde-push"
if "redde_push" in sys.modules:
    plugin = sys.modules["redde_push"]
else:
    spec = importlib.util.spec_from_file_location("redde_push", HERE / "__init__.py", submodule_search_locations=[str(HERE)])
    plugin = importlib.util.module_from_spec(spec)
    sys.modules["redde_push"] = plugin
    spec.loader.exec_module(plugin)
device = plugin.device


def b64(value) -> str:
    return base64.b64encode(json.dumps(value).encode()).decode()


class Calls:
    """A call made on a thread of its own, as the agent makes it, and what it came back with."""

    def __init__(self, phone, tool, args=None, wait=5.0):
        self.result = None
        self.thread = threading.Thread(target=self._run, args=(phone, tool, args or {}, wait), daemon=True)
        self.thread.start()

    def _run(self, phone, tool, args, wait):
        self.result = json.loads(phone.ask(tool, args, session="s1", wait=wait))

    def done(self):
        self.thread.join(5)
        return self.result


def waiting(phone, count=1):
    """What the phone is handed when it asks, once there is that much."""
    deadline = time.time() + 3
    while time.time() < deadline:
        found = phone.waiting()
        if len(found) >= count:
            return found
        time.sleep(0.02)
    return phone.waiting()


class PhoneTools(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.phone = device.Phone(Path(self.home.name))

    def tearDown(self):
        self.home.cleanup()

    def test_nothing_is_offered_until_the_phone_turns_it_on(self):
        self.assertEqual(self.phone.areas(), [])
        self.assertFalse(self.phone.offers("calendar") or self.phone.offers(None))
        self.assertEqual(self.phone.set_areas(["files", "calendar", "teleport"]), ["calendar", "files"])
        self.assertTrue(self.phone.offers("calendar") and self.phone.offers(None))
        self.assertFalse(self.phone.offers("photos"))
        # A call for an area that is off doesn't wait: it says so.
        self.assertIn("turned off", json.loads(self.phone.ask("phone_photos_search", {}, wait=5))["error"])
        self.assertEqual(self.phone.set_areas([]), [])

    def test_a_call_waits_for_the_phones_answer(self):
        self.phone.set_areas(["contacts"])
        call = Calls(self.phone, "phone_contacts_search", {"query": "Dana"})
        asked = waiting(self.phone)
        self.assertEqual(len(asked), 1)
        self.assertEqual({k: asked[0][k] for k in ("tool", "args", "session")},
                         {"tool": "phone_contacts_search", "args": {"query": "Dana"}, "session": "s1"})
        self.assertIsNone(call.result, "it is still waiting")
        self.assertTrue(self.phone.answer(asked[0]["id"], {"ok": True, "result": {"contacts": [{"name": "Dana Whitfield"}]}}))
        self.assertEqual(call.done(), {"contacts": [{"name": "Dana Whitfield"}]})
        # Answered, it is nobody's to answer again, and nothing is left lying about.
        self.assertEqual(self.phone.waiting(), [])
        self.assertFalse(self.phone.answer(asked[0]["id"], {"ok": True, "result": {}}))
        self.assertEqual(list((self.phone.dir / "requests").iterdir()) + list((self.phone.dir / "answers").iterdir()), [])

    def test_a_no_from_the_phone_comes_back_as_words(self):
        self.phone.set_areas(["reminders"])
        call = Calls(self.phone, "phone_reminders_add", {"title": "Renew the car registration"})
        self.phone.answer(waiting(self.phone)[0]["id"], {"ok": False, "error": "The person said no on the iPhone."})
        self.assertEqual(call.done(), {"error": "The person said no on the iPhone."})

    def test_a_phone_that_does_not_answer_is_said_so(self):
        self.phone.set_areas(["calendar"])
        result = json.loads(self.phone.ask("phone_calendar_events", {}, wait=0.4))
        self.assertIn("didn't answer", result["error"])
        self.assertEqual(self.phone.waiting(), [], "the request doesn't outlive the call")

    def test_a_file_from_the_phone_is_kept_here_and_named_by_its_path(self):
        self.phone.set_areas(["photos"])
        call = Calls(self.phone, "phone_photos_get", {"id": "ABC"})
        picture = b"\xff\xd8\xff\xe0 not really a picture"
        self.phone.answer(waiting(self.phone)[0]["id"], {"ok": True, "result": {
            "kind": "photo", "file": {"name": "photo ABC/../x.jpg", "base64": base64.b64encode(picture).decode()}}})
        result = call.done()
        self.assertNotIn("file", result)
        saved = Path(result["file_path"])
        self.assertEqual(saved.read_bytes(), picture)
        self.assertEqual(saved.parent, self.phone.dir / "files", "whatever the phone called it, it is in the plugin's folder")
        self.assertEqual((result["kind"], result["file_bytes"]), ("photo", len(picture)))
        # And the agent is told how to put it in front of the person: a bare path shows nothing.
        self.assertEqual(result["show_with"], "MEDIA:" + result["file_path"])

    def test_two_calls_at_once_get_their_own_answers(self):
        self.phone.set_areas(["calendar", "reminders"])
        first = Calls(self.phone, "phone_calendar_events", {"query": "one"})
        second = Calls(self.phone, "phone_reminders_list", {"list": "two"})
        for asked in waiting(self.phone, 2):
            self.phone.answer(asked["id"], {"ok": True, "result": {"for": asked["tool"]}})
        self.assertEqual(first.done(), {"for": "phone_calendar_events"})
        self.assertEqual(second.done(), {"for": "phone_reminders_list"})

    # ---- the app's command

    def test_the_apps_command(self):
        say = lambda *words: device.slash(self.phone, list(words))
        self.assertEqual(say("status"), "redde-push device status none")
        self.assertEqual(say("areas", "calendar,files"), "redde-push device areas calendar,files")
        self.assertEqual(say("status"), "redde-push device status calendar,files")
        self.assertEqual(json.loads(base64.b64decode(say("next").split()[-1])), [])
        call = Calls(self.phone, "phone_files_list", {"path": "notes"})
        waiting(self.phone)
        listed = json.loads(base64.b64decode(say("next").split()[-1]))
        self.assertEqual([(r["tool"], r["args"]) for r in listed], [("phone_files_list", {"path": "notes"})])
        self.assertEqual(say("done", listed[0]["id"], "not base64 at all!"), "redde-push device refused: that answer can't be read")
        self.assertEqual(say("done", listed[0]["id"], b64({"ok": True, "result": {"entries": []}})), "redde-push device done")
        self.assertEqual(call.done(), {"entries": []})
        self.assertEqual(say("done", listed[0]["id"], b64({"ok": True, "result": {}})), "redde-push device gone")
        self.assertEqual(say("done", "x/y", b64({"ok": True})), "redde-push device gone")
        self.assertEqual(say("areas", "none"), "redde-push device areas none")
        self.assertTrue(say("teleport").startswith("redde-push device: this command is for the Redde app"))
        # Through the plugin's own command, which is what the app runs.
        home = self.home.name
        original = plugin._home
        plugin._home = lambda: Path(home)
        try:
            self.assertEqual(plugin._slash("device areas photos"), "redde-push device areas photos")
        finally:
            plugin._home = original

    # ---- what the agent is offered

    def test_the_tools_are_offered_by_area(self):
        class Context:
            def __init__(self):
                self.tools = {}

            def register_tool(self, name, toolset, schema, handler, check_fn=None, **more):
                self.tools[name] = (toolset, schema, handler, check_fn)

        ctx = Context()
        device.register(ctx, lambda: self.phone)
        self.assertEqual(sorted(ctx.tools), sorted(device.TOOLS))
        for name, (toolset, schema, handler, check) in ctx.tools.items():
            self.assertEqual(toolset, "redde_phone")
            self.assertEqual(schema["name"], name)
            self.assertEqual(schema["parameters"]["type"], "object")
            self.assertTrue(set(schema["parameters"]["required"]) <= set(schema["parameters"]["properties"]), name)
            self.assertTrue(schema["description"].startswith("Runs on the user's iPhone"), name)
            self.assertFalse(check(), f"{name} is offered with everything off")
        self.phone.set_areas(["files"])
        offered = sorted(name for name, (_, _, _, check) in ctx.tools.items() if check())
        self.assertEqual(offered, ["phone_files_delete", "phone_files_list", "phone_files_read", "phone_files_write", "phone_info"])
        # Hermes before 0.21.5 hands every tool the turn's ids, wanted or not.
        call = threading.Thread(target=lambda: ctx.tools["phone_files_list"][2]({"path": ""}, task_id="t", session_id="s9", user_task=None), daemon=True)
        call.start()
        asked = waiting(self.phone)
        self.assertEqual(asked[0]["session"], "s9")
        self.phone.answer(asked[0]["id"], {"ok": True, "result": {}})
        call.join(5)

    def test_photos_can_be_asked_for_by_what_they_show(self):
        area, description, properties, required = device.TOOLS["phone_photos_search"]
        self.assertEqual(area, "photos")
        self.assertIn("query", properties)
        self.assertEqual(required, [], "by date alone, as before")
        self.assertIn("not_looked_at", description)

    def test_the_names_are_the_ones_the_app_and_the_manifest_know(self):
        manifest = (HERE / "plugin.yaml").read_text()
        listed = re.findall(r"^  - (phone_\w+)$", manifest, re.M)
        self.assertEqual(sorted(listed), sorted(device.TOOLS))
        app = HERE.parent.parent.parent / "Echo" / "Services" / "DeviceTools" / "DeviceTools.swift"
        if app.exists():   # (the plugin's folder on its own, as Hermes installs it, has no app beside it)
            known = re.findall(r'case \w+ = "(phone_\w+)"', app.read_text())
            self.assertEqual(sorted(known), sorted(device.TOOLS))
            areas = re.search(r"case ([\w, ]+)\n\n    var id: String", app.read_text())
            self.assertEqual(tuple(a.strip() for a in areas.group(1).split(",")), device.AREAS)


if __name__ == "__main__":
    unittest.main()

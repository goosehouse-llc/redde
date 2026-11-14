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

    def test_a_scheduled_jobs_run_is_told_at_once_that_the_phone_cant_be_reached(self):
        """2026-11-04: Morning Ideas asked the phone from its run, waited two minutes a call, tried again."""
        self.phone.set_areas(["calendar"])
        started = time.monotonic()
        result = json.loads(self.phone.ask("phone_calendar_events", {}, session="cron_925a79849c90_20261104_073012"))
        self.assertLess(time.monotonic() - started, 1)
        self.assertIn("scheduled job", result["error"])
        self.assertIn("don't call phone tools again", result["error"])
        self.assertEqual(self.phone.waiting(), [], "no request is left for a phone that never comes")
        # One with a way round it takes that way (the widget, by notification).
        self.assertEqual(self.phone.ask("phone_calendar_events", {}, session="cron_925a79849c90_20261104_073012",
                                        otherwise=lambda: "by note"), "by note")
        # A chat's turn still waits for the phone.
        self.assertIn("didn't answer", json.loads(self.phone.ask("phone_calendar_events", {}, session="20261104_073012_ab12cd", wait=0.3))["error"])

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
            self.assertIn("iPhone", schema["description"], name)   # (the calendar's leads with what it's for)
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

    def test_alarms_are_set_as_an_alarm_at_a_time_or_a_timer_from_now(self):
        area, description, properties, required = device.TOOLS["phone_alarms_set"]
        self.assertEqual(area, "alarms")
        self.assertEqual(required, ["title"], "at or minutes, whichever it is, is the phone's to check")
        self.assertEqual({"title", "at", "minutes"}, set(properties))
        self.assertEqual(properties["minutes"]["type"], "number", "half a minute is a timer too")
        self.assertIn("confirm", description)
        self.assertIn("confirm", device.TOOLS["phone_alarms_cancel"][1])
        self.phone.set_areas(["alarms"])
        self.assertTrue(self.phone.offers("alarms") and not self.phone.offers("files"))

    def test_a_call_and_a_message_are_the_persons_to_let_go(self):
        area, description, properties, required = device.TOOLS["phone_people_call"]
        self.assertEqual((area, required), ("people", ["to"]))
        self.assertIn("asks the user to confirm", description)
        self.assertEqual(properties["kind"]["enum"], ["phone", "facetime", "facetime_audio"])
        area, description, properties, required = device.TOOLS["phone_people_message"]
        self.assertEqual((area, required), ("people", ["to", "text"]))
        self.assertIn("taps Send", description)
        self.assertIn("can't read their messages", description)

    # ---- the widget, which a phone that isn't following the turn hears of by notification

    def _widget(self, sent, wait=0.3):
        """The agent's two widget tools, with what goes by notification kept in `sent`."""
        class Context:
            def __init__(self):
                self.tools = {}

            def register_tool(self, name, toolset, schema, handler, check_fn=None, **more):
                self.tools[name] = handler

        def to_widget(title, text, start, end):
            sent.append((title, text, start, end))
            return 1

        ctx = Context()
        device.register(ctx, lambda: self.phone, to_widget=to_widget)
        self.phone.set_areas(["widget"])
        before, device.WIDGET_WAIT = device.WIDGET_WAIT, wait
        self.addCleanup(setattr, device, "WIDGET_WAIT", before)
        return ctx.tools

    def test_what_is_written_for_the_widget_goes_by_notification_when_no_phone_is_following(self):
        sent = []
        tools = self._widget(sent)
        answer = json.loads(tools["phone_widget_set"]({"title": "Today", "text": "9:30 standup", "until": "2026-10-14T17:00"}, session_id="cron-1"))
        self.assertEqual(sent, [("Today", "9:30 standup", "", "2026-10-14T17:00")])
        self.assertEqual(answer["phones"], 1)
        self.assertIn("notification", answer["sent"])
        self.assertEqual(self.phone.waiting(), [], "the request isn't left for a phone to find later")
        json.loads(tools["phone_widget_clear"]({}))
        self.assertEqual(sent[-1], ("", "", "", ""), "nothing in it: the widget is cleared")

    def test_a_phone_that_is_following_writes_it_itself_and_nothing_is_sent(self):
        sent = []
        tools = self._widget(sent, wait=5.0)
        result = {}
        call = threading.Thread(target=lambda: result.update(json.loads(tools["phone_widget_set"]({"text": "Build 381 is green"}, session_id="s1"))), daemon=True)
        call.start()
        asked = waiting(self.phone)
        self.assertEqual((asked[0]["tool"], asked[0]["args"]), ("phone_widget_set", {"text": "Build 381 is green"}))
        self.phone.answer(asked[0]["id"], {"ok": True, "result": {"showing": {"text": "Build 381 is green"}}})
        call.join(5)
        self.assertEqual(result["showing"]["text"], "Build 381 is green")
        self.assertEqual(sent, [])

    def test_what_the_phone_could_not_show_is_not_sent(self):
        sent = []
        tools = self._widget(sent)
        self.assertIn("nothing to write", json.loads(tools["phone_widget_set"]({"text": " "}))["error"])
        self.assertIn("isn't a date", json.loads(tools["phone_widget_set"]({"text": "x", "at": "soon"}))["error"])
        self.assertEqual(sent, [])
        # And with no phone paired there is nowhere to send it.
        self.assertIn("isn't paired", json.loads(device.widget_by_note("phone_widget_set", {"text": "x"}, lambda *a: 0))["error"])
        self.assertIn("isn't paired", json.loads(device.widget_by_note("phone_widget_set", {"text": "x"}, None))["error"])

    def test_the_note_for_the_widget_says_what_and_when_as_written(self):
        core = plugin.core
        made = core.widget_note("Today", "9:30 standup", "2026-10-14T07:00", "2026-10-14T17:00")
        self.assertEqual((made["k"], made["t"], made["b"], made["f"], made["u"]), ("widget", "Today", "9:30 standup", "2026-10-14T07:00", "2026-10-14T17:00"))
        cleared = core.widget_note()
        self.assertFalse({"t", "b", "f", "u"} & set(cleared))
        phone = {"id": "dev-1", "key": core.b64u(bytes(32))}
        self.assertEqual(core.collapse_id(phone, made), core.collapse_id(phone, cleared), "each takes the last one's place on the phone")
        self.assertEqual(core.TTL["widget"], 43200)
        self.assertLessEqual(len(core.sealed(phone, core.widget_note("t" * 200, "x" * 2000))), 3600)

    def test_photos_can_be_asked_for_by_what_they_show(self):
        area, description, properties, required = device.TOOLS["phone_photos_search"]
        self.assertEqual(area, "photos")
        self.assertIn("query", properties)
        self.assertEqual(required, [], "by date alone, as before")
        self.assertIn("not_looked_at", description)

    def test_a_bot_has_areas_of_its_own(self):
        # A bot's home is <main>/profiles/<name>: its requests go where the app's command looks.
        bot = device.Phone(Path(self.home.name) / "profiles" / "health")
        self.assertEqual((bot.profile, bot.dir), ("health", self.phone.dir))
        self.phone.set_areas(["calendar", "health"])
        # Until the phone says anything about bots (an older Redde), a bot has none.
        self.assertEqual(bot.areas(), [])
        self.assertFalse(bot.offers(None) or bot.offers("health"))
        self.assertIn("Edit Bot", json.loads(bot.ask("phone_health_read", {"type": "steps"}, wait=5))["error"])
        # Then one it doesn't name has the calendar and reminders, of the main agent's (1.25.0).
        self.assertEqual(device.slash(self.phone, ["bots", "none"]), "redde-push device bots none")
        self.assertEqual(bot.areas(), ["calendar"])
        self.phone.set_areas(["calendar", "reminders", "health"])
        self.assertEqual(bot.areas(), ["calendar", "reminders"])
        self.phone.set_areas(["calendar", "health"])
        said = device.slash(self.phone, ["bots", "health=health,teleport", "scout=none", "bad/name=calendar"])
        self.assertTrue(said.startswith("redde-push device refused"))
        self.assertEqual(device.slash(self.phone, ["bots", "health=health,teleport", "scout=none"]),
                         "redde-push device bots health=health scout=none")
        self.assertEqual(bot.areas(), ["health"])
        self.assertTrue(bot.offers("health") and not bot.offers("calendar"))
        # One given none keeps none; one it never named keeps the default.
        self.assertEqual(device.Phone(Path(self.home.name) / "profiles" / "scout").areas(), [])
        self.assertEqual(device.Phone(Path(self.home.name) / "profiles" / "other").areas(), ["calendar"])
        # Never more than the main agent's.
        device.slash(self.phone, ["bots", "health=health,contacts"])
        self.assertEqual(bot.areas(), ["health"])
        self.assertEqual(self.phone.areas(), ["calendar", "health"])   # the main agent's stay as they were
        # Its call waits in the main folder, saying whose it is.
        call = Calls(bot, "phone_health_read", {"type": "steps"})
        request = waiting(self.phone)[0]
        self.assertEqual((request["tool"], request["profile"]), ("phone_health_read", "health"))
        self.assertEqual(device.slash(self.phone, ["done", request["id"], b64({"ok": True, "result": {"value": 9000}})]), "redde-push device done")
        self.assertEqual(call.done(), {"value": 9000})
        # The main agent's requests say so too.
        call = Calls(self.phone, "phone_calendar_events")
        self.assertEqual(waiting(self.phone)[0]["profile"], "default")
        device.slash(self.phone, ["done", waiting(self.phone)[0]["id"], b64({"ok": True, "result": {}})])
        call.done()
        # The whole list is replaced each time; `none` clears it, back to the default.
        self.assertEqual(device.slash(self.phone, ["bots", "none"]), "redde-push device bots none")
        self.assertEqual(bot.areas(), ["calendar"])

    def test_health_is_read_only_offered_alone_and_small(self):
        area, description, properties, required = device.TOOLS["phone_health_read"]
        self.assertEqual(area, "health")
        self.assertEqual(required, ["type"])
        self.assertEqual(properties["type"]["enum"], list(device.HEALTH_TYPES))
        self.assertIn("read only", description)
        self.assertIn("health_shared", description)
        # Offered only with Health on, and then its schema rides on every prompt: kept small.
        schema = {"name": "phone_health_read", "description": description,
                  "parameters": {"type": "object", "properties": properties, "required": required}}
        # (1.24.0: 37 kinds, the Watch's added; the list is what keeps the agent to names that exist.)
        self.assertLess(len(json.dumps(schema)), 1800)
        self.phone.set_areas(["health"])
        self.assertTrue(self.phone.offers("health"))
        self.assertFalse(self.phone.offers("calendar"))
        # The kinds are the app's, in its order.
        app = HERE.parent.parent.parent / "Echo" / "Services" / "DeviceTools" / "DeviceHealth.swift"
        if app.exists():
            body = app.read_text().split("nonisolated enum HealthKind", 1)[1].split("var id: String", 1)[0]
            kinds = [raw or name for name, raw in re.findall(r'case (\w+)(?: = "(\w+)")?', body)]
            self.assertEqual(tuple(kinds), device.HEALTH_TYPES)

    def test_apple_home_is_offered_alone_and_small(self):
        names = ("phone_home_list", "phone_home_set", "phone_home_scene")
        for name in names:
            self.assertEqual(device.TOOLS[name][0], "home")
        # Offered only with Apple Home on, and then all three ride on every prompt: kept small.
        size = sum(len(json.dumps({"name": n, "description": device.TOOLS[n][1], "parameters": {
            "type": "object", "properties": device.TOOLS[n][2], "required": device.TOOLS[n][3]}})) for n in names)
        self.assertLess(size, 2600)
        # The guard is the phone's, and the agent is told of it.
        self.assertIn("Locks, garage doors", device.TOOLS["phone_home_set"][1])
        self.assertIn("entity", device.TOOLS["phone_home_list"][1])
        self.phone.set_areas(["home"])
        self.assertTrue(self.phone.offers("home"))
        self.assertFalse(self.phone.offers("health"))

    def test_maps_is_offered_alone_and_small(self):
        names = ("phone_maps_search", "phone_maps_directions", "phone_maps_open")
        for name in names:
            self.assertEqual(device.TOOLS[name][0], "maps")
        size = sum(len(json.dumps({"name": n, "description": device.TOOLS[n][1], "parameters": {
            "type": "object", "properties": device.TOOLS[n][2], "required": device.TOOLS[n][3]}})) for n in names)
        self.assertLess(size, 2600)
        self.phone.set_areas(["maps"])
        self.assertTrue(self.phone.offers("maps"))
        self.assertFalse(self.phone.offers("home"))

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


class CopyOfThePhone(unittest.TestCase):
    """Tests for the read-only copy of calendar and reminders (issue 50)."""

    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.phone = device.Phone(Path(self.home.name))

    def tearDown(self):
        self.home.cleanup()

    def _sync(self, kind, items):
        """Helper to sync a copy via slash."""
        payload = {device._COPY_KEY[kind]: items}
        return device.slash(self.phone, ["sync", kind, b64(payload)])

    def _fresh_calendar(self):
        """Return a calendar copy with items at various times."""
        now = time.time()
        day = 86400
        return [
            {"title": "Meeting", "start": "2026-11-04T10:00", "start_ts": now + day},
            {"title": "Lunch", "start": "2026-11-06T12:00", "start_ts": now + 3 * day},
            {"title": "Past event", "start": "2026-11-01T09:00", "start_ts": now - day},
            {"title": "Robert's birthday", "start": "2026-11-05T18:00", "start_ts": now + 2 * day},
        ]

    def _fresh_reminders(self):
        """Return a reminders copy with various items."""
        now = time.time()
        day = 86400
        return [
            {"title": "Buy milk", "due": "2026-11-04T09:00", "due_ts": now + day, "list": "Shopping", "completed": False},
            {"title": "Call mom", "due": "2026-11-06T14:00", "due_ts": now + 3 * day, "list": "Personal", "completed": False},
            {"title": "Done task", "due": "2026-11-03T08:00", "due_ts": now, "list": "Shopping", "completed": True},
            {"title": "No due date", "list": "Personal", "completed": False},
        ]

    # 1. A fresh copy answers at once

    def test_fresh_copy_answers_at_once(self):
        """A fresh copy answers without bothering the phone."""
        self.phone.set_areas(["calendar", "reminders"])
        items = self._fresh_calendar()
        result = self._sync("calendar", items)
        self.assertEqual(result, "redde-push device sync calendar 4")
        answer = json.loads(self.phone.read("phone_calendar_events", {}))
        # The default window is now to a week on: the past event is not in it, soonest first.
        self.assertEqual([e["title"] for e in answer["events"]],
                         ["Meeting", "Robert's birthday", "Lunch"])
        self.assertNotIn("start_ts", answer["events"][0])  # stripped
        self.assertIn("synced_minutes_ago", answer)
        self.assertLessEqual(answer["synced_minutes_ago"], 1)
        self.assertEqual(self.phone.waiting(), [])  # phone was never asked

    # 2. Filters mirror the tool promises

    def test_filters_mirror_tool_promises(self):
        """Filters: query, limit, explicit start/end, date-only end."""
        self.phone.set_areas(["calendar"])
        items = self._fresh_calendar()
        self._sync("calendar", items)
        # Query filter
        answer = json.loads(self.phone.read("phone_calendar_events", {"query": "robert"}))
        self.assertEqual(len(answer["events"]), 1)
        self.assertEqual(answer["events"][0]["title"], "Robert's birthday")
        # Limit filter
        answer = json.loads(self.phone.read("phone_calendar_events", {"limit": 1}))
        self.assertEqual(len(answer["events"]), 1)
        self.assertEqual(answer["more"], 2)  # the window holds three; one is kept
        # Explicit start/end narrows the window
        from datetime import datetime
        birthday = datetime.fromtimestamp(time.time() + 2 * 86400).strftime("%Y-%m-%d")
        answer = json.loads(self.phone.read("phone_calendar_events", {
            "start": f"{birthday}T00:00", "end": f"{birthday}T23:59"
        }))
        self.assertEqual(len(answer["events"]), 1)
        self.assertEqual(answer["events"][0]["title"], "Robert's birthday")
        # Date-only end means the whole of that day
        answer = json.loads(self.phone.read("phone_calendar_events", {
            "start": birthday, "end": birthday
        }))
        self.assertEqual(len(answer["events"]), 1)
        self.assertEqual(answer["events"][0]["title"], "Robert's birthday")

    def test_a_search_matches_any_word_and_looks_a_year_ahead(self):
        """The agent searches in its own words ("dad flight Lisbon"); an event has one of them,
        and may be months away (a December flight asked about weeks ahead, 11-10)."""
        _matches, _span = device._matches, device._span
        flight = {"title": "NW 238 to Lisbon", "location": "Gate 12", "notes": "Dad's flight"}
        self.assertTrue(_matches(flight, "dad flight lisbon"))
        self.assertTrue(_matches(flight, "when is the flight"))
        self.assertFalse(_matches(flight, "dentist"))
        self.assertTrue(_matches({"title": "PT"}, "pt"))       # short query: as a whole
        start, end = _span({"query": "flight"})
        self.assertGreater(end - start, 360 * 86400)
        start, end = _span({})
        self.assertAlmostEqual(end - start, 7 * 86400, delta=5)

    def test_an_older_app_is_asked_for_a_year_and_word_by_word(self):
        """Redde 2.4 (293) looks a week ahead with no end and for the whole search: the plugin
        gives it the end, and asks word by word when the whole search finds nothing (11-10)."""
        self.phone.set_areas(["calendar"])
        flight = {"title": "Dad arrives NW 238", "start": "2026-12-17T12:41:00-05:00"}
        asked, result = [], {}
        reader = threading.Thread(target=lambda: result.update(json.loads(
            self.phone.read("phone_calendar_events", {"query": "dad flight"}, session="s1", wait=5))), daemon=True)
        reader.start()
        deadline = time.monotonic() + 10
        while reader.is_alive() and time.monotonic() < deadline:
            for request in self.phone.waiting():
                args = request["args"]
                asked.append(args)
                found = [flight] if args["query"].lower() in flight["title"].lower() else []   # the whole phrase, as 2.4 does
                self.phone.answer(request["id"], {"ok": True, "result": {"events": found, "more": 0}})
            time.sleep(0.05)
        reader.join(1)
        self.assertEqual(result.get("events"), [flight])
        self.assertEqual(asked[0]["query"], "dad flight")
        self.assertTrue(all(re.fullmatch(r"\d{4}-\d{2}-\d{2}", a["end"]) for a in asked), asked)
        self.assertGreater(device._epoch(asked[0]["end"]) - time.time(), 360 * 86400)
        self.assertEqual(sorted(a["query"] for a in asked[1:]), ["dad", "flight"])

    def test_a_newer_app_that_finds_it_is_asked_once(self):
        self.phone.set_areas(["calendar"])
        result = {}
        reader = threading.Thread(target=lambda: result.update(json.loads(
            self.phone.read("phone_calendar_events", {"query": "dad flight", "end": "2026-12-31"}, session="s1", wait=5))), daemon=True)
        reader.start()
        request = waiting(self.phone)[0]
        self.assertEqual(request["args"]["end"], "2026-12-31", "an end the agent gave is kept")
        self.phone.answer(request["id"], {"ok": True, "result": {"events": [{"title": "Dad arrives"}], "more": 0}})
        reader.join(5)
        self.assertEqual(result["events"], [{"title": "Dad arrives"}])
        self.assertEqual(self.phone.waiting(), [])

    def test_guessed_argument_names_are_taken_and_others_are_named(self):
        """Sol guessed since/until for start/end and was answered the coming week six times (11-10)."""
        fixed, ignored = device._calendar_args({"since": "2027-07-01", "until": "2027-07-31", "search": "flight", "colour": "red"})
        self.assertEqual(fixed, {"start": "2027-07-01", "end": "2027-07-31", "query": "flight"})
        self.assertEqual(ignored, ["colour"])
        fixed, _ = device._calendar_args({"date": "2027-07-08"})
        self.assertEqual(fixed, {"start": "2027-07-08", "end": "2027-07-08"})
        fixed, _ = device._calendar_args({"start": "2027-07-08T09:00", "from": "2026-01-01"})
        self.assertEqual(fixed, {"start": "2027-07-08T09:00"}, "the tool's own name wins")
        noted = json.loads(device._noting(json.dumps({"events": []}), ["colour"]))
        self.assertIn("colour", noted["ignored"])
        self.assertIn("start and end", noted["ignored"])
        self.assertEqual(device._noting('{"events": []}', []), '{"events": []}')
        # A day a copy can't reach is asked of the phone with the right names.
        self.phone.set_areas(["calendar"])
        result = {}
        args, _ = device._calendar_args({"since": "2027-07-08", "until": "2027-07-08"})
        reader = threading.Thread(target=lambda: result.update(json.loads(
            self.phone.read("phone_calendar_events", args, session="s1", wait=5))), daemon=True)
        reader.start()
        request = waiting(self.phone)[0]
        self.assertEqual((request["args"]["start"], request["args"]["end"]), ("2027-07-08", "2027-07-08"))
        self.phone.answer(request["id"], {"ok": True, "result": {"events": [{"title": "Flight"}], "more": 0}})
        reader.join(5)
        self.assertEqual(result["events"], [{"title": "Flight"}])

    # 3. Reminders copy

    def test_reminders_copy(self):
        """Reminders: drop completed unless include_completed, list filter, sort."""
        self.phone.set_areas(["reminders"])
        items = self._fresh_reminders()
        self._sync("reminders", items)
        # Drop completed by default
        answer = json.loads(self.phone.read("phone_reminders_list", {}))
        self.assertEqual(len(answer["reminders"]), 3)
        self.assertNotIn("Done task", [r["title"] for r in answer["reminders"]])
        # include_completed
        answer = json.loads(self.phone.read("phone_reminders_list", {"include_completed": True}))
        self.assertEqual(len(answer["reminders"]), 4)
        # List filter by name
        answer = json.loads(self.phone.read("phone_reminders_list", {"list": "Shopping"}))
        self.assertEqual(len(answer["reminders"]), 1)
        self.assertEqual(answer["reminders"][0]["title"], "Buy milk")
        # No-due last, soonest due first
        titles = [r["title"] for r in answer["reminders"]]
        self.assertEqual(titles, ["Buy milk"])
        # more counts
        answer = json.loads(self.phone.read("phone_reminders_list", {"list": "Personal", "limit": 1}))
        self.assertEqual(len(answer["reminders"]), 1)
        self.assertEqual(answer["more"], 1)

    # 4. live asks the phone

    def test_live_asks_the_phone(self):
        """A fresh copy + live=True asks the phone."""
        self.phone.set_areas(["calendar"])
        items = self._fresh_calendar()
        self._sync("calendar", items)
        # Start a call on a thread
        call = Calls(self.phone, "phone_calendar_events", {}, wait=5.0)
        # Wait for the phone to be asked
        asked = waiting(self.phone, 1)
        self.assertEqual(len(asked), 1)
        self.assertEqual(asked[0]["tool"], "phone_calendar_events")
        # The live argument should not be in the args
        self.assertNotIn("live", asked[0]["args"])
        # Answer the call
        self.phone.answer(asked[0]["id"], {"ok": True, "result": {"events": [{"title": "Live answer"}]}})
        result = call.done()
        self.assertEqual(result["events"][0]["title"], "Live answer")

    # 5. A stale copy answers only when the phone doesn't

    def test_stale_copy_answers_when_phone_doesnt(self):
        """A stale copy answers only when the phone doesn't."""
        self.phone.set_areas(["calendar"])
        items = self._fresh_calendar()
        self._sync("calendar", items)
        # Monkeypatch CACHE_FRESH to 0 so the copy is always stale
        before = device.CACHE_FRESH
        device.CACHE_FRESH = 0
        self.addCleanup(setattr, device, "CACHE_FRESH", before)
        # Read on a thread, with a short wait so the phone won't answer in time: while it
        # waits the phone was asked, and what comes back is the copy with a note.
        got = {}

        def read():
            got["answer"] = json.loads(self.phone.read("phone_calendar_events", {}, wait=0.3))

        thread = threading.Thread(target=read, daemon=True)
        thread.start()
        asked = waiting(self.phone, 1)
        self.assertEqual(asked[0]["tool"], "phone_calendar_events")
        thread.join(5)
        answer = got["answer"]
        self.assertIn("events", answer)
        self.assertIn("note", answer)
        self.assertIn("copy", answer["note"].lower())

    # Days a copy doesn't cover (1.25.1): asked of the phone, never "nothing on"

    def _sync_covering(self, items, since, until):
        from datetime import datetime
        payload = {"events": items, "from": datetime.fromtimestamp(since).isoformat(), "to": datetime.fromtimestamp(until).isoformat()}
        return device.slash(self.phone, ["sync", "calendar", b64(payload)])

    def _read_beyond(self, args, wait=0.3, session=None):
        got = {}

        def read():
            got["answer"] = json.loads(self.phone.read("phone_calendar_events", dict(args), session=session, wait=wait))

        thread = threading.Thread(target=read, daemon=True)
        thread.start()
        return thread, got

    def test_a_day_past_the_copy_is_asked_of_the_phone(self):
        """A fresh copy that ends before the day asked about doesn't call that day empty: the phone
        is asked, and its answer is the answer."""
        from datetime import datetime
        self.phone.set_areas(["calendar"])
        now = time.time()
        self.assertEqual(self._sync_covering(self._fresh_calendar(), now - 7 * 86400, now + 10 * 86400),
                         "redde-push device sync calendar 4")
        # Inside it: at once, from the copy.
        inside = datetime.fromtimestamp(now + 2 * 86400).strftime("%Y-%m-%d")
        answer = json.loads(self.phone.read("phone_calendar_events", {"start": inside, "end": inside}))
        self.assertEqual([e["title"] for e in answer["events"]], ["Robert's birthday"])
        self.assertNotIn("note", answer)
        self.assertEqual(self.phone.waiting(), [])
        # Past it: the phone.
        later = datetime.fromtimestamp(now + 37 * 86400).strftime("%Y-%m-%d")
        thread, got = self._read_beyond({"start": later, "end": later}, wait=5)
        asked = waiting(self.phone, 1)
        self.assertEqual(asked[0]["args"], {"start": later, "end": later})
        self.phone.answer(asked[0]["id"], {"ok": True, "result": {"events": [{"title": "Clinic"}]}})
        thread.join(5)
        self.assertEqual(got["answer"]["events"][0]["title"], "Clinic")

    def test_a_day_past_the_copy_with_no_phone_says_it_isnt_known(self):
        """The phone not answering, the copy says what it has and that the rest isn't known."""
        from datetime import datetime
        self.phone.set_areas(["calendar"])
        now = time.time()
        self._sync_covering(self._fresh_calendar(), now - 7 * 86400, now + 10 * 86400)
        later = datetime.fromtimestamp(now + 37 * 86400).strftime("%Y-%m-%d")
        thread, got = self._read_beyond({"start": later, "end": later})
        waiting(self.phone, 1)
        thread.join(5)
        self.assertEqual(got["answer"]["events"], [])
        self.assertIn("only covers", got["answer"]["note"])
        self.assertIn("Don't call those days free", got["answer"]["note"])
        # A scheduled run, with no phone to ask: the same, at once.
        answer = json.loads(self.phone.read("phone_calendar_events", {"start": later, "end": later},
                                            session="cron_ab12cd34_20261104_070000", wait=30))
        self.assertIn("only covers", answer["note"])

    def test_an_older_apps_full_copy_ends_at_its_last_event(self):
        """A copy with no days said, holding as many as an older app sent, covers only to its
        last event; a smaller one, to a month on."""
        self.phone.set_areas(["calendar"])
        now = time.time()
        full = [{"title": f"Visit {n}", "start_ts": now + n * 3600} for n in range(device._COPY_FULL)]
        self._sync("calendar", full)
        held = self.phone.copy("calendar")
        self.assertAlmostEqual(held["to_ts"], now + (device._COPY_FULL - 1) * 3600, delta=1)
        self._sync("calendar", self._fresh_calendar())
        held = self.phone.copy("calendar")
        self.assertAlmostEqual(held["to_ts"], held["at"] + device._COPY_AFTER, delta=1)
        self.assertAlmostEqual(held["from_ts"], held["at"] - device._COPY_BEFORE, delta=1)

    def test_a_scheduled_run_answers_from_any_copy_at_once(self):
        """A scheduled job's run has no phone following it: an old copy answers at once, with
        its note, and nothing is left for a phone to collect."""
        self.phone.set_areas(["calendar"])
        self._sync("calendar", self._fresh_calendar())
        before = device.CACHE_FRESH
        device.CACHE_FRESH = 0
        self.addCleanup(setattr, device, "CACHE_FRESH", before)
        started = time.monotonic()
        answer = json.loads(self.phone.read("phone_calendar_events", {}, session="cron_ab12cd34_20261104_070000", wait=30))
        self.assertLess(time.monotonic() - started, 2)
        self.assertIn("note", answer)
        self.assertEqual([e["title"] for e in answer["events"]], ["Meeting", "Robert's birthday", "Lunch"])
        self.assertEqual(self.phone.waiting(), [])

    def test_a_scheduled_run_with_no_copy_hears_at_once(self):
        """With no copy, a scheduled run hears at once that the phone can't be reached."""
        self.phone.set_areas(["calendar"])
        started = time.monotonic()
        answer = json.loads(self.phone.read("phone_calendar_events", {}, session="cron_ab12cd34_20261104_070000", wait=30))
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(answer["error"], device.NO_PHONE_IN_A_JOB)

    def test_the_shape_the_phone_hands_over(self):
        """The app sends what its tools describe: ISO date strings with the phone's own
        offset, not numeric timestamps — the copy still windows and sorts right."""
        from datetime import datetime, timedelta
        self.phone.set_areas(["calendar", "reminders"])
        now = datetime.now().astimezone()
        def when(days):
            return (now + timedelta(days=days)).isoformat()
        self._sync("calendar", [
            {"id": "a", "title": "Dentist", "start": when(1), "end": when(1), "all_day": False, "calendar": "Personal"},
            {"id": "b", "title": "Gym", "start": when(3), "end": when(3), "all_day": False, "calendar": "Personal"},
        ])
        self._sync("reminders", [{"id": "r", "title": "Milk", "list": "Shopping", "completed": False, "due": when(2)}])
        answer = json.loads(self.phone.read("phone_calendar_events", {}))
        self.assertEqual([e["title"] for e in answer["events"]], ["Dentist", "Gym"])
        answer = json.loads(self.phone.read("phone_reminders_list", {}))
        self.assertEqual(answer["reminders"][0]["title"], "Milk")

    # 6. Turning an area off takes the copy

    def test_turning_area_off_takes_the_copy(self):
        """Turning an area off takes its copy."""
        self.phone.set_areas(["calendar", "reminders"])
        items = self._fresh_calendar()
        self._sync("calendar", items)
        # Verify the copy exists
        self.assertIsNotNone(self.phone.copy("calendar"))
        # Turn off calendar
        self.phone.set_areas(["reminders"])
        # The copy should be gone
        self.assertIsNone(self.phone.copy("calendar"))
        # read should give the "turned off" error
        answer = json.loads(self.phone.read("phone_calendar_events", {}))
        self.assertIn("turned off", answer["error"])

    # 7. cache status / cache wipe

    def test_cache_status_and_wipe(self):
        """cache status and cache wipe."""
        self.phone.set_areas(["calendar", "reminders"])
        # Both off initially
        result = device.slash(self.phone, ["cache", "status"])
        self.assertIn("calendar off", result)
        self.assertIn("reminders off", result)
        # Sync a copy
        self._sync("calendar", self._fresh_calendar())
        result = device.slash(self.phone, ["cache", "status"])
        self.assertIn("calendar", result)
        self.assertIn("reminders off", result)
        # An empty calendar is a real calendar: an empty copy syncs and shows as 0 items.
        self.assertEqual(self._sync("calendar", []), "redde-push device sync calendar 0")
        self.assertEqual(len(json.loads(self.phone.read("phone_calendar_events", {}))["events"]), 0)
        # Wipe just calendar
        result = device.slash(self.phone, ["cache", "wipe", "calendar"])
        self.assertEqual(result, "redde-push device cache wiped")
        result = device.slash(self.phone, ["cache", "status"])
        self.assertIn("calendar off", result)
        # Bad kind is refused
        result = device.slash(self.phone, ["cache", "wipe", "photos"])
        self.assertIn("refused", result)

    # 8. Bad syncs refused

    def test_bad_syncs_refused(self):
        """Bad syncs are refused."""
        # >CACHE_MAX payload
        big_items = [{"title": f"item{i}", "start": "2026-11-04T10:00"} for i in range(1000)]
        result = self._sync("calendar", big_items)
        self.assertIn("too big", result)
        # Non-base64 junk
        result = device.slash(self.phone, ["sync", "calendar", "not base64!"])
        self.assertIn("refused", result)
        # Non-list value
        result = device.slash(self.phone, ["sync", "calendar", b64({"events": "not a list"})])
        self.assertIn("refused", result)
        # Kind photos is refused
        result = device.slash(self.phone, ["sync", "photos", b64({"photos": []})])
        self.assertIn("refused", result)
        # A copy item without a string title is dropped, not fatal
        items = [
            {"title": "Valid", "start": "2026-11-04T10:00"},
            {"start": "2026-11-04T11:00"},  # no title
            {"title": 123, "start": "2026-11-04T12:00"},  # non-string title
        ]
        result = self._sync("calendar", items)
        self.assertEqual(result, "redde-push device sync calendar 1")


if __name__ == "__main__":
    unittest.main()

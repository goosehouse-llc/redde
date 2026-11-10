"""Workstreams (`work.py`): python -m unittest discover -s companion/hermes-plugin/tests"""
import importlib.util
import json
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "redde-push"
if "redde_push" not in sys.modules:
    spec = importlib.util.spec_from_file_location("redde_push", HERE / "__init__.py", submodule_search_locations=[str(HERE)])
    plugin = importlib.util.module_from_spec(spec)
    sys.modules["redde_push"] = plugin
    spec.loader.exec_module(plugin)
plugin = sys.modules["redde_push"]
work, core = plugin.work, plugin.core


class StdioTransport:
    pass


class FakeServer:
    """Hermes's session methods as `hermes serve` has them, in memory: what was called, with what."""

    class _DropTransport:
        def write(self, obj):
            return False

    def __init__(self):
        self._sessions, self._sessions_lock, self.calls, self.next = {}, threading.Lock(), [], 0
        self.refuse: set[str] = set()
        self._methods = {name: self._handler(name) for name in
                         ("session.create", "session.resume", "prompt.submit", "session.steer", "session.interrupt", "session.close")}

    def _handler(self, name):
        def handle(rid, params):
            self.calls.append((name, dict(params), threading.current_thread().name))
            if name in self.refuse:
                return {"error": {"code": 4000, "message": f"{name} refused"}}
            if name == "session.create":
                self.next += 1
                sid, key = f"rt{self.next}", f"stored{self.next}"
                self._sessions[sid] = {"session_key": key, "running": False, "transport": StdioTransport(), "title": params.get("title")}
                return {"result": {"session_id": sid, "stored_session_id": key}}
            if name == "session.resume":
                self.next += 1
                sid = f"rt{self.next}"
                self._sessions[sid] = {"session_key": params["session_id"], "running": False, "transport": StdioTransport()}
                return {"result": {"session_id": sid}}
            if name == "prompt.submit":
                self._sessions[params["session_id"]]["running"] = True
                return {"result": {"status": "streaming"}}
            return {"result": {}}
        return handle


class WorkTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.home = Path(self.dir.name) / "profiles" / "coder"
        self.home.mkdir(parents=True)
        self.server = FakeServer()
        sys.modules["tui_gateway.server"] = self.server

    def tearDown(self):
        sys.modules.pop("tui_gateway.server", None)
        self.dir.cleanup()

    def start(self, title="Fix the build", brief="The build fails on main; find out why and fix it.", chat="chat1"):
        return work.act(self.home, "coder", chat, {"action": "start", "title": title, "brief": brief})

    def test_a_workstream_is_a_hidden_chat_given_its_brief(self):
        said = self.start()
        self.assertEqual(said["started"], "W1")
        create = next(p for n, p, _ in self.server.calls if n == "session.create")
        self.assertEqual(create["title"], "Work: W1 · Fix the build")
        self.assertTrue(create["hidden"])
        self.assertFalse(create["close_on_disconnect"])
        self.assertEqual(create["profile"], "coder")
        submit = next(p for n, p, _ in self.server.calls if n == "prompt.submit")
        self.assertEqual(submit, {"session_id": "rt1", "text": "The build fails on main; find out why and fix it."})
        # Its events go nowhere, not to the Dashboard's stdout; and nothing ran on the caller's thread.
        self.assertIsInstance(self.server._sessions["rt1"]["transport"], FakeServer._DropTransport)
        self.assertTrue(all(thread.startswith("redde-work-") for _, _, thread in self.server.calls))
        row = work.Store(self.home).get("W1")
        self.assertEqual((row["status"], row["session"], row["chat"]), ("working", "stored1", "chat1"))

    def test_the_main_agent_names_no_profile(self):
        work.act(Path(self.dir.name), "default", "c", {"action": "start", "title": "t", "brief": "b"})
        create = next(p for n, p, _ in self.server.calls if n == "session.create")
        self.assertNotIn("profile", create)

    def test_no_more_than_three_at_once(self):
        for n in range(work.AT_ONCE):
            self.assertIn("started", self.start(title=f"job {n}"))
        said = self.start(title="one too many")
        self.assertIn("already running", said["error"])
        self.assertEqual(len(said["running"]), work.AT_ONCE)

    def test_one_that_cant_start_says_so_and_frees_its_place(self):
        self.server.refuse.add("prompt.submit")
        said = self.start()
        self.assertIn("didn't start", said["error"])
        self.assertEqual(work.Store(self.home).get("W1")["status"], "failed")
        self.assertIn("session.close", [n for n, _, _ in self.server.calls])

    def test_a_workstream_starts_none_of_its_own(self):
        self.start()
        said = work.act(self.home, "coder", "stored1", {"action": "start", "title": "sub", "brief": "more"})
        self.assertIn("can't start workstreams", said["error"])

    def test_outside_the_dashboard_it_says_where_it_runs(self):
        sys.modules.pop("tui_gateway.server")
        said = self.start()
        self.assertIn("Dashboard", said["error"])
        self.assertFalse(work.Store(self.home).exists() and work.Store(self.home).rows())

    def test_its_end_is_written_down_and_reported(self):
        self.start()
        row = work.turn_ended(self.home, "stored1", failed=False, interrupted=False, reply="Fixed: a missing import.")
        self.assertEqual((row["status"], row["last"]), ("done", "Fixed: a missing import."))
        text = work.report_text(row)
        self.assertTrue(text.startswith('[Workstream W1 "Fix the build" finished.'))
        self.assertIn("not the user's words", text)
        self.assertTrue(text.endswith("Fixed: a missing import."))
        self.assertIsNone(work.turn_ended(self.home, "someone-elses", False, False))

    def test_a_report_waits_for_its_chat_to_be_free(self):
        self.start()
        chat = self.server._methods["session.create"]("x", {"title": "Bot Chat"})["result"]
        self.server._sessions[chat["session_id"]]["running"] = True
        old_wait = work.REPORT_WAIT
        try:
            work.report(chat["stored_session_id"], "coder", "[Workstream W1 …]")
            time.sleep(0.3)
            self.assertFalse([p for n, p, _ in self.server.calls if n == "prompt.submit" and p.get("display_kind")])
            self.server._sessions[chat["session_id"]]["running"] = False
            deadline = time.time() + 5
            while time.time() < deadline and not [p for n, p, _ in self.server.calls if n == "prompt.submit" and p.get("display_kind")]:
                time.sleep(0.1)
        finally:
            work.REPORT_WAIT = old_wait
        submit = [p for n, p, _ in self.server.calls if n == "prompt.submit" and p.get("display_kind")][-1]
        self.assertEqual(submit, {"session_id": chat["session_id"], "text": "[Workstream W1 …]", "queued": True, "display_kind": "hidden"})

    def test_waiting_on_the_person_and_answered(self):
        self.start()
        row = work.needs_you(self.home, "stored1", "rm -rf build/")
        self.assertEqual((row["status"], row["asked"]), ("needs_you", "rm -rf build/"))
        work.answered(self.home, "stored1")
        self.assertEqual(work.Store(self.home).get("W1")["status"], "working")

    def test_stopping_one_reads_as_stopped(self):
        self.start()
        said = work.act(self.home, "coder", "chat1", {"action": "stop", "id": "w1"})
        self.assertEqual(said, {"stopped": "W1"})
        self.assertIn("session.interrupt", [n for n, _, _ in self.server.calls])
        row = work.turn_ended(self.home, "stored1", failed=False, interrupted=False)
        self.assertEqual(row["status"], "stopped")

    def test_sending_steers_a_running_one_and_starts_an_idle_one(self):
        self.start()
        self.assertEqual(work.act(self.home, "coder", "c", {"action": "send", "id": "W1", "text": "Also run the tests."})["how"], "steered")
        self.server._sessions["rt1"]["running"] = False
        self.assertEqual(work.act(self.home, "coder", "c", {"action": "send", "id": "W1", "text": "Now push it."})["how"], "sent")
        sent = [p for n, p, _ in self.server.calls if n == "prompt.submit"][-1]
        self.assertEqual(sent, {"session_id": "rt1", "text": "Now push it.", "queued": True})

    def test_a_chat_hears_how_its_workstreams_stand(self):
        self.start()
        self.start(title="Write the notes", chat="other")
        work.needs_you(self.home, "stored1", "git push")
        note = work.digest(self.home, "chat1")
        self.assertIn('W1 "Fix the build": needs you (waiting on the user: git push)', note)
        self.assertNotIn("W2", note)
        self.assertIsNone(work.digest(self.home, "no-work-here"))

    def test_the_app_lists_them(self):
        self.start()
        root = Path(self.dir.name)
        said = work.slash(root, ["list", "coder"])
        self.assertTrue(said.startswith("redde-push work {"))
        listed = json.loads(said[len("redde-push work "):])
        self.assertEqual((listed["profile"], listed["engine"]), ("coder", "serve"))
        self.assertEqual([(w["id"], w["status"], w["session"]) for w in listed["work"]], [("W1", "working", "stored1")])
        self.assertEqual(json.loads(work.slash(root, ["list", "default"])[len("redde-push work "):])["work"], [])
        self.assertEqual(json.loads(work.slash(root, ["list", "coder", "chat-elsewhere"])[len("redde-push work "):])["work"], [])
        self.assertTrue(work.slash(root, ["stop", "coder", "W1"]).startswith('redde-push work {"stopped"'))
        for nonsense in (["nonsense"], ["list"], ["list", "../etc"], ["stop", "coder", "rm"]):
            self.assertEqual(work.slash(root, nonsense), "redde-push work: this command is for the Redde app.", nonsense)

    def test_a_chat_that_can_start_them_is_told_so(self):
        self.assertEqual(work.turn_note(self.home, "chat1", "desktop"), work.TURN_NOTE)
        self.assertIn("redde_work", work.TURN_NOTE)
        self.start()
        self.assertIsNone(work.turn_note(self.home, "stored1", "desktop"), "a workstream itself starts none")
        for platform in ("cron", "subagent", "bot_room"):
            self.assertIsNone(work.turn_note(self.home, "chat1", platform), platform)
        sys.modules.pop("tui_gateway.server")
        self.assertIsNone(work.turn_note(self.home, "chat1", "telegram"), "nowhere to start one")

    def test_its_note(self):
        made = core.work_note("coder", "W3", "Fix the build", "needs", "git push origin main", "stored3", bot="Coder")
        self.assertEqual({k: made[k] for k in ("k", "p", "d", "x", "w", "t", "s", "b")},
                         {"k": "work", "p": "coder", "d": "Coder", "x": "W3", "w": "needs", "t": "Fix the build", "s": "stored3", "b": "git push origin main"})
        self.assertNotIn("r", made)
        self.assertEqual(core.work_note("coder", "W3", "t", "done", engine="api")["r"], "api", "its chat is opened over the API")


class APIServerAdapter:
    """The gateway's API server, as work_runs.py reads it: its runs' table."""
    _port, _host, _api_key = 18642, "127.0.0.1", "main-key-main-key"

    def __init__(self):
        self._run_statuses = {}


class GatewayTests(unittest.TestCase):
    """Workstreams over the Hermes API (`work_runs.py`, 1.23.0): run by the gateway as runs of the
    plugin's own. The gateway's API is answered here by `self.answers`."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.home = Path(self.dir.name) / "profiles" / "coder"
        self.home.mkdir(parents=True)
        self.api = APIServerAdapter()
        runner = types.SimpleNamespace(adapters={"api_server": self.api})
        sys.modules["gateway.run"] = types.SimpleNamespace(_gateway_runner_ref=lambda: runner)
        self.asked, self.runs = [], {}
        self._ask = work.work_runs.ask
        work.work_runs.ask = self.fake_ask

    def tearDown(self):
        work.work_runs.ask = self._ask
        sys.modules.pop("gateway.run", None)
        sys.modules.pop("tui_gateway.server", None)
        self.dir.cleanup()

    def fake_ask(self, method, path, profile, body=None, wait=0):
        self.asked.append((method, path, profile, body))
        if (method, path) == ("POST", "/api/sessions"):
            return {"session": {"id": "api_work_1", "title": body["title"]}}
        if (method, path) == ("POST", "/v1/runs"):
            run = f"run_{len(self.runs) + 1}"
            self.runs[run] = {"run_id": run, "status": "running", "session_id": body["session_id"]}
            return {"run_id": run, "status": "started"}
        if method == "GET" and path.startswith("/v1/runs/"):
            return self.runs.get(path.split("/")[3], {})
        return {}

    def start(self, platform="api_server", chat="api_chat"):
        return work.act(self.home, "coder", chat, {"action": "start", "title": "Fix the build", "brief": "Find out why."}, platform)

    def test_a_chat_over_the_api_starts_one_in_the_gateway(self):
        # (Some Hermes builds load the Dashboard's session methods in the gateway too: not used there.)
        sys.modules["tui_gateway.server"] = FakeServer()
        said = self.start()
        self.assertEqual(said["started"], "W1")
        self.assertEqual(self.asked[0], ("POST", "/api/sessions", "coder", {"title": "Work: W1 · Fix the build"}))
        self.assertEqual(self.asked[1], ("POST", "/v1/runs", "coder", {"input": "Find out why.", "session_id": "api_work_1"}))
        row = work.Store(self.home).get("W1")
        self.assertEqual((row["engine"], row["session"], row["run"], row["chat"]), ("api", "api_work_1", "run_1", "api_chat"))
        # Hermes's approval hook there names the run: it is found by that too.
        self.assertEqual(work.Store(self.home).of_session("run_1")["ref"], "W1")
        self.assertEqual(json.loads(work.slash(Path(self.dir.name), ["list", "coder"])[len("redde-push work "):])["work"][0]["engine"], "api")

    def test_a_bots_chat_at_its_own_address_counts_as_the_api(self):
        self.assertIn("started", self.start(platform="cli"))

    def test_a_chat_elsewhere_in_the_gateway_is_told_it_cant(self):
        said = self.start(platform="telegram")
        self.assertIn("this chat runs elsewhere", said["error"])
        self.assertEqual(self.asked, [])

    def test_stopping_and_sending(self):
        self.start()
        self.assertEqual(work.act(self.home, "coder", "", {"action": "send", "id": "W1", "text": "and the tests"}),
                         {"sent": "W1", "how": "steered"})
        self.assertIn(("POST", "/v1/runs/run_1/steer", "coder", {"input": "and the tests"}), self.asked)
        self.assertEqual(work.act(self.home, "coder", "", {"action": "stop", "id": "W1"}), {"stopped": "W1"})
        self.assertIn(("POST", "/v1/runs/run_1/stop", "coder", {}), self.asked)
        # One whose run has ended gets a run of its own.
        self.runs["run_1"]["status"] = "completed"
        work.Store(self.home).update("W1", status="done", stopping=0)
        self.assertEqual(work.act(self.home, "coder", "", {"action": "send", "id": "W1", "text": "one more"})["how"], "sent")
        self.assertEqual(work.Store(self.home).get("W1")["run"], "run_2")

    def test_the_work_sheet_answers_its_approval(self):
        self.start()
        self.assertIn("isn't waiting", work.answer(self.home, "coder", "W1", "once")["error"])
        work.needs_you(self.home, "run_1", "rm -rf build")
        # Hermes 0.22.7 wants the exact request and the run's turn.
        self.runs["run_1"].update(status="waiting_for_approval", execution_generation=3,
                                  pending_controls=[{"kind": "approval", "prompt_id": "p9"}])
        self.assertEqual(work.slash(Path(self.dir.name), ["answer", "coder", "W1", "once"]),
                         'redde-push work {"answered": "W1", "choice": "once"}')
        self.assertEqual(self.asked[-1], ("POST", "/v1/runs/run_1/approval", "coder",
                                          {"request_id": "p9", "execution_generation": 3, "choice": "once"}))
        self.assertEqual(work.Store(self.home).get("W1")["status"], "working")
        # Earlier ones take the choice alone.
        work.needs_you(self.home, "run_1", "rm -rf build")
        self.runs["run_1"] = {"run_id": "run_1", "status": "waiting_for_approval"}
        work.answer(self.home, "coder", "W1", "deny")
        self.assertEqual(self.asked[-1][3], {"choice": "deny"})
        self.assertIn("isn't waiting", work.answer(self.home, "coder", "W1", "maybe")["error"])

    def test_one_over_the_dashboard_is_answered_in_its_chat(self):
        sys.modules.pop("gateway.run")
        sys.modules["tui_gateway.server"] = FakeServer()
        work.act(self.home, "coder", "c", {"action": "start", "title": "t", "brief": "b"})
        work.needs_you(self.home, "stored1", "git push")
        self.assertEqual(work.answer(self.home, "coder", "W1", "once"), {"error": "answer W1 in its own chat"})

    def test_its_report_is_a_run_in_its_chat_once_that_is_free(self):
        self.api._run_statuses["app_run"] = {"session_id": "api_chat", "status": "running"}
        work.report("api_chat", "coder", "[Workstream W1 …]", engine="api")
        time.sleep(0.3)
        self.assertEqual([a for a in self.asked if a[1] == "/v1/runs"], [])
        self.api._run_statuses["app_run"]["status"] = "completed"
        deadline = time.time() + 5
        while time.time() < deadline and not any(a[1] == "/v1/runs" for a in self.asked):
            time.sleep(0.1)
        self.assertIn(("POST", "/v1/runs", "coder", {"input": "[Workstream W1 …]", "session_id": "api_chat"}), self.asked)

    def test_a_store_from_1_22_0_gains_the_new_columns(self):
        import sqlite3
        path = work.db_path(self.home)
        path.parent.mkdir(parents=True)
        con = sqlite3.connect(path)
        con.executescript(work._SCHEMA)
        con.execute("INSERT INTO work(ref, title, brief, status, created, updated) VALUES('W1','t','b','done',1,1)")
        con.commit()
        con.close()
        self.assertEqual(work.Store(self.home).get("W1")["engine"], "serve")


if __name__ == "__main__":
    unittest.main()

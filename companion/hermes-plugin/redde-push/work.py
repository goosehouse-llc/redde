"""Workstreams (1.22.0, 2026-11-10): an agent hands a job to a chat of its own that works on it
by itself, and hears back when it is done.

A bot (or the main agent) calls `redde_work` with `start`: the plugin opens a hidden chat in the
same profile, titled "Work: W3 · <title>", and sends it the brief as its first message. It runs
like any chat of that profile, with the same tools, and asks before acting as that profile asks.
When its turn ends the plugin writes down how it ended and what it said, tells the phones, and
puts a short report into the chat that started it, as a turn of that chat's own: the agent there
reads it and tells the person what came of it, or says nothing ([SILENT]) when there's nothing to
tell. Waiting on an approval, it is "needs you" until it is answered.

Where it runs: in `hermes serve` (the Dashboard), through the session methods Hermes's own group
rooms use in-process (`tui_gateway.server._methods`), called from a thread of our own so no
client's connection is bound to it, and with a sink of its own for its events, which nobody is
watching. Redde opens a workstream's chat like any other and sees it live. In any other process
(the gateway: the Hermes API, Telegram) the tool says it can't start one there.

Kept per profile in `<home>/redde-push/work.db` (SQLite): what each workstream is for, its chat,
how it stands. Hermes keeps the chats themselves.
"""
from __future__ import annotations

import contextvars
import json
import logging
import re
import sqlite3
import sys
import threading
import time
from pathlib import Path

log = logging.getLogger("redde-push")

TOOL = "redde_work"
TOOLSET = "redde_work"
TITLE_PREFIX = "Work: "
#: Running at once, per profile: more wait their turn as "busy" for the agent to start later.
AT_ONCE = 3
#: How long the agent's report line and a workstream's last words are kept, in characters.
LAST_LIMIT = 1200
BRIEF_LIMIT = 8000
TITLE_LIMIT = 80
#: A call into Hermes's session methods that hasn't answered in this long is given up on.
CALL_WAIT = 30
#: A report waits this long for the chat it goes to to finish its own turn, then is dropped
#: (the digest at that chat's next turn still says how the workstream ended).
REPORT_WAIT = 600
#: Kept this long after they end, then forgotten (the chats stay in Hermes).
KEPT_FOR = 30 * 86400

STATUSES = ("starting", "working", "needs_you", "done", "failed", "stopped")
OPEN = ("starting", "working", "needs_you")

DESCRIPTION = (
    "Hand a job to a workstream: a chat of your own that works on it by itself, in the background, "
    "with your tools, while you go on talking with the user. Use it for work that takes many steps or "
    "a while (research, a change to code, a long errand), not for a quick look-up. "
    "action 'start' with a short 'title' and a 'brief' that says everything it needs: it can't see this "
    "chat. You hear back here when it finishes; the user can open it, watch it and reply to it in Redde. "
    "'list' shows yours and how each stands; 'read' with 'id' (W1, W2…) gives one's last words and recent "
    "messages; 'send' with 'id' and 'text' adds to one (while it works, it reads it at its next step); "
    "'stop' with 'id' stops its turn. When one is started, tell the user in a sentence; don't repeat the brief.")

REPORT_HEAD = ("[Workstream {ref} \"{title}\" {how}. This is a report from your own workstream, not the user's "
               "words. Tell the user briefly what came of it, or answer exactly [SILENT] if there is nothing "
               "they need to hear.]")


class WorkError(Exception):
    pass


# ---- the store, per profile -------------------------------------------------------------------

def db_path(home: Path) -> Path:
    return Path(home) / "redde-push" / "work.db"


_SCHEMA = """
CREATE TABLE IF NOT EXISTS work (
    ref TEXT PRIMARY KEY, title TEXT NOT NULL, brief TEXT NOT NULL, session TEXT, chat TEXT,
    status TEXT NOT NULL, last TEXT, asked TEXT, created REAL NOT NULL, updated REAL NOT NULL,
    ended REAL, stopping INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS work_session ON work(session);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
"""


class Store:
    """One profile's workstreams. Every call opens and closes its own connection: the Dashboard and
    the gateway may both have one open, and a hook may run on any thread."""

    def __init__(self, home: Path):
        self.home = Path(home)
        self.path = db_path(home)

    def exists(self) -> bool:
        return self.path.exists()

    def _open(self) -> sqlite3.Connection:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        con = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA journal_mode=WAL")
        con.executescript(_SCHEMA)
        return con

    def add(self, title: str, brief: str, chat: str, now: float | None = None) -> dict | None:
        """A new workstream, "starting"; None when AT_ONCE are already running."""
        now = time.time() if now is None else now
        con = self._open()
        try:
            con.execute("BEGIN IMMEDIATE")
            running = con.execute(f"SELECT COUNT(*) FROM work WHERE status IN ({','.join('?' * len(OPEN))})", OPEN).fetchone()[0]
            if running >= AT_ONCE:
                con.execute("ROLLBACK")
                return None
            row = con.execute("SELECT value FROM meta WHERE key='next'").fetchone()
            number = int(row[0]) if row else 1
            con.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('next', ?)", (str(number + 1),))
            ref = f"W{number}"
            con.execute("INSERT INTO work(ref, title, brief, chat, status, created, updated) VALUES(?,?,?,?,?,?,?)",
                        (ref, title, brief, chat, "starting", now, now))
            con.execute("DELETE FROM work WHERE ended IS NOT NULL AND ended < ?", (now - KEPT_FOR,))
            con.execute("COMMIT")
            return self.get(ref)
        except Exception:
            con.execute("ROLLBACK") if con.in_transaction else None
            raise
        finally:
            con.close()

    def get(self, ref: str) -> dict | None:
        con = self._open()
        try:
            row = con.execute("SELECT * FROM work WHERE ref = ? COLLATE NOCASE", (ref.strip(),)).fetchone()
            return dict(row) if row else None
        finally:
            con.close()

    def of_session(self, session: str) -> dict | None:
        """The workstream whose chat this is: cheap when the profile has none."""
        if not session or not self.exists():
            return None
        con = self._open()
        try:
            row = con.execute("SELECT * FROM work WHERE session = ?", (session,)).fetchone()
            return dict(row) if row else None
        finally:
            con.close()

    def rows(self, chat: str | None = None, limit: int = 50) -> list[dict]:
        if not self.exists():
            return []
        con = self._open()
        try:
            if chat:
                found = con.execute("SELECT * FROM work WHERE chat = ? ORDER BY created DESC LIMIT ?", (chat, limit))
            else:
                found = con.execute("SELECT * FROM work ORDER BY created DESC LIMIT ?", (limit,))
            return [dict(r) for r in found]
        finally:
            con.close()

    def update(self, ref: str, **fields) -> None:
        if not fields:
            return
        fields.setdefault("updated", time.time())
        con = self._open()
        try:
            con.execute(f"UPDATE work SET {', '.join(f'{k} = ?' for k in fields)} WHERE ref = ?", (*fields.values(), ref))
        finally:
            con.close()


# ---- Hermes's session methods, in-process (hermes serve) ---------------------------------------

def server():
    """`tui_gateway.server` when this process is a Dashboard with the session methods we use."""
    module = sys.modules.get("tui_gateway.server")
    if module is None:
        return None
    if not all(hasattr(module, name) for name in ("_methods", "_sessions", "_sessions_lock", "_DropTransport")):
        return None
    return module


_ids = iter(range(1, 1 << 62))


def call(method: str, params: dict, wait: float = CALL_WAIT) -> dict:
    """One of Hermes's session methods, answered in-process. On a thread of its own with nothing
    bound: a hook or tool runs on a thread whose context has the app's connection, and a session
    made there would send its events to the app, and be closed with it."""
    srv = server()
    if srv is None:
        raise WorkError("workstreams run in Hermes's Dashboard (hermes serve), which this isn't")
    handler = srv._methods.get(method)
    if handler is None:
        raise WorkError(f"this Hermes has no {method}")
    answer: dict = {}
    done = threading.Event()

    def run():
        try:
            answer["envelope"] = handler(f"redde-work-{next(_ids)}", params)
        except Exception as error:   # (a handler's own failure, reported as one)
            answer["error"] = error
        finally:
            done.set()

    threading.Thread(target=contextvars.Context().run, args=(run,), name=f"redde-work-{method}", daemon=True).start()
    if not done.wait(wait):
        raise WorkError(f"{method} didn't answer")
    if "error" in answer:
        raise WorkError(f"{method} failed: {answer['error']}")
    envelope = answer.get("envelope")
    if not isinstance(envelope, dict):
        raise WorkError(f"{method} gave no answer")
    if isinstance(envelope.get("error"), dict):
        raise WorkError(str(envelope["error"].get("message") or f"{method} was refused"))
    result = envelope.get("result")
    return result if isinstance(result, dict) else {}


def _record(stored: str) -> tuple[str, dict] | None:
    """The live session with this stored id: (its runtime id, its record)."""
    srv = server()
    if srv is None or not stored:
        return None
    with srv._sessions_lock:
        for sid, record in srv._sessions.items():
            if str(record.get("session_key") or "") == stored:
                return sid, record
    return None


def _quiet(runtime: str) -> None:
    """Gives a session nobody watches a sink of its own: made on our thread it would have fallen
    back to the Dashboard's stdout, a log. (A new sink, not Hermes's shared detached one, which
    marks a session as left by its client and soon closed.) An app attached later still gets it."""
    srv = server()
    with srv._sessions_lock:
        record = srv._sessions.get(runtime)
        if record is not None and (record.get("transport") is None
                                   or type(record.get("transport")).__name__ == "StdioTransport"):
            record["transport"] = srv._DropTransport()


def _profile_param(profile: str) -> dict:
    return {} if profile in ("", "default") else {"profile": profile}


def open_session(stored: str, profile: str) -> str:
    """The runtime id of a stored session, resumed (quietly) when it isn't live."""
    found = _record(stored)
    if found:
        return found[0]
    result = call("session.resume", {"session_id": stored, "omit_messages": True, **_profile_param(profile)})
    runtime = str(result.get("session_id") or "")
    if not runtime:
        raise WorkError("couldn't open that chat")
    _quiet(runtime)
    return runtime


def running(stored: str) -> bool:
    found = _record(stored)
    return bool(found and found[1].get("running"))


def begin(profile: str, ref: str, title: str, brief: str) -> str:
    """Opens the workstream's hidden chat and sends it the brief: its stored session id."""
    made = call("session.create", {"title": f"{TITLE_PREFIX}{ref} · {title}", "hidden": True,
                                   "close_on_disconnect": False, "idempotency_key": f"redde-work-{profile}-{ref}",
                                   **_profile_param(profile)})
    runtime, stored = str(made.get("session_id") or ""), str(made.get("stored_session_id") or "")
    if not runtime or not stored:
        raise WorkError("Hermes didn't open a chat for it")
    _quiet(runtime)
    try:
        call("prompt.submit", {"session_id": runtime, "text": brief})
    except WorkError:
        try:
            call("session.close", {"session_id": runtime})
        except WorkError:
            pass
        raise
    return stored


def say(stored: str, profile: str, text: str) -> str:
    """Adds to a workstream: into its turn while it works (`session.steer`), else a turn of its
    own. "steered" or "sent"."""
    runtime = open_session(stored, profile)
    if running(stored):
        try:
            call("session.steer", {"session_id": runtime, "text": text})
            return "steered"
        except WorkError:
            pass   # (an older Hermes, or the turn just ended: a queued message instead)
    call("prompt.submit", {"session_id": runtime, "text": text, "queued": True})
    return "sent"


def halt(stored: str) -> bool:
    found = _record(stored)
    if not found or not found[1].get("running"):
        return False
    call("session.interrupt", {"session_id": found[0]})
    return True


def report(chat: str, profile: str, text: str) -> None:
    """Into the chat that started a workstream, as a turn of its own the person sees only the
    answer of. After that chat's own turn: a message sent to a busy chat is kept in the running
    turn and then run again as its own, so the agent would hear it twice."""
    def deliver():
        deadline = time.time() + REPORT_WAIT
        try:
            while running(chat) and time.time() < deadline:
                time.sleep(2)
            if running(chat):
                log.info("redde-push: a workstream's report found its chat still busy; left to the digest")
                return
            runtime = open_session(chat, profile)
            call("prompt.submit", {"session_id": runtime, "text": text, "queued": True, "display_kind": "hidden"})
        except WorkError as error:
            log.info("redde-push: a workstream's report didn't reach its chat: %s", error)
        except Exception:
            log.debug("redde-push: a workstream's report failed", exc_info=True)

    threading.Thread(target=deliver, name="redde-work-report", daemon=True).start()


# ---- what the agent sees ------------------------------------------------------------------------

def _clip(text, limit: int) -> str:
    text = " ".join(str(text or "").split()) if limit <= TITLE_LIMIT else str(text or "").strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def _shown(row: dict) -> dict:
    out = {"id": row["ref"], "title": row["title"], "status": row["status"]}
    if row.get("last"):
        out["last"] = _clip(row["last"], 300)
    if row.get("asked"):
        out["waiting_on"] = _clip(row["asked"], 200)
    return out


def start(home: Path, profile: str, chat: str, title: str, brief: str) -> dict:
    title, brief = _clip(title, TITLE_LIMIT), _clip(brief, BRIEF_LIMIT)
    if not title or not brief:
        return {"error": "start needs a title and a brief"}
    if server() is None:
        return {"error": "Workstreams run in Hermes's Dashboard (hermes serve); this chat runs elsewhere, "
                         "so do the job here yourself or ask the user to use Redde over the Dashboard."}
    store = Store(home)
    if chat and store.of_session(chat):
        return {"error": "a workstream can't start workstreams of its own; do the work here"}
    row = store.add(title, brief, chat)
    if row is None:
        return {"error": f"{AT_ONCE} are already running; wait for one to finish (list shows them)",
                "running": [_shown(r) for r in store.rows() if r["status"] in OPEN]}
    try:
        stored = begin(profile, row["ref"], title, brief)
    except WorkError as error:
        store.update(row["ref"], status="failed", last=f"Didn't start: {error}", ended=time.time())
        return {"error": f"it didn't start: {error}"}
    store.update(row["ref"], session=stored, status="working")
    return {"started": row["ref"], "title": title, "session": stored,
            "note": "Tell the user in one short sentence; you hear back here when it finishes."}


def act(home: Path, profile: str, chat: str, args: dict) -> dict:
    """`redde_work`."""
    action = str(args.get("action") or "list")
    store = Store(home)
    if action == "start":
        return start(home, profile, chat, str(args.get("title") or ""), str(args.get("brief") or ""))
    if action == "list":
        return {"workstreams": [_shown(r) for r in store.rows(limit=20)]}
    row = store.get(str(args.get("id") or ""))
    if row is None:
        return {"error": "no workstream with that id; list shows them"}
    if action == "read":
        out = _shown(row) | {"brief": _clip(row["brief"], 600)}
        out["recent"] = transcript(home, row.get("session") or "", 8)
        return out
    if action == "send":
        text = str(args.get("text") or "").strip()
        if not text or not row.get("session"):
            return {"error": "send needs text, to a workstream that started"}
        try:
            how = say(row["session"], profile, text)
        except WorkError as error:
            return {"error": str(error)}
        store.update(row["ref"], status="working", ended=None, asked=None)
        return {"sent": row["ref"], "how": how}
    if action == "stop":
        if row["status"] not in OPEN or not row.get("session"):
            return {"error": f"{row['ref']} isn't running"}
        store.update(row["ref"], stopping=1)
        try:
            stopped = halt(row["session"])
        except WorkError as error:
            return {"error": str(error)}
        if not stopped:
            store.update(row["ref"], status="stopped", stopping=0, ended=time.time())
        return {"stopped": row["ref"]}
    return {"error": "action is start, list, read, send or stop"}


def transcript(home: Path, session: str, limit: int) -> list[dict]:
    """A workstream's last user and agent messages, from the profile's state.db (read-only)."""
    db = Path(home) / "state.db"
    if not session or not db.exists():
        return []
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        try:
            rows = con.execute("SELECT role, content FROM messages WHERE session_id = ? AND role IN ('user','assistant') "
                               "AND content IS NOT NULL AND content != '' ORDER BY id DESC LIMIT ?", (session, limit)).fetchall()
        finally:
            con.close()
    except sqlite3.Error:
        return []
    return [{"role": role, "text": _clip(content, 800)} for role, content in reversed(rows)]


def last_words(home: Path, session: str) -> str:
    found = [m for m in transcript(home, session, 6) if m["role"] == "assistant"]
    return found[-1]["text"] if found else ""


def digest(home: Path, chat: str) -> str | None:
    """`pre_llm_call` in a chat that started workstreams: how its open ones stand, and the ones
    that ended since it last heard, for the model alone."""
    rows = [r for r in Store(home).rows(chat=chat, limit=10) if r["status"] in OPEN or (r.get("ended") or 0) > time.time() - 3600]
    if not rows:
        return None
    lines = []
    for r in rows:
        line = f"- {r['ref']} \"{r['title']}\": {r['status'].replace('_', ' ')}"
        if r.get("asked"):
            line += f" (waiting on the user: {_clip(r['asked'], 160)})"
        elif r.get("last") and r["status"] not in OPEN:
            line += f": {_clip(r['last'], 200)}"
        lines.append(line)
    return "[Redde: your workstreams (redde_work), for you alone:\n" + "\n".join(lines) + "]"


# ---- hooks ---------------------------------------------------------------------------------------

def turn_began(home: Path, session: str) -> None:
    store = Store(home)
    row = store.of_session(session)
    if row and row["status"] not in ("working", "needs_you"):
        store.update(row["ref"], status="working", ended=None)


def needs_you(home: Path, session: str, what: str) -> dict | None:
    store = Store(home)
    row = store.of_session(session)
    if row and row["status"] in OPEN:
        store.update(row["ref"], status="needs_you", asked=_clip(what, 400))
        return store.get(row["ref"])
    return None


def answered(home: Path, session: str) -> None:
    store = Store(home)
    row = store.of_session(session)
    if row and row["status"] == "needs_you":
        store.update(row["ref"], status="working", asked=None)


def turn_ended(home: Path, session: str, failed: bool, interrupted: bool, reply: str = "") -> dict | None:
    """`on_session_end` with a turn: settles the workstream, the row as it now is (None for a chat
    that isn't one, or a turn that changes nothing)."""
    store = Store(home)
    row = store.of_session(session)
    if row is None:
        return None
    words = (reply or "").strip() or last_words(home, session)
    if row.get("stopping") or interrupted:
        status = "stopped"
    elif failed:
        status = "failed"
    else:
        status = "done"
    store.update(row["ref"], status=status, last=_clip(words, LAST_LIMIT) or None, asked=None, stopping=0, ended=time.time())
    return store.get(row["ref"])


def report_text(row: dict) -> str:
    how = {"done": "finished", "failed": "ended with an error", "stopped": "was stopped"}.get(row["status"], row["status"])
    head = REPORT_HEAD.format(ref=row["ref"], title=row["title"], how=how)
    return head + ("\n\n" + row["last"] if row.get("last") else "")


# ---- the app ------------------------------------------------------------------------------------

_REF = re.compile(r"W\d{1,6}", re.IGNORECASE)


def home_of_profile(root: Path, profile: str) -> Path:
    return Path(root) if profile == "default" else Path(root) / "profiles" / profile


def slash(root: Path, words: list[str]) -> str:
    """`/redde-push work list <profile> [chat]`: that agent's workstreams as JSON, for the app's
    Work sheet. `work stop <profile> <id>`: stops one. The profile is named: the app's command
    reaches the main agent's copy of the plugin, whichever agent it is about. Every reply starts
    "redde-push work"."""
    from .calls import PROFILE
    if len(words) >= 2 and words[0] in ("list", "stop") and PROFILE.fullmatch(words[1]):
        profile = words[1]
        home = home_of_profile(root, profile)
        if words[0] == "list" and len(words) <= 3:
            rows = Store(home).rows(chat=words[2] if len(words) == 3 else None, limit=50)
            return "redde-push work " + json.dumps({"profile": profile, "engine": "serve" if server() else "none", "work": [
                {"id": r["ref"], "title": r["title"], "status": r["status"], "session": r.get("session") or "",
                 "chat": r.get("chat") or "", "last": _clip(r.get("last") or "", 600), "asked": r.get("asked") or "",
                 "created": int(r["created"]), "updated": int(r["updated"]), "ended": int(r["ended"]) if r.get("ended") else None}
                for r in rows]}, ensure_ascii=False)
        if words[0] == "stop" and len(words) == 3 and _REF.fullmatch(words[2]):
            said = act(home, profile, "", {"action": "stop", "id": words[2]})
            return "redde-push work " + json.dumps(said, ensure_ascii=False)
    return "redde-push work: this command is for the Redde app."


def register(ctx, home_of, profile_of) -> None:
    def handle(args, **kwargs) -> str:
        args = args if isinstance(args, dict) else {}
        home = Path(home_of())
        try:
            said = act(home, profile_of(home), str(kwargs.get("session_id") or ""), args)
        except Exception as error:
            log.debug("redde-push: redde_work failed", exc_info=True)
            said = {"error": f"that didn't work: {error}"}
        return json.dumps(said, ensure_ascii=False)

    schema = {"name": TOOL, "description": DESCRIPTION,
              "parameters": {"type": "object", "properties": {
                  "action": {"type": "string", "enum": ["start", "list", "read", "send", "stop"]},
                  "title": {"type": "string", "description": "start: a few words, shown to the user"},
                  "brief": {"type": "string", "description": "start: everything the workstream needs to do the job"},
                  "id": {"type": "string", "description": "read, send, stop: W1, W2…"},
                  "text": {"type": "string", "description": "send: what to add"}},
                  "required": ["action"]}}
    ctx.register_tool(name=TOOL, toolset=TOOLSET, schema=schema, handler=handle, emoji="🧵")

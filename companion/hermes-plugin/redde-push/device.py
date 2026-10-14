"""Phone tools: things on the person's iPhone that the agent can ask the Redde app to do, because
iOS lets an app do them with its owner's permission. The calendar, reminders, contacts, the photo
library, one folder of files, alarms, a widget of Redde's that the agent writes on, and starting
a call or a message for the person to send. Nothing here reaches into other apps: iOS allows no
app that.

How a call travels. The agent calls a tool here; the call is written down as a small file in the
Hermes home and the tool waits. The Redde app, which is following the turn, sees the tool start,
asks this plugin what is wanted (`/redde-push device next`, over the Dashboard), does it on the
phone, where the person may be asked first, and hands the answer back (`/redde-push device done
<id> <answer>`), which is written down beside the request. The tool reads it and returns. Files
and not memory, because the agent's turn and the app's command can be in different processes
(the gateway's and the Dashboard's).

Which tools the agent is offered is the phone's to say (`/redde-push device areas calendar,files`
or `none`): a tool whose area is off isn't offered at all. With every area off, which is how it
starts, the agent sees none of this.

The tools' names and arguments must match what the app knows (Echo/Services/DeviceTools in the
Redde repository).
"""

from __future__ import annotations

import base64
import json
import os
import re
import threading
import time
import uuid
from pathlib import Path

TOOLSET = "redde_phone"
#: How long a call waits for the phone, in seconds: a person may have to say yes on it.
WAIT = 120.0
#: A request nobody collected, or a saved file nobody needs any more, is cleared out after this.
STALE = 600.0
AREAS = ("calendar", "reminders", "contacts", "photos", "files", "alarms", "widget", "people")
#: How long a call for the widget waits for a phone that is following the turn, before what was
#: written is sent to the phone as a notification instead.
WIDGET_WAIT = 10.0

_WHERE = ("Runs on the user's iPhone, through the Redde app. It answers only while Redde is open on the phone "
          "and following this conversation. ")
_ASKED = "The user is asked to confirm on the phone before it happens. "
_WHEN = ("Dates are ISO 8601, like 2026-10-13T09:00 (the phone's own time zone unless one is given) or "
         "2026-10-13 for a whole day.")


def _text(description: str) -> dict:
    return {"type": "string", "description": description}


def _count(description: str) -> dict:
    return {"type": "integer", "description": description}


#: name -> (area, description, properties, required). The area decides whether it is offered.
TOOLS: dict[str, tuple[str | None, str, dict, list[str]]] = {
    "phone_info": (None, _WHERE + "What the phone allows right now: which phone tools are on and whether the user is asked "
                   "first, the local time and the time zone. Call it when unsure what you may do.", {}, []),
    "phone_calendar_events": ("calendar", _WHERE + "The user's calendar events between two moments (default: the coming week), "
                              "soonest first. " + _WHEN, {
        "start": _text("From when. Default: now."), "end": _text("Until when. Default: a week after the start."),
        "query": _text("Only events with these words in the title, place or notes."),
        "limit": _count("At most this many (default 50)."),
    }, []),
    "phone_calendar_add_event": ("calendar", _WHERE + "Adds an event to the user's calendar. " + _ASKED + _WHEN, {
        "title": _text("What it is."), "start": _text("When it starts; a day alone makes it an all-day event."),
        "end": _text("When it ends. Default: an hour after the start."),
        "all_day": {"type": "boolean", "description": "An all-day event."},
        "location": _text("Where."), "notes": _text("Notes."),
        "calendar": _text("The calendar's name. Default: the user's default calendar."),
    }, ["title", "start"]),
    "phone_reminders_list": ("reminders", _WHERE + "The user's reminders that are still to do, soonest due first.", {
        "list": _text("Only this reminders list, by name."),
        "include_completed": {"type": "boolean", "description": "The completed ones too."},
        "limit": _count("At most this many (default 50)."),
    }, []),
    "phone_reminders_add": ("reminders", _WHERE + "Adds a reminder. " + _ASKED + _WHEN, {
        "title": _text("What to be reminded of."),
        "due": _text("When it is due; with a time of day the phone alerts the user then."),
        "notes": _text("Notes."), "list": _text("The reminders list's name. Default: the user's default list."),
    }, ["title"]),
    "phone_reminders_complete": ("reminders", _WHERE + "Marks a reminder as done. " + _ASKED, {
        "id": _text("The reminder's id, as phone_reminders_list gave it."),
    }, ["id"]),
    "phone_contacts_search": ("contacts", _WHERE + "Looks someone up in the user's contacts: names, phone numbers, email and "
                              "postal addresses, birthday. It cannot change contacts.", {
        "query": _text("A name or part of one; or a phone number or an email address, to find whose it is."),
        "limit": _count("At most this many (default 10)."),
    }, ["query"]),
    "phone_photos_search": ("photos", _WHERE + "Finds photos in the user's library: by when they were taken and what kind they "
                            "are, newest first, and with query by what they show or say, best match first. Gives each one's id, "
                            "date, kind and size, not the pictures. With query each one also says what the phone made out in it "
                            "(shows), text it read in it, a caption the user wrote, and how well it matched: those are the "
                            "phone's guesses, so fetch a likely one with phone_photos_get and look at it before saying what it "
                            "is. The phone looks through the library bit by bit: not_looked_at counts the pictures it has not "
                            "got to, which nothing found does not rule out. " + _WHEN, {
        "query": _text("What the picture shows or says, in a few plain English words: things, animals, places, activities, or "
                       "words written in it, like 'bowling scoreboard', 'dog beach' or 'receipt hardware store'. Captions and "
                       "keywords the user gave a photo are matched as well. Dates go in start and end, not here."),
        "start": _text("Taken from when."), "end": _text("Taken until when."),
        "kind": {"type": "string", "enum": ["photo", "screenshot", "video", "any"], "description": "What kind (default any)."},
        "favorites": {"type": "boolean", "description": "Only the ones marked as favorites."},
        "limit": _count("At most this many (default 30)."),
    }, []),
    "phone_photos_get": ("photos", _WHERE + "Fetches one photo to look at. The picture is saved on this machine as a JPEG and "
                         "its path is returned as file_path: use your image tools on that path. Redde shows the user the "
                         "picture in the conversation as it is fetched, so there is no need to show it again in that reply. To "
                         "show it in a later reply, write the show_with line (MEDIA: and the path) on a line of its own; a "
                         "bare path shows the user nothing.", {
        "id": _text("The photo's id, as phone_photos_search gave it."),
        "max_edge": _count("Its longest side in pixels (default 1280)."),
    }, ["id"]),
    "phone_photos_delete": ("photos", _WHERE + "Deletes photos from the user's library. iOS shows the user the photos and asks; "
                            "deleted ones stay in Recently Deleted for 30 days.", {
        "ids": {"type": "array", "items": {"type": "string"}, "description": "The photos' ids, as phone_photos_search gave them."},
    }, ["ids"]),
    "phone_files_list": ("files", _WHERE + "Lists Redde's folder in the phone's Files app (On My iPhone, Redde), the one place on "
                         "the phone you can read and write files.", {
        "path": _text("A folder inside it, like notes. Default: the top."),
    }, []),
    "phone_files_read": ("files", _WHERE + "Reads a file in Redde's folder on the phone. Text comes back as text; any other file "
                         "is saved on this machine and its path returned as file_path (write the show_with line on a line of "
                         "its own to show it to the user in the conversation).", {
        "path": _text("The file's path inside the folder, like notes/list.txt."),
    }, ["path"]),
    "phone_files_write": ("files", _WHERE + "Saves a text file to Redde's folder on the phone, where the user finds it in the "
                          "Files app. " + _ASKED, {
        "path": _text("Where to save it inside the folder, like notes/list.txt."), "text": _text("What the file says."),
    }, ["path", "text"]),
    "phone_files_delete": ("files", _WHERE + "Deletes a file or a folder inside Redde's folder on the phone. " + _ASKED, {
        "path": _text("Its path inside the folder."),
    }, ["path"]),
    "phone_alarms_set": ("alarms", _WHERE + "Sets an alarm or a timer on the phone. It rings there like the Clock app's, through "
                         "silent mode and a Focus, whether or not Redde is open by then. Give `at` for an alarm at a time, or "
                         "`minutes` for a timer counting down from now: one of the two. " + _ASKED, {
        "title": _text("What it is for; the phone shows it when it rings."),
        "at": _text("When to ring, like 2026-10-14T06:10 (the phone's own time zone unless one is given)."),
        "minutes": {"type": "number", "description": "A timer instead: how many minutes from now (0.5 is thirty seconds), a day at most."},
    }, ["title"]),
    "phone_alarms_list": ("alarms", _WHERE + "The alarms and timers set through Redde that have yet to ring, soonest first, with "
                          "their ids. The Clock app's own alarms are not among them: the phone shows those to no app.", {}, []),
    "phone_alarms_cancel": ("alarms", _WHERE + "Cancels an alarm or a timer that was set through Redde. " + _ASKED, {
        "id": _text("Its id, as phone_alarms_list or phone_alarms_set gave it."),
    }, ["id"]),
    "phone_widget_set": ("widget", "Runs on the user's iPhone, through the Redde app: writes a title and a few lines on Redde's "
                         "\"From Your Agent\" widget, on the Home Screen or Lock Screen, where the user sees them without opening "
                         "anything. For what is worth a glance: today's plan, something that is running, when to leave. Unlike the "
                         "other phone tools it also works with Redde closed: what you write is then sent as a notification and the "
                         "widget changes when the phone receives it. With `at`, it shows from that moment and what is there stays "
                         "until then, so a day can be laid out ahead; with `until`, it comes off then and what was there before "
                         "shows again. " + _WHEN, {
        "text": _text("A few short lines, 300 characters at most. A line break starts a new line."),
        "title": _text("A heading over them, 60 characters at most."),
        "at": _text("From when it shows. Default: now."),
        "until": _text("Until when it holds. Default: until you write something else."),
    }, ["text"]),
    "phone_people_call": ("people", _WHERE + "Starts a phone call or a FaceTime call from the user's iPhone. The phone asks the "
                          "user to confirm before it dials, and you are not told whether they did. You are not on the call: it is "
                          "between the user and whoever they called. Give a number, or a name as it is in their contacts (that "
                          "needs the contacts tools turned on); when a contact has several numbers, say which with `label`.", {
        "to": _text("Whom to call: a phone number, or a contact's name."),
        "label": _text("Which of the contact's numbers, like mobile or work, or its last four digits when two share a label."),
        "kind": {"type": "string", "enum": ["phone", "facetime", "facetime_audio"], "description": "Default: phone."},
    }, ["to"]),
    "phone_people_message": ("people", _WHERE + "Writes a text message for the user to send: the phone opens Messages with the "
                             "recipient and your text filled in, and the user reads it and taps Send, or doesn't. Nothing is sent "
                             "without that tap, and you are told which it was. You can't read their messages. Give a number, or a "
                             "name as it is in their contacts (that needs the contacts tools turned on).", {
        "to": _text("Whom it is for: a phone number, or a contact's name. Several, separated by commas, for a group."),
        "text": _text("The message, as it should be sent."),
        "label": _text("Which of the contact's numbers, like mobile or work, or its last four digits when two share a label."),
    }, ["to", "text"]),
    "phone_widget_clear": ("widget", "Runs on the user's iPhone, through the Redde app: takes everything off Redde's \"From Your "
                           "Agent\" widget, what was set for later included. Works with Redde closed too, as phone_widget_set "
                           "does.", {}, []),
}


def _interrupted() -> bool:
    """The turn was stopped: Hermes can't end a tool that is waiting, so the tool looks."""
    try:
        from tools.interrupt import is_interrupted
        return bool(is_interrupted())
    except Exception:
        return False


class Phone:
    """The requests waiting for the phone, its answers, and which areas it has turned on: small
    files under the plugin's folder in the Hermes home, readable only by its owner."""

    def __init__(self, home: Path):
        self.dir = Path(home) / "redde-push" / "device"

    def _folder(self, name: str) -> Path:
        folder = self.dir / name
        folder.mkdir(parents=True, exist_ok=True)
        for made in (self.dir.parent, self.dir, folder):
            try:
                os.chmod(made, 0o700)
            except OSError:
                pass
        return folder

    def _write(self, path: Path, data) -> None:
        scratch = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        with open(os.open(scratch, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file:
            json.dump(data, file)
        os.replace(scratch, path)

    @staticmethod
    def _read(path: Path):
        try:
            return json.loads(path.read_text())
        except (OSError, ValueError):
            return None

    # ---- which tools are offered

    def areas(self) -> list[str]:
        kept = self._read(self.dir / "areas.json") or {}
        return [area for area in kept.get("areas", []) if area in AREAS]

    def set_areas(self, areas: list[str]) -> list[str]:
        self._folder("requests")
        self._write(self.dir / "areas.json", {"areas": [a for a in AREAS if a in areas], "at": time.time()})
        return self.areas()

    def offers(self, area: str | None) -> bool:
        on = self.areas()
        return bool(on) if area is None else area in on

    # ---- a call, from the agent's side

    def ask(self, tool: str, args: dict, session: str | None = None, wait: float = WAIT, otherwise=None) -> str:
        """Writes the request down, waits for the phone's answer and gives the tool's result.
        `otherwise`, when given, is what to do and answer if the phone never collects it."""
        area = TOOLS[tool][0]
        if not self.offers(area):
            return json.dumps({"error": "Phone tools for this are turned off in Redde on the iPhone (Settings, Phone tools)."})
        request = uuid.uuid4().hex[:16]
        asked = self._folder("requests") / f"{request}.json"
        answered = self._folder("answers") / f"{request}.json"
        self._tidy()
        self._write(asked, {"id": request, "tool": tool, "args": args or {}, "session": session or "", "at": time.time()})
        deadline = time.monotonic() + wait
        try:
            while time.monotonic() < deadline:
                answer = self._read(answered)
                if answer is not None:
                    return self._result(answer)
                if _interrupted():
                    return json.dumps({"error": "The turn was stopped before the phone answered."})
                time.sleep(0.15)
            if otherwise is not None:
                return otherwise()
            return json.dumps({"error": "The phone didn't answer. Phone tools work while Redde is open on the iPhone and following "
                                        "this conversation, and some need the user to tap Allow there. Say so, and try again when they are ready."})
        finally:
            for path in (asked, answered):
                try:
                    path.unlink()
                except OSError:
                    pass

    def _result(self, answer: dict) -> str:
        if not answer.get("ok"):
            return json.dumps({"error": str(answer.get("error") or "The phone couldn't do that.")})
        result = answer.get("result")
        # A file comes as its bytes; the agent is given a path to it on this machine.
        if isinstance(result, dict) and isinstance(result.get("file"), dict):
            blob = result.pop("file")
            try:
                data = base64.b64decode(blob.get("base64") or "", validate=True)
            except ValueError:
                data = b""
            if data:
                name = re.sub(r"[^A-Za-z0-9._-]+", "_", str(blob.get("name") or "file"))[-80:].lstrip(".") or "file"
                path = self._folder("files") / f"{uuid.uuid4().hex[:8]}-{name}"
                with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as file:
                    file.write(data)
                result["file_path"] = str(path)
                result["file_bytes"] = len(data)
                # How the agent puts it in front of the person: Redde fetches what a MEDIA: line names.
                result["show_with"] = f"MEDIA:{path}"
        return json.dumps(result if result is not None else {})

    def _tidy(self) -> None:
        """Clears out what was left behind: requests whose tool is long gone, files long fetched."""
        now = time.time()
        for name, age in (("requests", STALE), ("answers", STALE), ("files", 24 * 3600.0)):
            try:
                for path in (self.dir / name).iterdir():
                    if now - path.stat().st_mtime > age:
                        path.unlink()
            except OSError:
                pass

    # ---- the same call, from the phone's side

    def waiting(self) -> list[dict]:
        """The requests the phone hasn't answered, oldest first."""
        found = []
        try:
            paths = sorted((self.dir / "requests").glob("*.json"), key=lambda p: p.stat().st_mtime)
        except OSError:
            return []
        for path in paths:
            request = self._read(path)
            if isinstance(request, dict) and request.get("id") and not (self.dir / "answers" / path.name).exists():
                found.append({key: request.get(key) for key in ("id", "tool", "args", "session")})
        return found

    def answer(self, request: str, answer: dict) -> bool:
        """The phone's answer to a request. False for a request that is no longer waiting."""
        if not re.fullmatch(r"[0-9a-f]{16}", request or "") or not (self.dir / "requests" / f"{request}.json").exists():
            return False
        self._write(self._folder("answers") / f"{request}.json", answer)
        return True


def slash(phone: Phone, words: list[str]) -> str:
    """`/redde-push device …`, which is the app's. Every reply starts "redde-push device"."""
    if words[:1] == ["areas"] and len(words) == 2:
        on = phone.set_areas([] if words[1] == "none" else words[1].split(","))
        return "redde-push device areas " + (",".join(on) or "none")
    if words == ["status"]:
        return "redde-push device status " + (",".join(phone.areas()) or "none")
    if words == ["next"]:
        return "redde-push device next " + base64.b64encode(json.dumps(phone.waiting()).encode()).decode()
    if words[:1] == ["done"] and len(words) == 3:
        try:
            answer = json.loads(base64.b64decode(words[2], validate=True))
        except ValueError:
            return "redde-push device refused: that answer can't be read"
        if not isinstance(answer, dict):
            return "redde-push device refused: that answer can't be read"
        return "redde-push device done" if phone.answer(words[1], answer) else "redde-push device gone"
    return "redde-push device: this command is for the Redde app."


_watching: set[str] = set()


def _watch(phone, every: float = 2.0) -> None:
    """Has this process list its tools afresh when the phone turns an area on or off.

    Hermes remembers the list of tools it worked out (`model_tools.get_tool_definitions`), and
    what it remembers doesn't go by whether a tool is on offer: a process that listed its tools
    while phone tools were off would never offer them, and one that listed them while they were
    on would offer them for ever. The phone's word arrives in one process (the Dashboard's, by
    the app's command) and has to be heard in the other too (the gateway's), so each looks at the
    file. Clearing what Hermes remembers is the function it has for a changed dependency; where
    it can't be found, a change takes a restart of Hermes, and a tool that is off still refuses."""
    seen, first = None, True
    while True:
        try:
            stamp = (phone().dir / "areas.json").stat().st_mtime_ns
        except Exception:
            stamp = None
        if not first and stamp != seen:
            try:
                import model_tools
                model_tools._clear_tool_defs_cache()
            except Exception:
                pass
        seen, first = stamp, False
        time.sleep(every)


def _readable(when: str) -> bool:
    """Whether the phone will be able to read a date: it does the reading, in its own time zone."""
    from datetime import datetime
    try:
        datetime.fromisoformat(when.strip().replace("Z", "+00:00"))
        return True
    except ValueError:
        return False


def widget_by_note(tool: str, args: dict, to_widget) -> str:
    """What a call for the widget does when no phone is following the turn: what was written
    goes to every paired phone as a notification, which puts it on the widget. `to_widget`
    (title, text, at, until) sends it and says to how many phones."""
    title, text = str(args.get("title") or "").strip(), str(args.get("text") or "").strip()
    start, end = str(args.get("at") or "").strip(), str(args.get("until") or "").strip()
    if tool == "phone_widget_clear":
        title = text = start = end = ""
    else:
        if not (title or text):
            return json.dumps({"error": "The argument \"text\" is missing: there is nothing to write."})
        for name, when in (("at", start), ("until", end)):
            if when and not _readable(when):
                return json.dumps({"error": f"\"{name}\" isn't a date the phone can read: write it like 2026-10-13T09:00."})
    try:
        phones = to_widget(title, text, start, end) if to_widget else 0
    except Exception as error:
        return json.dumps({"error": f"The phone isn't following this conversation, and the notification couldn't be sent: {error}"})
    if not phones:
        return json.dumps({"error": "The phone isn't following this conversation and isn't paired for notifications, so there "
                                    "was no way to reach its widget. It works while Redde is open on this conversation, or at "
                                    "any time once the phone is paired (Redde's Settings, When Redde is closed)."})
    return json.dumps({"sent": "The phone isn't following this conversation, so this went to it as a notification. The widget "
                               "changes when the phone receives it; you won't hear back.", "phones": phones})


def register(ctx, phone, to_widget=None) -> None:
    """Offers the tools to the agent. `phone` gives the `Phone` of the Hermes home in use: asked
    for at each call, since a home is a profile's and a process can serve several. `to_widget`
    sends something for the widget as a notification (see `widget_by_note`)."""
    try:
        home = str(phone().dir)
    except Exception:
        home = ""
    if home not in _watching:
        _watching.add(home)
        threading.Thread(target=_watch, args=(phone,), name="redde-phone-areas", daemon=True).start()

    def offered(area):
        def check() -> bool:
            try:
                return phone().offers(area)
            except Exception:
                return False
        check.__qualname__ = f"redde_phone_{area or 'any'}_offered"
        try:    # (a check that reads a file is quick and must not be remembered for half a minute)
            from tools.registry import no_cache_check_fn
            no_cache_check_fn(check)
        except Exception:
            pass
        return check

    checks = {area: offered(area) for area in (None, *AREAS)}

    def handler(name):
        def handle(args, **kwargs) -> str:
            args = args if isinstance(args, dict) else {}
            if TOOLS[name][0] == "widget":
                # A phone following the turn does it and answers; any other hears by notification.
                return phone().ask(name, args, session=kwargs.get("session_id"), wait=WIDGET_WAIT,
                                   otherwise=lambda: widget_by_note(name, args, to_widget))
            return phone().ask(name, args, session=kwargs.get("session_id"))
        return handle

    for name, (area, description, properties, required) in TOOLS.items():
        schema = {"name": name, "description": description,
                  "parameters": {"type": "object", "properties": properties, "required": required}}
        ctx.register_tool(name=name, toolset=TOOLSET, schema=schema, handler=handler(name), check_fn=checks[area], emoji="📱")

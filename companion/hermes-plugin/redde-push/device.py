"""Phone tools: things on the person's iPhone that the agent can ask the Redde app to do, because
iOS lets an app do them with its owner's permission. The calendar, reminders, contacts, the photo
library, one folder of files, alarms, a widget of Redde's that the agent writes on, starting a
call or a message for the person to send, reading the Apple Health data they chose to share
(read only, each kind shared on its own), and Apple Home (HomeKit) on the phone. Nothing here reaches into other apps: iOS allows no app
that.

How a call travels. The agent calls a tool here; the call is written down as a small file in the
Hermes home and the tool waits. The Redde app, which is following the turn, sees the tool start,
asks this plugin what is wanted (`/redde-push device next`, over the Dashboard), does it on the
phone, where the person may be asked first, and hands the answer back (`/redde-push device done
<id> <answer>`), which is written down beside the request. The tool reads it and returns. Files
and not memory, because the agent's turn and the app's command can be in different processes
(the gateway's and the Dashboard's).

Which tools the agent is offered is the phone's to say (`/redde-push device areas calendar,files`
or `none`): a tool whose area is off isn't offered at all. With every area off, which is how it
starts, the agent sees none of this. The main agent's areas are those; a bot (another Hermes
profile) has its own, which the phone gives all at once (`/redde-push device bots
health=health,calendar scout=none`): a bot it gives none gets none (1.24.0), and one it doesn't
name gets the calendar and reminders, when they're on for the main agent (1.25.0). Every
profile's requests are written down in the main home's folder, the one the app's command reads,
each with the profile that made it, so the phone asks on that bot's behalf and by its rules.

How a copy answers (issue 50). With Redde's Settings › Phone tools › Keep a copy turned on, the
app also hands this plugin, while it is open, a whole read-only copy of the calendar and reminders
its tools could already show (`/redde-push device sync calendar|reminders <base64>`). A read of
either then answers from that copy on the person's own Hermes — fresh, and saying
`synced_minutes_ago` — even while the phone is away; a copy older than CACHE_FRESH only answers
when the phone doesn't, and says so. The phone stays the source of truth: nothing here edits a
copy, adding and changing always go to the phone, `live` asks the phone for a read too, turning
an area off wipes its copy, and `device cache wipe` wipes it by hand.

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
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

TOOLSET = "redde_phone"
#: How long a call waits for the phone, in seconds: a person may have to say yes on it.
WAIT = 120.0
#: A scheduled job's run: cron_<job id>_<date>_<time>. Phone tools answer at once there.
SCHEDULED_RUN = re.compile(r"^cron_[A-Za-z0-9]+_\d{8}_\d{6}")
NO_PHONE_IN_A_JOB = ("The iPhone can't be reached from a scheduled job: Redde answers phone tools only while it's open in a "
                     "chat. Go on without it, and don't call phone tools again in this run.")
#: A request nobody collected, or a saved file nobody needs any more, is cleared out after this.
STALE = 600.0
AREAS = ("calendar", "reminders", "contacts", "photos", "files", "alarms", "widget", "people", "health", "home")
#: A Hermes profile's name, as the phone may give it.
PROFILE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}")
# What a bot has when the phone hasn't set it, of the main agent's areas (1.25.0, asked 2026-11-10).
BOT_DEFAULT = ("calendar", "reminders")
#: The kinds of Apple Health data `phone_health_read` knows (the app's `HealthKind`); the person
#: shares each on its own, and phone_info says which.
HEALTH_TYPES = ("steps", "walking_running_distance", "active_energy", "exercise_minutes", "stand_hours", "flights_climbed",
                "time_in_daylight", "weight", "bmi", "body_fat", "heart_rate", "resting_heart_rate", "heart_rate_variability",
                "blood_pressure", "vo2_max", "walking_heart_rate", "cardio_recovery", "afib_burden", "ecg", "heart_alerts",
                "sleep", "wrist_temperature", "breathing_disturbances", "respiratory_rate", "blood_oxygen", "body_temperature",
                "water", "caffeine", "dietary_energy", "protein", "walking_steadiness", "noise_exposure", "headphone_audio",
                "mindful_minutes", "workouts", "workout_routes", "menstrual_flow")
#: How long a call for the widget waits for a phone that is following the turn, before what was
#: written is sent to the phone as a notification instead.
WIDGET_WAIT = 10.0

#: A copy at most this old answers without bothering the phone (6 hours).
CACHE_FRESH = 6 * 3600.0
#: Past this a copy is too old to answer at all, stale or not (30 days).
CACHE_KEEP = 30 * 86400.0
#: The most JSON the phone may hand over as one copy, in bytes (1.5 MB).
CACHE_MAX = 1_500_000
#: The most items in one copy.
_COPY_ITEMS = 500
#: What a calendar copy that doesn't say what it covers is taken to cover: the week before it was
#: made to a month after, or, where it holds as many events as an older app sent (200), only to
#: its last one. A copy answers only for days it covers; the rest are asked of the phone.
_COPY_BEFORE = 7 * 86400.0
_COPY_AFTER = 30 * 86400.0
_COPY_FULL = 200
#: Tool name -> kind the copy is for.
_COPY_OF = {"phone_calendar_events": "calendar", "phone_reminders_list": "reminders"}
#: The kinds of copies.
_COPY_KINDS = ("calendar", "reminders")
#: The payload key the app fills for each kind.
_COPY_KEY = {"calendar": "events", "reminders": "reminders"}

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
    # (Led by what it is for, in the words people ask with: Hermes's tool search lists a tool by its
    # first sentence and finds nothing for a query whose rarest word no tool has, "agenda" say.)
    "phone_calendar_events": ("calendar", "The user's calendar, agenda or schedule: events, meetings and appointments today, "
                              "tomorrow or any days, from every calendar on their iPhone. Between two moments (default: the "
                              "coming week), soonest first. " + _WHEN + " Runs through the Redde app on the phone: it answers "
                              "while Redde is open there, and, if the phone keeps a copy of its calendar on the server — Redde's "
                              "Settings, Phone tools, Keep a copy — from that copy with Redde closed, saying when it was last synced.", {
        "start": _text("From when. Default: now."), "end": _text("Until when. Default: a week after the start, or a year when searching with query."),
        "query": _text("Find events by any of these words in the title, place or notes (a name, a place, a flight number): with no "
                       "end it searches the coming year, so use it to find when something is rather than reading week by week."),
        "limit": _count("At most this many (default 50)."),
        "live": {"type": "boolean", "description": "Ask the phone now, instead of answering from Redde's copy of it, if the phone keeps one."},
    }, []),
    "phone_calendar_add_event": ("calendar", _WHERE + "Adds an event to the user's calendar. " + _ASKED + _WHEN, {
        "title": _text("What it is."), "start": _text("When it starts; a day alone makes it an all-day event."),
        "end": _text("When it ends. Default: an hour after the start."),
        "all_day": {"type": "boolean", "description": "An all-day event."},
        "location": _text("Where."), "notes": _text("Notes."),
        "calendar": _text("The calendar's name. Default: the user's default calendar."),
    }, ["title", "start"]),
    "phone_reminders_list": ("reminders", _WHERE + "The user's reminders that are still to do, soonest due first. "
                            "If the phone keeps a copy of its reminders on the server — Redde's Settings, Phone tools, Keep a copy — "
                            "this answers from that copy with Redde closed, and says when it was last synced.", {
        "list": _text("Only this reminders list, by name."),
        "include_completed": {"type": "boolean", "description": "The completed ones too."},
        "limit": _count("At most this many (default 50)."),
        "live": {"type": "boolean", "description": "Ask the phone now, instead of answering from Redde's copy of it, if the phone keeps one."},
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
    "phone_health_read": ("health", _WHERE + "Reads the user's Apple Health data, read only, and only the types they share "
                          "(phone_info lists them as health_shared). Gives numbers with units: by day, week or month, or a "
                          "total; sleep as nights, workouts as a list. " + _WHEN, {
        "type": {"type": "string", "enum": list(HEALTH_TYPES), "description": "What to read."},
        "start": _text("From when. Default: 7 days ago (14 for workouts)."), "end": _text("Until when. Default: now."),
        "stat": {"type": "string", "enum": ["sum", "average", "min", "max", "latest"],
                 "description": "Default: sum for amounts (steps), average for measurements (weight)."},
        "by": {"type": "string", "enum": ["day", "week", "month", "total"], "description": "Default: day."},
    }, ["type"]),
    "phone_home_list": ("home", _WHERE + "The user's Apple Home (HomeKit) accessories: name, room, kind, state, "
                        "brightness, temperature and target (in unit), and scenes. To show them, pass the rows as a 'home' "
                        "card's devices as they are, entity included: its controls then work on the phone directly.", {
        "room": _text("Only this room."), "query": _text("Only accessories matching these words, like 'office light'."),
    }, []),
    "phone_home_set": ("home", _WHERE + "Changes an Apple Home accessory. Locks, garage doors, doors, windows and the security "
                       "system always ask the user first; the rest may not. Give only what changes.", {
        "target": _text("The accessory, by name with its room if needed ('office light'), or its entity."),
        "all": {"type": "boolean", "description": "Every match, like all the kitchen lights."},
        "on": {"type": "boolean"}, "brightness": _count("0-100."), "color_temperature": _count("Kelvin, 2000-6500."),
        "color": _text("A colour as #RRGGBB."), "target_temperature": {"type": "number", "description": "In the unit phone_home_list gives."},
        "mode": {"type": "string", "enum": ["heat", "cool", "auto", "off"]}, "fan_speed": _count("0-100."),
        "position": _count("Blinds, windows, doors: 0 closed to 100 open."),
        "lock": {"type": "string", "enum": ["lock", "unlock"]}, "door": {"type": "string", "enum": ["open", "close"]},
        "security": {"type": "string", "enum": ["home", "away", "night", "off"]},
    }, ["target"]),
    "phone_home_scene": ("home", _WHERE + "Runs an Apple Home scene by name. One that unlocks or opens something asks the "
                         "user first.", {"scene": _text("The scene's name.")}, ["scene"]),
    "phone_widget_clear": ("widget","Runs on the user's iPhone, through the Redde app: takes everything off Redde's \"From Your "
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
    files under the plugin's folder in the main Hermes home, readable only by its owner. Made
    from a bot's home (`<main>/profiles/<name>`), it is that bot's: the same folder, its own areas."""

    def __init__(self, home: Path):
        home = Path(home)
        if home.parent.name == "profiles":
            self.profile, root = home.name, home.parent.parent
        else:
            self.profile, root = "default", home
        self.dir = root / "redde-push" / "device"

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
        """The areas this agent is offered. A bot's are some of the main agent's: the ones the phone
        gave it, or BOT_DEFAULT when the phone hasn't set that bot; none at all until the phone has
        said anything about bots (an older Redde would answer a bot's request as the main agent's)."""
        kept = self._read(self.dir / "areas.json") or {}
        main = [area for area in kept.get("areas", []) if area in AREAS]
        if self.profile == "default":
            return main
        bots = self._bots()
        if bots is None:
            return []
        mine = bots.get(self.profile, BOT_DEFAULT)
        return [area for area in main if area in mine]

    def _bots(self) -> dict[str, list[str]] | None:
        """Each bot the phone set, with its areas (empty: it was given none); None before it set any."""
        kept = self._read(self.dir / "bots.json")
        bots = kept.get("bots") if isinstance(kept, dict) else None
        if not isinstance(bots, dict):
            return None
        return {name: [a for a in AREAS if a in (areas or [])] for name, areas in bots.items()
                if isinstance(name, str) and PROFILE.fullmatch(name) and isinstance(areas, list)}

    def bots(self) -> dict[str, list[str]]:
        """Each bot the phone set, with its areas; the others have BOT_DEFAULT."""
        return self._bots() or {}

    def set_bots(self, bots: dict[str, list[str]]) -> dict[str, list[str]]:
        """Replaces every bot's areas. One given none is kept as none (not BOT_DEFAULT)."""
        self._folder("requests")
        kept = {name: [a for a in AREAS if a in areas] for name, areas in bots.items()
                if PROFILE.fullmatch(name) and name != "default"}
        self._write(self.dir / "bots.json", {"bots": kept, "at": time.time()})
        return self.bots()

    def set_areas(self, areas: list[str]) -> list[str]:
        self._folder("requests")
        self._write(self.dir / "areas.json", {"areas": [a for a in AREAS if a in areas], "at": time.time()})
        # Turning an area off takes its copy with it.
        for kind in _COPY_KINDS:
            if kind not in areas:
                try:
                    (self.dir / "cache" / f"{kind}.json").unlink()
                except OSError:
                    pass
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
            where = "Settings, Phone tools" if self.profile == "default" else "this bot's Edit Bot, Phone tools"
            return json.dumps({"error": f"Phone tools for this are turned off in Redde on the iPhone ({where})."})
        if SCHEDULED_RUN.match(session or ""):
            # No phone follows a scheduled job's run, so nothing would ever collect the request
            # (2026-11-04: Morning Ideas waited two minutes a call and tried again and again). A
            # copy kept for when Redde is closed answers at once, however old.
            return otherwise() if otherwise is not None else json.dumps({"error": NO_PHONE_IN_A_JOB})
        request = uuid.uuid4().hex[:16]
        asked = self._folder("requests") / f"{request}.json"
        answered = self._folder("answers") / f"{request}.json"
        self._tidy()
        self._write(asked, {"id": request, "tool": tool, "args": args or {}, "session": session or "", "profile": self.profile,
                            "at": time.time()})
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
                found.append({key: request.get(key) for key in ("id", "tool", "args", "session")}
                             | {"profile": request.get("profile") or "default"})
        return found

    def answer(self, request: str, answer: dict) -> bool:
        """The phone's answer to a request. False for a request that is no longer waiting."""
        if not re.fullmatch(r"[0-9a-f]{16}", request or "") or not (self.dir / "requests" / f"{request}.json").exists():
            return False
        self._write(self._folder("answers") / f"{request}.json", answer)
        return True

    # ---- a read-only copy of the phone's calendar and reminders

    def sync(self, kind: str, payload: dict) -> tuple[int, str | None]:
        """Accept a copy from the phone. Reject unless kind is calendar/reminders and
        payload is a dict whose _COPY_KEY[kind] is a list of at most _COPY_ITEMS items;
        write it (keeping only dict items with a string title, only scalar values,
        strings capped at 1000 chars, via _plain); return (count, None); on rejection
        return (0, "short reason")."""
        if kind not in _COPY_KINDS:
            return (0, f"redde-push device refused: unknown kind {kind}")
        key = _COPY_KEY[kind]
        if not isinstance(payload, dict) or key not in payload:
            return (0, "redde-push device refused: that copy can't be read")
        items = payload[key]
        if not isinstance(items, list):
            return (0, "redde-push device refused: that copy can't be read")
        if len(items) > _COPY_ITEMS:
            return (0, f"redde-push device refused: that copy is too big ({len(items)} items, {_COPY_ITEMS} at most)")
        # Keep only dict items with a string title, only scalar values, strings capped at 1000 chars.
        plain = [_plain(item) for item in items if isinstance(item, dict) and isinstance(item.get("title"), str)]
        data = {"at": time.time(), key: plain}
        # The days a calendar copy covers, as the app says (1.25.1): an event past them isn't in it,
        # so a day past them isn't empty, only not known here.
        if kind == "calendar":
            since, until = _epoch(payload.get("from")), _epoch(payload.get("to"))
            if since is not None and until is not None and since <= until:
                data["from_ts"], data["to_ts"] = since, until
        self._write(self._folder("cache") / f"{kind}.json", data)
        return (len(plain), None)

    def copy(self, kind: str) -> dict | None:
        """Read the copy file; return None if missing, malformed, or older than CACHE_KEEP;
        else {"at": <float>, "age": <seconds old>, <key>: <items>}."""
        path = self._folder("cache") / f"{kind}.json"
        data = self._read(path)
        if not isinstance(data, dict):
            return None
        at = data.get("at")
        if not isinstance(at, (int, float)):
            return None
        if time.time() - at > CACHE_KEEP:
            return None
        key = _COPY_KEY[kind]
        items = data.get(key)
        if not isinstance(items, list):
            return None
        held = {"at": at, "age": time.time() - at, key: items}
        if kind == "calendar":
            since, until = data.get("from_ts"), data.get("to_ts")
            if not isinstance(since, (int, float)) or not isinstance(until, (int, float)):
                # An older app's copy says nothing of its days: taken to be the usual window, or,
                # where it is full, to end at its last event.
                starts = [s for s in (_start_of(item) for item in items if isinstance(item, dict)) if s is not None]
                since = at - _COPY_BEFORE
                until = max(starts) if len(items) >= _COPY_FULL and starts else at + _COPY_AFTER
            held["from_ts"], held["to_ts"] = float(since), float(until)
        return held

    def wipe(self, kind: str | None = None) -> None:
        """Unlink cache/<kind>.json (or both kinds when kind is None), ignoring OSError."""
        if kind is None:
            for k in _COPY_KINDS:
                try:
                    (self.dir / "cache" / f"{k}.json").unlink()
                except OSError:
                    pass
        else:
            try:
                (self.dir / "cache" / f"{kind}.json").unlink()
            except OSError:
                pass

    @staticmethod
    def _covers(tool: str, args: dict, held: dict) -> bool:
        """Whether the copy covers what is asked: for the calendar, every day of the window asked
        about (a December day in a copy that ends in November was answered "nothing on", 11-10)."""
        if _COPY_OF.get(tool) != "calendar" or "to_ts" not in held:
            return True
        start, end = _span(args)
        return held["from_ts"] <= start and end <= held["to_ts"]

    def _copy_answer(self, tool: str, args: dict, held: dict, stale: bool = False) -> str:
        """Filter the held items with the module helpers into {"events": [...]} or
        {"reminders": [...], ...} plus "more": <int left out> and "synced_minutes_ago": <int>;
        when stale, add "note" saying the phone didn't answer, this is Redde's copy of its
        calendar/reminders last synced N minutes ago and things may have changed.
        Strip *_ts keys via _undecorate."""
        kind = _COPY_OF[tool]
        key = _COPY_KEY[kind]
        items = held[key]
        if kind == "calendar":
            found, more = _window(items, args)
        else:
            found, more = _wanted(items, args)
        # Strip *_ts keys.
        found = [_undecorate(item) for item in found]
        result = {key: found, "more": more, "synced_minutes_ago": int(held["age"] / 60)}
        if stale:
            result["note"] = (f"This is Redde's copy of its {kind} last synced "
                              f"{result['synced_minutes_ago']} minutes ago and things may have changed.")
        if not self._covers(tool, args, held):
            since, until = (time.strftime("%Y-%m-%d", time.localtime(held[k])) for k in ("from_ts", "to_ts"))
            result["note"] = (f"The phone didn't answer, and Redde's copy of its calendar only covers {since} to {until}: "
                              "what is shown is only what falls in that, and nothing can be said about the days outside it. "
                              "Don't call those days free; say the calendar couldn't be read for them.")
        return json.dumps(result)

    #: The most words of a search asked of the phone one by one.
    _MOST_WORDS = 4

    def _ask_phone(self, tool: str, args: dict, session: str | None = None, wait: float = WAIT, otherwise=None) -> str:
        """`ask`, so that an older Redde searches the calendar as this plugin does. Redde 2.4 (293)
        looks a week ahead when no end is given and for the whole of the search, and missed a
        flight five weeks away that was searched for in other words (an iPad, 11-10). So a search
        is sent with its end (a year on), and when several words find nothing, each word is asked
        for on its own and the answers put together. A newer Redde finds it the first time."""
        query = str(args.get("query") or "").strip()
        if tool != "phone_calendar_events" or not query:
            return self.ask(tool, args, session=session, wait=wait, otherwise=otherwise)
        asked = dict(args)
        if asked.get("end") is None:
            asked["end"] = datetime.fromtimestamp(_span(args)[1]).strftime("%Y-%m-%d")
        first = self.ask(tool, asked, session=session, wait=wait, otherwise=otherwise)
        words = _words(query)[: self._MOST_WORDS]
        try:
            found = json.loads(first)
        except ValueError:
            return first
        if len(words) < 2 or not isinstance(found, dict) or found.get("events") != [] or "synced_minutes_ago" in found:
            return first
        answers: list[str | None] = [None] * len(words)

        def one(i: int, word: str) -> None:
            answers[i] = self.ask(tool, {**asked, "query": word}, session=session, wait=wait, otherwise=lambda: None)

        threads = [threading.Thread(target=one, args=(i, word), daemon=True) for i, word in enumerate(words)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(wait + 5)
        events, seen, more = [], set(), 0
        for text in answers:
            try:
                part = json.loads(text) if text else None
            except ValueError:
                part = None
            if not isinstance(part, dict) or not isinstance(part.get("events"), list):
                continue
            more += int(part.get("more") or 0)
            for event in part["events"]:
                key = (event.get("title"), event.get("start"))
                if key not in seen:
                    seen.add(key)
                    events.append(event)
        if not events:
            return first
        events.sort(key=lambda event: _epoch(event.get("start")) or 0)
        limit = _limit(args)
        return json.dumps({"events": events[:limit], "more": more + max(0, len(events) - limit)})

    def read(self, tool: str, args: dict, session: str | None = None, wait: float = WAIT) -> str:
        """The tool handler for the two read tools:
        - pop a live argument (bool) from args; if live is True, return self.ask(tool, args, session=session).
        - only consult the copy if self.offers(_COPY_OF[tool]); else fall through to ask.
        - held = self.copy(kind); if held and held["age"] <= CACHE_FRESH: return the copy answer at once.
        - if held (older, still within CACHE_KEEP): return self.ask(tool, args, session=session,
          wait=wait, otherwise=lambda: self._copy_answer(tool, args, held, stale=True)).
        - else return self.ask(tool, args, session=session)."""
        live = args.pop("live", False)
        if live:
            return self._ask_phone(tool, args, session=session, wait=wait)
        kind = _COPY_OF.get(tool)
        if kind is None:
            return self._ask_phone(tool, args, session=session, wait=wait)
        if not self.offers(kind):
            return self._ask_phone(tool, args, session=session, wait=wait)
        held = self.copy(kind)
        if held is None:
            return self._ask_phone(tool, args, session=session, wait=wait)
        if held["age"] <= CACHE_FRESH and self._covers(tool, args, held):
            return self._copy_answer(tool, args, held)
        if held["age"] <= CACHE_FRESH:
            # Days the copy doesn't cover: the phone, and the copy for what it has if it doesn't answer.
            return self._ask_phone(tool, args, session=session, wait=wait, otherwise=lambda: self._copy_answer(tool, args, held))
        # Older but still within CACHE_KEEP: ask the phone, fall back to copy.
        return self._ask_phone(tool, args, session=session, wait=wait,
                        otherwise=lambda: self._copy_answer(tool, args, held, stale=True))

    # ---- the same call, from the phone's side


def slash(phone: Phone, words: list[str]) -> str:
    """`/redde-push device …`, which is the app's. Every reply starts "redde-push device"."""
    if words[:1] == ["areas"] and len(words) == 2:
        on = phone.set_areas([] if words[1] == "none" else words[1].split(","))
        return "redde-push device areas " + (",".join(on) or "none")
    if words == ["status"]:
        return "redde-push device status " + (",".join(phone.areas()) or "none")
    # bots <profile>=<area,...|none> ...: every bot the phone set, at once; `bots none` clears them all,
    # which leaves every bot with BOT_DEFAULT (of the main agent's areas).
    if words[:1] == ["bots"] and len(words) >= 2:
        given: dict[str, list[str]] = {}
        if words[1:] != ["none"]:
            for word in words[1:]:
                name, _, areas = word.partition("=")
                if not PROFILE.fullmatch(name) or not areas:
                    return f"redde-push device refused: {word} isn't <bot>=<areas>"
                given[name] = [] if areas == "none" else areas.split(",")
        held = phone.set_bots(given)
        return "redde-push device bots " + (" ".join(f"{n}={','.join(a) or 'none'}" for n, a in sorted(held.items())) or "none")
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
    # sync <kind> <b64>
    if words[:1] == ["sync"] and len(words) == 3:
        try:
            raw = base64.b64decode(words[2], validate=True)
        except ValueError:
            return "redde-push device refused: that copy can't be read"
        if len(raw) > CACHE_MAX:
            return f"redde-push device refused: that copy is too big ({len(raw)} bytes, {CACHE_MAX} at most)"
        try:
            payload = json.loads(raw)
        except ValueError:
            return "redde-push device refused: that copy can't be read"
        if not isinstance(payload, dict):
            return "redde-push device refused: that copy can't be read"
        kind = words[1]
        count, problem = phone.sync(kind, payload)
        if problem:
            return problem
        return f"redde-push device sync {kind} {count}"
    # cache status
    if words[:1] == ["cache"] and words[1:2] == ["status"]:
        parts = []
        for kind in _COPY_KINDS:
            held = phone.copy(kind)
            if held is None:
                parts.append(f"{kind} off")
            else:
                parts.append(f"{kind} {int(held['age'] / 60)}m")
        return "redde-push device cache " + " ".join(parts)
    # cache wipe [kind]
    if words[:1] == ["cache"] and words[1:2] == ["wipe"]:
        if len(words) == 3 and words[2] not in _COPY_KINDS:
            return f"redde-push device refused: unknown kind {words[2]}"
        phone.wipe(words[2] if len(words) == 3 else None)
        return "redde-push device cache wiped"
    return "redde-push device: this command is for the Redde app."


_watching: set[str] = set()


def watch(path_of, every: float = 2.0) -> None:
    """Starts `_watch` on the file `path_of()` names, once for each file."""
    try:
        key = str(path_of())
    except Exception:
        key = ""
    if key not in _watching:
        _watching.add(key)
        threading.Thread(target=_watch, args=(path_of, every), name="redde-tools-watch", daemon=True).start()


def _watch(path_of, every: float = 2.0) -> None:
    """Has this process list its tools afresh when the phone turns an area on or off (or, for
    `calls.py`, changes which agents may call it): when the file `path_of()` names changes.

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
            stamp = path_of().stat().st_mtime_ns
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


def _limit(args: dict) -> int:
    try:
        return max(1, min(200, int(args.get("limit") or 50)))
    except (TypeError, ValueError):
        return 50


def _zone(name):
    try:
        return ZoneInfo(str(name)) if name else timezone.utc
    except (ValueError, ZoneInfoNotFoundError):
        return timezone.utc


def _moment(text, zone, day_end: bool = False):
    """A date as the phone writes it, or the agent: with an offset, or in the phone's own zone.
    A day alone is its first moment, or with `day_end` the first moment of the next."""
    text = str(text or "").strip()
    if not text:
        return None
    try:
        moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=zone)
    if day_end and re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
        moment += timedelta(days=1)
    return moment


def _readable(when: str) -> bool:
    """Whether the phone will be able to read a date: it does the reading, in its own time zone."""
    from datetime import datetime
    try:
        datetime.fromisoformat(when.strip().replace("Z", "+00:00"))
        return True
    except ValueError:
        return False


def _epoch(text) -> float | None:
    """Convert a date string to epoch seconds, or None if it can't be parsed."""
    from datetime import datetime
    try:
        return datetime.fromisoformat(str(text).strip().replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return None


def _start_of(item) -> float | None:
    """Numeric start or due timestamp from an item, if present and a number."""
    for key in ("start_ts", "due_ts"):
        try:
            if item.get(key) is not None:
                return float(item[key])
        except (TypeError, ValueError):
            pass
    return _epoch(item.get("start") or item.get("due"))


def _limit(args) -> int:
    """The limit from args, clamped to 1..200; bad input defaults to 50."""
    try:
        n = int(args.get("limit") or 50)
        return max(1, min(200, n))
    except (ValueError, TypeError):
        return 50


#: Words a search leaves out, as the app does (DeviceCalendar.matches).
_FILLERS = {"the", "and", "for", "with", "from", "into", "onto", "our", "his", "her", "their", "my", "any", "all"}
#: How far ahead a calendar search with no end looks (the app's searchReach).
_SEARCH_REACH = 365 * 86400.0


#: Tools shown to the agent outright: it found the calendar through tool search, saw one line of it,
#: guessed since/until for start/end and was answered the coming week six times (11-10).
_ALWAYS_SHOWN = ("phone_calendar_events",)
#: What an agent writes for the calendar tool's arguments when it guesses their names.
_CALENDAR_NAMES = {
    "start": ("since", "from", "after", "begin", "start_date", "from_date", "start_time", "starting", "time_min", "timeMin"),
    "end": ("until", "to", "before", "end_date", "to_date", "end_time", "ending", "time_max", "timeMax"),
    "query": ("q", "search", "text", "keyword", "keywords", "term", "terms"),
    "limit": ("max", "max_results", "maxResults", "count"),
}
_CALENDAR_DAY = ("date", "day", "on")


def _calendar_args(args: dict) -> tuple[dict, list[str]]:
    """The calendar tool's arguments under their own names, and those it doesn't take. A day alone
    ("date": "2027-07-08") is that whole day."""
    known = {"start", "end", "query", "limit", "live"}
    fixed = {key: value for key, value in args.items() if key in known}
    ignored = []
    for key, value in args.items():
        if key in known or value in (None, ""):
            continue
        own = next((name for name, others in _CALENDAR_NAMES.items() if key in others), None)
        if own:
            fixed.setdefault(own, value)
        elif key in _CALENDAR_DAY:
            fixed.setdefault("start", value)
            fixed.setdefault("end", value)
        else:
            ignored.append(key)
    return fixed, ignored


def _noting(answer: str, ignored: list[str]) -> str:
    """The answer, telling the agent which of its arguments were left out and what the tool takes."""
    if not ignored:
        return answer
    try:
        result = json.loads(answer)
    except ValueError:
        return answer
    if isinstance(result, dict):
        result["ignored"] = (f"Not arguments of this tool, so not used: {', '.join(sorted(ignored))}. It takes start and end "
                             "(ISO dates or times; a day alone is the whole day), query, limit and live.")
        return json.dumps(result)
    return answer


def _words(query: str) -> list[str]:
    """A search's words, in order, once each: three letters or more and not a filler."""
    found = []
    for word in re.split(r"[^\w]+", query.lower()):
        if len(word) >= 3 and word not in _FILLERS and word not in found:
            found.append(word)
    return found


def _matches(item, query: str) -> bool:
    """Whether any word of a query (already lowercased; three letters or more, not a filler) is in
    the item's title, location or notes; a query with no such word, as a whole. The agent searches
    in its own words ("dad flight"), which an event seldom has all of (11-10)."""
    if not query:
        return True
    texts = [str(item.get(key) or "").lower() for key in ("title", "location", "notes")]
    words = _words(query)
    if not words:
        return any(query in text for text in texts)
    return any(word in text for word in words for text in texts)


def _span(args) -> tuple[float, float]:
    """The window the calendar tool is asked about, as epoch seconds: start default now, end
    default start+7 days; a date-only end means the whole of that day (add one day)."""
    now = time.time()
    start = _epoch(args.get("start")) or now
    end = _epoch(args.get("end"))
    if end is None:
        # A search looks a year ahead (a week missed a flight a month away, 11-10).
        end = start + (_SEARCH_REACH if str(args.get("query") or "").strip() else 7 * 86400)
    if isinstance(args.get("end"), str) and _readable(args["end"]) and "T" not in args["end"]:
        end = end + 86400
    return start, end


def _window(items, args) -> tuple[list, int]:
    """Filter items to a time window, soonest first, and apply the limit.
    Mirrors the calendar tool's promise: start default now, end default start+7 days;
    a date-only end means the whole of that day (add one day).
    Returns (found[:limit], max(0, len(found) - limit))."""
    start, end = _span(args)
    query = (args.get("query") or "").lower().strip()
    found = []
    for item in items:
        s = _start_of(item)
        if s is None:
            continue
        if not (start <= s < end):
            continue
        if query and not _matches(item, query):
            continue
        found.append(item)
    found.sort(key=lambda item: _start_of(item) or 0)
    limit = _limit(args)
    return (found[:limit], max(0, len(found) - limit))


def _wanted(items, args) -> tuple[list, int]:
    """Filter items to what the reminders tool wants: drop completed unless include_completed,
    filter to list by name when given, sort soonest-due first with no-due-date last then title.
    Returns (found[:limit], max(0, len(found) - limit))."""
    query = (args.get("query") or "").lower().strip()
    include_completed = args.get("include_completed")
    list_name = args.get("list")
    found = []
    for item in items:
        if not include_completed and item.get("completed"):
            continue
        if list_name and item.get("list") and item["list"].lower() != list_name.lower():
            continue
        if query and not _matches(item, query):
            continue
        found.append(item)
    # Sort: soonest due first, no-due-date last, then title.
    def sort_key(item):
        due = _start_of(item)
        if due is None:
            return (1, 0, item.get("title") or "")
        return (0, due, item.get("title") or "")
    found.sort(key=sort_key)
    limit = _limit(args)
    return (found[:limit], max(0, len(found) - limit))


def _undecorate(item) -> dict:
    """Drop keys ending in _ts from an item."""
    return {k: v for k, v in item.items() if not k.endswith("_ts")}


def _plain(item) -> dict:
    """A copy item kept to plain scalars, strings capped at 1000 chars: the copy is read by
    this plugin's code and handed to the agent, not run as anything."""
    result = {}
    for key, value in item.items():
        if isinstance(value, bool) or isinstance(value, (int, float)):
            result[key] = value
        elif isinstance(value, str):
            result[key] = value[:1000]
    return result


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
    watch(lambda: phone().dir / "areas.json")
    watch(lambda: phone().dir / "bots.json")

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
            # Route the two copyable tools through the copy path first.
            if name == "phone_calendar_events":
                args, ignored = _calendar_args(args)
                return _noting(phone().read(name, args, session=kwargs.get("session_id")), ignored)
            if name in _COPY_OF:
                return phone().read(name, args, session=kwargs.get("session_id"))
            if TOOLS[name][0] == "widget":
                # A phone following the turn does it and answers; any other hears by notification.
                return phone().ask(name, args, session=kwargs.get("session_id"), wait=WIDGET_WAIT,
                                   otherwise=lambda: widget_by_note(name, args, to_widget))
            return phone().ask(name, args, session=kwargs.get("session_id"))
        return handle

    try:    # Shown outright, never behind tool search, whose one line hides the names it takes (11-10).
        import toolsets
        for name in _ALWAYS_SHOWN:
            if name not in toolsets._HERMES_CORE_TOOLS:
                toolsets._HERMES_CORE_TOOLS.append(name)
    except Exception:
        pass
    for name, (area, description, properties, required) in TOOLS.items():
        schema = {"name": name, "description": description,
                  "parameters": {"type": "object", "properties": properties, "required": required}}
        ctx.register_tool(name=name, toolset=TOOLSET, schema=schema, handler=handler(name), check_fn=checks[area], emoji="📱")

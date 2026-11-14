# redde-push

A Hermes plugin that notifies your iPhone, iPad or Mac, through [Redde](https://redde.goosehouse.org),
when the agent finishes a reply, waits for you, or gives up on a turn, also when Redde isn't running.
Each device pairs on its own and gets every note (ideas, briefings, heads-ups, approvals waiting,
replies); calls (`call_user`) ring only an iPhone or an iPad, never a Mac.

What a notification says is encrypted here, on your Hermes, with a key that only this plugin and
that device hold. It travels through a relay run by Goosehouse and through Apple's push service;
both carry it without being able to read it. The design is in
[docs/push.md](https://github.com/goosehouse-llc/redde/blob/main/docs/push.md).

## Set up

```
hermes plugins install goosehouse-llc/redde/companion/hermes-plugin/redde-push --enable
```

Restart Hermes (`hermes gateway restart`, and `hermes serve` if you run the Dashboard).

Or leave the terminal out of it: with the Hermes Dashboard login saved in Redde, Settings ›
Notifications › Alerts When Redde Is Closed has an Install the Plugin button that has this Hermes fetch
and enable the same plugin. Hermes 0.21.5 and later load it at once; earlier ones still need the
restart above.

**If Redde is connected through the Dashboard**, that is all there is to do here. In Redde:
Settings › Notifications › Alerts When Redde Is Closed › Pair with your server, on each iPhone,
iPad or Mac. A notification on the device confirms the pairing.

**Otherwise** (Redde on the Hermes API, or a device that isn't signed in to this Hermes), pair
with a code:

```
hermes redde-push pair
```

It shows a QR code and a link, and waits. In Redde: Settings › Notifications › Alerts When
Redde Is Closed › Pair with a code (on a Mac, copy the link and paste it). A notification on the device
confirms the pairing. Run it once for each device.

Run the command as the user Hermes runs as, without `-p`: the pairing is kept in that Hermes home
and read by the gateway and the Dashboard from there.

## Updating

The install line again, with `--force` on the end, then restart Hermes as above. Your pairings are
kept: they live beside the plugin, not in it. (`hermes plugins update redde-push` works from Hermes
0.21.5; earlier releases answer that the plugin wasn't installed from git, which is how they see
one that came out of a folder of a repository.) What each version changed is in
[CHANGELOG.md](CHANGELOG.md).

## Commands

| | |
|---|---|
| `hermes redde-push pair` | pair a device |
| `hermes redde-push list` | the paired devices (and which kind each is, for one paired from Redde 2.3 on) |
| `hermes redde-push test` | send each a test notification |
| `hermes redde-push remove <name or id>` | forget a device |
| `hermes redde-push notify mine` | notify about conversations each device took part in (the default) |
| `hermes redde-push notify all` | notify about every conversation on this Hermes |

## What is sent, and when

- **A reply finished**: the conversation's title and the reply's first 500 characters.
- **A command waits for approval**: the command and why it was stopped. For a turn over the
  Dashboard the notification has Approve and Deny, and opening the conversation brings back its
  card; Hermes waits five minutes for an answer by default (`approvals.timeout`).
- **The agent asks you a question**: the question and its choices. On Hermes 0.21.3 and later
  the notification takes your answer, typed or by a choice's button, and opening the conversation
  brings back its card.
- **A command run as root waits for your password, or a skill for a secret**: which command, or
  what is asked for. Hermes waits two minutes for a password and five for a secret. Over the
  Dashboard, on Hermes 0.21.3 and later; see below.
- **A turn ended without a reply**: the provider's error. Hermes doesn't tell a plugin that it
  has given up, only each time a request fails, so the plugin waits to see whether anything
  follows: 20 seconds after an error Hermes doesn't retry (a refused key), two and a half minutes
  after one it does (the provider is down), eleven after a rate limit. If the reply arrives
  after all, it takes the notification's place.
- **A task handed to a subagent came back**: what the agent says about it, or, over the Hermes
  API on 0.21.3 and later, where Hermes starts no turn for it, the task's own summary.
- **A bot said something in a group chat**: the group chat's name, the bot's, and the message.
  Reply on the notification answers in the group chat.
- **A bot waits on you in a group chat**: a command to approve (Approve and Deny on the
  notification), or a reply that didn't finish and waits for you to retry it (Retry).
- **One of a bot's schedules ran**: the schedule's name, the bot's, and what it came up with;
  opening it shows the bot's answer in its chat. The plugin reads every profile's cron jobs on
  this machine each half minute for it (`routines.py`). From 1.21.1 a schedule that answers in
  the bot's chat says what the bot said there, read from the bot's `state.db` (read-only), once
  it has (up to ten minutes; then the run's output), and a briefing says which session its run
  was in, which each run's turn writes down in `cron-runs.json`.

All of them only for conversations your phone has taken part in: over the Dashboard the app tells
the plugin which those are, and over the Hermes API every turn counts. A session at the terminal
or in Hermes Desktop stays quiet unless you choose `notify all`. Group chats notify for the ones
Redde lists, which it tells the plugin over the Dashboard; Hermes Desktop's own group chats
aren't on the server, so they don't. A bot's chat or a group chat you mute in Redde sends that
phone nothing while it is muted.

Hermes has no hook for a bot's message in a group chat, so the plugin reads the group chats' own
log every four seconds, from whichever of Hermes's processes has it loaded (several reading at
once send each message once). A bot waiting on you is known to the process running the group
chat: the Dashboard's, which is also where Redde answers it.

Hermes has a hook for a plugin when a reply finishes and when a command needs approval. For the
rest the plugin reads what Hermes hands every plugin after each answer from the model: a call to
the question tool there means a question is about to be asked. A password or a secret being
asked for appears nowhere a plugin is shown, so while a followed conversation runs tools the
plugin looks, twice a second, at the list the Dashboard keeps of what it is waiting on a person
for (the list it gives a client that reconnects). That list is Hermes's own business, not an
interface: a later Hermes may move it, and then those two notifications stop until the plugin
catches up. Nothing else depends on it.

The relay is sent the encrypted note and the secret that lets it through to your phone. It is
never sent the key, and it stores nothing that passes.

## What it keeps

`$HERMES_HOME/redde-push/`, readable only by you: `devices.json` (each device's relay id, relay
secret, key, name and kind: `iphone`, `ipad` or `mac`, absent for one paired by an older Redde), `watch.json` (which sessions each phone follows), `rooms.json` (which group
chats), `mutes.json` (what each phone has muted, until when), `room-cursors.json` and `room-waits.json`
(how far each group chat has been read, and what it has been said to wait on), and
`routine-runs.json` (the last run of each bot's schedule it has told of), and `calls.json` (which
agents each phone takes calls from, and the calls of the last day), and `keys.json` with `keys/`
(the keys agents have asked for: each request's name, profile and why, never a value, and a key
pair made for that request alone, deleted once it is answered), and `leave.json` (when to wake
each device for Leave-By Alerts' traffic re-check: an opaque id, the event's title and a time,
each forgotten once sent), and `turn-notes.json` (what Redde says to the agent with a message it
is about to send: your reply language, your units and, on a question about places, roughly where
you are; removed when that message's turn starts, see "With a message" below), and `work.db`
(each workstream: its id, title, brief, its session and the chat that started it, how it stands
and its last words, forgotten 30 days after it ends). Delete the folder
and nothing is paired.

## Phone tools

From 1.2.0 the plugin also offers the agent tools that are carried out on the iPhone, by the
Redde app: the calendar, reminders, contacts, the photo library, Redde's folder in the Files
app and, from 1.3.0, alarms and timers, a widget the agent writes on, and calls and messages
(a call the phone asks the person to confirm, a message written for them to send)
(`phone_calendar_events`, `phone_reminders_add`, `phone_photos_search`, `phone_alarms_set`,
`phone_widget_set`, `phone_people_call` and so on, twenty-one in the toolset `redde_phone`;
`device.py` has each one's description). They need no pairing, with one exception: what the agent writes for the widget
in a turn no phone is following (a scheduled job, another client) is sent to the paired phones
as a note, sealed like any other, and the phone puts it on the widget.
Photos are found by date and kind, and by what they show or say (`query`): the phone looks at
its pictures itself and answers with the ones that match, not with the pictures.

The agent is offered none of them until the phone turns an area on (Redde's Settings → Phone
tools), and only that area's then. A call waits, for up to two minutes, while the app does the
work, asking the person first where it should; the app hears of the call in the turn it is
following and answers through this plugin's command over the Dashboard, so the tools answer
only while Redde is open on the phone and in that conversation, and the app needs the
Dashboard login. A photo or a file the agent asks for is saved under `redde-push/device/files`
in the Hermes home for a day.

A conversation already open on the Dashboard keeps the tools it started with; a new one sees
the change within a couple of seconds.

From 1.15.0 the phone can also hand the agent a read-only copy of its calendar and reminders
(Redde's Settings → Phone tools → Keep a copy, off until you turn it on): while Redde is open
the app sends what its `phone_calendar_events` and `phone_reminders_list` could already show,
and from then on a read of either answers from that copy, on the person's own Hermes, even with
Redde closed — saying `synced_minutes_ago`. A copy older than six hours answers only when the
phone can't; past thirty days it answers no more. Writes always go to the phone, and a `live`
read does too; turning the area or the setting off takes the copy with it, and the app can wipe
it by hand (`/redde-push device cache wipe`).

## Calls

From 1.8.0 an agent can ring the paired iPhone like a phone call, with `call_user` (toolset
`redde_calls`), for something that shouldn't wait until you next look. Its one argument, `line`,
is what it says first when you answer; a missed call shows it. The phone decides which agents may
call it (Redde's Settings): with calls on, every agent sees the tool, and one you haven't allowed
is refused when it tries, and told so. One agent calls
at most once in five minutes (in one minute after a call you picked up), and all of them twenty
times a day. A call goes through the relay
as a VoIP push, sealed like any note, to an address Redde gives the relay once calls are on; the
tool returns when Apple has it, without waiting to hear whether you answered. A conversation
already open keeps the tools it started with: it gets `call_user` once it is opened again. From
1.10.0 a device says at pairing whether it is an iPhone, an iPad or a Mac, and a Mac is never rung.

## Ideas

From 1.9.0 an agent can offer things it could do for you, with `suggest_to_user` (toolset
`redde_ideas`): up to five ideas, each a heading, a line on why now, and the request it would
carry out. They come to every paired iPhone as one notification and as cards at the top of
Redde's chats: swipe one right and its request goes to that agent as your message, in its chat;
swipe left and it is put away. Nothing is done until you take one. Redde's Settings, Agent,
Morning Ideas sets up a daily Hermes job that has the main agent look at your day and offer
ideas this way. One agent sends ideas at most ten times an hour. The tool is offered once a
phone is paired. From 1.10.0 a run of that job, or of Routine Suggestions, that wrote its ideas
out instead of calling the tool (a model that didn't find it behind Hermes 0.22's `tool_search`)
still reaches the phone: lines `IDEA: title | why now | the request` become the cards, and any
other answer but NOTHING NEW comes as a briefing.

## Keys asked for

From 1.10.0 an agent that needs a key it hasn't got (an API key for a plugin or an MCP server it is
setting up) asks for it by name with `request_secret` (toolset `redde_keys`), and never in the
chat: you get a card in Redde (a notification on each paired iPhone, the call's card in the chat,
and Settings, Agent, Keys Asked For) with the name, which profile's `.env` it goes in, and why.
Paste the key there and it goes straight into that `.env`; or decline. The agent learns only
that it is set or declined, on its next turn or with `secret_status`, and refers to it in config
as `${env:NAME}`.

The key travels sealed to that one request: the plugin makes a key pair for each request
(X25519), Redde seals what you paste to it (HKDF-SHA256, AES-GCM, bound to the request's id,
name and profile) and hands it to the plugin over the Hermes Dashboard, as a plugin command,
which Hermes keeps in no session and no log. The plugin opens it once, writes it with Hermes's
own `.env` writer (its lock and quoting; the line replaced if the name is there), and deletes the
request's private half. Nothing of the value is kept by the plugin, the relay, the notification or
the app. Over the Hermes API alone there is no such command, so Redde needs the Dashboard login
for that server to answer (Settings, Connection); without it, it says so and sends nothing.
Requests wait a day; one agent may ask ten times an hour; names that change how programs run
(`PATH`, `LD_…`, `PYTHON…`, `HERMES_HOME`) are refused. Hermes reads `.env` when it starts, so a
key counts after the next restart, which the card offers.

## Watches, follow-ups, heads-ups and briefings

Also from 1.9.0, things the agent does for you on its own time, each a Hermes cron job:

- **Watches**, made from Redde (Settings, Agent, Watches & Follow-ups, or a message's Watch
  This…): jobs named `[redde-watch:<id>] …` that look at something on a schedule. Each run is told
  what it said last time and answers NOTHING NEW or what changed; only a change reaches the phone.
  A watch can be a bot's (its job in the bot's profile), and can hand what it sees to another
  agent: its job delivers `bot-chat:<profile>`, so Hermes gives each change to that agent's Bot
  Chat as a turn, where it acts with its own tools; it answers `[SILENT]` when nothing changed.
- **Watches the agent sets**: asked to let you know when something happens, the agent calls
  `keep_an_eye_on` (toolset `redde_ideas`), which makes the same kind of watch, for a number of days.
- **Follow-ups**: when you mention something to do later, the agent may call `follow_up_later`
  (toolset `redde_ideas`), which makes a job that runs once at that time and offers it back to
  you as an idea card.
- **Heads-ups**: `heads_up_before` makes a job that runs once, a few minutes before an event on
  your calendar, named `[redde-notify] Heads-up: …`; its answer, what you need for the event,
  comes as a notification. Redde's Settings, Agent, Heads-Ups sets up a morning job that has the
  main agent set them for the day. From 1.10.0 the notification carries the event's start and
  address, for Redde's leave time and its Up Next widget.
- **Briefings**: the answer of any job whose name starts with `[redde-notify] ` comes to the
  paired phones as a notification and is kept in Redde's Briefings, the whole of it (up to 1,800
  characters from 1.10.0; 500 before). Redde's
  Evening Wrap-up is one: what got done today, what waits on you, what carries over.

The tools are offered once a phone is paired.

## Goals and skipping a run

From 1.15.0 (Redde 2.4):

- **Goals**: something you want to reach over days or weeks. When a message sounds like one ("I
  want to run a 10K by March", "help me save for the trip"), and only then, the agent is told it
  can propose a plan and, once you agree, call `redde_goal` (toolset `redde_ideas`; actions `set`,
  `update`, `status`, `end`). A goal is kept in the profile's `redde-push/goals.json`; each step
  becomes a Kanban card in triage under tenant `redde-goal-<id>`, so no worker starts on it until
  you approve it in Redde (on a Hermes with no board, the steps are kept in the file alone); and a
  job named `[redde-goal:<id>] …` checks in, by default Mondays at 9:00, or every other day at
  9:00 when the goal is under two weeks away. Each check-in is told the goal's steps and how each
  stands, and starts its answer with `PROGRESS: <done>/<steps> | <how it's going> | <next>`;
  that comes to the phones as a briefing carrying the goal's id and progress. Anything that needs
  your say comes as an idea card. Unrelated to Hermes's own `/goal` command.
- **Skipping a run**: Redde's Coming Up skips a repeating job's next run by adding
  ` [redde-skip:<when>]` to its name (the one change the Hermes API can make to a job besides
  pausing it). Every half minute, phone paired or not, the plugin moves such a job's next run on
  to the one after with Hermes's own schedule arithmetic and takes the mark off. Over the
  Dashboard, `/redde-push skip <profile> <job> <when>` does it at once.
- **Watches on email** (Redde's watch templates) answer `NO EMAIL ACCESS` where the agent has no
  tool that reads email; the phone is told once, and the watch is paused.

`/redde-push goals list` gives the app every agent's goals, with their steps and latest progress;
`/redde-push goals end <profile> <goal>` ends one. A goal's check-in job is the truth: delete it
(over either connection) and the goal is ended; change its schedule and the goal's follows.

## Leave-By Alerts' traffic re-check

From 1.11.0. Redde's Leave-By Alerts (Settings, Agent) work out on the device, with Apple Maps,
when to leave for each event on its calendar that has a street address, and set a notification
for then. iOS runs the app in the background when it likes, so the traffic can change after Redde
last looked. With this plugin and the Dashboard login, Redde asks this Hermes to wake the device
about twenty minutes before each leaving time (`/redde-push leave set <device> <wakes>`, over the
Dashboard). At that time the plugin sends that one device a sealed note of its own kind
(`leave`); the device asks Apple Maps again, moves its alert if the traffic changed, and shows one
quiet notification with the result ("Dentist: traffic checked", "Dentist: traffic is heavier").

What Hermes is told, per alert: an opaque id (a hash of the device's own name for the alert), the
event's title for the note, and when to wake. No address, no place, nothing else from the
calendar. Redde sends the whole list each time it changes, so a moved alert replaces its old
time and one deleted or moved off the calendar is taken back; turning Leave-By Alerts off takes
them all (`leave cancel <device>`). Each wake is sent once, from the thread that reads the
schedules (every half minute), then forgotten; one more than fifteen minutes late (Hermes was
down) is let go unsent. At most 30 a device, the soonest. Over the Hermes API alone there is no
way for the app to say any of this, and Leave-By Alerts work as before.

## With a message (1.21.0)

Some of your settings in Redde are things the agent has to hear with a message: the language to
reply in, your units, which calendars to look at, roughly where you are when you ask about a
place (only with Current Location on), "keep it short, I'm driving". The Hermes API takes them
as the turn's instructions. The Dashboard takes none, so Redde used to write them after the
message as a note, "(Reply in Dutch.)", which Redde hides and every other app shows.

From 1.21.0 Redde hands the note to the plugin just before it sends the message
(`/redde-push turn <session> <mark> <note>`, the mark being a hash of the message's words), and
the plugin gives it to the model as that turn's context: Hermes puts a plugin's context after
the message for the model alone, and stores the message as it was typed. The note is kept in
`turn-notes.json` until the turn starts (a message queued behind another turn finds its own by
the mark), two hours at most. On a Hermes with an older plugin, or none, Redde writes the note
after the message as before.

## Workstreams (1.22.0, over the Hermes API from 1.23.0)

`redde_work` (`work.py`): the main agent or a bot hands a job to a workstream, a chat of its own
that works on it by itself while the chat that started it goes on. Actions: `start` (a title
and a brief that says everything the job needs: the workstream sees nothing else), `list`,
`read` (its last messages), `send` (more to do: steers it if it is running, else a new turn) and
`stop`. Three at once per agent; a workstream can't start one of its own.

It runs inside `hermes serve` (the Dashboard), the way Hermes runs its own group rooms: a hidden
session in the agent's profile, titled "Work: W1 · <title>", out of the chat list, kept open with
no client on it. When its turn ends the plugin writes down how it ended (done, failed or
stopped, with its last words) and, once the chat that started it is free, queues a hidden turn
there with the report, worded as a report and not as your words; the agent tells you what came
of it, or answers `[SILENT]`. Every turn in that chat also hears, as context, how its open
workstreams stand. A step that needs approval waits for you as Hermes asks it, in the
workstream's own session, which Redde opens; the approval timeout (`approvals.timeout`, 300 s at
first) applies there as anywhere, so an agent whose workstreams ask often may want it longer.

Over the Hermes API (`work_runs.py`, 1.23.0) the gateway runs them instead: a session of the
API's own with the same title, whose turns are runs (`POST /v1/runs`) the plugin starts on the
gateway's own listener with the profile's own API key (the main one, or a bot's own
`API_SERVER_KEY` at `/p/<bot>/`). Hermes's hooks follow its turns as on the Dashboard; the report
reaches the chat that started it as a run of that chat's own once the chat has none going. The
key that starts a run is the only one that may answer its approvals, so a step that needs yours
is answered from Redde's Work sheet through the plugin. A chat on another platform (Telegram,
the CLI) is told workstreams run for chats in Redde.

For Redde: `/redde-push work list <profile> [chat]` (JSON after `redde-push work `),
`/redde-push work stop <profile> <W#>` and `/redde-push work answer <profile> <W#> <once|deny|…>`,
and a `work` note to the paired devices when one is done, fails or waits for you (`r: "api"` for
one the gateway runs). With no Dashboard login, Redde sends the same commands to the plugin's
route on the API server: `POST /v1/redde/command` with `{"command": "…"}` and the main API key,
answered `{"output": "…"}`.

## Models & providers over the Hermes API (1.26.0)

The Dashboard has routes for a profile's provider keys, its own endpoints, its main model, helper
models and config; the Hermes API has none that write. So that Redde's Models & Providers page
works on either connection, the plugin puts one route on the API server (`models.py`):
`POST /v1/redde/models` with the main API key and `{"action": "…", "profile": "default" | "<bot>"}`.
It runs Hermes's own functions in that profile's own home (a bot's keys go to
`profiles/<bot>/.env`, its settings to its own config.yaml) and answers in the Dashboard's shapes:

- `load` (`refresh`): the model picker's list, the provider keys (set or not, each only as Hermes's
  «redacted» preview), the endpoints, the helper models, the fallbacks and this plugin's version.
- `set_key`, `remove_key`: a provider's API key or an endpoint's (`HERMES_CUSTOM_…_API_KEY`), nothing
  else; a «redacted» preview is refused.
- `set_main`, `set_helper`: as the Dashboard's model assignment; neither takes a key.
- `set_fallbacks`: the list replaced whole, each entry keeping what it had beyond provider, model
  and base URL; the older `fallback_model` is taken out, as `hermes fallback` does.
- `save_endpoint`, `activate_endpoint`, `delete_endpoint`, `test_endpoint`: as the Dashboard's
  endpoint routes. The main model's own endpoint isn't deleted (409): Hermes would leave the main
  model with no provider.

No answer holds a key, none is logged, and no key is written into config.yaml: an older endpoint
whose key is written there has it moved to .env behind `key_env` before the main model is pointed
at it. A Hermes without one of the functions used answers that action 501.

## Requirements

Hermes 0.21.0 or later; 0.21.3 or later is the one to have. On 0.21.0 the Dashboard stops a turn
twenty seconds after the app disconnects, so little is left to notify about; setting
`dashboard.ws_orphan_reap_grace_s: 0` in `config.yaml` turns that off. It also keeps no list of
what it is waiting on, so there a password or a secret goes unannounced, and a question's card
doesn't come back when the conversation is opened.

`cryptography`, which Hermes already depends on. Nothing else: the QR code is drawn by `qr.py`
here.

## Tests

In the Redde repository, beside this folder: `companion/hermes-plugin/tests` (unit tests, run
with Hermes's own Python) and `scripts/hermes-lab/lab.sh push` and `lab.sh device`, which run the
plugin inside unmodified Hermes releases. They are kept out of this folder because everything in it is copied,
and scanned, when the plugin is installed. The scan is also why this page and the plugin's code
avoid the name of the command that runs another as root: Hermes refuses to install a plugin from
GitHub that has it in either.

## Cards

`redde_show` (`cards.py`): the agent shows a map, a list of places, the weather or the time under
its reply, and the Redde app draws them (MapKit). Nothing is sent to the phone; the app reads the
call, and the tool's answer, from the conversation. Offered unless Redde turns it off
(`/redde-push cards off`, from Settings → Agent → Cards in replies).

A weather or a time card names only its place. The tool looks it up (`forecast.py`): the place
through Open-Meteo's place search, then its forecast (now, 12 hours, 7 days) or its time zone, and
answers with the numbers and the filled card, so what the agent says and what the card shows
agree. This is the only thing the plugin asks of a service outside your Hermes and your phone:
the place's name goes to geocoding-api.open-meteo.com and its coordinates to api.open-meteo.com.
Open-Meteo is free without a key for non-commercial use, and its data is under CC BY 4.0 (the card
credits it). Each hour of the card has its chance of rain and, from 1.10.0, its wind gusts, and the card says
when it was read (`updated`, the place's time with its offset); the app draws the hours with the
rain to scale and calls out the first run of hours at 50 % or more, which the tool's answer says
too ("storms likely 14:00–17:00, likeliest 80% at 15:00"). From 1.10.0 a place in a `places` card can carry
its `price` ("$$"), `hours` (whether it is open, in words: "Open until 9 PM", "Closes at 5 PM")
and `pick` (the agent's pick); the app adds the walk to each from where the phone is, where it
already knows. Older apps ignore all of these. Redde tells the plugin the phone's time zone and temperature units
(`/redde-push cards on tz=… units=…`) for "what time is it" with no place. When a message asks the time or
the weather (in English), the plugin adds a line to that message only: the person's time in that
zone, and to show the card before answering. An agent asked "what time is it" otherwise answers
from Hermes's clock, which is the server's.

From 1.10.0, asked what is on the calendar ("what's on my calendar tomorrow", "what do I have today", "am I
free Friday", "when is my next meeting"), in English, the plugin adds a line to that turn: look
the events up with the calendar tool, show them as an `agenda` card, then answer in a line. An
`agenda` holds the `events` as the calendar tool gave them (each a `title` and a `start`: an ISO
date-time with its offset, or a date for all day; `end`, `location`, `calendar` if known) and the
`date` or `dates` asked about, so a free day shows as one. The app draws it by day. The plugin
looks nothing up for it and checks only that each event has a title and a dated start. Asked to
put something on the calendar, the line isn't added: that's an errand (below).

Asked to send, book, buy or change something for you, an agent is told to show a review card
first and wait for your tap (how much it may do unasked is set per agent in Redde, Settings →
Agent → Before Acting). An agent whose actions Hermes itself already asks you about, such as a
coding bot whose writes and commands a `pre_tool_call` hook sends for approval, would ask twice:
from 1.10.0, `/redde-push gated <profile> on` leaves the review card out for that agent, and Hermes's approval
is the one ask (`/redde-push gated <profile> off` undoes it; the list is kept on the server, in
the main home's `redde-push/gated.json`).

From 1.12.0, five more cards (asked 2026-10-30). A `purchase` card shows products to buy, the
agent's pick first, each with its price, rating, store and page (Redde opens the page in the
browser; nothing is bought). A `home` card shows the smart-home devices the agent touched or was
asked about, as Home Assistant reports them, each with its entity id; its switches and steppers
send the agent a message naming the entity, and the agent acts with its own Home Assistant tools
(Redde never talks to Home Assistant itself; unlocking a door or opening a garage asks on the phone
first). A `reminder` card shows a reminder, timer, alarm or scheduled message the agent set, with
Change and Cancel. A `compare` card puts two to four things side by side. A `score` card shows
games, final, live or upcoming. So the tool's description stays short on every prompt, their
fields are not in the schema: when a message asks what to buy, for the home, for a reminder or a
timer, which is better, or about a game (in English), the plugin adds that card's exact shape to
that message only, with the person's time for a reminder or a game; and the tool's error gives the
shape when a card comes without it. (Hermes 0.22 keeps a note with its message, so it is sent again with
each later turn of that conversation: what it costs, it costs for the conversation.) None of these lines is added with cards off or for a gated agent.

From 1.14.0 a purchase card is checked before it shows: `redde_show` reads each product's own page
from the Hermes server (a few at once, about five seconds at most) and makes the card what the
store says now. A dead link (the site isn't found, the page is gone, or it sends you to the store's
home or search page) is taken off its product and the agent is told; a page that loads gives the
product its current price and currency, whether it is in stock, its picture if it had none, and its
rating and reviews if the agent gave none (from the page's schema.org Product data, its microdata,
its Open Graph metas, or Amazon's own page), and the card's note says when the prices were
checked. A store that won't show its page to a program (Amazon's Robot Check, a 403 or a 503) or a
page too slow to answer leaves the product as the agent wrote it, and the agent hears it wasn't
checked. Only public web pages are read: http or https on the usual ports, never an address on the
Hermes machine, the home network or the tailnet, checked again at every redirect. Nothing is
bought, and no cookies or keys are sent. In Redde, a product with no picture of its own shows its
store page's picture, with Link previews on. From 1.29.0 the card may also say what the pick
usually sells for (`usual_price`, from a price history or the maker's list price, never a guess),
which Redde shows as a deal meter.

From 1.30.0 the phone tools have a Maps area: places near the iPhone or a place named, how long
the way takes with traffic (driving, walking, cycling, transit) with its turns, and Apple Maps
opened to go there (`phone_maps_search`, `phone_maps_directions`, `phone_maps_open`), offered only
while Maps is on in Redde.

From 1.13.0, six more the same way (asked 2026-10-31). A `recipe` card shows a recipe with its
times, the servings its amounts are for (Redde scales them on the phone), ingredients to tick and
steps. A `delivery` card shows a package's tracking, a `flight` card a flight or a trip's legs with
each time in its airport's own zone, a `show` card films and series with ratings and where they
stream, a `conversion` card units (worked out on the phone) or money (at the rate the agent found),
and a `stock` card share prices with the day's line. Asked for a recipe, a package, a flight,
something to watch, a conversion or a share's price (in English), the agent hears that card's shape
and to look the thing up first, never making up a price, a time, a status, a rating or a link.
Pictures (a recipe's, a poster) show only with Link previews on in Redde; the cards never fetch
anything themselves, and nothing on them books, buys or trades.

From 1.10.0 a review may say its `kind` (`email`, `message`, `event`, `purchase`, `other`) and a `subtitle`
("From your Gmail · as you"): the app draws an email or a message as itself, who it's to, its
subject and its words, and anything else as rows. Without a kind it goes by the fields' labels
(To and Subject, an email). A checklist's items each take a `section` (or `group`), or come in
`sections` (or `groups`) each with its `items`; an item may have a short `note` ("×2"), and the
list a `subtitle` ("Nov 7 – 8") and a `verb` ("packed": "3 of 8 packed"). All optional.

## Email (1.16.0)

Redde's inbox for the person's own email, for any provider with IMAP and an app password (Gmail,
iCloud, Fastmail, Yahoo, others), added in the Redde app, which puts `REDDE_MAIL_ADDRESS`,
`REDDE_MAIL_PASSWORD` and `REDDE_MAIL_PROVIDER` in the main profile's .env through Keys Asked For
(`REDDE_MAIL_IMAP_HOST`/`_PORT` and `REDDE_MAIL_SMTP_HOST`/`_PORT` for another provider; more
accounts with `REDDE_MAIL_ACCOUNTS=WORK` and `REDDE_MAIL_WORK_*`). Never `EMAIL_*`: those are
Hermes's own email platform's, which answers mail as a chat and marks everything read. A Hermes
with the google-workspace skill's Gmail sign-in gets that account over the Gmail API as well.

- Every few minutes (3 by default) the schedules' thread looks for new mail: sender, subject, a
  short snippet and flags only. Rules sort it first (Gmail's categories, list headers, receipts);
  the rest goes to the model a few at a time, as data. The person's own rules (archive, mark
  read, label, move, tell me) run with no model, each logged and undoable.
- The agent gets `redde_mail`. Reading an email gives its text as data, never instructions.
  Replies are drafts shown as a card in Redde and sent only unchanged after the person approves;
  trashing and the agent's unsubscribing are approved too. While an account is set up, other ways
  of sending mail (himalaya, the google-workspace script, the Nous Gmail connector) are blocked.
- State: `redde-push/mail/` under the main home (the inbox's small index, rules, the log, drafts,
  settings). The app's command is `/redde-push mail …` (see the repository's tmp/mail-contract.md).

## Task reports in the chat (1.27.0)

When a task the agent handed to a subagent finishes and no reply of the agent's reports it, the
plugin tells the phone the task's own summary. It also keeps that report in the main home's
`redde-push/task-reports.json` (0600, three days, ten per chat), and Redde asks for a chat's
reports with `/redde-push tasks <session>` (over the Dashboard, or the plugin's route on the
Hermes API). The app shows a report at the end of its chat until Hermes writes its own
"[ASYNC DELEGATION …]" row there, which on the Dashboard happens only once a client is in the chat
again; that row then stays open, so the chat says what the notification said.


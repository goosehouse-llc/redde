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
Voice › Notify when Redde is closed has an Install the Plugin button that has this Hermes fetch
and enable the same plugin. Hermes 0.21.5 and later load it at once; earlier ones still need the
restart above.

**If Redde is connected through the Dashboard**, that is all there is to do here. In Redde:
Settings › Notifications › Notify when Redde is closed › Pair with your server, on each iPhone,
iPad or Mac. A notification on the device confirms the pairing.

**Otherwise** (Redde on the Hermes API, or a device that isn't signed in to this Hermes), pair
with a code:

```
hermes redde-push pair
```

It shows a QR code and a link, and waits. In Redde: Settings › Notifications › Notify when Redde
is closed › Pair with a code (on a Mac, copy the link and paste it). A notification on the device
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
  this machine each half minute for it (`routines.py`).

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
each forgotten once sent). Delete the folder and nothing is paired.

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
the weather (in English), the plugin adds a line to that turn only: the person's time in that
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

From 1.10.0 a review may say its `kind` (`email`, `message`, `event`, `purchase`, `other`) and a `subtitle`
("From your Gmail · as you"): the app draws an email or a message as itself, who it's to, its
subject and its words, and anything else as rows. Without a kind it goes by the fields' labels
(To and Subject, an email). A checklist's items each take a `section` (or `group`), or come in
`sections` (or `groups`) each with its `items`; an item may have a short `note` ("×2"), and the
list a `subtitle` ("Nov 7 – 8") and a `verb` ("packed": "3 of 8 packed"). All optional.

# Changelog

What changed in each version of the Redde plugin (`redde-push`). Redde offers an update, in
Settings › Redde Plugin, to a Hermes whose plugin is older than the one the app goes with.

## 1.11.0 (2026-10-30)

Leave-By Alerts' traffic re-check
- Redde asks this Hermes, over the Dashboard (`/redde-push leave set <device> <wakes>`, `leave
  cancel <device>`), to wake the device about twenty minutes before each Leave-By Alert's leaving
  time. At that time the plugin sends that one device a sealed note of a new kind, `leave`; the
  device asks Apple Maps again, moves its alert if the traffic changed and says so in one quiet
  notification. Hermes is told an opaque id for each alert, the event's title and the time to wake,
  nothing else. Each device's list replaces what it said before (a moved alert, a deleted event),
  at most 30 a device; each wake is sent once, from the thread that reads the schedules, and one
  more than fifteen minutes late is let go. A device unpaired is forgotten with its wakes. Kept:
  `leave.json` in `$HERMES_HOME/redde-push/`.

## 1.10.0 (2026-10-30)

Goes with Redde 2.3.1. Everything here was on the main branch after 1.9.0 was declared, without a
new number, so a Hermes that installed 1.9.0 then was never offered it; this version is what
tells them apart.

Ideas and briefings
- Morning Ideas and Routine Suggestions reach the phone even when the model doesn't call
  `suggest_to_user` (Hermes 0.22 keeps plugin tools behind `tool_search`, and a model that doesn't
  look there writes its ideas out instead). Lines `IDEA: title | why now | the request` in the
  job's answer become idea cards; any other answer comes as a briefing, or why the run failed;
  NOTHING NEW stays silent.
- Briefings carry up to 1,800 characters instead of 500, so a Week Ahead arrives whole.
- A heads-up's notification carries the event's start and address, for the leave time Redde
  works out on the device and the Up Next widget.

Keys asked for
- New tool `request_secret` (toolset `redde_keys`), and `secret_status`: an agent that needs an
  API key asks for it by name, and the person pastes it in a card in Redde, never in the chat. The
  key is sealed to that one request (X25519, HKDF-SHA256, AES-GCM), handed over the Hermes
  Dashboard as a plugin command and written with Hermes's own `.env` writer; the agent only learns
  set or declined. Requests last a day, ten an hour per agent; names that change how programs run
  (`PATH`, `LD_…`, `PYTHON…`, `HERMES_HOME`) are refused. Kept: `keys.json` and `keys/` in
  `$HERMES_HOME/redde-push/`, never a value.

Cards
- Asked what's on the calendar, an agent is told to look the events up and show them as an
  `agenda` card (events by day, a free day shown as one), then answer in a line.
- `places`: each place can have a `price`, `hours` (open or closed, in words) and `pick` (the
  agent's pick).
- `review`: a `kind` (email, message, event, purchase, other) and a `subtitle`, so the app draws
  an email or a message as itself.
- `checklist`: a `subtitle`, a `verb` ("3 of 8 packed"), `groups` or `sections`, and a short
  `note` on an item.
- `weather`: each hour's wind gusts, and when it was read (`updated`); the tool's answer calls
  out the rain window ("storms likely 14:00–17:00, likeliest 80% at 15:00").
- All of these fields are optional, and older apps ignore them.

Approvals
- `/redde-push gated <profile> on|off`: an agent whose actions Hermes already asks about (a
  coding bot behind a `pre_tool_call` approval hook) gets no "show a review card first" note, so
  it is asked once, by Hermes, not twice. Kept in the main home's `redde-push/gated.json`.

Devices
- A device says at pairing whether it is an iPhone, an iPad or a Mac (Redde 2.3.1 and later);
  `hermes redde-push list` shows it, the words say "device", and `call_user` never rings a Mac.
  Devices paired before keep working, counted as iPhones.

## 1.9.0 (2026-10-28)

Goes with Redde 2.3.
- `suggest_to_user` (toolset `redde_ideas`): up to five ideas, each a heading, why now and the
  request, as cards in Redde and one notification; ten offers an hour per agent.
- Watches: jobs named `[redde-watch:<id>]` that tell the phone only what changed; an agent's own
  with `keep_an_eye_on`; a bot's, and ones that hand a change to another agent's Bot Chat.
- Follow-ups: `follow_up_later` brings a loose end back as an idea card.
- Heads-ups: `heads_up_before` makes a one-time job before an event.
- Briefings: the answer of any job named `[redde-notify] …` comes to the phone and stays in Redde's
  Briefings (Evening Wrap-up, Week Ahead).
- Cards answered with a tap in `redde_show`: review before acting, choice, checklist and form; a
  nudge to show a review card before an errand, worded by each agent's Before Acting level.
- `redde_show` is among the tools Hermes 0.22 shows live (GitHub #35).

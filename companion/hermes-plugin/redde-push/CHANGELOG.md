# Changelog

What changed in each version of the Redde plugin (`redde-push`). Redde offers an update, in
Settings › Redde Plugin, to a Hermes whose plugin is older than the one the app goes with.

## 1.13.0 (2026-10-31)

Six more cards for `redde_show`, drawn by Redde 2.3.1
- `recipe`: a recipe the agent looked up, with its source and page, picture, prep, cook and total
  times, the servings its amounts are for (Redde scales them on the phone), ingredients to tick
  off and numbered steps ("a recipe for banana bread", "what can I make for dinner with chicken").
- `delivery`: a package's tracking: what's in it, the carrier, the number, the carrier's words for
  where it stands, the day it should come, and the scans ("where's my package?").
- `flight`: a flight, or a trip's legs, each end with its airport code, city, terminal, gate and
  its time in that airport's own zone, the new time when it is late, the status and the seat ("is
  my flight on time?"). Not booking one, or fares.
- `show`: films and series, with year, format, seasons or runtime, genres, ratings as found, an
  overview, who made it, where it streams (the services' names), poster, trailer and page.
- `conversion`: an amount from one unit to another, which Redde works out again on the phone as
  the person changes it, or one currency to another at the rate the agent found, with when.
- `stock`: share prices with the change since the last close, the day's prices for a line, the
  day's range, market cap and when the price is from. Redde never buys or sells anything.

Each card's shape is in a line added to the turn only when the person's message asks for that kind
of thing (in English), ordered so the 1.12.0 cards keep their asks ("remind me when my package
arrives" stays a reminder), and in the tool's error when a card comes without it. Every new line
says to look the thing up first and never to make up a price, a time, a status, a rating or a link;
the delivery and flight lines carry the person's time. The schema gains only the six names: 5,907
characters (from 5,735), its description 1,615 (from 1,506).

## 1.12.0 (2026-10-30)

Five more cards for `redde_show`, drawn by Redde 2.3.1
- `purchase`: products to buy, the agent's pick first (each with its price, currency, old price,
  rating, reviews, store, page, picture, badge, why, pros, cons and a few specs) and a note such as
  when the prices were checked. Asked what to buy ("which headphones should I buy", "best laptop
  under $1000", "recommend a stand mixer", "gift ideas for Dad", "where can I buy…"), the agent is
  told to look it up first and never make up a price, a rating or a link. Not for an errand ("buy
  it", "add to cart": the review note's) or a place to eat (a places card).
- `home`: the smart-home devices the agent touched or was asked about, as Home Assistant reports
  them (lights with brightness, switches, thermostats, covers and garage doors, locks, sensors,
  fans, media), each with its entity id. Their controls in Redde send the agent a message ("Turn
  off Kitchen lights (light.kitchen)"), which it does with its own Home Assistant tools; Redde
  never talks to Home Assistant itself.
- `reminder`: a reminder, timer, alarm or scheduled message the agent set: what, when (ISO with its
  offset), how it repeats, where it lives and its id, so Change and Cancel in Redde name it back.
- `compare`: two to four things side by side, criterion by criterion, with the better one per row,
  a verdict and a pick ("which is better, A or B?"; things to buy are a purchase card).
- `score`: games, with both teams (name, short name, colour, score, record), final, live (period
  and clock) or upcoming (start, broadcast), league and venue. Redde's Refresh asks the agent again.

Their fields are not in the tool's schema, which rides on every prompt: each card's shape is in a
line added to the turn only when the person's message asks for that kind of thing (in English,
like the calendar's), and in the tool's error when a card comes without it. The schema is smaller
than before (5,735 characters, from 5,989; its description 1,506, from 1,666): a route's ends take a
name, an address and coordinates only. Cards off, or an agent whose actions Hermes already asks
about (`gated`), get none of these lines.

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

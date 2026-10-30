# Redde plugin 1.10.0 — GitHub release draft

A draft for the GitHub release, not made yet (no tag, no release). Title: **Redde plugin 1.10.0**.
The repository has no tags yet; a suggestion for one, when it is made: `redde-push-1.10.0`, on the commit that carries `version: 1.10.0` in
`companion/hermes-plugin/redde-push/plugin.yaml`. The full list is in that folder's
`CHANGELOG.md`. Everything below the line is the release's text.

---

The Hermes plugin that goes with Redde 2.3.1. It brings the proactive features of Redde 2.3
(Morning Ideas, heads-ups before events, the Evening Wrap-up, the Week Ahead) up to date, and adds
keys asked for and the new answer cards.

If your Hermes installed the plugin as 1.9.0, update it: much of what Redde 2.3.1 uses came after
that number was set, and Redde offers an update only to a plugin older than the one it goes with.

## What's new

- **Morning Ideas that always arrive.** On Hermes 0.22 a model may not find `suggest_to_user`
  behind `tool_search` and write its ideas out instead. Those lines (`IDEA: title | why now | the
  request`) now become idea cards on your phone, and any other answer comes as a briefing, so a
  morning run is never silent for nothing. The same for Routine Suggestions.
- **Whole briefings.** Up to 1,800 characters instead of 500: a Week Ahead arrives whole.
- **Heads-ups with where and when.** A heads-up carries the event's start and address, so Redde
  can work out when to leave and show it in the Up Next widget.
- **Keys asked for.** An agent that needs an API key asks for it by name with `request_secret`,
  and you paste it into a card in Redde, never into the chat. The key is sealed to that one
  request on your device, handed to your Hermes over the Dashboard, and written straight into the
  profile's `.env`. The agent only learns that it was set or declined.
- **Your calendar as a card.** Ask "what's on my calendar tomorrow?" and the agent shows the
  events as an agenda card, then answers in a line.
- **Richer answer cards.** Places with price, opening hours and the agent's pick; a review card
  that shows an email or a message as itself; checklists with groups, notes and progress
  ("3 of 8 packed"); weather with hourly gusts, when it was read, and the rain window called out.
  All optional; older apps ignore them.
- **One approval, not two.** `/redde-push gated <profile> on` leaves the review card out for an
  agent whose actions Hermes already asks you about, such as a coding bot behind an approval hook.
- **iPad and Mac.** A device says at pairing whether it is an iPhone, an iPad or a Mac;
  `hermes redde-push list` shows which, and a Mac is never rung by `call_user`.

## Install or update

On the machine that runs Hermes, as the user Hermes runs as:

```
hermes plugins install goosehouse-llc/redde/companion/hermes-plugin/redde-push --enable --force
```

Then restart Hermes (`hermes gateway restart`, and `hermes serve` if you run the Dashboard). Your
pairings are kept: they live beside the plugin, not in it. (`--force` replaces the copy that is
there; on a first install it does no harm.)

Or from Redde, with your Hermes Dashboard login saved: Settings › Redde Plugin › Update the Plugin
(or Settings › Agent › Ahead of Your Day, which also sets up the daily jobs). Hermes 0.21.5 and
later load it at once; earlier ones still need the restart above.

## What needs Redde 2.3.1

- Seeing the new cards as drawn: the agenda, places with hours and the pick, the email review,
  grouped checklists, gusts and the rain window. An older Redde shows these cards as before.
- Keys asked for: the card that takes the key, and Settings › Agent › Keys Asked For.
- Leave times and the Up Next widget from heads-ups.
- Pairing an iPad or a Mac by kind (Settings › Notifications › Notify When Redde Is Closed).
- Ahead of Your Day: turning on Morning Ideas, Heads-Ups, Leave-By Alerts, the Evening Wrap-up and
  the Week Ahead in one step (Settings › Agent › Ahead of Your Day).

Everything else works with any Redde that worked with 1.9.0. Hermes 0.21.0 or later; 0.21.3 or
later is the one to have.

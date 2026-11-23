# Redde plugin 1.36.1 — GitHub release draft

Title: **Redde plugin 1.36.1**. Tag: `redde-push-1.36.1`, on the commit that carries
`version: 1.36.1` in `companion/hermes-plugin/redde-push/plugin.yaml`. The last release page is
`redde-push-1.31.0`; this one covers 1.31.1 to 1.36.1. The full list is in that folder's
`CHANGELOG.md`. Publish it when Redde 2.7 is out. Everything below the line is the release's text.

---

The Hermes plugin that goes with Redde 2.7: goals whose steps you tick off and that ask before they nag, ideas you can say no to for good, Ask Me First when bots
hand work to each other, notifications cleared on every device, and briefings switched the same
way on all of them.

Update it from Redde's Settings › Redde Plugin, or on your Hermes with `hermes plugins install`
and `--force`. If you have several profiles, update each one's copy, and restart both the gateway
and `hermes serve` afterwards.

## What's new

- **Goals that go quiet ask first (1.36).** After two weeks with nothing done on a goal, its next
  check-in asks you once whether you still want it. If you don't answer, the check-ins pause a
  week later instead of carrying on. Nothing is deleted: Keep Going on the goal's page in Redde
  starts them again.
- **Don't Suggest This (1.36).** Hold an idea card, or open it, and choose Don't Suggest This.
  None of your agents will offer ideas like it again. Redde's Morning Ideas page lists what you
  turned down, so you can let one back in.
- **Things to keep in mind (1.36).** Tell your agent something that's always true for you
  ("driving into France, I need 3-day car insurance"), or add it in Settings › Your Day. Heads-Ups,
  Morning Ideas and the Week Ahead check it against the days around each event and say when
  something is missing or runs out before you're back.
- **When you've gone quiet (1.36).** An optional daily job that runs only once you haven't written
  to your agents for 12 to 72 hours, and speaks up only if something needs you. The hourly checks
  don't call your model.
- **Fewer pings for what you ignore (1.36).** Ideas you leave alone three times come quietly until
  you touch one, and a watch that keeps finding nothing slows down, then pauses and tells you.
- **Real-life steps stay yours (1.36.1).** Your agent plans what happens in your life (bottling,
  race day, a date arriving) as your step, even when it sets a reminder for it, and a check-in no
  longer marks its own step done just because it scheduled something.
- **Goals with your steps and your agent's (1.35).** A goal's plan now says who does each step.
  Your steps are a checklist you tick off in Redde, on the goal or from its Today tile, and the
  progress moves at once on every device. Your agent's steps go on the Kanban board ready to run,
  so agreeing the plan in the chat is the only approval. At check-ins your agent asks about the
  steps that are yours instead of guessing, and never marks one done unless you said so. Goals
  made before keep working: a step whose card still waits in Triage counts as yours.
- **Briefings the same on all your devices (1.34).** Notify Me, Drawer Only and Off were each
  device's own, so turning a job off on your iPhone left your iPad still notifying. Now there is
  one choice per job for all of them: a job turned off sends to none, and a Drawer Only job's
  briefings come quietly everywhere.
- **Heads-Ups for the calendars you pick (1.34).** The phone's calendar tool takes `calendars`,
  the calendars to read by name, and Redde's copy of your calendar answers the same way.
- **Notifications in sync (1.33).** A notification you tap, answer, swipe away, or see by opening
  its chat on one device goes from your others too, by a silent push. A device that missed it
  catches up when Redde next opens.
- **Ask Me First for bots (1.32).** When one of your bots hands work to another with Hermes's
  `message_agent`, it waits for you first, and Redde shows it as "Sol wants to ask Code" with Ask
  or Don't Ask (aloud in voice mode, or with a nod). Where nobody could say yes, such as a
  scheduled run, Hermes refuses it. Turn it off in Redde's Settings › Replies & Writing.

## Fixes

- Film and series cards are drawn again with models that keep to the tool's schema (they had written only `text` for each title, and the card was refused) (1.36.1).
- A schedule whose run failed no longer sends its error to your phone unless the schedule asks
  for its failures to be told (1.31.1, GitHub issue 79).
- Hermes's install scan rates the plugin safe again on 0.22.7, 0.23.1 and 0.23.2 (1.33.0).
- A purchase card sent with the wrong fields says which came (1.33.1).

## Good to know

- Ticking steps off, briefings on every device and cleared notifications need Redde 2.7. An older Redde keeps each
  device's own choices and clears notifications only where you cleared them.

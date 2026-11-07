# Redde plugin 1.19.4 — GitHub release draft

A draft for the GitHub release, not made yet. Title: **Redde plugin 1.19.4**. Tag:
`redde-push-1.19.4`, on the commit that carries `version: 1.19.4` in
`companion/hermes-plugin/redde-push/plugin.yaml`. The last release page is `redde-push-1.12.0`;
this one covers everything since (1.13.0 to 1.19.4). The full list is in that folder's
`CHANGELOG.md`. Everything below the line is the release's text.

---

The Hermes plugin that goes with Redde 2.4: email, goals, two new phone tools, and quieter, more
reliable scheduled runs.

Update it from Redde's Redde Plugin page, linked from each screen that needs it, or on your Hermes with
`hermes plugins install` and `--force`. If you have several profiles, update each one's copy, and
restart both the gateway and `hermes serve` afterwards.

## What's new

- **Email.** Connect Gmail or any mailbox over IMAP and SMTP with an app password, pasted into
  Redde's Keys Asked For, never into a chat. Every few minutes the plugin sorts new mail into
  Important, Needs Reply, FYI and Newsletters, by rules first and the model only for what's left
  (sender, subject and a snippet, as data). Your rules (archive, mark read, label, move, tell me)
  run on every new email with no model, are logged in Agent Activity and can be undone; they never
  delete. The agent gets `redde_mail`: it reads emails as data, never as instructions, and a reply
  is a draft you approve, sent only unchanged. While an account is set up, other ways of sending
  mail are blocked and pointed at `redde_mail`. Tagging rules can add up to five labels, and a
  ready-made "Receipts with attachments → Paperless" rule is offered. Emails come to Redde with
  their HTML, so the reader shows them as their senders laid them out.
- **Goals.** `redde_goal` turns a goal into a plan of Kanban cards for you to approve, and a
  check-in job reports progress as a briefing.
- **Phone tools: Apple Home and Health.** With them on in Redde, the agent can list and control
  your HomeKit accessories and scenes (locks, garage doors, doors, windows and the alarm are
  always put to you), and read the Health data kinds you chose, as totals or averages.
- **Keep a Copy.** The calendar and reminders can answer while Redde is closed, from a read-only
  copy the phone hands over; adding and changing still go through the phone.
- **Run On.** A scheduled job can run on a model of its own.
- **Memory.** "Remember that…" and "Forget that…" keep one clean entry; memories imported from
  ChatGPT or Claude can go to long-term memory.
- **Notifications where you are.** While Redde is in use on one device, notes go only there.
- **Quiet runs stay quiet.** A scheduled run with nothing new sends nothing, and a reminder is a
  real job that goes off on time and says what it is.
- **Skips and Coming Up.** Skip one run of a repeating job from Redde.
- **Calendar colours.** Each event on a calendar card comes in its calendar's colour, so an iPad
  or a Mac that can't see that calendar draws it as the iPhone does.
- **More cards** (1.13–1.14): recipes, deliveries, flights, shows, conversions and stock quotes;
  purchase links are checked on your server, and dead ones are dropped.

Needs Hermes 0.21 or later; reminders that skip the model need 0.22.

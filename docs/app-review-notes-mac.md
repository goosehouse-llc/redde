# App Review notes — the Mac app

The notes for the Mac version of Redde (platform macOS, same App Store record as the iPhone
app). `scripts/app-store-push.py notes --mac` puts the test key in and sends them; they take plain
text, 4,000 characters at most.

2.7 (303) answers the review of 2.5 (294) on 2026-11-24: entitlements without a matching feature
(camera, contacts, calendars, location), an error on sending a chat, and a populated demo mode.

```text
REVIEW OF 2.5 (November 24): WHAT 2.7 CHANGES

1. DEMO MODE (2.1(a), information needed). Redde has a demo agent built in, with real content and no account, key, server or network:
- On the "Set up Redde" sheet, under Other Agents, choose "Claude Code, Codex and others (ACP)".
- Click "Try the Demo Agent", then Test connection, then Done.
- Send "Fix the notes": the agent shows its steps, a file's changes and an approval to click. "Show me a plan" shows a plan; "Ask me a question", a question with choices.
Redde > Settings… > Connection > Set up connection… opens the sheet again.

2. ERROR ON SENDING A CHAT (2.1(a)). We found one way it happened. Test connection used the API key as typed, but a chat read the key back from the Keychain: where saving it there failed, the test passed and the chat went without the key, and the model server answered with an error. 2.7 keeps the key for the session, and saves it in the login keychain when the app's data protection keychain refuses it.
To try a real model: on the same sheet, under Direct to a Model, choose "OpenAI-compatible server". URL https://openrouter.ai/api/v1, API key <<REVIEW KEY>>, model name google/gemma-3-27b-it. Test connection, Done, then type a question and press Return. The key was checked working on November 24.

3. ENTITLEMENTS (2.4.5(i)). The camera entitlement is removed: voice mode's camera button was its only use on the Mac, and it is gone. The other three are each off until the person turns a feature on, when macOS asks:
- Contacts (personal-information.addressbook): Redde > Settings… > Phone Tools. Turn on Phone tools and set Contacts to "Ask each time" or "Allow": the agent can then look up a contact by name. What it finds goes only to the person's own server.
- Calendars (personal-information.calendars): Settings… > Phone Tools > Calendar (the agent reads a day's events and adds one, each add confirmed); Settings… > Calendars (which calendars the agent may see); Settings… > Location > Leave-By Alerts (the next events' addresses, to Apple Maps for the travel time).
- Location (personal-information.location): Settings… > Location > Current Location (roughly where the Mac is, about 100 m, sent to the person's own server only with a question about places, directions or weather) and Leave-By Alerts (to Apple Maps only).
Not asked about, for completeness: microphone (voice mode), user-selected files (attaching, saving, exporting), photos (Settings… > Phone Tools > Photos), incoming network (Settings… > Connection > Connection details > Sign in with a browser: a one-time listener on 127.0.0.1 for a Hermes Dashboard's OAuth sign-in with PKCE, RFC 8252, open only while the sign-in sheet is).

ABOUT THE APP
Redde is a chat client for self-hosted AI agents (Hermes, and coding agents through ACP) and OpenAI-compatible models, the native Mac version of the iPhone and iPad app (same bundle id, universal purchase). It has no account; conversations go only to the server the person sets up. Hermes screens (Skills, Memory, Files, Plugins, bots, Projects, Kanban, Your Day) need the person's own Hermes; plugins are installed by that server, and the app runs no plugin code.

ICLOUD (off by default): Settings… > General > Sync with iCloud keeps servers and settings in the person's own iCloud (key-value store and iCloud Keychain), shared with the iPhone app. Nothing goes to us.
LINK PREVIEWS (off by default): Settings… > Replies & Writing: the app opens a linked page for its title and picture.
IN-APP PURCHASES: Settings… > About > Support Redde: three optional one-time tips (consumables) that unlock nothing.
APP TRANSPORT SECURITY: plain HTTP is allowed (NSAllowsArbitraryLoads) because self-hosted servers on private networks usually have no public certificate. The review endpoint is HTTPS.
```

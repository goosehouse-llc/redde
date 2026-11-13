**App Store name:** Redde Agent (Hermes Redde until 2.5) · **Display name:** Redde · **Bundle ID:** com.goosehouse.echo · **SKU:** redde-ios (fixed when the record was created; internal only)

# App Review notes

Paste the block below into App Store Connect → App Review Information → Notes. The field takes plain text, 4,000 characters at most; this is 3,908 with the placeholder and about 3,967 with a key in its place (2.6). Replace `<<REVIEW KEY>>` first, or let `scripts/app-store-push.py notes` put the key in and send them: until 1.8 the notes went in by hand, and from 1.1 to 1.7.1 with the placeholder still in them. Keep it under the limit when adding to it: the notes for 1.6 ran to 6,600 before they were cut.

```text
Redde is a voice and chat client for a self-hosted AI assistant. It has no account; conversations go only to the user's own server.

TO TEST
1. On the "Set up Redde" sheet choose "OpenAI-compatible (direct to a model)".
2. Enter URL https://openrouter.ai/api/v1, API key <<REVIEW KEY>>, model name google/gemma-3-27b-it.
3. Tap Test connection, then Done.
4. Type a question, or tap the microphone and speak.

Hermes screens (Skills, Memory, Files, bots, Terminal, Email…) and proactive features (Morning Ideas, watches) need the user's self-hosted Hermes server and plugin; the app downloads and runs no code.

CODING AGENTS: in Set up Redde choose the ACP connection, then Try the Demo Agent: built into the app (no computer, no AI), it shows steps, a file change, an approval, a plan and a question.

EMAIL: the user's Hermes reads and sends mail; the app sends only email the user approved.

OFF BY DEFAULT (Settings > Agent)
Leave-By Alerts: the next day's events, Apple Maps travel times, a local notification.
Current Location: roughly where the user is (~100 m), sent to their server only with a question about places, directions or weather.
Places: arriving at or leaving a place the user set; only "arrived at Home" is sent.
Health: sleep, steps and workouts, summarized for the morning ideas.

PHONE TOOLS (off by default)
Settings > Phone tools: the user's Hermes can ask for calendar events, reminders, a contact, photos, files in the app's folder, alarms (AlarmKit), a widget, a call (iOS confirms), a text the user sends, Apple Home (HomeKit; locks, doors and the alarm always ask) or Health data of the kinds the user picks (read only, totals). Each area asks its permission when turned on; data goes only to the user's server.

CARPLAY (voice-based conversational app entitlement)
Ask has three cards: Ask, Talk (hands-free until "that's all") and New Chat. Chats and Bots list conversations; picking one continues it by voice. Answers are spoken, not shown.

NOTIFICATIONS AND CALLS (off by default)
Settings > Notifications: the user's Hermes sends notifications through our relay, redde-push.goosehouse.org, to APNs, end-to-end encrypted (CryptoKit); the relay keeps only the push token. Calls from Agents: a VoIP push through the same relay, always reported to CallKit as an incoming call. Time-sensitive: leave-by alerts, a missed call, a key the agent asks for.

LIVE VOICE (off by default)
Settings > Voice > Voice mode: GPT-Live, Gemini Live, Grok Voice or ElevenLabs on the user's own key (the review account has none), or Local call (on the device, no key).

IN-APP PURCHASES
Settings > About > Support Redde: three optional one-time tips (consumables) that unlock nothing.

BACKGROUND MODES (iPhone)
Audio: voice conversations continue in CarPlay and when the phone locks.
Processing: a reply keeps streaming after the phone locks (BGContinuedProcessingTaskRequest); on the charger, the Phone tools > Photos index, on the device (BGProcessingTask).
Voice over IP: only Calls from Agents; each push is reported to CallKit.
Background fetch: only Leave-By Alerts (BGAppRefreshTask), for the traffic.

PERMISSIONS
Location When In Use: Places, Current Location, Leave-By Alerts. Always: Places only (region monitoring).
Calendar: agenda cards, Leave-By Alerts, Phone tools.
Health (read only, background delivery): Health in Settings > Agent; Phone tools > Health.
HomeKit: only Phone tools > Apple Home.
Reminders, Contacts, Photos, Alarms: only for Phone tools.
Microphone: voice mode, dictation, and Wake Phrase (off by default) while Redde is on screen; transcribed on the device.
Motion: nod or shake to answer (AirPods too), on the device.
Camera: the + menu, scanning a setup code, voice mode's camera button.

APP TRANSPORT SECURITY
Plain HTTP is allowed (NSAllowsArbitraryLoads): private self-hosted servers rarely have public TLS certificates. The review endpoint is HTTPS.
```

Not part of the notes; these have fields of their own in App Store Connect.

**Privacy policy:** https://legal.goosehouse.org/redde/privacy
**Support:** https://legal.goosehouse.org/redde/support

**App Store name:** Hermes Redde · **Display name:** Redde · **Bundle ID:** com.goosehouse.echo · **SKU:** redde-ios (fixed when the record was created; internal only)

# App Review notes

Paste the block below into App Store Connect → App Review Information → Notes. The field takes plain text, 4,000 characters at most; this is 3,910 with the placeholder and about 3,969 with a key in its place (2.3.1). Replace `<<REVIEW KEY>>` first, or let `scripts/app-store-push.py notes` put the key in and send them: until 1.8 the notes went in by hand, and from 1.1 to 1.7.1 with the placeholder still in them. Keep it under the limit when adding to it: the notes for 1.6 ran to 6,600 before they were cut.

```text
Redde is a voice and chat client for a self-hosted AI assistant. It has no account; conversations go only to the server the user configures.

TO TEST
1. On the "Set up Redde" sheet choose "OpenAI-compatible (direct to a model)".
2. Enter URL https://openrouter.ai/api/v1, API key <<REVIEW KEY>>, model name google/gemma-3-27b-it.
3. Tap Test connection (it reports "Connected"), then Done.
4. Type a question and tap the arrow, or tap the microphone and speak. Replies are read aloud.

Hermes screens (Skills, Memory, Files, Plugins, bots, Terminal over SSH) and the proactive features (Morning Ideas, heads-ups, Week Ahead, watches) need a self-hosted Hermes server with the user's own plugin (Redde plugin 1.10); the app downloads and runs no code.

NEW IN 2.3, ALL OFF BY DEFAULT (Settings > Agent)
Leave-By Alerts: reads the next day of events on the device, asks Apple Maps the travel time to each street address, and schedules a local notification.
Current Location: roughly where the user is (neighborhood, ~100 m) goes to their own server only with a question about places, directions or weather.
Places: arriving at or leaving a place the user set; only "arrived at Home" goes to their server.
Health: last night's sleep, steps and workouts, summarized in a line for the server's morning ideas.
Ahead of Your Day: Leave-By Alerts and the daily jobs in one sheet.

PHONE TOOLS (off by default)
Settings > Phone tools: the user's Hermes can ask for calendar events, reminders, a contact, photos, files in the app's folder, alarms (AlarmKit), a widget, a call (iOS confirms) or a text the user sends. Each area asks its permission when turned on; data goes only to the user's server.

CARPLAY (voice-based conversational app entitlement)
Ask has three cards: Ask (one question), Talk (hands-free until "that's all") and New Chat. Chats and Bots list conversations and bots by name, status and time only; picking one continues it by voice. Answers are spoken; no reply text is shown.

NOTIFICATIONS AND CALLS (off by default)
Settings > Notifications: the user's Hermes sends notifications through our relay, redde-push.goosehouse.org, to APNs, encrypted end to end with CryptoKit; the relay keeps only the push token. Calls from Agents: a VoIP push through the same relay, always reported to CallKit as an incoming call. Time-sensitive: leave-by alerts, a missed call, a key the agent asks for.

LIVE VOICE (off by default)
Settings > Voice > Voice mode: GPT-Live, Gemini Live, Grok Voice or ElevenLabs holds the call on the user's own key, over a WebSocket. The review account has none.

IN-APP PURCHASES
Settings > About > Support Redde: three optional one-time tips (consumables) that unlock nothing.

BACKGROUND MODES (iPhone)
Audio: a voice conversation continues in CarPlay during navigation, and when the phone locks.
Processing: only BGContinuedProcessingTaskRequest, so a reply the user asked for keeps streaming after the phone locks.
Voice over IP: only Calls from Agents; each push is reported to CallKit.
Background fetch: only Leave-By Alerts (BGAppRefreshTask), to refresh the time to leave with the traffic.

PERMISSIONS
Location When In Use: Places, Current Location, Leave-By Alerts. Always: Places only (region monitoring).
Calendar: a day's events in a message, the calendar picker, Leave-By Alerts, Phone tools.
Health (read only, background delivery): Health in Settings > Agent.
Reminders, Contacts, Photos, Alarms: only for Phone tools.
Microphone: voice mode, dictation, and Wake Phrase (off by default) while Redde is on screen; transcribed on the device.
Motion: nod or shake to answer, AirPods head movement, on the device.
Camera: the + menu, scanning a setup code, voice mode's camera button.

APP TRANSPORT SECURITY
Plain HTTP is allowed (NSAllowsArbitraryLoads): self-hosted servers on private networks usually have no public TLS certificate. The review endpoint is HTTPS.
```

Not part of the notes; these have fields of their own in App Store Connect.

**Privacy policy:** https://legal.goosehouse.org/redde/privacy
**Support:** https://legal.goosehouse.org/redde/support

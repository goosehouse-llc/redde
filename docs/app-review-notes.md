**App Store name:** Hermes Redde · **Display name:** Redde · **Bundle ID:** com.goosehouse.echo · **SKU:** redde-ios (fixed when the record was created; internal only)

# App Review notes

Paste the block below into App Store Connect → App Review Information → Notes. The field takes plain text, 4,000 characters at most; this is 3,931 with the placeholder and about 3,990 with a key in its place. Replace `<<REVIEW KEY>>` first, or let `scripts/app-store-push.py notes` put the key in and send them: until 1.8 the notes went in by hand, and from 1.1 to 1.7.1 with the placeholder still in them. Keep it under the limit when adding to it: the notes for 1.6 ran to 6,600 before they were cut.

```text
Redde is a voice and chat client for a self-hosted AI assistant. It has no account; conversations go only to the server the user configures.

TO TEST
1. On the "Set up Redde" sheet choose "OpenAI-compatible (direct to a model)".
2. Enter URL https://openrouter.ai/api/v1, API key <<REVIEW KEY>>, model name google/gemma-3-27b-it.
3. Tap Test connection (it reports "Connected"), then Done.
4. Type a question and tap the arrow, or tap the microphone and speak. Replies are read aloud.

Hermes screens (Skills, Memory, Files, Plugins, bots, Terminal over SSH) need a self-hosted Hermes server. Plugins are installed by that server; the app runs no plugin code.

PHONE TOOLS (optional, off by default)
Settings > Phone tools: the user's Hermes can ask for calendar events, reminders, a contact, photos, files in the app's folder, alarms (AlarmKit), a widget, a call (iOS confirms) or a text the user sends. Each area is off until turned on, when iOS asks its permission; changes ask first. Data goes only to the user's server.

CARPLAY (voice-based conversational app entitlement)
Connect to CarPlay or the CarPlay Simulator. Ask has three cards: Ask (one question), Talk (hands-free until "that's all") and New Chat. Chats and Bots list conversations and bots by name, status and time only; picking one continues it by voice. The voice card shows Listening, Thinking, Speaking, Stop and Pause. Answers are spoken; no reply text is shown.

APPLE WATCH
On the paired watch tap Ask and dictate; the reply is shown and read aloud.

ICLOUD (off by default)
Settings > iCloud keeps servers and settings in the user's own iCloud. Nothing goes to us.

NOTIFICATIONS (optional, off by default)
Settings > Notifications > Notify when Redde is closed. Pairing takes a plugin the user's Hermes server installs itself; the app downloads and runs no code. The server sends them through our relay, redde-push.goosehouse.org, to APNs, encrypted end to end with CryptoKit; the relay keeps only the push token.

CALLS FROM AGENTS (optional, off by default)
Settings > Notifications > Calls from Agents: an agent the user allows rings the phone, a VoIP push through the same relay, always reported to CallKit as an incoming call; answering opens voice mode. Needs a paired Hermes.

LINK PREVIEWS (off by default)
Settings > Appearance: the phone opens a linked page for its title and picture.

MICROPHONE
Voice mode, dictation, a reply with Talk over replies, and, with Wake Phrase on (Settings > Voice, off by default), while Redde is on screen. Transcribed on the device; no audio is kept or sent but in a live voice call.

LIVE VOICE (optional, off by default)
Settings > Voice > Voice mode: GPT-Live, Gemini Live, Grok Voice or ElevenLabs holds the call, on the user's own key, the audio going straight there over a WebSocket. ElevenLabs also reads replies. The review account has none.

IN-APP PURCHASES
Settings > About > Support Redde: three optional one-time tips (consumables) that unlock nothing.

BACKGROUND MODES (iPhone)
Audio: a voice conversation continues in CarPlay when the driver switches to navigation, and on the phone when it locks.
Processing: only BGContinuedProcessingTaskRequest, so a reply the user asked for keeps streaming after the phone locks.
Voice over IP: only Calls from Agents; each push is reported to CallKit as an incoming call.

PERMISSIONS
Calendar: attaching a day's events from the message field; also Phone tools.
Reminders, Contacts, Photos, Alarms: only for Phone tools, asked when the user turns that area on.
Motion & Fitness: nod or shake to answer (Settings > Voice), AirPods head movement, read on the device.
Camera: the + menu, "Scan a setup code", and voice mode's camera button (a still with each spoken question).

APP TRANSPORT SECURITY
Plain HTTP is allowed (NSAllowsArbitraryLoads): self-hosted servers on private networks usually have no public TLS certificate. The review endpoint is HTTPS.
```

Not part of the notes; these have fields of their own in App Store Connect.

**Privacy policy:** https://legal.goosehouse.org/redde/privacy
**Support:** https://legal.goosehouse.org/redde/support

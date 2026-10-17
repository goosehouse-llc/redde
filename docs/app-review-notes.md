**App Store name:** Redde for Hermes · **Display name:** Redde · **Bundle ID:** com.goosehouse.echo · **SKU:** redde-ios (fixed when the record was created; internal only)

# App Review notes

Paste the block below into App Store Connect → App Review Information → Notes. The field takes plain text, 4,000 characters at most; this is 3,903 with the placeholder and about 3,962 with a key in its place. Replace `<<REVIEW KEY>>` first, or let `scripts/app-store-push.py notes` put the key in and send them: until 1.8 the notes went in by hand, and from 1.1 to 1.7.1 with the placeholder still in them. Keep it under the limit when adding to it: the notes for 1.6 ran to 6,600 before they were cut.

```text
Redde is a voice and chat client for a self-hosted AI assistant. It has no account, and conversations go only to the server the user configures. We run one service for it, an optional notification relay.

TO TEST
1. On the "Set up Redde" sheet choose "OpenAI-compatible (direct to a model)".
2. Enter URL https://openrouter.ai/api/v1, API key <<REVIEW KEY>>, model name google/gemma-3-27b-it.
3. Tap Test connection (it reports "Connected"), then Done.
4. Type a question and tap the arrow, or tap the microphone and speak. Replies are read aloud.

Hermes connections and screens (Skills, Tools, Memory, Files…) need a self-hosted Hermes server and say so without one.

PHONE TOOLS (optional, off by default)
Settings > Phone tools. The user's Hermes assistant can ask the app for calendar events, reminders, a contact, photos, files in the app's own folder, alarms and timers (AlarmKit) and a widget it writes on, start a call (iOS confirms) or draft a text the user sends. Each area is off until the user turns it on, when iOS asks for its permission (visible without a server). Changes ask first. What is read goes only to the user's server. The tools need a plugin there, so the review endpoint can't run them.

CARPLAY (voice-based conversational app entitlement)
Connect the phone to CarPlay or the CarPlay Simulator. Ask has three cards: Ask (one question), Talk (hands-free until the user says "that's all") and New Chat, with rows for a note and short answers. Chats lists conversations by name and time only; picking one carries it on by voice. The voice card shows Listening, Thinking and Speaking, with Stop and Pause. Answers are spoken; no reply text is shown.

APPLE WATCH
Open Redde on the paired watch, tap Ask and dictate; the reply is shown and read aloud. Background audio: with Bluetooth headphones a reply keeps playing after the wrist is lowered. The watch app records nothing.

TERMINAL (new in 1.9)
Settings > Terminal, or More in a chat: a shell on the user's own server over SSH, signed in with a key the app makes and keeps in the Keychain. It needs an SSH server, so the review endpoint can't use it.

NOTIFICATIONS (optional, off by default)
Settings > Voice > Notify when Redde is closed. Pairing takes a plugin on the user's Hermes server: "Install the Plugin" asks that server to install it on itself; the app downloads and runs no code. The server sends them through our relay, redde-push.goosehouse.org, to APNs, encrypted between server and iPhone with CryptoKit; the relay keeps only the push token.

MICROPHONE
Used only while the user talks to the app: voice mode, dictation into the message field, and, with "Talk over replies", while a reply plays, so speaking interrupts it. Transcription is on the device; no audio is kept or sent.

IN-APP PURCHASES
Settings > About > Support Redde: three optional one-time tips (consumables) that unlock nothing.

BACKGROUND MODES (iPhone)
Audio: a voice conversation continues in CarPlay when the driver switches to navigation, and on the phone when it locks.
Processing: only BGContinuedProcessingTaskRequest, so a reply the user asked for keeps streaming after the phone locks.

PERMISSIONS
Calendar: the calendar card and the Calendar chip in the message field attach a day's events; also Phone tools.
Reminders, Contacts, Photos, Alarms: only for Phone tools, asked when the user turns that area on.
Motion & Fitness: for Settings > Voice > Nod or shake to answer. AirPods head movement is read on the device while a request waits, to tell a nod (approve) from a shake (deny); nothing is kept or sent.
Camera: the + menu's Camera, "Scan a setup code", and voice mode's camera button, which sends a still with each spoken question.

APP TRANSPORT SECURITY
Plain HTTP is allowed (NSAllowsArbitraryLoads) because self-hosted servers on private networks usually have no public TLS certificate. The review endpoint is HTTPS.
```

Not part of the notes; these have fields of their own in App Store Connect.

**Privacy policy:** https://legal.goosehouse.org/redde/privacy
**Support:** https://legal.goosehouse.org/redde/support

**App Store name:** Redde for Hermes · **Display name:** Redde · **Bundle ID:** com.goosehouse.echo · **SKU:** redde-ios (fixed when the record was created; internal only)

# App Review notes

Paste the block below into App Store Connect → App Review Information → Notes. The field takes plain text, 4,000 characters at most; this is 3,931 with the placeholder and about 3,990 with a key in its place. Replace `<<REVIEW KEY>>` first. Keep it under the limit when adding to it: the notes for 1.6 ran to 6,600 before they were cut.

```text
Redde is a voice and chat client for a self-hosted AI assistant. It has no account, and conversations go only to the server the user configures. We run one service for it, an optional notification relay.

TO TEST
1. On the "Set up Redde" sheet choose "OpenAI-compatible (direct to a model)".
2. Enter URL https://openrouter.ai/api/v1, API key <<REVIEW KEY>>, model name google/gemma-3-27b-it.
3. Tap Test connection (it reports "Connected"), then Done.
4. Type a question and tap the arrow, or tap the microphone and speak. Replies are read aloud.

The Hermes connections and the Skills, Tools, Context files, Memory, Files and Gateway screens need a self-hosted Hermes server; they say so when none is configured.

PHONE TOOLS (new in 1.8; optional, off by default)
Settings > Phone tools. The user's assistant, on their own Hermes server, can ask the app for calendar events, reminders, a contact, photos, and files in the app's own folder. Each area is off until the user sets it to "Ask each time" or "Allow reading"; iOS asks for that permission then, which can be seen without a server. Adding, changing and deleting always ask first; deleting photos uses the system's confirmation. What is read goes only to the user's server. The tools need a plugin on that server, so the review endpoint can't run them.

CARPLAY (voice-based conversational app entitlement)
Connect the phone to CarPlay or the CarPlay Simulator. Ask has three cards: Ask (one question), Talk (hands-free until the user says "that's all") and New Chat, and rows to take a spoken note and to switch short answers. Chats lists conversations by name and time only; picking one carries it on by voice. The voice card shows Listening, Thinking and Speaking, with Stop and Pause. Answers are spoken; no reply text is shown.

APPLE WATCH
Open Redde on the paired watch, tap Ask and dictate; the reply is shown and read aloud. Background audio: with Bluetooth headphones a reply keeps playing after the wrist is lowered. The watch app records nothing.

NOTIFICATIONS (optional, off by default)
Settings > Voice > Notify when Redde is closed. A user can pair their own Hermes server, which takes a plugin there. "Install the Plugin" asks that server to install it on itself; the app downloads and runs no code. The server sends notifications through our relay, redde-push.goosehouse.org, to APNs, encrypted between server and iPhone with CryptoKit. The relay keeps the device's push token and can't read them.

MICROPHONE
Used only while the user talks to the app: voice mode, dictation into the message field, and, with "Talk over replies", while a reply is spoken, so that speaking interrupts it. Transcription is on the device; no audio is kept or sent.

IN-APP PURCHASES
Settings > About > Support Redde: three optional one-time tips (consumables) that unlock nothing.

BACKGROUND MODES (iPhone)
Audio: a voice conversation continues in CarPlay when the driver switches to navigation, and on the phone when it locks.
Processing: only BGContinuedProcessingTaskRequest, so a reply the user asked for keeps streaming after the phone locks.

PERMISSIONS
Calendar: the calendar card on a new conversation and the Calendar chip in the message field attach a day's events; Phone tools' Calendar lets the assistant look up and add events.
Reminders, Contacts, Photos (new in 1.8): only for Phone tools, asked when the user turns that area on.
Motion & Fitness (new in 1.8): asked when the user turns on Settings > Voice > Nod or shake to answer. Head movement from AirPods is read on the device while a request from the assistant waits, to tell a nod (approve) from a shake (deny). Nothing is kept or sent.
Camera: Camera in the + menu, to attach a photo, and "Scan a setup code".

APP TRANSPORT SECURITY
Plain HTTP is allowed (NSAllowsArbitraryLoads) because self-hosted servers on private networks usually have no public TLS certificate. The review endpoint is HTTPS.
```

Not part of the notes; these have fields of their own in App Store Connect.

**Privacy policy:** https://legal.goosehouse.org/redde/privacy
**Support:** https://legal.goosehouse.org/redde/support

**App Store name:** Hermes Redde · **Display name:** Redde · **Bundle ID:** com.goosehouse.echo · **SKU:** redde-ios (fixed when the record was created; internal only)

# App Review notes

Paste the block below into App Store Connect → App Review Information → Notes. The field takes plain text, 4,000 characters at most; this is 3,934 with the placeholder and about 3,993 with a key in its place. Replace `<<REVIEW KEY>>` first, or let `scripts/app-store-push.py notes` put the key in and send them: until 1.8 the notes went in by hand, and from 1.1 to 1.7.1 with the placeholder still in them. Keep it under the limit when adding to it: the notes for 1.6 ran to 6,600 before they were cut.

```text
Redde is a voice and chat client for a self-hosted AI assistant. It has no account; conversations go only to the server the user configures.

TO TEST
1. On the "Set up Redde" sheet choose "OpenAI-compatible (direct to a model)".
2. Enter URL https://openrouter.ai/api/v1, API key <<REVIEW KEY>>, model name google/gemma-3-27b-it.
3. Tap Test connection (it reports "Connected"), then Done.
4. Type a question and tap the arrow, or tap the microphone and speak. Replies are read aloud.

Hermes screens (Skills, Memory, Files, bots) need a self-hosted Hermes server.

PHONE TOOLS (optional, off by default)
Settings > Phone tools. The user's Hermes can ask for calendar events, reminders, a contact, photos, files in the app's folder, alarms and timers (AlarmKit) and a widget it writes on, start a call (iOS confirms) or draft a text the user sends. Each area is off until turned on, when iOS asks for its permission. Changes ask first. What is read goes only to the user's server, through a plugin there, so the review endpoint can't run them.

CARPLAY (voice-based conversational app entitlement)
Connect to CarPlay or the CarPlay Simulator. Ask has three cards: Ask (one question), Talk (hands-free until "that's all") and New Chat. Chats and Bots list conversations and bots by name, status and time only; picking one continues it by voice. The voice card shows Listening, Thinking, Speaking, Stop and Pause. Answers are spoken; no reply text is shown.

APPLE WATCH
On the paired watch tap Ask and dictate; the reply is shown and read aloud, and with Bluetooth headphones plays on after the wrist is lowered (background audio).

TERMINAL
Settings > Terminal: a shell on the user's own server over SSH, with a key the app makes and keeps in the Keychain.

ICLOUD (off by default)
Settings > iCloud > Sync with iCloud keeps the user's servers and settings in their own iCloud (keys in iCloud Keychain). Nothing goes to us.

NOTIFICATIONS (optional, off by default)
Settings > Voice > Notify when Redde is closed. Pairing takes a plugin on the user's Hermes server, which "Install the Plugin" asks it to install; the app downloads and runs no code. The server sends them through our relay, redde-push.goosehouse.org, to APNs, encrypted end to end with CryptoKit; the relay keeps only the push token.

LINK PREVIEWS (off by default)
Settings > Appearance > Link previews: the phone opens a linked page for its title and picture. Nothing else is sent.

MICROPHONE
Voice mode, dictation, a reply with Talk over replies, and, with Wake Phrase on (Settings > Voice, off by default), while Redde is on screen. Transcribed on the device; no audio is kept or sent but in a live voice call.

LIVE VOICE (optional, off by default)
Settings > Voice > Conversation: GPT-Live, Gemini Live, Grok Voice or ElevenLabs holds the call, on the user's own key, the audio going straight there over a WebSocket. The review account has none.

IN-APP PURCHASES
Settings > About > Support Redde: three optional one-time tips (consumables) that unlock nothing.

BACKGROUND MODES (iPhone)
Audio: a voice conversation continues in CarPlay when the driver switches to navigation, and on the phone when it locks.
Processing: only BGContinuedProcessingTaskRequest, so a reply the user asked for keeps streaming after the phone locks.

PERMISSIONS
Calendar: attaching a day's events from the message field; also Phone tools.
Reminders, Contacts, Photos, Alarms: only for Phone tools, asked when the user turns that area on.
Motion & Fitness: Nod or shake to answer (Settings > Voice), AirPods head movement read on the device while a request waits.
Camera: the + menu's Camera, "Scan a setup code", and voice mode's camera button, which sends a still with each spoken question.

APP TRANSPORT SECURITY
Plain HTTP is allowed (NSAllowsArbitraryLoads) because self-hosted servers on private networks usually have no public TLS certificate. The review endpoint is HTTPS.
```

Not part of the notes; these have fields of their own in App Store Connect.

**Privacy policy:** https://legal.goosehouse.org/redde/privacy
**Support:** https://legal.goosehouse.org/redde/support

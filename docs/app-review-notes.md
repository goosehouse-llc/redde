**App Store name:** Redde for Hermes · **Display name:** Redde · **Bundle ID:** com.goosehouse.echo · **SKU:** redde-ios (fixed when the record was created; internal only)

# App Review notes

Paste the block below into App Store Connect → App Review Information → Notes. The field takes plain text, 4,000 characters at most; this is 3,896 with the placeholder and about 3,955 with a key in its place. Replace `<<REVIEW KEY>>` first. Keep it under the limit when adding to it: the notes for 1.6 ran to 6,600 before they were cut.

```text
Redde is a voice and chat client for a self-hosted AI assistant. It has no account, and conversations go only to the server the user configures. We run one service for it, an optional notification relay.

TO TEST
1. On the "Set up Redde" sheet choose "OpenAI-compatible (direct to a model)".
2. Enter URL https://openrouter.ai/api/v1, API key <<REVIEW KEY>>, model name google/gemma-3-27b-it.
3. Tap Test connection (it reports "Connected"), then Done.
4. Type a question and tap the arrow, or tap the microphone and speak. Replies are read aloud.

The Hermes connections and the Skills, Tools, Context files, Memory, Files and Gateway screens need a self-hosted Hermes server; they say so when none is configured.

CARPLAY (voice-based conversational app entitlement)
Connect the phone to CarPlay or the CarPlay Simulator. Two tabs, new in 1.7. Ask has three buttons: Ask (one question), Talk (hands-free until the user says "that's all") and New Chat. Chats lists the user's conversations by name and time only; picking one carries it on by voice. The voice card shows Listening, Thinking and Speaking, with Mute and End buttons. Answers are spoken; no reply text is shown.

APPLE WATCH
Open Redde on the paired watch, tap Ask and dictate; the reply is shown and read aloud. The watch gets its connection from the iPhone app. New in 1.7: a list of the user's conversations, and an Ask Redde complication. Background audio: with Bluetooth headphones a reply keeps playing after the wrist is lowered. The watch app records nothing.

NOTIFICATIONS (new in 1.7; optional, off by default)
Settings > Voice > Notify when Redde is closed. A user can pair their own Hermes server (it takes a plugin there, so the review endpoint can't show it). "Install the Plugin" asks that server to install it on itself; the app downloads and runs no code. That server then sends notifications through our relay, redde-push.goosehouse.org, to APNs, encrypted between server and iPhone with CryptoKit; the notification service extension decrypts them. The relay keeps the device's push token and can't read them; the privacy policy describes it.

SIGN IN WITH A BROWSER (new in 1.7)
For a Hermes Dashboard that uses Google or another identity provider: ASWebAuthenticationSession opens that server's own login page (OAuth with PKCE, returning to a loopback listener on the phone). It is the user's server's login, not an account with us.

MICROPHONE
Used only while the user talks to the app: voice mode, the dictation button in the message field, and, with "Talk over replies" (on with headphones), while a reply is spoken, so that speaking interrupts it. Transcription is on the device; no audio is kept or sent.

IN-APP PURCHASES
Settings > About > Support Redde offers three optional one-time tips (consumables). They unlock nothing; there are no subscriptions.

BACKGROUND MODES (iPhone)
Audio: a voice conversation the user started continues in CarPlay when the driver switches to navigation, and on the phone when it locks.
Processing: only BGContinuedProcessingTaskRequest. A reply the user asked for keeps streaming after the phone locks; iOS shows its progress with a stop button. Nothing is scheduled for later.

PERMISSIONS
Calendar: asked for only when the user taps the calendar card on a new conversation or the Calendar chip in the message field; it attaches that day's events to the message.
Camera: Camera in the + menu, to attach a photo, and "Scan a setup code", which reads a QR code. No picture is kept or sent.

ASSOCIATED DOMAINS (applinks:redde.goosehouse.org)
A setup link, https://redde.goosehouse.org/connect#..., opens a sheet that shows what it would set. Nothing is saved until the user confirms.

APP TRANSPORT SECURITY
Plain HTTP is allowed (NSAllowsArbitraryLoads) because self-hosted servers on private networks usually have no public TLS certificate. The review endpoint is HTTPS.
```

Not part of the notes; these have fields of their own in App Store Connect.

**Privacy policy:** https://legal.goosehouse.org/redde/privacy
**Support:** https://legal.goosehouse.org/redde/support

**App Store name:** Redde for Hermes · **Display name:** Redde · **Bundle ID:** com.goosehouse.echo · **SKU:** redde-ios (fixed when the record was created; internal only)

# App Review notes

Paste the block below into App Store Connect → App Review Information → Notes. The field takes plain text, 4,000 characters at most; this is 3,735 with the placeholder and about 3,794 with a key in its place. Replace `<<REVIEW KEY>>` first. Keep it under the limit when adding to it: the notes for 1.6 ran to 6,600 before they were cut.

```text
Redde is a voice and chat client for a self-hosted AI assistant. It has no server of its own and collects no data; everything goes to the server the user configures.

TO TEST
1. On the "Set up Redde" sheet choose "OpenAI-compatible (direct to a model)".
2. Enter URL https://openrouter.ai/api/v1, API key <<REVIEW KEY>>, model name google/gemma-3-27b-it.
3. Tap Test connection (it reports "Connected"), then Done.
4. Type a question and tap the arrow, or tap the microphone and speak. Speech is recognized on the device; replies are read aloud.
5. Optional: + attaches a photo to ask about; "Hey Siri, ask Redde" starts voice mode.

The Hermes connections and the Skills, Tools, Context files and Memory screens need a self-hosted Hermes server; they say so when none is configured.

CARPLAY (voice-based conversational app entitlement)
Set up the phone as above and connect it to CarPlay or the CarPlay Simulator. Redde shows two rows: Ask Redde (one question) and Talk with Redde (hands-free, ended by saying "that's all"). Tap Ask Redde and speak: the card shows Listening, Thinking and Speaking, and the answer is spoken through the car's speakers. No reply text is shown.

APPLE WATCH (new in 1.6)
Set up the iPhone as above, then open Redde on the paired watch. Tap Ask and dictate a question; the reply is shown and read aloud. The watch gets its connection from the iPhone app and then talks to the server itself. If it asks for the iPhone to be set up first, open the iPhone app once.
Background audio in the watch app: with Bluetooth headphones connected, a reply being read keeps playing after the wrist is lowered and stops when it ends. On the watch's speaker it plays only while the app is on screen. The watch app records nothing; questions use the system's dictation.

IN-APP PURCHASES
Settings > About > Support Redde offers three optional one-time tips (consumables), submitted with this version. They unlock nothing; there are no subscriptions. Until they are approved the screen says "Tips aren't available right now", by design.

BACKGROUND MODES (iPhone)
Audio: a voice conversation the user started continues when Redde leaves the foreground: in CarPlay when the driver switches to navigation, and on the phone when it locks. Redde records only while the user has started listening and stops when the conversation ends.
Processing: used only for BGContinuedProcessingTaskRequest. When the user sends a message and locks the phone, that reply keeps streaming instead of being cut off after about 30 seconds; iOS shows its progress activity with a stop button. Nothing is scheduled for later.

PERMISSIONS
Calendar: asked for only when the user taps the "What's on my calendar today?" card on a new conversation, or the Calendar chip shown in the message field when the text mentions a day. The tap reads that one day's events and attaches them to the message. Once granted, the card shows the next event; it is read on the device and nothing is sent until the card is tapped.
Camera: started by the user in two places: Camera in the + menu, to attach a photo, and "Scan a setup code" on the setup sheet (new in 1.6), which reads a QR code holding a server's address. No picture is kept or sent.

ASSOCIATED DOMAINS (applinks:redde.goosehouse.org, new in 1.6)
A setup link, https://redde.goosehouse.org/connect#..., opens the app on a sheet that shows what the link would set. Nothing is saved until the user confirms. The details follow the # and are not sent to the website.

APP TRANSPORT SECURITY
Plain HTTP is allowed (NSAllowsArbitraryLoads) because self-hosted servers on private networks usually have no public TLS certificate. HTTPS is used whenever the address provides it; the review endpoint is HTTPS.
```

Not part of the notes; these have fields of their own in App Store Connect.

**Privacy policy:** https://legal.goosehouse.org/redde/privacy
**Support:** https://legal.goosehouse.org/redde/support

# CarPlay entitlement request (draft)

Submit at https://developer.apple.com/contact/carplay/ (Account holder: Goosehouse LLC, team 579BSQT6J4). Bundle ID: com.goosehouse.echo.

**App name:** Redde (App Store name "Redde for Hermes")

**Category requested:** Voice-based conversational apps (entitlement `com.apple.developer.carplay-voice-based-conversation`, iOS 26.4 and later).

**Description**

Redde is a voice client for Hermes, an open-source AI agent that users run on their own computer. The app connects only to the user's own server; there is no hosted service. Speech recognition and synthesis run on the phone.

**What the CarPlay experience is**

Opening Redde on the CarPlay screen shows a list with two rows: "Ask Redde" (one question) and "Talk with Redde" (a hands-free conversation, ended by voice). One tap starts listening through the vehicle's microphone; the question goes to the user's server and the answer is spoken through the vehicle's speakers. While that happens the screen shows a standard voice-control card (Listening / Thinking / Speaking / Done). Responses are spoken only: no reply text, images, or other content appear on the car screen. When the answer ends, the card closes back onto the two rows. There are no other screens, no conversation list, and no typing.

**Why it belongs on CarPlay**

The use case is asking a personal assistant questions, and having it take actions on the user's own systems, while driving without touching the phone. After a single tap the interaction is entirely spoken; the CarPlay screen only provides the tap to start and a status glance. It uses CPListTemplate and CPVoiceControlTemplate only.

**Driver distraction**

No content is displayed beyond the voice-control state titles and the two list rows. Interaction is one tap, then voice. The app does not play media, show notifications, or present alerts on the car screen, and it does not register as a system assistant or respond to the steering-wheel voice button.

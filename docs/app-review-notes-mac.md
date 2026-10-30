# App Review notes — the Mac app

The notes for the Mac version of Hermes Redde (platform macOS, same App Store record as the iPhone
app). `scripts/app-store-push.py notes --mac` puts the test key in and sends them; they take plain
text, 4,000 characters at most.

```text
Redde is a chat client for a self-hosted AI assistant, the native Mac version of the iPhone and iPad app (same bundle id, universal purchase). It has no account; conversations go only to the server the user configures.

TO TEST
1. On the "Set up Redde" sheet choose "OpenAI-compatible (direct to a model)".
2. Enter URL https://openrouter.ai/api/v1, API key <<REVIEW KEY>>, model name google/gemma-3-27b-it.
3. Click Test connection (it reports "Connected"), then Done.
4. Type a question and press Return.

Hermes screens (Skills, Memory, Files, Plugins, bots, Projects, Kanban) need a self-hosted Hermes server. Plugins are installed by that server; the app runs no plugin code.

ICLOUD (off by default)
Settings > iCloud keeps servers and settings in the user's own iCloud (key-value store and iCloud Keychain), shared with the iPhone app. Nothing goes to us.

LINK PREVIEWS (off by default)
Settings > Appearance: the app opens a linked page for its title and picture.

IN-APP PURCHASES
Settings > About > Support Redde: three optional one-time tips (consumables) that unlock nothing, the same as on iPhone.

SANDBOX ENTITLEMENTS
Outgoing network: the user's servers and model endpoints.
Incoming network: only a listener on the Mac's own loopback address while the user signs in to a Hermes Dashboard with a browser, which returns to it.
Microphone, camera: voice mode and showing the agent something in it, only when the user starts them; speech is transcribed on the device.
User-selected files: attaching a file, saving one a reply sent, exporting a conversation.
Calendars, contacts, photos: Settings > Phone tools, each area off until the user turns it on, when macOS asks its permission; data goes only to the user's server. Calendars also: Settings > Agent > Calendars (their names) and Leave-By Alerts (next events, to Apple Maps only).
Location (off by default, Settings > Agent): Current Location sends roughly where the Mac is (neighborhood, ~100 m) to the user's own server only with a question about places, directions or weather; Leave-By Alerts send it to Apple Maps only, for the travel time.

APP TRANSPORT SECURITY
Plain HTTP is allowed (NSAllowsArbitraryLoads): self-hosted servers on private networks usually have no public TLS certificate. The review endpoint is HTTPS.
```

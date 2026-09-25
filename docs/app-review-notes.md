**App Store name:** Redde for Hermes · **Display name:** Redde · **Bundle ID:** com.goosehouse.echo · **SKU:** redde-ios (fixed when the record was created; internal only)

# App Review notes (paste into App Store Connect → App Review Information → Notes)

Redde is a voice and chat client for a self-hosted AI assistant. It has no server of its own and collects no data; everything goes to the server the user configures.

**To test:**
1. Open the app. On the "Set up Redde" sheet choose **Fast lane (direct to inference)**.
2. Enter:
   - URL: `https://openrouter.ai/api/v1`
   - API key: `<<REVIEW KEY>>`
   - Model name: `google/gemma-3-27b-it`
3. Tap **Test connection** (it should report "Connected"), then **Done**.
4. Type a question and tap the arrow, or tap the microphone and speak. Speech recognition runs on-device; replies are read aloud.
5. Optional: tap the + button to attach a photo and ask about it; say "Hey Siri, ask Redde" to enter voice mode from Siri.

The Settings sections for "Redde API", "Redde serve", Skills, Tools, Context files and Memory require a self-hosted Hermes gateway and are not exercisable with the review credentials; they show a clear message when no gateway is configured.

**CarPlay (voice-based conversational app, `com.apple.developer.carplay-voice-based-conversation`):**
1. Set up the Fast lane on the phone as above, then connect the phone to CarPlay (a vehicle or the CarPlay Simulator).
2. Open Redde on the CarPlay home screen. It shows two rows: **Ask Redde** (one question) and **Talk with Redde** (hands-free conversation, ended by saying "that's all").
3. Tap **Ask Redde** and speak a question. The voice-control card shows Listening, Thinking and Speaking; the answer is spoken through the car's speakers and no reply text is shown. When it finishes, the card closes back onto the two rows.

**App Transport Security:** the app allows plain-HTTP connections (`NSAllowsArbitraryLoads`) because users' self-hosted servers on private networks typically have no public TLS certificate. HTTPS is used whenever the configured address provides it. The review endpoint above is HTTPS.

**Privacy policy:** https://legal.goosehouse.org/redde/privacy
**Support:** https://legal.goosehouse.org/redde/support

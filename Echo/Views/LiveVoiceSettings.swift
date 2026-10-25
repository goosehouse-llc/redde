import SwiftUI

/// Settings → Voice → Conversation: who holds a voice conversation, Redde or a live engine
/// (GPT-Live, Gemini Live, Grok Voice: `LiveVoice`), for the main agent and every bot without a
/// choice of its own (Edit Bot → Voice, `BotVoice.conversation`); and for a live engine, the key
/// its calls use, the voice, and when a quiet one ends.
struct LiveVoiceSettings: View {
    @State private var settings = Settings.shared
    @State private var hasKey = false
    /// What the person's Hermes says of GPT-Live: nil while asking, or when it can't be asked.
    @State private var hermes: LiveSetup.Status?
    @State private var asked = false

    private var reachesHermes: Bool { BotDirectory.reachable(settings) }
    private var engine: LiveEngine? { settings.voiceEngine.live }

    var body: some View {
        Form {
            Section {
                Picker("Conversation", selection: $settings.voiceEngine) {
                    Text("Redde").tag(Settings.VoiceEngine.redde)
                    ForEach(LiveEngine.allCases, id: \.self) { engine in
                        Text(engine.name).tag(Settings.VoiceEngine(rawValue: engine.rawValue) ?? .redde)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text((engine.map { "\($0.company)'s voice model talks and listens at the same time: interrupt it whenever you like, and it answers small talk at once and says \u{201C}let me check\u{201D} while your agent works. Anything real goes to your agent, as in a typed chat, and the voice says the answer in its own words." }
                     ?? "Your iPhone hears you, your agent answers, and the voice you picked reads the answer out. Nothing goes anywhere but your server and that voice.")
                     + "\n\nFor the main agent and every bot without its own choice (Edit Bot → Voice).")
            }
            if let engine {
                Section("Calls use") {
                    if engine == .gptLive {
                        LabeledContent("Your Hermes's key") { Text(hermesState).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                    }
                    SecretField(item: engine.keyItem, prompt: keyPrompt(engine), replacePrompt: "Replace stored \(engine.company) key",
                                saveTitle: "Save key", removeTitle: "Remove key", optional: true, hasValue: $hasKey)
                        .id(engine)
                }
                Section {
                    NavigationLink {
                        LiveVoiceList(engine: engine,
                                      selection: Binding(get: { settings.appLiveVoice(engine) },
                                                         set: { settings.setAppLiveVoice($0 ?? engine.defaultVoice, for: engine) }),
                                      name: settings.headerTitle)
                    } label: {
                        LabeledContent("Voice", value: engine.voiceName(settings.appLiveVoice(engine)))
                    }
                    Picker("Hang up after quiet", selection: $settings.liveHangUp) {
                        ForEach(Settings.liveHangUps, id: \.self) { minutes in
                            Text(minutes == 0 ? "Never" : minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text(footer(engine))
                }
            }
        }
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: settings.voiceEngine) {
            hasKey = engine.map { Keychain.read($0.keyItem) != nil } ?? false
            guard engine == .gptLive, reachesHermes else { asked = true; return }
            hermes = await LiveSetup.status(profile: nil, settings: settings, fresh: true)
            asked = true
        }
    }

    private var hermesState: String {
        guard reachesHermes else { return "Needs the Dashboard" }
        guard asked else { return "Asking…" }
        guard let hermes else { return "Can't (Hermes 0.21.3 or later)" }
        return hermes.available ? "Comes with the next Redde plugin" : "Has no OpenAI key"
    }

    private func keyPrompt(_ engine: LiveEngine) -> String {
        switch engine {
        case .gptLive: "OpenAI API key"
        case .gemini: "Gemini API key (Google AI Studio)"
        case .grok: "xAI API key"
        case .elevenLabs: "ElevenLabs API key"
        }
    }

    private func footer(_ engine: LiveEngine) -> String {
        let key = engine == .gptLive
            ? "Calls use the OpenAI key above, kept in your iPhone's Keychain, on either connection. Calls with your Hermes's own key "
              + "(OPENAI_API_KEY, or voice.gpt_live.api_key in its config) come with the next Redde plugin. "
            : "Calls use the \(engine.company) key above, kept in your iPhone's Keychain, on either connection. "
        let limit = engine == .gemini ? "Google ends a call's connection after about ten minutes. " : ""
        return key + "The voice is the one calls use, unless a bot has its own (Edit Bot → Voice).\n\n"
            + "While a call is open, what your microphone hears goes to \(engine.company), and your agent's answers go there to be spoken. "
            + engine.cost + " A call hangs up when you tap the orb, say a stop phrase, leave voice mode, or after the quiet set here. "
            + limit
            + "In a call, bots' reading voices and the voice speed don't apply: it is \(engine.company)'s voice."
    }
}

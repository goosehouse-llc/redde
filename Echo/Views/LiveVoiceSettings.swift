import SwiftUI

/// Settings → Voice → Voice mode: who holds a voice conversation, Redde or a live engine
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
                Picker("Voice mode", selection: $settings.voiceEngine) {
                    Text(VoiceSettings.modeName(nil)).tag(Settings.VoiceEngine.redde)
                    ForEach(LiveEngine.allCases, id: \.self) { engine in
                        Text(VoiceSettings.modeName(engine)).tag(Settings.VoiceEngine(rawValue: engine.rawValue) ?? .redde)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text((engine.map { String(localized: "\($0.company)'s voice model talks and listens at the same time: interrupt it whenever you like, and it answers small talk at once and says \u{201C}let me check\u{201D} while your agent works. Anything real goes to your agent, as in a typed chat, and the voice says the answer in its own words.") }
                     ?? String(localized: "Your iPhone hears you, your agent answers, and the reading voice (Settings → Voice) reads the answer out. Nothing goes anywhere but your server and that voice."))
                     + "\n\n" + String(localized: "For the main agent and every bot without its own choice (Edit Bot → Voice)."))
            }
            Section {
                Toggle("Keep Calls On When Locked", isOn: $settings.liveWhenLocked)
            } footer: {
                settings.liveWhenLocked
                    ? Text("A live call goes on with your iPhone locked: the microphone stays open (the orange dot shows it) and the service bills its minutes until you hang up or say a stop phrase, or it ends by itself: after a quiet (Hang up after quiet) or, with hands-free off, after an answer.")
                    : Text("Locking your iPhone hangs up a live call, unless it is hands-free or on your car's screen.")
            }
            if let engine {
                Section {
                    Toggle("Group Chats as Calls", isOn: $settings.liveGroupCalls)
                } footer: {
                    settings.liveGroupCalls
                        ? Text("Voice mode in a group chat is a \(engine.name) call: \(engine.company)'s voice hands what you say to the group, and each bot's reply is said in that bot's \(engine.name) voice (Edit Bot → Voice), the call switching to it for the reply. The call is billed for as long as it is open.")
                        : Text("Voice mode in a group chat is Redde's: your iPhone hears you, and each bot's reply is read in its reading voice.")
                }
                Section("Calls use") {
                    if engine == .gptLive {
                        LabeledContent("Your Hermes's key") { Text(hermesState).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                    }
                    SecretField(item: engine.keyItem, prompt: keyPrompt(engine), replacePrompt: String(localized: "Replace stored \(engine.company) key"),
                                saveTitle: String(localized: "Save key"), removeTitle: String(localized: "Remove key"), optional: true, hasValue: $hasKey)
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
                            (minutes == 0 ? Text("Never") : Text("\(minutes) minutes")).tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text(footer(engine))
                }
            }
        }
        .navigationTitle("Voice Mode")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: settings.voiceEngine) {
            hasKey = engine.map { Keychain.read($0.keyItem) != nil } ?? false
            guard engine == .gptLive, reachesHermes else { asked = true; return }
            hermes = await LiveSetup.status(profile: nil, settings: settings, fresh: true)
            asked = true
        }
    }

    private var hermesState: String {
        guard reachesHermes else { return String(localized: "Needs the Dashboard") }
        guard asked else { return String(localized: "Asking…") }
        guard let hermes else { return String(localized: "Can't (Hermes 0.21.3 or later)") }
        return hermes.available ? String(localized: "Comes with the next Redde plugin") : String(localized: "Has no OpenAI key")
    }

    private func keyPrompt(_ engine: LiveEngine) -> String {
        switch engine {
        case .gptLive: String(localized: "OpenAI API key")
        case .gemini: String(localized: "Gemini API key (Google AI Studio)")
        case .grok: String(localized: "xAI API key")
        case .elevenLabs: String(localized: "ElevenLabs API key")
        }
    }

    private func footer(_ engine: LiveEngine) -> String {
        let key = engine == .gptLive
            ? String(localized: "Calls use the OpenAI key above, kept in your iPhone's Keychain, on either connection. Calls with your Hermes's own key (OPENAI_API_KEY, or voice.gpt_live.api_key in its config) come with the next Redde plugin.")
            : String(localized: "Calls use the \(engine.company) key above, kept in your iPhone's Keychain, on either connection.")
        let limit = engine == .gemini ? String(localized: "Google ends a call's connection after about ten minutes.") + " " : ""
        return key + " " + String(localized: "The voice is the one calls use, unless a bot has its own (Edit Bot → Voice).") + "\n\n"
            + String(localized: "While a call is open, what your microphone hears goes to \(engine.company), and your agent's answers go there to be spoken.") + " "
            + engine.cost + " " + String(localized: "A call hangs up when you tap the orb, say a stop phrase, leave voice mode, or after the quiet set here.") + " "
            + limit
            + String(localized: "In a call, bots' reading voices and the voice speed don't apply: it is \(engine.company)'s voice.")
    }
}

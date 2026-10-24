import SwiftUI

/// Settings → Voice → Conversation: who holds a voice conversation, Redde or GPT-Live
/// (`LiveVoice`), and for GPT-Live, who sets its calls up, the voice, and when a quiet one ends.
struct LiveVoiceSettings: View {
    @State private var settings = Settings.shared
    @State private var hasKey = false
    /// What the person's Hermes says of GPT-Live: nil while asking, or when it can't be asked.
    @State private var hermes: LiveSetup.Status?
    @State private var asked = false

    private var reachesHermes: Bool { BotDirectory.reachable(settings) }

    var body: some View {
        Form {
            Section {
                Picker("Conversation", selection: $settings.voiceEngine) {
                    Text("Redde").tag(Settings.VoiceEngine.redde)
                    Text("GPT-Live").tag(Settings.VoiceEngine.gptLive)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(settings.voiceEngine == .redde
                     ? "Your iPhone hears you, your agent answers, and the voice you picked reads the answer out. Nothing goes anywhere but your server and that voice."
                     : "OpenAI's voice model talks and listens at the same time: interrupt it whenever you like, and it answers small talk at once and says \u{201C}let me check\u{201D} while your agent works. Anything real goes to your agent, as in a typed chat, and the voice says the answer in its own words.")
            }
            if settings.voiceEngine == .gptLive {
                Section("Calls are set up by") {
                    LabeledContent("Your Hermes") { Text(hermesState).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                    SecretField(item: .openAILive, prompt: "OpenAI API key (optional)", replacePrompt: "Replace stored OpenAI key",
                                saveTitle: "Save key", removeTitle: "Remove key", optional: true, hasValue: $hasKey)
                }
                Section {
                    Picker("Voice", selection: $settings.liveVoice) {
                        ForEach(LiveSetup.voices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Picker("Hang up after quiet", selection: $settings.liveHangUp) {
                        ForEach(Settings.liveHangUps, id: \.self) { minutes in
                            Text(minutes == 0 ? "Never" : minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text(footer)
                }
            }
        }
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: settings.voiceEngine) {
            hasKey = Keychain.read(.openAILive) != nil
            guard settings.voiceEngine == .gptLive, reachesHermes else { asked = true; return }
            hermes = await LiveSetup.status(profile: nil, settings: settings, fresh: true)
            asked = true
        }
    }

    private var hermesState: String {
        guard reachesHermes else { return "Needs the Dashboard" }
        guard asked else { return "Asking…" }
        guard let hermes else { return "Can't (Hermes 0.21.3 or later)" }
        return hermes.available ? "Sets calls up" + (hermes.voice.map { ", voice \($0.capitalized)" } ?? "") : "Has no OpenAI key"
    }

    private var footer: String {
        "Your Hermes sets calls up with its own OpenAI key (OPENAI_API_KEY, or voice.gpt_live.api_key in its config), "
            + "through the Dashboard. Where it can't, or on the Hermes API, Redde uses the key above, kept in your iPhone's Keychain. "
            + "The voice is for calls Redde sets up; through Hermes it is Hermes's (voice.gpt_live.voice).\n\n"
            + "While a call is open, what your microphone hears goes to OpenAI, and your agent's answers go there to be spoken. "
            + "OpenAI bills the key's account $0.05 a minute, quiet minutes too: a call hangs up when you tap the orb, "
            + "say a stop phrase, leave voice mode, or after the quiet set here. "
            + "Bots' own voices and the voice speed don't apply: everyone speaks with OpenAI's voice."
    }
}

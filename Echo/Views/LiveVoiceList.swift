import SwiftUI

/// A live engine's voices by language (`LiveEngine.voiceGroups`), each with Hear it
/// (`LiveVoicePreview`): Settings → Voice → Voice mode's voice, and a bot's own
/// (`BotVoicePicker`), whose list starts with the one it has without (`inherit`).
struct LiveVoiceList: View {
    let engine: LiveEngine
    @Binding var selection: String?
    /// The row for no voice of its own ("As in Settings (Marin)"); nil, no such row.
    var inherit: String?
    /// Who the sample line says it is.
    let name: String
    /// For reading replies (`ElevenLabsSpeech`), not a call: no row for the call agent's own voice.
    var reading = false
    @State private var preview = LiveVoicePreview()
    /// ElevenLabs: the account's own voices, listed with its key.
    @State private var account: [ElevenLabsVoice] = []
    @State private var listing = false
    @State private var listProblem: String?

    var body: some View {
        Form {
            if let inherit {
                Section { row(inherit, voice: nil, language: nil) }
            }
            if engine.voicesFromAccount {
                Section("Your voices") {
                    if listing { ProgressView() }
                    if let listProblem { Label(listProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if inherit == nil, !reading { row("The agent's own", voice: "", language: nil) }
                    ForEach(account) { voice in row(voice.name, voice: voice.id, language: nil, detail: voice.detail, sample: voice.sample) }
                }
            } else {
                ForEach(engine.voiceGroups, id: \.language) { group in
                    Section(group.language) {
                        ForEach(group.voices, id: \.self) { voice in row(voice.capitalized, voice: voice, language: group.language) }
                    }
                }
            }
            Section {
                if let problem = preview.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } footer: {
                Text(engine.voicesFromAccount
                     ? "Your ElevenLabs account's voices, each with its own sample to hear."
                     : "Hear it opens a call of a few seconds with your \(engine.company) key, in which the voice says one line: a fraction of a cent each time. \(engine.company) has no recordings of these voices to play instead.")
            }
        }
        .navigationTitle("\(engine.name) Voice")
        .navigationBarTitleDisplayMode(.inline)
        .task { await listAccount() }
        .onDisappear { preview.stop() }
    }

    private func listAccount() async {
        guard engine.voicesFromAccount, account.isEmpty else { return }
        guard let key = Keychain.read(engine.keyItem)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            listProblem = "Save your \(engine.company) key first."
            return
        }
        listing = true
        defer { listing = false }
        do { account = try await ElevenLabsVoice.all(key: key) } catch { listProblem = error.localizedDescription }
    }

    private func row(_ title: String, voice: String?, language: String?, detail: String? = nil, sample: URL? = nil) -> some View {
        let chosen = selection == voice
        return HStack(spacing: 12) {
            Button { selection = voice } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if let style = detail ?? voice.flatMap(engine.style(of:)) {
                            Text(style).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if chosen { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(chosen ? .isSelected : [])
            if let voice, language != nil || sample != nil {
                if preview.playing == voice {
                    Button("Stop", systemImage: "stop.circle") { preview.stop() }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .buttonStyle(.borderless)
                        .symbolEffect(.pulse)
                } else {
                    Button("Hear \(title)", systemImage: "play.circle") {
                        if let sample { preview.playSample(sample, of: voice) } else { preview.play(voice, of: engine, as: name, in: language ?? "English") }
                    }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}

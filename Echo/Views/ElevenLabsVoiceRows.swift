import SwiftUI

/// Settings → Voice with ElevenLabs reading replies (`ElevenLabsSpeech`): the key, the same one
/// live calls with ElevenLabs use, and the voice Redde reads in. Bots get voices of their own from
/// the same account (Edit Bot → Voice).
struct ElevenLabsVoiceRows: View {
    private enum Trial: Equatable { case idle, speaking, spoke, failed(String) }
    private static let sentence = "This is ElevenLabs, reading your replies out on your own key."

    @State private var settings = Settings.shared
    @State private var hasKey = ElevenLabsSpeech.key != nil
    @State private var trial: Trial = .idle
    @State private var player = KokoroPlayer()
    @State private var holdsSession = false

    var body: some View {
        SecretField(item: LiveEngine.elevenLabs.keyItem, prompt: String(localized: "ElevenLabs API key"),
                    replacePrompt: String(localized: "Replace stored ElevenLabs key"),
                    saveTitle: String(localized: "Save key"), removeTitle: String(localized: "Remove key"), optional: true, hasValue: $hasKey)
        NavigationLink {
            LiveVoiceList(engine: .elevenLabs, selection: Binding(
                get: { settings.elevenLabsVoice.nilIfEmpty },
                set: { settings.elevenLabsVoice = $0 ?? "" }),
                          name: settings.headerTitle, reading: true)
        } label: {
            LabeledContent("Voice", value: settings.elevenLabsVoice.nilIfEmpty.flatMap(ElevenLabsVoice.name) ?? String(localized: "Your account's first", comment: "The ElevenLabs voice used when none is picked: the account's first voice"))
        }
        .disabled(!hasKey)
        // A real sentence, not a voice's preview: whether ElevenLabs reads on this key, and what
        // it says when it won't (the on-device voice reads replies then, 2026-10-27).
        Button { trial == .speaking ? release() : test() } label: {
            LabeledContent(trial == .speaking ? String(localized: "Stop") : String(localized: "Say a test sentence")) {
                switch trial {
                case .idle: EmptyView()
                case .speaking: ProgressView()
                case .spoke: Text("Spoken by \(LiveEngine.elevenLabs.company)").lineLimit(2)
                case let .failed(why): Text(why).foregroundStyle(.red).lineLimit(4)
                }
            }
        }
        .disabled(!hasKey)
        .onAppear { if trial == .idle, let problem = ElevenLabsSpeech.problem { trial = .failed(problem) } }
        .onDisappear { release() }
    }

    private func test() {
        guard let key = ElevenLabsSpeech.key else { return }
        trial = .speaking
        Task {
            do {
                var voice = settings.elevenLabsVoice.nilIfEmpty
                if voice == nil { voice = try await ElevenLabsVoice.all(key: key).first?.id }
                guard let voice else {
                    trial = .failed(String(localized: "No voices in this ElevenLabs account."))
                    return
                }
                guard trial == .speaking else { return }   // stopped meanwhile
                try? AudioSessionController.shared.activateForPlayback()
                holdsSession = true
                player.onFailure = { _ in trial = .failed(ElevenLabsSpeech.problem ?? String(localized: "ElevenLabs didn't answer.")) }
                player.onDrained = {
                    if trial == .speaking { trial = .spoke }
                    release(keeping: true)
                }
                player.begin()
                player.enqueueElevenLabs(Self.sentence, voice: voice, speed: settings.voiceSpeed, previous: nil, key: key)
                player.finish()
            } catch {
                guard trial == .speaking else { return }
                trial = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops the sentence and gives the audio session back; `keeping` leaves what was found shown.
    private func release(keeping: Bool = false) {
        player.release()
        if holdsSession { AudioSessionController.shared.deactivate(); holdsSession = false }
        if !keeping, trial == .speaking { trial = .idle }
    }
}

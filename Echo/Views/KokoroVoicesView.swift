import SwiftUI

/// Picks a Kokoro voice from the server's own list, with a play button to hear each one.
/// Blends like `am_onyx(2)+bm_george(1)` stay available through the custom field, which is also
/// where a voice is typed for a server that doesn't list its own (`SpeechServer`).
struct KokoroVoicesView: View {
    @State private var settings = Settings.shared
    @State private var voices: [String] = []
    @State private var error: String?
    @State private var loading = true
    /// The server answered but names no voices: one is typed above.
    @State private var unlisted = false
    @State private var playing: String?
    @State private var player = KokoroPlayer()
    /// A preview took the audio session; give it back on leaving or other apps stay silenced.
    @State private var holdsSession = false

    private struct VoiceGroup: Identifiable {
        let id: String
        let title: String
        let voices: [String]
    }

    var body: some View {
        List {
            Section {
                TextField("am_onyx(2)+bm_george(1)", text: $settings.kokoroVoice)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.body.monospaced())
            } header: {
                Text("Current voice")
            } footer: {
                Text("Pick a voice below, or type a blend: voice names joined with + and optional weights in parentheses.")
            }

            if let error {
                Section { Label(error, systemImage: unlisted ? "character.cursor.ibeam" : "wifi.exclamationmark").foregroundStyle(.secondary) }
            } else if loading {
                Section { ProgressView("Loading voices from Kokoro…") }
            }

            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.voices, id: \.self) { voice in
                        HStack {
                            Button {
                                settings.kokoroVoice = voice
                            } label: {
                                HStack {
                                    Text(displayName(voice))
                                    Spacer()
                                    if settings.kokoroVoice == voice {
                                        Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {
                                preview(voice)
                            } label: {
                                Image(systemName: playing == voice ? "stop.circle.fill" : "play.circle")
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(playing == voice ? String(localized: "Stop preview") : String(localized: "Preview \(displayName(voice))"))
                        }
                    }
                }
            }
        }
        .navigationTitle("Kokoro voices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { release() }
    }

    // MARK: - Data

    private func load() async {
        guard let base = settings.kokoroBaseURL else { error = String(localized: "Set the server TTS address first."); loading = false; return }
        do {
            voices = try await KokoroPlayer.voiceIDs(baseURL: base)
        } catch {
            unlisted = KokoroPlayer.isUnlisted(error)
            self.error = unlisted ? String(localized: "This server doesn't list its voices. Type the name of one it has above.")
                : String(localized: "Couldn't reach Kokoro: \(error.localizedDescription)")
        }
        if voices.isEmpty, error == nil {
            unlisted = true
            error = String(localized: "This server doesn't list its voices. Type the name of one it has above.")
        }
        loading = false
    }

    private var groups: [VoiceGroup] {
        // Kokoro ids are <language><gender>_<name>: a=American, b=British, e=Spanish, f=French,
        // h=Hindi, i=Italian, j=Japanese, p=Portuguese, z=Chinese; f/m = female/male.
        let languages = ["a": String(localized: "American English"), "b": String(localized: "British English"),
                         "e": String(localized: "Spanish"), "f": String(localized: "French"),
                         "h": String(localized: "Hindi"), "i": String(localized: "Italian"),
                         "j": String(localized: "Japanese"), "p": String(localized: "Portuguese"),
                         "z": String(localized: "Chinese")]
        var buckets: [String: [String]] = [:]
        var others: [String] = []
        for voice in voices {
            // Another server's names ("alloy", "en_US-amy-medium") say nothing of the kind.
            guard SpokenLanguage.kokoroLanguage(of: voice) != nil else { others.append(voice); continue }
            let code = String(voice.prefix(2))
            buckets[code, default: []].append(voice)
        }
        let unsorted = others.isEmpty ? [] : [VoiceGroup(id: "other", title: String(localized: "Voices", comment: "A speech server's voices, as it names them"), voices: others)]
        return unsorted + buckets.keys.sorted().compactMap { code in
            guard let voices = buckets[code] else { return nil }
            let language = languages[String(code.prefix(1))] ?? code.uppercased()
            let gender = code.hasSuffix("f") ? String(localized: "female", comment: "A voice's gender") : code.hasSuffix("m") ? String(localized: "male", comment: "A voice's gender") : ""
            return VoiceGroup(id: code, title: "\(language) · \(gender)", voices: voices)
        }
    }

    private func displayName(_ voice: String) -> String {
        guard SpokenLanguage.kokoroLanguage(of: voice) != nil, let underscore = voice.firstIndex(of: "_") else { return voice }
        return voice[voice.index(after: underscore)...].capitalized
    }

    // MARK: - Preview

    private func preview(_ voice: String) {
        if playing == voice {
            release()
            return
        }
        guard let base = settings.kokoroBaseURL else { return }
        // The shared helper, so the route bookkeeping the voice loop relies on stays right.
        try? AudioSessionController.shared.activateForPlayback()
        holdsSession = true
        playing = voice
        player.onDrained = { if playing == voice { playing = nil } }
        player.onFailure = { _ in playing = nil }
        player.begin(baseURL: base)
        player.enqueue("Hi, I'm \(displayName(voice)). This is how Redde would sound.", baseURL: base, model: settings.speechModelOrDefault, voice: voice)
        player.finish()
    }

    private func release() {
        player.release()   // stop() alone leaves the engine running and the session busy
        playing = nil
        if holdsSession { AudioSessionController.shared.deactivate(); holdsSession = false }
    }
}

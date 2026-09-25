import SwiftUI

/// Picks a Kokoro voice from the server's own list, with a play button to hear each one.
/// Blends like `am_onyx(2)+bm_george(1)` stay available through the custom field.
struct KokoroVoicesView: View {
    @State private var settings = Settings.shared
    @State private var voices: [String] = []
    @State private var error: String?
    @State private var loading = true
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
                Section { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary) }
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
                            .accessibilityLabel(playing == voice ? "Stop preview" : "Preview \(displayName(voice))")
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
        guard let base = settings.kokoroBaseURL else { error = "Set the server TTS address first."; loading = false; return }
        struct Envelope: Decodable { var voices: [Entry]; struct Entry: Decodable { var id: String } }
        var request = URLRequest(url: base.appending(path: "v1/audio/voices"))
        request.timeoutInterval = 6
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            voices = try JSONDecoder().decode(Envelope.self, from: data).voices.map(\.id).sorted()
        } catch {
            self.error = "Couldn't reach Kokoro: \(error.localizedDescription)"
        }
        loading = false
    }

    private var groups: [VoiceGroup] {
        // Kokoro ids are <language><gender>_<name>: a=American, b=British, e=Spanish, f=French,
        // h=Hindi, i=Italian, j=Japanese, p=Portuguese, z=Chinese; f/m = female/male.
        let languages = ["a": "American English", "b": "British English", "e": "Spanish", "f": "French",
                         "h": "Hindi", "i": "Italian", "j": "Japanese", "p": "Portuguese", "z": "Chinese"]
        var buckets: [String: [String]] = [:]
        for voice in voices {
            let code = String(voice.prefix(2))
            buckets[code, default: []].append(voice)
        }
        return buckets.keys.sorted().compactMap { code in
            guard let voices = buckets[code] else { return nil }
            let language = languages[String(code.prefix(1))] ?? code.uppercased()
            let gender = code.hasSuffix("f") ? "female" : code.hasSuffix("m") ? "male" : ""
            return VoiceGroup(id: code, title: "\(language) · \(gender)", voices: voices)
        }
    }

    private func displayName(_ voice: String) -> String {
        guard let underscore = voice.firstIndex(of: "_") else { return voice }
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
        player.enqueue("Hi, I'm \(displayName(voice)). This is how Redde would sound.", baseURL: base, voice: voice)
        player.finish()
    }

    private func release() {
        player.release()   // stop() alone leaves the engine running and the session busy
        playing = nil
        if holdsSession { AudioSessionController.shared.deactivate(); holdsSession = false }
    }
}

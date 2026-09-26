import Speech
import SwiftUI

/// Picks the language Redde listens for. On-device transcription understands one language at a
/// time; picking one downloads its speech model if it isn't on the iPhone yet.
struct SpeechLanguageView: View {
    @State private var settings = Settings.shared
    @State private var locales: [Locale] = []
    @State private var installed: Set<String> = []
    @State private var status: Status = .idle

    private enum Status: Equatable { case idle, downloading, failed(String) }

    var body: some View {
        List {
            Section {
                row(id: "", title: "iPhone's language", detail: Self.name(Locale.current.identifier(.bcp47)))
            } footer: {
                statusText
            }
            Section("Languages") {
                ForEach(locales, id: \.self) { locale in
                    let id = locale.identifier(.bcp47)
                    row(id: id, title: Self.name(id), detail: installed.contains(id) ? "Downloaded" : nil)
                }
            }
        }
        .navigationTitle("Listening language")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if locales.isEmpty { ProgressView() } }
        .task { await load() }
    }

    private func row(id: String, title: String, detail: String?) -> some View {
        Button {
            guard settings.speechLanguage != id else { return }
            settings.speechLanguage = id
            Task { await prepare() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if settings.speechLanguage == id {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var statusText: some View {
        switch status {
        case .idle:
            Text("Speak in this language in voice mode. Transcription stays on this iPhone. Replies are read in the language they're written in, whatever you pick here.")
        case .downloading:
            Label("Downloading the speech model…", systemImage: "arrow.down.circle")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    private func load() async {
        let supported = await SpeechTranscriber.supportedLocales
        installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        locales = supported.sorted { Self.name($0.identifier(.bcp47)) < Self.name($1.identifier(.bcp47)) }
    }

    private func prepare() async {
        status = .downloading
        do {
            try await SpeechRecognizer.prepareAssets()
            status = .idle
            installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// "Spanish (Mexico)", in the iPhone's own language.
    static func name(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }
}

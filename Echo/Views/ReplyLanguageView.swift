import SwiftUI

/// Settings → Voice → Reply language: Automatic, or one language every reply comes in.
struct ReplyLanguageView: View {
    @State private var settings = Settings.shared
    @State private var query = ""

    private var languages: [String] {
        let all = ReplyLanguage.codes.sorted { ReplyLanguage.displayName($0) < ReplyLanguage.displayName($1) }
        guard !query.isEmpty else { return all }
        return all.filter { ReplyLanguage.displayName($0).localizedCaseInsensitiveContains(query)
            || ReplyLanguage.name($0).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    row(code: "", title: "Automatic", detail: "The language you write or speak in")
                } footer: {
                    Text("Asks the agent to answer in this language, whatever language you write or speak in. On the Hermes Dashboard it's added to each message as a note, “(Reply in …)”, which other apps show; Redde hides it. For voice mode, pick a matching Listening language too.")
                }
            }
            Section("Languages") {
                ForEach(languages, id: \.self) { code in
                    let native = Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized(with: Locale(identifier: code))
                    row(code: code, title: ReplyLanguage.displayName(code),
                        detail: native == ReplyLanguage.displayName(code) ? nil : native)
                }
            }
        }
        .searchable(text: $query, prompt: "Search languages")
        .navigationTitle("Reply language")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(code: String, title: String, detail: String?) -> some View {
        Button {
            settings.replyLanguage = code
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if settings.replyLanguage == code {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

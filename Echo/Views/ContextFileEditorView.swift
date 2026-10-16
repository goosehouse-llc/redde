import SwiftUI

/// Edits one of the agent's files in its Hermes home on the gateway host (SOUL.md,
/// ENVIRONMENT.md, the memory files), through the Hermes Dashboard; Hermes picks the change up on
/// the next turn. The server says where the home is: not always `~/.hermes` (GitHub issue 15).
struct ContextFileEditorView: View {
    let title: String
    /// Where the file is in the Hermes home, e.g. "memories/MEMORY.md".
    let file: String
    let purpose: String

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var original: String?
    /// Where the file is on the host, once known.
    @State private var path: String?
    /// The server said where the home is; otherwise `path` is Hermes's usual layout, a guess.
    @State private var homeKnown = false
    @State private var missing = false
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    private var dirty: Bool { content != (original ?? "") }
    /// SOUL.md has a route of its own, which finds the profile's folder by itself.
    private var isSoul: Bool { file == "SOUL.md" }
    private var profile: String { Settings.shared.profileName ?? ProfileCatalog.defaultID }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $content)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 380)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                if let path { Text(path) }
            } footer: {
                Text(missing ? "\(missingNote) \(purpose)" : purpose)
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save", action: save).disabled(saving || !dirty)
            }
        }
        .overlay { if loading { ProgressView("Loading \(title)…") } }
        .task { await load() }
    }

    private var missingNote: String {
        homeKnown || isSoul
            ? "This file doesn't exist yet. Saving creates it."
            : "Nothing is at this path, and the Hermes Dashboard didn't say where this profile keeps its files. Saving creates the file here."
    }

    private func load() async {
        defer { loading = false }
        let client = HermesServeClient.shared
        let home = await client.profileHome()
        homeKnown = home != nil
        let path = Settings.shared.profileFilePath(file, home: home)
        self.path = path
        do {
            if let text = try await isSoul ? client.soul(profile: profile) : client.readText(path: path) {
                content = text
                original = text
            } else {
                missing = true
                original = ""
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard let path else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                let client = HermesServeClient.shared
                if isSoul { try await client.setSoul(profile: profile, content: content) }
                else { try await client.writeText(path: path, content: content) }
                original = content
                missing = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

import SwiftUI

/// Edits one of the agent's context files on the gateway host (SOUL.md, ENVIRONMENT.md).
/// Read and written through hermes serve's file API; Hermes picks the change up on the next turn.
struct ContextFileEditorView: View {
    let title: String
    let path: String
    let purpose: String

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var original: String?
    @State private var missing = false
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    private var dirty: Bool { content != (original ?? "") }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $content)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 380)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text(path)
            } footer: {
                Text(missing ? "This file doesn't exist yet. Saving creates it. \(purpose)" : purpose)
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

    private func load() async {
        defer { loading = false }
        do {
            if let text = try await HermesServeClient.shared.readText(path: path) {
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
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await HermesServeClient.shared.writeText(path: path, content: content)
                original = content
                missing = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

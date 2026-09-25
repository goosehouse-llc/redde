import SwiftUI

/// Create or edit a Hermes skill (a SKILL.md) through the dashboard's write endpoints.
/// "Draft with Redde" asks the agent to write the first version from a plain-English brief.
struct SkillEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Conversation.self) private var conversation

    /// nil = new skill.
    let existing: String?
    var onSaved: () -> Void = {}

    /// The name before the last edit, so a rename can rewrite the draft's front matter.
    @State private var previousName = ""
    @State private var name = ""
    @State private var category = ""
    @State private var content = ""
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var showDraft = false
    @State private var brief = ""
    @State private var drafting = false
    @State private var draftProgress = ""

    private var isNew: Bool { existing == nil }
    private var canSave: Bool {
        !saving && !name.trimmingCharacters(in: .whitespaces).isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("skill-name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!isNew)
                if isNew {
                    TextField("Category (optional)", text: $category)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text(isNew ? "New skill" : "Skill")
            } footer: {
                Text(isNew ? "Lowercase with hyphens, like the folder it becomes in ~/.hermes/skills." : "Renaming isn't supported by the gateway; create a new skill instead.")
            }

            Section {
                TextEditor(text: $content)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 320)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                HStack {
                    Text("SKILL.md")
                    Spacer()
                    Button("Draft with Redde", systemImage: "sparkles") { showDraft = true }
                        .font(.caption)
                        .textCase(nil)
                }
            } footer: {
                Text("Front matter (name, description, version, metadata) then When to Use, Procedure, Pitfalls, Verification. Redde loads it on demand when a request matches.")
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle(isNew ? "New skill" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save", action: save).disabled(!canSave)
            }
        }
        .overlay { if loading { ProgressView("Loading skill…") } }
        .sheet(isPresented: $showDraft) { draftSheet }
        .task { await load() }
        .onChange(of: name) { _, new in
            if isNew { content = content.replacingOccurrences(of: "name: \(previousName)\n", with: "name: \(new)\n") }
            previousName = new
        }
    }

    // MARK: - Draft with Hermes

    private var draftSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should this skill make Redde good at?", text: $brief, axis: .vertical)
                        .lineLimit(3 ... 8)
                } header: {
                    Text("Brief")
                } footer: {
                    Text("Redde writes a complete SKILL.md from this, using the gateway's own conventions. You review it before saving.")
                }
                if drafting {
                    Section {
                        ProgressView(draftProgress.isEmpty ? "Asking Redde…" : draftProgress)
                    }
                }
            }
            .navigationTitle("Draft with Redde")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showDraft = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Draft") { Task { await draft() } }
                        .disabled(drafting || brief.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func draft() async {
        let viaAPI = conversation.ledgerAPI() != nil
        guard viaAPI || HermesServeClient.shared.hasCredentials else {
            error = "Drafting needs the Redde API key or the Redde serve login in Settings."
            showDraft = false
            return
        }
        drafting = true
        defer { drafting = false }
        let skillName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "new-skill" : name
        let prompt = """
        Write a complete SKILL.md for a Hermes skill named "\(skillName)". \
        Brief from the user: \(brief)

        Use the standard Hermes skill format: YAML front matter with name, description, version 1.0.0, \
        and metadata.hermes (tags, category\(category.isEmpty ? "" : " = \(category)")), then sections \
        "When to Use", "Procedure", "Pitfalls", and "Verification". Reply with only the file contents \
        inside a single ```markdown code fence and nothing else.
        """
        do {
            let transport: any HermesTransport
            var sessionID: String?
            if let api = conversation.ledgerAPI(), let key = Keychain.read(.gatewayAPIKey), let base = Settings.shared.gatewayBaseURL {
                let session = try await api.createSession(title: "Skill draft: \(skillName) · \(Date.now.formatted(date: .abbreviated, time: .shortened))")
                sessionID = session.id
                transport = HermesSessionsTransport(baseURL: base, apiKey: key)
            } else {
                transport = HermesServeTransport()   // creates its own session
            }
            var text = ""
            for try await event in transport.stream(TurnRequest(userText: prompt, history: [], sessionID: sessionID, model: nil, instructions: nil)) {
                switch event {
                case let .textDelta(delta):
                    text += delta
                    draftProgress = "\(text.count) characters…"
                case let .toolStarted(tool, _):
                    draftProgress = "using \(tool)…"
                default: break
                }
            }
            content = Self.extractMarkdown(text)
            if name.isEmpty, let drafted = Self.frontMatterValue("name", in: content) { name = drafted }
            showDraft = false
        } catch {
            self.error = "Draft failed: \(error.localizedDescription)"
            showDraft = false
        }
    }

    /// Prefer the fenced block; fall back to the whole reply.
    static func extractMarkdown(_ reply: String) -> String {
        if let open = reply.range(of: "```markdown") ?? reply.range(of: "```md") ?? reply.range(of: "```") {
            let rest = reply[open.upperBound...]
            if let close = rest.range(of: "```") {
                return String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func frontMatterValue(_ key: String, in markdown: String) -> String? {
        guard markdown.hasPrefix("---") else { return nil }
        for line in markdown.split(separator: "\n").dropFirst() {
            if line == "---" { break }
            if line.hasPrefix("\(key):") {
                return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Load / save

    private func load() async {
        if let existing {
            name = existing
            loading = true
            defer { loading = false }
            do { content = try await HermesServeClient.shared.skillContent(name: existing) }
            catch { self.error = error.localizedDescription }
        } else if content.isEmpty {
            content = Self.template(name: "")
        }
        previousName = name
    }

    static func template(name: String) -> String {
        """
        ---
        name: \(name)
        description: What this skill helps with, in one line
        version: 1.0.0
        metadata:
          hermes:
            tags: []
            category: general
        ---

        # Title

        ## When to Use
        Trigger conditions for this skill.

        ## Procedure
        1. Step one
        2. Step two

        ## Pitfalls
        - Known failure modes and fixes

        ## Verification
        How to confirm it worked.
        """
    }

    private func save() {
        saving = true
        error = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        Task {
            defer { saving = false }
            do {
                if isNew {
                    try await HermesServeClient.shared.createSkill(name: trimmedName, content: content, category: category)
                } else {
                    try await HermesServeClient.shared.updateSkill(name: trimmedName, content: content)
                }
                onSaved()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

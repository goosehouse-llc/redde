import SwiftUI
import UniformTypeIdentifiers

/// Settings › Agent › What Your Agent Remembers, and Edit Bot › Memory ("memory you can see", 2.4): what the agent
/// remembers, entry by entry (`AgentMemory`), to read, correct, delete or add to, and an import from
/// ChatGPT or Claude. Changes are kept on the page until Save, which writes only what changed.
struct MemoryView: View {
    /// A bot's profile; nil for the one Redde is using.
    var profile: String? = nil
    /// Its name, for the title ("Ops's Memory").
    var owner: String? = nil
    /// Words to look for on opening: the entry a reply's chip named.
    var focus: String? = nil

    @State private var model: AgentMemoryModel
    @State private var search = ""
    @State private var undo: (target: AgentMemory.Target, id: AgentMemoryModel.Row.ID, text: String)?
    @State private var importing = false
    @State private var confirmingDiscard = false
    @FocusState private var focused: AgentMemoryModel.Row.ID?

    init(profile: String? = nil, owner: String? = nil, focus: String? = nil, model: AgentMemoryModel? = nil) {
        self.profile = profile
        self.owner = owner
        self.focus = focus
        _model = State(initialValue: model ?? AgentMemoryModel(profile: profile))
        _search = State(initialValue: focus.map { String($0.prefix(40)) } ?? "")
    }

    var body: some View {
        List {
            if model.needsLogin {
                Section {
                    Text("Your agent's memory is read through the Hermes Dashboard. Add its login in Settings › Connection to see it here.")
                        .foregroundStyle(.secondary)
                }
            } else {
                intro
                ForEach(AgentMemory.Target.allCases) { target in
                    if model.files[target] != nil { section(target) }
                }
                if let problem = model.problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote) }
                }
                if profile == nil { files }
            }
        }
        .navigationTitle(owner.map { String(localized: "\($0)'s Memory") } ?? String(localized: "Memory"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $search, prompt: Text("Search memory"))
        .toolbar { toolbar }
        .overlay(alignment: .bottom) { undoBar }
        .overlay { if model.loading, model.files.isEmpty { ProgressView() } }
        .refreshable { if !model.dirty { await model.load() } }
        .task { if model.files.isEmpty { await model.load() } }
        .sheet(isPresented: $importing) {
            NavigationStack { MemoryImportView(profile: profile, model: model) }
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { model.discard() }
        }
    }

    /// The two files themselves, to edit as text (they were rows of their own on Settings → Agent,
    /// beside this page, until the 2.4 tidy).
    private var files: some View {
        Section {
            NavigationLink {
                ContextFileEditorView(title: "MEMORY.md", file: "memories/MEMORY.md",
                                      purpose: String(localized: "The agent's own notes: things it decided to remember across conversations. Injected into every system prompt."))
            } label: { Label("MEMORY.md", systemImage: "brain") }
            NavigationLink {
                ContextFileEditorView(title: "USER.md", file: "memories/USER.md",
                                      purpose: String(localized: "What the agent knows about you: preferences, facts, how you like answers. Also injected into every prompt."))
            } label: { Label("USER.md", systemImage: "person.crop.circle") }
        } header: {
            Text("Edit the Files", comment: "Memory: the section with MEMORY.md and USER.md, to edit as text")
        } footer: {
            Text("The files the memory tool writes, as plain text.", comment: "Memory: under MEMORY.md and USER.md")
        }
    }

    private var intro: some View {
        Section {
            if let provider = model.provider {
                Label {
                    Text("Your agent also keeps memories with \(provider). Those aren't shown here; this page shows Hermes's own memory, which it reads at the start of every conversation.")
                } icon: { Image(systemName: "info.circle") }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } footer: {
            if model.provider == nil {
                Text("What your agent knows when a conversation starts. Say “remember that…” or “forget that…” in any chat, or change it here. Changes reach new conversations. Notes kept in Basic Memory or another long-term store aren't loaded into every conversation; your agent searches them when needed.")
            }
        }
    }

    private func title(_ target: AgentMemory.Target) -> LocalizedStringKey {
        target == .user ? "About You" : "Notes"
    }

    private func shown(_ target: AgentMemory.Target) -> [AgentMemoryModel.Row] {
        let rows = model.rows(target).filter { !$0.deleted }
        let words = search.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return rows }
        return rows.filter { $0.text.localizedCaseInsensitiveContains(words) || ($0.original ?? "").localizedCaseInsensitiveContains(words) }
    }

    @ViewBuilder
    private func section(_ target: AgentMemory.Target) -> some View {
        let rows = shown(target)
        Section {
            if rows.isEmpty {
                Text(search.isEmpty ? (target == .user ? "Nothing about you yet." : "No notes yet.") : "No match.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                MemoryRowField(text: Binding(get: { model.binding(target, row.id)?.text ?? "" },
                                             set: { model.update(target, row.id, text: $0) }),
                               changed: row.changed, isNew: row.isNew)
                    .focused($focused, equals: row.id)
                    .swipeActions {
                        Button(role: .destructive) { remove(target, row) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { MemoryPasteboard.copy(row.text) }
                        Button("Delete", systemImage: "trash", role: .destructive) { remove(target, row) }
                    }
            }
            if search.isEmpty {
                Button {
                    focused = model.add(target)
                } label: { Label("Add", systemImage: "plus") }
            }
        } header: {
            Text(title(target))
        } footer: {
            fullness(target)
        }
    }

    private func fullness(_ target: AgentMemory.Target) -> some View {
        let used = model.size(target), limit = model.files[target]?.limit ?? target.defaultLimit
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(min(used, limit)), total: Double(max(limit, 1)))
                .tint(used > limit ? .red : used > limit * 9 / 10 ? .orange : .accentColor)
                .accessibilityLabel(Text("\(used) of \(limit) characters"))
            Text(used > limit
                 ? "\(used) of \(limit) characters: over Hermes's limit, so your agent can't add more here."
                 : "\(used) of \(limit) characters")
                .font(.caption)
                .monospacedDigit()
        }
    }

    private func remove(_ target: AgentMemory.Target, _ row: AgentMemoryModel.Row) {
        model.delete(target, row.id)
        if !row.isNew { withAnimation { undo = (target, row.id, row.text) } }
    }

    @ViewBuilder
    private var undoBar: some View {
        if let undo {
            HStack {
                Text("Deleted “\(undo.text)”").lineLimit(1).font(.footnote)
                Spacer()
                Button("Undo") {
                    model.delete(undo.target, undo.id, false)
                    withAnimation { self.undo = nil }
                }
                .bold()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.regularMaterial, in: .capsule)
            .padding()
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: undo.id) {
                try? await Task.sleep(for: .seconds(6))
                withAnimation { self.undo = nil }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            if model.dirty {
                Button(model.saving ? String(localized: "Saving…") : String(localized: "Save")) {
                    Task { if await model.save() { undo = nil } }
                }
                .disabled(model.saving)
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                Button("Import from ChatGPT or Claude…", systemImage: "square.and.arrow.down") { importing = true }
                if model.dirty {
                    Button("Discard Changes", systemImage: "arrow.uturn.backward", role: .destructive) { confirmingDiscard = true }
                }
            } label: { Label("More", systemImage: "ellipsis.circle") }
            .disabled(model.needsLogin)
        }
    }
}

/// One entry, edited in place: grows with its text, marked while changed.
private struct MemoryRowField: View {
    @Binding var text: String
    let changed: Bool
    let isNew: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField(isNew ? "Something your agent should know" : "", text: $text, axis: .vertical)
                .lineLimit(1...8)
            if changed {
                Circle().fill(.tint).frame(width: 6, height: 6)
                    .accessibilityLabel(Text("Changed"))
            }
        }
    }
}

nonisolated enum MemoryPasteboard {
    @MainActor static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Import

/// Memory › Import from ChatGPT or Claude: the export is read on the phone (`MemoryImport`), the
/// person ticks what's true, and only that goes to their server: straight into About You, or to
/// the agent to keep in its own words.
struct MemoryImportView: View {
    let profile: String?
    let model: AgentMemoryModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var picking = false
    @State private var reading = false
    @State private var result: MemoryImport.Result?
    @State private var manifest: MemoryImport.Manifest?
    @State private var picked = Set<MemoryImport.Candidate.ID>()
    @State private var edits: [MemoryImport.Candidate.ID: String] = [:]
    @State private var problem: String?
    @State private var saving = false
    @State private var longTerm: LongTermMemoryModel
    @State private var savedTo: String?

    init(profile: String?, model: AgentMemoryModel, showingManifest: Bool = false) {
        self.profile = profile
        self.model = model
        _longTerm = State(initialValue: LongTermMemoryModel(profile: profile, demo: model.demo))
        if model.demo, showingManifest {
            _manifest = State(initialValue: MemoryImport.demoManifest)
        } else if model.demo {
            let demo = MemoryImport.demoResult
            _result = State(initialValue: demo)
            _picked = State(initialValue: Set(demo.candidates.filter { !$0.isNote }.prefix(4).map(\.id)
                                              + demo.candidates.filter(\.isNote).prefix(2).map(\.id)))
        }
    }

    /// The ticked ones, as edited.
    private var chosenCandidates: [MemoryImport.Candidate] {
        (result?.candidates ?? []).filter { picked.contains($0.id) }.map { candidate in
            var edited = candidate
            if let text = edits[candidate.id] { edited.text = text }
            return edited
        }
    }

    /// The ticked facts (About You takes these, not whole notes).
    private var chosenFacts: [String] { chosenCandidates.filter { $0.kind != .note }.map(\.text) }

    var body: some View {
        List {
            if let result {
                candidateSections(result)
                if let problem { problemSection(problem) }
            } else if let manifest {
                manifestSections(manifest)
                if let problem { problemSection(problem) }
            } else {
                Section {
                    chooseButton
                    if reading { HStack { ProgressView(); Text("Reading…").foregroundStyle(.secondary) } }
                } footer: {
                    Text("In ChatGPT: Settings › Data Controls › Export Data. In Claude: Settings › Privacy › Export Data. Each emails you a link: download the files, then choose them here (several at once is fine). They're read on this \(MemoryImportView.device), and nothing leaves it until you choose what to keep.")
                }
                if let problem { problemSection(problem) }
            }
        }
        .navigationTitle("Import Memory")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .safeAreaInset(edge: .bottom) { if result != nil { actions } }
        .task { if longTerm.store == nil { await longTerm.detect(provider: model.provider) } }
        .alert(savedTo ?? "", isPresented: Binding(get: { savedTo != nil }, set: { if !$0 { savedTo = nil; dismiss() } })) {
            Button("OK") { savedTo = nil; dismiss() }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .json, .folder], allowsMultipleSelection: true) { picked in
            guard case let .success(urls) = picked, !urls.isEmpty else { return }
            read(urls)
        }
    }

    private var chooseButton: some View {
        Button { picking = true } label: { Label("Choose the Export Files…", systemImage: "doc.zipper") }
            .disabled(reading)
    }

    private func problemSection(_ problem: String) -> some View {
        Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote) }
    }

    // MARK: Claude's email

    @ViewBuilder
    private func manifestSections(_ manifest: MemoryImport.Manifest) -> some View {
        Section {
            ForEach(["memories", "conversations"], id: \.self) { category in
                if let part = manifest.part(category) {
                    Button {
                        // Opened in the browser, where claude.ai is signed in: never fetched here.
                        if part.url.absoluteString.hasPrefix(MemoryImport.claudeExportPrefix) { openURL(part.url) }
                    } label: {
                        Label(category == "memories" ? "Download Memories" : "Download Conversations",
                              systemImage: category == "memories" ? "brain.head.profile" : "bubble.left.and.bubble.right")
                    }
                }
            }
        } header: {
            Text("Claude now sends the export in parts")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("This file only lists the downloads. Each opens in your browser, where you're signed in to Claude, and may work only once.")
                if let expires = manifest.expiresAt {
                    Text(expires > .now
                         ? "The links stop working \(expires.formatted(date: .abbreviated, time: .shortened))."
                         : "These links expired \(expires.formatted(date: .abbreviated, time: .shortened)). Ask Claude for a new export.")
                }
                Text("Memories is what Claude knows about you; Conversations is larger and finds more, slowly.")
            }
        }
        Section {
            chooseButton
            if reading { HStack { ProgressView(); Text("Reading…").foregroundStyle(.secondary) } }
        } footer: {
            Text("Then choose the downloaded files here: the .zip files, or what your browser unzipped (a memories folder, conversations.json). Several at once is fine.")
        }
    }

    // MARK: The list

    @ViewBuilder
    private func candidateSections(_ result: MemoryImport.Result) -> some View {
        let facts = result.candidates.filter { $0.kind == .saved }
        let said = result.candidates.filter { $0.kind == .said }
        let project = result.candidates.filter { $0.kind == .projectMemory }
        let notes = result.candidates.filter { $0.kind == .note }
        Section {
            Text("\(picked.count) of \(result.candidates.count) chosen. Read on this \(MemoryImportView.device) from \(result.source == .unknown ? String(localized: "the export") : result.source.rawValue); nothing has left it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if !facts.isEmpty {
            Section(result.source == .claude ? "Claude's memory of you" : "Saved memories") { rows(facts, source: result.source) }
        }
        if !said.isEmpty {
            Section("From your chats") { rows(said, source: result.source) }
        }
        if !project.isEmpty {
            Section {
                rows(project, source: result.source)
            } header: {
                Text("Claude project memory")
            } footer: {
                Text("About projects more than you: better kept in long-term memory.")
            }
        }
        ForEach(Self.folders(notes), id: \.self) { folder in
            Section {
                rows(notes.filter { ($0.folder ?? "") == folder }, source: result.source)
            } header: {
                Text(Self.folderTitle(folder))
            } footer: {
                if folder == Self.folders(notes).last {
                    Text("Whole notes, too long for About You: they go to long-term memory.")
                }
            }
        }
    }

    static func folders(_ notes: [MemoryImport.Candidate]) -> [String] {
        let order = ["people", "areas", "topics", "projects"]
        let found = Set(notes.map { $0.folder ?? "" })
        return order.filter(found.contains) + found.subtracting(order).sorted()
    }

    static func folderTitle(_ folder: String) -> LocalizedStringKey {
        switch folder {
        case "people": "Notes: People"
        case "areas": "Notes: Areas"
        case "topics": "Notes: Topics"
        case "projects": "Notes: Projects"
        case "": "Notes"
        default: "Notes: \(folder.capitalized)"
        }
    }

    private func rows(_ candidates: [MemoryImport.Candidate], source: MemoryImport.Source) -> some View {
        ForEach(candidates) { candidate in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button {
                    if picked.contains(candidate.id) { picked.remove(candidate.id) } else { picked.insert(candidate.id) }
                } label: {
                    Image(systemName: picked.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(picked.contains(candidate.id) ? Color.accentColor : .secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(picked.contains(candidate.id) ? Text("Chosen") : Text("Not chosen"))
                VStack(alignment: .leading, spacing: 2) {
                    if candidate.kind == .note {
                        Text(candidate.text)
                        Text(Self.preview(candidate.body ?? ""))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        TextField("", text: Binding(get: { edits[candidate.id] ?? candidate.text }, set: { edits[candidate.id] = $0 }), axis: .vertical)
                            .lineLimit(1...4)
                        Text(Self.origin(candidate, source: source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static func preview(_ body: String) -> String {
        let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let words = body.split(whereSeparator: \.isWhitespace).count
        return String(localized: "\(words) words · ") + (lines.first ?? "")
    }

    static func origin(_ candidate: MemoryImport.Candidate, source: MemoryImport.Source) -> String {
        switch candidate.kind {
        case .saved: String(localized: "Saved in \(source == .unknown ? String(localized: "the export") : source.rawValue)")
        case .projectMemory: String(localized: "Claude project memory")
        case .note: ""
        case .said: candidate.count > 1 ? String(localized: "You said this \(candidate.count) times") : String(localized: "From a chat")
        }
    }

    // MARK: Actions

    /// Where the ticked ones go: About You (in every conversation; facts only), the long-term store
    /// this Hermes has (searched when needed; facts and notes), or to the agent in a chat.
    private var actions: some View {
        VStack(spacing: 10) {
            // One above the other: a store's name ("Save to Supermemory") needs the width.
            VStack(spacing: 8) {
                Button { add() } label: {
                    Text(saving ? String(localized: "Saving…")
                         : chosenFacts.count == chosenCandidates.count ? String(localized: "Add to About You")
                         : String(localized: "Add \(chosenFacts.count) Facts to About You"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(chosenFacts.isEmpty || saving)
                if let store = longTerm.store {
                    Button { saveLongTerm(store) } label: { Text(store.buttonTitle).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .disabled(chosenCandidates.isEmpty || saving)
                }
            }
            .controlSize(.large)
            Text(longTerm.store == .notesFile
                 ? "About You is loaded into every conversation, so keep it to what should shape every reply; notes don't go there. A notes file isn't searched on its own: your agent reads it when you ask."
                 : "About You is loaded into every conversation, so keep it to what should shape every reply; notes don't go there. \(longTerm.store?.name ?? String(localized: "Long-term memory")) is searched when needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Or Ask My Agent to Keep Them in Its Own Words") { askAgent() }
                .font(.footnote)
                .disabled(chosenFacts.isEmpty || saving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func saveLongTerm(_ store: LongTermMemory.Store) {
        saving = true
        problem = nil
        let chosen = chosenCandidates, source = result?.source ?? .unknown
        Task {
            defer { saving = false }
            do {
                let (saved, message) = try await longTerm.save(chosen, from: source)
                if let message {
                    LaunchRouter.shared.requestGoalChat(profile: profile ?? Settings.shared.profileName ?? ProfileCatalog.defaultID, message: message)
                    dismiss()
                } else if saved {
                    savedTo = store.name.map { String(localized: "Saved \(chosen.count) to \($0).") }
                        ?? String(localized: "Saved \(chosen.count) to notes/imported-\(LongTermMemory.fileSource(source)).md on your Hermes.")
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    static var device: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "iPad") : String(localized: "iPhone")
        #else
        String(localized: "Mac")
        #endif
    }

    private func read(_ urls: [URL]) {
        reading = true
        problem = nil
        Task {
            defer { reading = false }
            let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
            defer { for (url, ok) in zip(urls, scoped) where ok { url.stopAccessingSecurityScopedResource() } }
            do {
                switch try await MemoryImport.read(urls) {
                case let .manifest(found):
                    manifest = found
                case let .result(read):
                    result = read
                    picked = Set(read.candidates.filter(\.saved).map(\.id))
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func add() {
        saving = true
        Task {
            defer { saving = false }
            if await model.addAndSave(chosenFacts) { dismiss() } else { problem = model.problem ?? String(localized: "That didn't save.") }
        }
    }

    private func askAgent() {
        let message = MemoryImport.agentMessage(chosenFacts, from: result?.source ?? .unknown)
        LaunchRouter.shared.requestGoalChat(profile: profile ?? Settings.shared.profileName ?? ProfileCatalog.defaultID, message: message)
        dismiss()
    }
}

// MARK: - Under a reply

/// "Remembered" / "Forgot" under a reply whose turn changed the agent's memory; a tap opens the
/// Memory page at that entry.
struct MemoryChip: View {
    let change: AgentMemory.ReplyChange
    var profile: String?
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Label {
                Text(label).lineLimit(1)
            } icon: {
                Image(systemName: change.kind == .forgot ? "brain.filled.head.profile" : "brain.head.profile")
            }
            .font(.footnote)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityHint(Text("Opens what your agent remembers"))
        .sheet(isPresented: $open) {
            NavigationStack {
                MemoryView(profile: profile, focus: change.kind == .forgot ? nil : change.text)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { open = false } } }
            }
        }
    }

    private var label: String {
        let words = change.text.map { $0.count > 48 ? String($0.prefix(48)) + "…" : $0 }
        switch change.kind {
        case .remembered: return words.map { String(localized: "Remembered: \($0)") } ?? String(localized: "Remembered")
        case .forgot: return words.map { String(localized: "Forgot: \($0)") } ?? String(localized: "Forgot")
        case .changed: return String(localized: "Memory updated")
        }
    }
}

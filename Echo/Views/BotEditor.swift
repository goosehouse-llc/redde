import SwiftUI

/// Making a bot, or changing one (the chat list's Bots, and a bot's chat's ••• menu): what it is
/// called, what it does, its personality (its SOUL.md), its model and its face; whether the chat
/// list shows it; deleting it. All kept on the server as Hermes Desktop keeps them
/// (BotManagement.swift), so Desktop and Redde on other devices see the same bot. The main profile
/// is the person's agent: here, only what it does and its personality.
struct BotEditor: View {
    enum Mode: Identifiable, Equatable {
        case new
        case edit(HermesBot)

        var id: String {
            switch self {
            case .new: "new"
            case let .edit(bot): "edit:\(bot.name)"
            }
        }
    }

    enum Outcome: Equatable {
        case made(String)
        case changed
        case deleted(String)
    }

    let mode: Mode
    /// What the person calls their agent.
    let mainName: String
    var onDone: (Outcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var about = ""
    @State private var soul = ""
    @State private var model: ModelChoice?
    @State private var shown = true
    /// New: the face picked for it, until it is made.
    @State private var face: BotFace?
    @State private var models: [ModelChoice] = []
    /// Changing: the bot as the server had it, so only what changed is written.
    @State private var original: Original?
    @State private var loading = true
    @State private var working = false
    @State private var problem: String?
    @State private var modelQuestion: String?
    @State private var madeNotes: MadeBot?
    @State private var confirmingDelete = false
    @State private var pickingFace = false

    private struct Original: Equatable {
        var title: String
        var about: String
        var soul: String
        var model: ModelChoice?
        var shown: Bool
    }

    private var editing: HermesBot? {
        if case let .edit(bot) = mode { return bot }
        return nil
    }

    private var isMain: Bool { editing?.isDefault == true }
    private var roster: [HermesBot] { BotDirectory.shared.roster?.bots ?? [] }
    private var typedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Its profile's name: the one it has, or the one the name typed gives a new bot.
    private var handle: String? {
        if let editing { return editing.name }
        return BotNames.handle(for: typedTitle, taken: Set(roster.flatMap { [$0.name] + $0.previousNames }))
    }

    /// Another bot already called what was typed.
    private var nameClash: HermesBot? {
        let typed = typedTitle.lowercased()
        guard !typed.isEmpty else { return nil }
        return roster.first { $0.name != editing?.name && $0.label(mainName: mainName).lowercased() == typed }
    }

    private var shownFace: BotFace {
        if isMain { return BotDirectory.shared.mainFace }
        if let editing { return BotDirectory.shared.roster?.faces[editing.name] ?? BotFace(seed: editing.name) }
        if let face { return face }
        guard let handle else { return BotFace(seed: "new bot") }
        return BotRoster(bots: roster + [HermesBot(name: handle)]).faces[handle] ?? BotFace(seed: handle)
    }

    /// The personality a new bot gets when none is written.
    private var writtenForIt: String {
        guard editing == nil else { return "" }
        return BotNames.soul(title: typedTitle.nilIfEmpty ?? "New Bot", handle: handle ?? "new-bot", description: about)
    }

    private var change: BotChange {
        guard let original else { return BotChange() }
        var change = BotChange()
        if !isMain, typedTitle != original.title { change.title = typedTitle }
        if about.trimmingCharacters(in: .whitespacesAndNewlines) != original.about { change.description = about }
        if soul != original.soul { change.soul = soul }
        if !isMain, let model, model.id != original.model?.id { change.model = model }
        if !isMain, shown != original.shown { change.hidden = !shown }
        return change
    }

    private var canSave: Bool {
        guard !working, nameClash == nil else { return false }
        if editing == nil { return handle != nil && !typedTitle.isEmpty && !loading }
        return original != nil && !change.isEmpty && (isMain || !typedTitle.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { faceHeader }
                    .listRowBackground(Color.clear)
                if !isMain {
                    Section {
                        TextField("Scout", text: $title)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                    } header: {
                        Text("Name")
                    } footer: {
                        nameFooter
                    }
                }
                Section {
                    TextField("What it's for", text: $about, axis: .vertical)
                        .lineLimit(1 ... 4)
                } header: {
                    Text("What it does")
                } footer: {
                    Text("Under its name in your chat list, and how the other bots know what to ask it.")
                }
                Section {
                    NavigationLink {
                        PersonalityEditor(text: $soul, written: writtenForIt)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Personality")
                            Text(soulSummary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .disabled(loading && editing != nil)
                    if !isMain {
                        NavigationLink {
                            BotModelList(models: models, selection: $model, sameAs: editing == nil ? "Same as \(mainName)" : nil, loading: loading)
                        } label: {
                            LabeledContent("Model", value: model?.name ?? (editing == nil ? "Same as \(mainName)" : loading ? "…" : "Not set"))
                        }
                    }
                } footer: {
                    if isMain {
                        Text("Your agent's own: its model is picked in each conversation, its name in Settings.")
                    } else if editing == nil {
                        Text("It starts as a copy of \(mainName)'s setup on your server: its settings, API keys and sign-ins, so it can use the same models and tools. Its chats and memories are its own.")
                    }
                }
                if editing != nil, !isMain {
                    Section {
                        Toggle("Show in the chat list", isOn: $shown)
                    } footer: {
                        Text("A hidden bot stays on your server; find it again under Hidden Bots at the end of your bots.")
                    }
                    Section {
                        Button("Delete Bot", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    }
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle(editing == nil ? "New Bot" : isMain ? mainName : (original?.title.nilIfEmpty ?? editing?.label(mainName: mainName) ?? "Bot"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(editing == nil ? "Create" : "Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
            .task { await load() }
            .sheet(isPresented: $pickingFace) { facePicker }
            .confirmationDialog("Delete \(editing?.label(mainName: mainName) ?? "this bot")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Bot", role: .destructive) { delete() }
            } message: {
                Text("Its chat, memories and settings are deleted from your server. This can't be undone.")
            }
            .alert("Use this model?", isPresented: Binding(get: { modelQuestion != nil }, set: { if !$0 { modelQuestion = nil } })) {
                Button("Use It") { save(modelConfirmed: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(modelQuestion ?? "")
            }
            .alert("\(typedTitle) is made", isPresented: Binding(get: { madeNotes != nil }, set: { if !$0 { finishMade() } })) {
                Button("OK") { finishMade() }
            } message: {
                Text(madeNotes?.notes.joined(separator: "\n\n") ?? "")
            }
        }
        .interactiveDismissDisabled(working)
    }

    private var faceHeader: some View {
        VStack(spacing: 8) {
            BotAvatar(face: shownFace, size: 96)
                .accessibilityLabel("Its face")
            Button("Change Face") { pickingFace = true }
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var nameFooter: some View {
        if let nameClash {
            Text("\(nameClash.label(mainName: mainName)) is already called that.").foregroundStyle(.orange)
        } else if let editing {
            Text("Others call it @\(BotMentions.tag(for: HermesBot(name: editing.name, title: typedTitle.nilIfEmpty))). Its handle stays @\(editing.handle).")
        } else if let handle {
            Text("Others call it @\(handle).")
        } else if !typedTitle.isEmpty {
            Text("Give it a name with a letter or number in it.").foregroundStyle(.orange)
        }
    }

    private var soulSummary: String {
        if loading && editing != nil { return "…" }
        let text = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return editing == nil ? "Written for it from its name and what it does" : "None" }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#* ")) }.filter { !$0.isEmpty }
        return lines.prefix(2).joined(separator: " · ")
    }

    @ViewBuilder private var facePicker: some View {
        if let editing {
            BotFacePicker(bot: editing, name: editing.label(mainName: mainName), current: shownFace) {
                Task { _ = try? await BotDirectory.shared.refresh() }
            }
        } else {
            BotFacePicker(bot: HermesBot(name: handle ?? "new-bot", face: face), name: typedTitle.nilIfEmpty ?? "New Bot", current: shownFace,
                          choose: { face = $0 })
        }
    }

    // MARK: - Server

    private func load() async {
        let client = HermesServeClient.shared
        defer { loading = false }
        guard let editing else {
            models = (try? await client.modelOptions(forProfile: "default")) ?? []
            return
        }
        do {
            async let details = client.botDetails(editing)
            let options = isMain ? [] : ((try? await client.modelOptions(forProfile: editing.name)) ?? [])
            let read = try await details
            models = options
            let current = options.first(where: \.isCurrent)
                ?? read.model.map { ModelChoice(provider: read.provider ?? "", providerName: read.provider ?? "", model: $0, name: $0, isCurrent: true) }
            let start = Original(title: editing.title ?? editing.displayName ?? "", about: read.description, soul: read.soul,
                                 model: current, shown: !editing.isHidden)
            title = start.title
            about = start.about
            soul = start.soul
            model = start.model
            shown = start.shown
            original = start
        } catch {
            problem = "Couldn't read this bot: \(error.localizedDescription)"
        }
    }

    private func save(modelConfirmed: Bool = false) {
        problem = nil
        working = true
        Task {
            defer { working = false }
            let client = HermesServeClient.shared
            do {
                if let editing {
                    var change = change
                    change.modelConfirmed = modelConfirmed
                    switch try await client.changeBot(editing, change) {
                    case let .confirmModel(question):
                        modelQuestion = question
                    case .done:
                        dismiss()
                        onDone(.changed)
                    }
                } else if let handle {
                    let made = try await client.makeBot(
                        NewBot(title: typedTitle, handle: handle, description: about, soul: soul, model: model, face: face))
                    if made.notes.isEmpty {
                        dismiss()
                        onDone(.made(made.name))
                    } else {
                        madeNotes = made
                    }
                }
            } catch {
                problem = error.localizedDescription
                // Partly changed, or changed elsewhere: what the list shows is read again.
                if editing != nil { _ = try? await BotDirectory.shared.refresh() }
            }
        }
    }

    private func finishMade() {
        guard let made = madeNotes else { return }
        madeNotes = nil
        dismiss()
        onDone(.made(made.name))
    }

    private func delete() {
        guard let editing else { return }
        problem = nil
        working = true
        Task {
            defer { working = false }
            do {
                try await HermesServeClient.shared.deleteBot(editing)
                dismiss()
                onDone(.deleted(editing.name))
            } catch {
                problem = "Couldn't delete it: \(error.localizedDescription)"
            }
        }
    }
}

/// A bot's personality, its SOUL.md: who it is and how it talks, read at the start of every chat.
struct PersonalityEditor: View {
    @Binding var text: String
    /// What a new bot gets when nothing is written here; empty when changing one.
    let written: String

    var body: some View {
        TextEditor(text: $text)
            .font(.callout)
            .overlay(alignment: .topLeading) {
                if text.isEmpty, !written.isEmpty {
                    Text(written)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 12)
            .navigationTitle("Personality")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Text(written.isEmpty
                     ? "Who it is and how it talks (its SOUL.md on the server). It reads this at the start of every chat; a chat already going keeps the one it began with."
                     : "Who it is and how it talks (its SOUL.md on the server). Left empty, it gets the one shown, written from its name and what it does.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.bar)
            }
            .toolbar {
                if text.isEmpty, !written.isEmpty {
                    Button("Edit This") { text = written }
                }
            }
    }
}

/// The models a bot can have, as the per-chat picker groups them.
struct BotModelList: View {
    let models: [ModelChoice]
    @Binding var selection: ModelChoice?
    /// A new bot's first row: no model of its own, the main profile's.
    let sameAs: String?
    let loading: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let sameAs {
                Section { row(sameAs, nil) }
            }
            ForEach(ModelPickerView.grouped(models), id: \.provider) { group in
                Section(group.name) {
                    ForEach(group.models) { row($0.name, $0) }
                }
            }
            if models.isEmpty {
                Section {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Hermes offered no models for it.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, _ choice: ModelChoice?) -> some View {
        let picked = selection?.model == choice?.model && selection?.provider == choice?.provider
        return Button {
            selection = choice
            dismiss()
        } label: {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                if picked { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The bots hidden from the chat list (here or in Hermes Desktop), each to be shown again.
struct HiddenBotsView: View {
    let mainName: String
    @Environment(\.dismiss) private var dismiss
    @State private var showing: String?
    @State private var problem: String?

    private var bots: [HermesBot] { BotDirectory.shared.roster?.bots.filter { $0.isHidden && !$0.isDefault } ?? [] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(bots) { bot in
                        HStack(spacing: 12) {
                            BotAvatar(face: BotDirectory.shared.roster?.faces[bot.name] ?? BotFace(seed: bot.name), size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bot.label(mainName: mainName))
                                if !bot.description.isEmpty {
                                    Text(bot.description).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if showing == bot.name {
                                ProgressView()
                            } else {
                                Button("Show") { show(bot) }
                                    .buttonStyle(.bordered)
                                    .disabled(showing != nil)
                            }
                        }
                    }
                } footer: {
                    Text("Hidden here and in Hermes Desktop alike. A hidden bot keeps its chat, and the other bots can still message it.")
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Hidden Bots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func show(_ bot: HermesBot) {
        showing = bot.name
        problem = nil
        Task {
            defer { showing = nil }
            do {
                _ = try await HermesServeClient.shared.changeBot(bot, BotChange(hidden: false))
                let roster = try await BotDirectory.shared.refresh()
                if !roster.bots.contains(where: { $0.isHidden && !$0.isDefault }) { dismiss() }
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

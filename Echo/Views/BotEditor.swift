import AVFoundation
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
    /// The toolsets the server has, the ones the main agent has, and the ones the bot has (nil:
    /// the main agent's).
    @State private var offered: [BotToolset] = []
    @State private var mainToolsets: Set<String> = []
    @State private var toolsets: Set<String>?
    /// Its skills, each on or off for it; nil until read (or when they can't be).
    @State private var skills: [HermesServeClient.DashboardSkill]?
    /// The ones it reads in full at the start of every message; nil until read.
    @State private var alwaysLoaded: Set<String>?
    /// The template New Bot started from (`BotTemplate`).
    @State private var template = BotTemplate.blank.id
    /// Changing: the bot as the server had it, so only what changed is written.
    @State private var original: Original?
    @State private var loading = true
    /// Read once per opening: the screen appears again each time Personality or Model is closed,
    /// and reading again then put the server's back over what had been changed.
    @State private var loaded = false
    @State private var working = false
    @State private var problem: String?
    @State private var modelQuestion: String?
    @State private var madeNotes: MadeBot?
    @State private var confirmingDelete = false
    @State private var pickingFace = false
    @State private var pickingVoice = false

    /// A picked voice, in a word: its name, or Redde's own.
    static func voiceSummary(_ voice: BotVoice) -> String {
        var speed = voice.speed.map { " · " + BotVoicePicker.speedLabel($0) } ?? ""
        if let conversation = voice.conversation { speed += " · " + (conversation.live?.name ?? "Redde") }
        if voice.sameAsMain == true { return String(localized: "Same as the main agent") + speed }
        if let id = voice.kokoro { return BotVoicePicker.kokoroName(id) + speed }
        if let id = voice.onDevice { return (AVSpeechSynthesisVoice(identifier: id)?.name ?? String(localized: "A built-in voice")) + speed }
        return String(localized: "Automatic", comment: "A bot's voice: one picked for it by itself") + speed
    }

    private struct Original: Equatable {
        var title: String
        var about: String
        var soul: String
        var model: ModelChoice?
        var shown: Bool
        var toolsets: Set<String>?
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
        // The main agent's again: its list as it is now (an empty one means something else to each release).
        if toolsets != original.toolsets { change.toolsets = (toolsets ?? mainToolsets).sorted() }
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
                if editing == nil {
                    Section {
                        templates
                    } header: {
                        Text("Start from")
                    } footer: {
                        Text("Its name, what it does, its personality, face and tools filled in. Change any of them before you make it.")
                    }
                }
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
                if let editing, !isMain {
                    Section {
                        Button { pickingVoice = true } label: {
                            LabeledContent("Voice", value: Settings.shared.botVoicesHere[editing.name].map(Self.voiceSummary)
                                           ?? String(localized: "Automatic", comment: "A bot's voice: one picked for it by itself"))
                        }
                        .foregroundStyle(.primary)
                    } footer: {
                        Text("What its replies are read in, in voice mode, group chats and the car, and whether its voice mode is Redde's or a live call (GPT-Live, Gemini Live, Grok Voice, ElevenLabs).")
                    }
                    .sheet(isPresented: $pickingVoice) { BotVoicePicker(bot: editing, mainName: mainName) }
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
                            BotModelList(models: models, selection: $model, sameAs: editing == nil ? String(localized: "Same as \(mainName)") : nil,
                                         loading: loading)
                        } label: {
                            LabeledContent("Model", value: model?.name
                                           ?? (editing == nil ? String(localized: "Same as \(mainName)") : loading ? "…" : String(localized: "Not set")))
                        }
                    }
                    // The main agent's too (his ask 2026-10-22: Code Execution off for Sol): its
                    // list is the one the others' "Same as" follows.
                    NavigationLink {
                        BotToolsList(offered: offered, selection: $toolsets, main: mainToolsets, mainName: mainName, isMain: isMain)
                    } label: {
                        LabeledContent("Tools", value: toolsSummary)
                    }
                    .disabled(offered.isEmpty)
                    // Its skills, each on or off for it alone, at once (not on Save). One being made
                    // has none of its own yet.
                    if let editing {
                        NavigationLink {
                            BotSkillsList(bot: editing, name: isMain ? mainName : title.nilIfEmpty ?? editing.label(mainName: mainName),
                                          skills: $skills, alwaysLoaded: $alwaysLoaded,
                                          hasSkillsTool: offered.isEmpty || (toolsets ?? mainToolsets).contains("skills"))
                        } label: {
                            LabeledContent("Skills", value: skillsSummary)
                        }
                        .disabled(skills == nil)
                        // Its plugins, its own as its skills are (a profile's), changed at once.
                        NavigationLink {
                            PluginsView(profile: editing.name, owner: isMain ? mainName : title.nilIfEmpty ?? editing.label(mainName: mainName))
                        } label: {
                            Text("Plugins")
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
            .navigationTitle(editing == nil ? String(localized: "New Bot")
                             : isMain ? mainName : (original?.title.nilIfEmpty ?? editing?.label(mainName: mainName) ?? String(localized: "Bot")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(editing == nil ? String(localized: "Create") : String(localized: "Save")) { save() }
                            .disabled(!canSave)
                    }
                }
            }
            .task { await load() }
            .sheet(isPresented: $pickingFace) { facePicker }
            .confirmationDialog(editing.map { String(localized: "Delete \($0.label(mainName: mainName))?") } ?? String(localized: "Delete this bot?"),
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
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
            BotAvatar(face: shownFace, name: typedTitle.nilIfEmpty ?? (isMain ? mainName : ""), size: 96)
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

    /// The templates, as faces in a row: Blank first.
    private var templates: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach([BotTemplate.blank] + BotTemplate.all) { choice in
                    let picked = template == choice.id
                    Button { use(choice) } label: {
                        VStack(spacing: 6) {
                            if choice.id == BotTemplate.blank.id {
                                Image(systemName: "plus").font(.title2.weight(.medium)).frame(width: 52, height: 52)
                                    .background(.quaternary, in: .circle)
                            } else {
                                BotAvatar(face: choice.face, name: choice.title, size: 52)
                            }
                            Text(choice.id == BotTemplate.blank.id ? String(localized: "Blank", comment: "A bot template: start from nothing") : choice.title)
                                .font(.caption)
                        }
                        .padding(6)
                        .background(picked ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.id == BotTemplate.blank.id ? String(localized: "Blank", comment: "A bot template: start from nothing") : choice.title)
                    .accessibilityHint(choice.about)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Fills the form from a template. A name the person typed stays; one a template gave goes
    /// with it.
    private func use(_ choice: BotTemplate) {
        let previous = ([BotTemplate.blank] + BotTemplate.all).first { $0.id == template }
        template = choice.id
        if typedTitle.isEmpty || typedTitle == previous?.title { title = choice.title }
        about = choice.about
        soul = choice.soul
        face = choice.id == BotTemplate.blank.id ? nil : choice.face
        toolsets = choice.toolsets(offered: offered).map(Set.init)
    }

    /// How many of its skills are on, or "…" until they are read.
    private var skillsSummary: String {
        guard let skills else { return loading ? "…" : String(localized: "Can't be read", comment: "A bot's skills: they couldn't be read") }
        let on = skills.filter { $0.enabled ?? true }.count
        let summary = on == skills.count ? String(localized: "All \(skills.count)", comment: "All of a bot's skills or tools, e.g. “All 12”")
            : String(localized: "\(on) of \(skills.count)", comment: "How many of a bot's skills or tools it has, e.g. “3 of 12”")
        let pinned = alwaysLoaded?.count ?? 0
        return pinned == 0 ? summary : String(localized: "\(summary) · \(pinned) always", comment: "A bot's skills, and how many it reads at the start of every message")
    }

    private var toolsSummary: String {
        if loading { return "…" }
        guard let toolsets, isMain || toolsets != mainToolsets else { return String(localized: "Same as \(mainName)") }
        if isMain, toolsets.count > 2 {
            return toolsets.count == offered.count ? String(localized: "All \(offered.count)", comment: "All of a bot's skills or tools, e.g. “All 12”")
                : String(localized: "\(toolsets.count) of \(offered.count)", comment: "How many of a bot's skills or tools it has, e.g. “3 of 12”")
        }
        let names = offered.filter { toolsets.contains($0.name) }.map(\.title)
        return names.count <= 2 ? (names.isEmpty ? String(localized: "None", comment: "A bot with no tools, or no personality") : names.joined(separator: ", "))
            : String(localized: "\(names.count) of \(offered.count)", comment: "How many of a bot's skills or tools it has, e.g. “3 of 12”")
    }

    private var soulSummary: String {
        if loading && editing != nil { return "…" }
        let text = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return editing == nil ? String(localized: "Written for it from its name and what it does")
                : String(localized: "None", comment: "A bot with no tools, or no personality")
        }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "#* ")) }   // ("**Mission:** …")
            .filter { !$0.isEmpty }
        return lines.prefix(2).joined(separator: " · ")
    }

    @ViewBuilder private var facePicker: some View {
        if let editing {
            BotFacePicker(bot: editing, name: editing.label(mainName: mainName), current: shownFace) {
                Task { _ = try? await BotDirectory.shared.refresh() }
            }
        } else {
            BotFacePicker(bot: HermesBot(name: handle ?? "new-bot", face: face), name: typedTitle.nilIfEmpty ?? String(localized: "New Bot"), current: shownFace,
                          choose: { face = $0 })
        }
    }

    // MARK: - Server

    private func load() async {
        guard !loaded else { return }
        let client = HermesServeClient.shared
        defer { loading = false }
        guard let editing else {
            async let tools = client.toolsetsOffered()
            async let board = client.dashboardToolsets()
            models = (try? await client.modelOptions(forProfile: "default")) ?? []
            let main = try? await tools
            offered = Self.withKanban(main?.toolsets ?? [], board: try? await board)
            mainToolsets = await client.mainToolsetsNow() ?? main?.enabledToolsets ?? []
            loaded = !models.isEmpty
            return
        }
        do {
            async let details = client.botDetails(editing)
            async let tools = client.toolsetsOffered()
            async let ownSkills = client.dashboardSkills(profile: editing.name)
            async let preloaded = client.alwaysLoadedSkills(profile: editing.name)
            async let board = client.dashboardToolsets()
            let options = isMain ? [] : ((try? await client.modelOptions(forProfile: editing.name)) ?? [])
            var read = try await details
            let described = (try? await tools)?.enabledToolsets
            let main = await client.mainToolsetsNow() ?? described ?? []
            // The main agent's own: as its chats have them.
            if isMain { read.toolsets = read.toolsets.map { var set = $0; set.enabled = main.contains(set.name); return set } }
            models = options
            let current = options.first(where: \.isCurrent)
                ?? read.model.map { ModelChoice(provider: read.provider ?? "", providerName: read.provider ?? "", model: $0, name: $0, isCurrent: true) }
            let start = Original(title: editing.title ?? editing.displayName ?? "", about: read.description, soul: read.soul,
                                 model: current, shown: !editing.isHidden,
                                 toolsets: !isMain && read.enabledToolsets == main ? nil : read.enabledToolsets)
            offered = Self.withKanban(read.toolsets, board: try? await board)
            mainToolsets = main
            toolsets = start.toolsets
            skills = try? await ownSkills
            alwaysLoaded = (try? await preloaded).map(Set.init)
            title = start.title
            about = start.about
            soul = start.soul
            model = start.model
            shown = start.shown
            original = start
            loaded = true
        } catch {
            problem = String(localized: "Couldn't read this bot: \(error.localizedDescription)")
        }
    }

    /// Kanban offered too: Hermes lists a toolset that is off by default only where it is on
    /// already, so no bot could be given it, and none in a group chat could make a card (2026-10-26).
    /// A bot's own list is what its group chats on its own server use (lab.sh templates, 0.21.5 on).
    private static func withKanban(_ offered: [BotToolset], board: [HermesSessionsAPI.Toolset]?) -> [BotToolset] {
        guard !offered.isEmpty, !offered.contains(where: { $0.name == "kanban" }),
              let kanban = board?.first(where: { $0.name == "kanban" }) else { return offered }
        return offered + [BotToolset(name: "kanban", description: kanban.description ?? "", enabled: false)]
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
                        NewBot(title: typedTitle, handle: handle, description: about, soul: soul, model: model, face: face,
                               toolsets: toolsets.map { set in offered.map(\.name).filter(set.contains) }))
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
                problem = String(localized: "Couldn't delete it: \(error.localizedDescription)")
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
                (written.isEmpty
                     ? Text("Who it is and how it talks (its SOUL.md on the server). It reads this at the start of every chat; a chat already going keeps the one it began with.")
                     : Text("Who it is and how it talks (its SOUL.md on the server). Left empty, it gets the one shown, written from its name and what it does."))
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
                            BotAvatar(face: BotDirectory.shared.roster?.faces[bot.name] ?? BotFace(seed: bot.name), name: bot.label(mainName: mainName), size: 30)
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


/// The toolsets a bot has: any of those the server offers, or the main agent's. Hermes 0.21.5 and
/// later keep a bot to its list; earlier ones give every bot all of them.
struct BotToolsList: View {
    let offered: [BotToolset]
    @Binding var selection: Set<String>?
    /// The main agent's toolsets.
    let main: Set<String>
    let mainName: String
    /// The main agent's own list: no "Same as" to fall back on.
    var isMain = false

    var body: some View {
        Form {
            if !isMain {
                Section {
                    Button { selection = nil } label: {
                        HStack {
                            Text("Same as \(mainName)")
                            Spacer()
                            if selection == nil { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == nil ? .isSelected : [])
                } footer: {
                    Text("The tools \(mainName) has.")
                }
            }
            Section {
                ForEach(offered) { toolset in
                    let on = (selection ?? main).contains(toolset.name)
                    Toggle(isOn: Binding(
                        get: { on },
                        set: { on in
                            var set = selection ?? main
                            if on { set.insert(toolset.name) } else { set.remove(toolset.name) }
                            selection = set
                        })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(toolset.title)
                            if !toolset.description.isEmpty {
                                Text(toolset.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    // Never none: Hermes takes an empty list for every tool.
                    .disabled(on && (selection ?? main).count == 1)
                }
            } footer: {
                if isMain {
                    Text("\(mainName)'s tools over the Hermes Dashboard, its Bot Chat included, from the next message (Hermes 0.21.0: in chats started after the change); the first reply after a change is slow on a model running on your own machine. The Hermes API server keeps its own list (platform_toolsets.api_server in config.yaml on the Hermes host).")
                } else {
                    Text("Fewer tools make a bot's every turn quicker to start on a model running on your own machine. Hermes 0.21.5 and later keep a bot to these; earlier ones give every bot all of \(mainName)'s.")
                }
            }
        }
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A bot's skills, each on or off for it alone (`skills.disabled` in its profile; his ask
/// 2026-10-22), and the few it reads in full at the start of every message (`skills.auto_load`:
/// the Home bot with its Home Assistant skills always at hand, the rest read when needed). A
/// switch or a pin takes effect at once.
struct BotSkillsList: View {
    let bot: HermesBot
    let name: String
    @Binding var skills: [HermesServeClient.DashboardSkill]?
    @Binding var alwaysLoaded: Set<String>?
    /// Its Skills tool is on: without it no skill is listed for it or read, always loaded or not.
    let hasSkillsTool: Bool
    @State private var busy: Set<String> = []
    @State private var problem: String?
    @State private var query = ""

    private var byCategory: [(category: String, skills: [HermesServeClient.DashboardSkill])] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = (skills ?? []).filter {
            words.isEmpty || $0.name.lowercased().contains(words) || ($0.description ?? "").lowercased().contains(words)
        }
        let grouped = Dictionary(grouping: shown) { $0.category?.isEmpty == false ? $0.category! : String(localized: "Other", comment: "Skills with no category") }
        return grouped.keys.sorted().compactMap { key in grouped[key].map { (key, $0.sorted { $0.name < $1.name }) } }
    }

    var body: some View {
        List {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if !hasSkillsTool {
                Label("\(name)'s Skills tool is off (Edit Bot → Tools), so it reads none of these.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Section {
            } footer: {
                Text("On, \(name) sees a skill listed and reads it only when it needs it. Off, it doesn't see it at all. Pinned (\(Image(systemName: "pin.fill"))), it reads the skill in full at the start of every message: keep that to the few it needs every time, as each makes every message slower to start. A pin takes effect in new chats, and in \(name)'s ongoing chat once that starts fresh or is condensed.")
            }
            ForEach(byCategory, id: \.category) { group in
                Section("\(group.category.capitalized) · \(group.skills.count)") {
                    ForEach(group.skills) { skill in row(skill) }
                }
            }
        }
        .searchable(text: $query, prompt: "Find a skill")
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ skill: HermesServeClient.DashboardSkill) -> some View {
        let on = skill.enabled ?? true
        let pinned = alwaysLoaded?.contains(skill.name) == true
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                if pinned {
                    Label("Always loaded", systemImage: "pin.fill").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                }
                if let description = skill.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if on, alwaysLoaded != nil {
                Button { pin(skill, !pinned) } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .foregroundStyle(pinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(busy.contains(skill.name))
                .accessibilityLabel(pinned ? String(localized: "Always loaded") : String(localized: "Loaded when needed"))
                .accessibilityHint(pinned ? String(localized: "Reads it only when needed instead") : String(localized: "Reads it in full at the start of every message"))
            }
            Toggle("", isOn: Binding(get: { on }, set: { toggle(skill, $0) }))
                .labelsHidden()
                .disabled(busy.contains(skill.name))
                .accessibilityLabel(skill.name)
        }
    }

    /// Always loaded, or read when needed: the whole list written at once (the Dashboard merges it
    /// into the bot's config, the list replacing the one there).
    private func pin(_ skill: HermesServeClient.DashboardSkill, _ on: Bool) {
        guard var set = alwaysLoaded else { return }
        let before = set
        if on { set.insert(skill.name) } else { set.remove(skill.name) }
        alwaysLoaded = set
        busy.insert(skill.name)
        problem = nil
        Task {
            defer { busy.remove(skill.name) }
            do {
                try await HermesServeClient.shared.setAlwaysLoadedSkills(set.sorted(), profile: bot.name)
            } catch {
                alwaysLoaded = before
                problem = on ? String(localized: "Couldn't pin \(skill.name): \(error.localizedDescription)")
                    : String(localized: "Couldn't unpin \(skill.name): \(error.localizedDescription)")
            }
        }
    }

    private func toggle(_ skill: HermesServeClient.DashboardSkill, _ on: Bool) {
        guard let i = skills?.firstIndex(where: { $0.name == skill.name }) else { return }
        busy.insert(skill.name)
        skills?[i].enabled = on
        problem = nil
        Task {
            defer { busy.remove(skill.name) }
            do {
                try await HermesServeClient.shared.toggleSkill(name: skill.name, enabled: on, profile: bot.name)
                // An off skill can't be read at all, so it is no longer always loaded either.
                if !on, alwaysLoaded?.contains(skill.name) == true { pin(skill, false) }
            } catch {
                if let i = skills?.firstIndex(where: { $0.name == skill.name }) { skills?[i].enabled = !on }
                problem = on ? String(localized: "Couldn't switch \(skill.name) on: \(error.localizedDescription)")
                    : String(localized: "Couldn't switch \(skill.name) off: \(error.localizedDescription)")
            }
        }
    }
}

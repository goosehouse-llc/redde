import SwiftUI

/// Which model answers, and how hard it thinks. Lists come from the active backend: the
/// gateway's model options for the Hermes transports, llama-swap's loaded models for the fast lane.
struct ModelPickerView: View {
    /// Opened from Settings rather than a conversation: on Hermes, where each conversation has its
    /// own model (GitHub issue 58), only the reasoning effort and where models are picked.
    var fromSettings = false
    @Environment(Conversation.self) private var conversation
    @State private var settings = Settings.shared
    /// Make This the Default: the pick asked about, then Hermes's own question for an expensive one.
    @State private var makingDefault: ModelChoice?
    @State private var hermesAsks: (choice: ModelChoice, question: String)?
    @State private var savingDefault = false
    @State private var choices: [ModelChoice] = []
    @State private var error: String?
    @State private var loading = true
    /// Provider sections folded shut. Seeded once per open: cloud sections start collapsed
    /// unless they hold the current selection; Local stays open.
    @State private var collapsed: Set<String> = []
    @State private var collapsedSeeded = false

    private var isFastLane: Bool { settings.transport == .chatCompletions }

    /// The conversation whose own switches the menu shows: one that exists on the server, on the
    /// Dashboard connection, which is where a session can be told how to run.
    private var controlledSession: String? {
        #if DEBUG
        if DevHooks.demoChatControls { return DemoChatControls.session }
        #endif
        return settings.transport.hasLedger ? conversation.serverSessionID : nil
    }

    private var byProvider: [(provider: String, name: String, models: [ModelChoice])] {
        Self.grouped(choices)
    }

    /// One "Local" section leads: every custom endpoint serves the same llama-swap catalog, so
    /// their groups fold together, deduped by model id and keyed to the current endpoint's slug.
    /// Cloud providers follow alphabetically.
    static func grouped(_ choices: [ModelChoice]) -> [(provider: String, name: String, models: [ModelChoice])] {
        let grouped = Dictionary(grouping: choices, by: \.provider)
        var out: [(provider: String, name: String, models: [ModelChoice])] = []
        let customKeys = grouped.keys.filter { $0.hasPrefix("custom") }.sorted()
        if !customKeys.isEmpty {
            let slug = customKeys.first { grouped[$0]?.contains(where: \.isCurrent) ?? false } ?? customKeys[0]
            var seen: Set<String> = []
            var models: [ModelChoice] = []
            for key in [slug] + customKeys.filter({ $0 != slug }) {
                for var choice in grouped[key] ?? [] where seen.insert(choice.model).inserted {
                    choice.provider = slug
                    models.append(choice)
                }
            }
            out.append((slug, String(localized: "Local", comment: "Models served by your own machines"), models.sorted { $0.name < $1.name }))
        }
        for key in grouped.keys.filter({ !$0.hasPrefix("custom") }).sorted() {
            guard let models = grouped[key], let first = models.first else { continue }
            out.append((key, first.providerName, models.sorted { $0.name < $1.name }))
        }
        return out
    }

    var body: some View {
        List {
            Section {
                // A menu, not segments: seven levels don't share a phone-width row without
                // truncating "Default" and "Medium" to "…".
                Picker("Reasoning effort", selection: $settings.reasoningEffort) {
                    ForEach(Settings.reasoningEfforts, id: \.value) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Reasoning effort")
            } footer: {
                if isFastLane {
                    Text("How much the model thinks before answering. None asks the model not to think; any other level asks it to, and is passed on as its effort. Models that don't grade effort treat every level the same, and a server that fixes thinking on or off has the last word. Default leaves it to the server.")
                } else {
                    Text("How much the model thinks before answering. None asks the model not to think; some models and servers decide that themselves. X-High and Max are for frontier models such as Claude and GPT; others treat them as High or may refuse them. Applies to this conversation and to new ones. Default leaves it to the gateway, and leaves the open conversation at the level it has.")
                }
            }
            .onChange(of: settings.reasoningEffort) { _, effort in applyEffortToOpenConversation(effort) }

            if !fromSettings, let stored = controlledSession {
                ChatControlsSection(stored: stored, source: ChatControlsSection.defaultSource,
                                    offersAutoApprove: conversation.connection != .hermesSessions)
            }

            if fromSettings, !isFastLane {
                Section {
                    Label {
                        Text("Each conversation has its own model: pick one from the conversation's menu. Without one, a conversation runs on the model your server is set to, and a bot's chat on the bot's own, which Edit Bot changes.",
                             comment: "Settings › Model: where models are picked now that each conversation has its own")
                    } icon: { Image(systemName: "bubble.left.and.text.bubble.right") }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Model")
                }
            } else {
                modelSections
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !fromSettings || isFastLane { await load() } }
        .refreshable { await load() }
        .confirmationDialog(makeDefaultQuestion, isPresented: Binding(get: { makingDefault != nil }, set: { if !$0 { makingDefault = nil } }),
                            titleVisibility: .visible, presenting: makingDefault) { choice in
            Button(String(localized: "Make It the Default", comment: "Model picker: confirms making a model a bot's or the server's default")) { makeDefault(choice, confirmed: false) }
        } message: { _ in
            Text(makeDefaultDetail)
        }
        .confirmationDialog(hermesAsks?.question ?? "", isPresented: Binding(get: { hermesAsks != nil }, set: { if !$0 { hermesAsks = nil } }),
                            titleVisibility: .visible, presenting: hermesAsks) { asked in
            Button(String(localized: "Use It", comment: "Model picker: says yes to Hermes's question about an expensive model")) { makeDefault(asked.choice, confirmed: true) }
        }
    }

    @ViewBuilder
    private var modelSections: some View {
            Section {
                Button { select(nil) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isFastLane ? Settings.defaultFastLaneModel : defaultTitle)
                            defaultSubtitle.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if currentIsDefault { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("Model")
            } footer: {
                if !isFastLane { modelFooter }
            }

            // This conversation's pick as its bot's model, or the server's, from now on.
            if let candidate = defaultCandidate {
                Section {
                    Button { makingDefault = candidate } label: {
                        HStack {
                            Label(String(localized: "Make \(candidate.name) \(ownerName)'s Default", comment: "Model picker: makes the picked model a bot's (or the server's) default, e.g. Make GLM 5 Sol's Default"),
                                  systemImage: "pin")
                            if savingDefault { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(savingDefault)
                } footer: {
                    Text("\(ownerName)'s other conversations without a pick of their own move to it too, and so do new ones.",
                         comment: "Model picker: under Make … the Default; the bot's name, or “your server”")
                }
            }

            if let error {
                Section { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary).font(.footnote) }
            } else if loading {
                Section { ProgressView("Loading models…") }
            }

            ForEach(byProvider, id: \.provider) { group in
                Section {
                    if !collapsed.contains(group.provider) {
                        modelRows(group.models)
                    }
                } header: {
                    Button {
                        withAnimation(.snappy) {
                            if collapsed.contains(group.provider) { collapsed.remove(group.provider) }
                            else { collapsed.insert(group.provider) }
                        }
                    } label: {
                        HStack {
                            Text(group.name)
                            Spacer()
                            if collapsed.contains(group.provider) {
                                Text("\(group.models.count)").foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(collapsed.contains(group.provider) ? -90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
    }

    @ViewBuilder
    private func modelRows(_ models: [ModelChoice]) -> some View {
        ForEach(models) { choice in
                        Button { select(choice) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.name)
                                    if choice.name != choice.model {
                                        Text(choice.model).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                // The checkmark is what the conversation runs on; a server's
                                // `isCurrent` is only its default (config.yaml), named as that so
                                // the two are never taken for one another (GitHub issue 44).
                                if isSelected(choice) { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                                else if choice.isCurrent {
                                    (isFastLane ? Text("current", comment: "The model the server uses now")
                                                : Text("server default", comment: "Model picker: the model the Hermes server is set to use when none is picked (its config.yaml)"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
        }
    }

    /// The model the server lists as its own default: the one it is set to in config.yaml. Both
    /// Hermes connections mark it so, as the model list is asked for without a session.
    private var serverDefault: ModelChoice? { choices.first(where: \.isCurrent) }

    /// Who a conversation without a pick takes its model from: its bot, or the server.
    private var ownerName: String {
        conversation.bot?.name ?? String(localized: "your server", comment: "Model picker: whose model a normal conversation runs on without a pick, as in “your server's model”")
    }

    /// The row that clears the conversation's pick.
    private var defaultTitle: String {
        if let bot = conversation.bot {
            return String(localized: "\(bot.name)'s Model", comment: "Model picker: the row for a bot chat's default, the bot's own model, e.g. Sol's Model")
        }
        return String(localized: "Server Default", comment: "Model picker: the row for the model the Hermes server is set to use")
    }

    /// Under the default row: the model that means, once the server has said.
    private var defaultSubtitle: Text {
        if isFastLane { return Text("llama-swap's configured default") }
        guard let model = serverDefault?.model else {
            return conversation.bot != nil
                ? Text("The model the bot is set to use", comment: "Model picker: under a bot's default, before the server says which model that is")
                : Text("The model your server is set to use", comment: "Model picker: under Gateway default, before the server says which model that is")
        }
        return conversation.bot != nil
            ? Text("\(model), set for the bot", comment: "Model picker: under a bot's default, the bot's model, e.g. zai-glm-5-3-flash")
            : Text("\(model), set on your server", comment: "Model picker: under Gateway default, the model the Hermes server is set to use, e.g. zai-glm-5-3-flash")
    }

    /// What a pick here changes.
    private var modelFooter: Text {
        guard let model = serverDefault?.model else {
            return Text("A pick here changes this conversation only.", comment: "Model picker footer, before the server says which model is the default")
        }
        return Text("A pick here changes this conversation only. Without one, it runs on \(ownerName)'s model, \(model).",
                    comment: "Model picker footer: whose model a conversation without a pick runs on (a bot's name or “your server”), and the model")
    }

    /// The pick the checkmark shows: the open conversation's own.
    private var pick: ConversationModels.Pick? { conversation.ownModel }

    /// The conversation's own pick, when it is a model the server lists and not already the
    /// default, on the Dashboard, where a bot's model (the main agent's too) can be changed.
    private var defaultCandidate: ModelChoice? {
        guard !isFastLane, conversation.connection == .hermesServe, owner != nil, let pick,
              let choice = choices.first(where: { $0.model == pick.model && (pick.provider == nil || $0.provider == pick.provider) }),
              !(serverDefault?.model == choice.model && serverDefault?.provider == choice.provider) else { return nil }
        return choice
    }

    /// The bot whose model a conversation without a pick runs on: its own, or the main agent.
    private var owner: HermesBot? {
        let bots = BotDirectory.shared.bots(for: settings.connectionKey)
        if let profile = conversation.routeProfile { return bots.first { $0.name == profile } }
        return bots.first(where: \.isDefault)
    }

    private var makeDefaultQuestion: String {
        String(localized: "Make \(makingDefault?.name ?? "") \(ownerName)'s default?", comment: "Model picker: asks before changing a bot's or the server's model")
    }

    private var makeDefaultDetail: String {
        conversation.bot != nil
            ? String(localized: "This changes the bot's model on your Hermes, as Edit Bot does.", comment: "Model picker: under the question before changing a bot's model")
            : String(localized: "This changes your Hermes's main model, as Edit Bot does for your main agent: its scheduled jobs use it too.", comment: "Model picker: under the question before changing the main agent's model")
    }

    /// Writes the pick to the bot (or the main agent) on the server, then lets this conversation
    /// follow it rather than hold a pick of its own.
    private func makeDefault(_ choice: ModelChoice, confirmed: Bool) {
        guard let owner else { return }
        savingDefault = true
        Task {
            defer { savingDefault = false }
            do {
                switch try await HermesServeClient.shared.changeBot(owner, BotChange(model: choice, modelConfirmed: confirmed)) {
                case let .confirmModel(question):
                    hermesAsks = (choice, question)
                    return
                case .done:
                    conversation.pickOwnModel(nil)
                    _ = try? await BotDirectory.shared.refresh()
                    await load()
                }
            } catch {
                self.error = String(localized: "Couldn't change the default: \(error.localizedDescription)", comment: "Model picker: Make … the Default failed")
            }
        }
    }

    private var currentIsDefault: Bool {
        isFastLane ? settings.fastLaneModel == Settings.defaultFastLaneModel : pick == nil
    }

    private func isSelected(_ choice: ModelChoice) -> Bool {
        if isFastLane { return settings.fastLaneModel == choice.model }
        guard let pick else { return false }
        return pick.model == choice.model && (pick.provider == nil || pick.provider == choice.provider)
    }

    private func select(_ choice: ModelChoice?) {
        if isFastLane {
            settings.fastLaneModel = choice?.model ?? Settings.defaultFastLaneModel
            return
        }
        conversation.pickOwnModel(choice.map { .init(model: $0.model, provider: $0.provider.nilIfEmpty) })
        applyToOpenConversation(choice)
    }

    /// Both hermes backends pin a conversation's model once it has one, so a picker change must
    /// also re-pin the open conversation: sessions via the model-lock route, serve via
    /// `config.set`. "Gateway default" re-pins to the option the backend marks current — a
    /// pin can't be cleared, only moved.
    private func applyToOpenConversation(_ choice: ModelChoice?) {
        guard let target = choice ?? choices.first(where: \.isCurrent) else { return }
        Task {
            do {
                try await conversation.pinOpenSessionModel(target.model, provider: target.provider)
            } catch {
                self.error = String(localized: "Couldn't switch this conversation: \(error.localizedDescription)")
            }
        }
    }

    /// A serve session keeps its own reasoning level once set, so a picker change re-pins the
    /// open conversation too (`config.set key=reasoning`, session-scoped). The Hermes API sends
    /// the level with every turn and needs nothing here. "Default" is skipped: the host has no
    /// "back to whatever config.yaml says" for a live session, only levels, so the open
    /// conversation stays where it is and new ones pick up the gateway default.
    private func applyEffortToOpenConversation(_ effort: String) {
        guard !effort.isEmpty, conversation.connection == .hermesServe, let sid = conversation.serverSessionID else { return }
        Task {
            do {
                try await HermesServeClient.shared.withLiveSession(stored: sid) { runtime in
                    try await HermesServeClient.shared.setSessionReasoning(runtimeSession: runtime, effort: effort)
                }
            } catch {
                self.error = String(localized: "Couldn't change this conversation's reasoning effort: \(error.localizedDescription)")
            }
        }
    }

    /// The active backend's models: llama-swap's on the fast lane, the gateway's otherwise.
    static func loadChoices(conversation: Conversation, settings: Settings) async throws -> [ModelChoice] {
        if settings.transport == .chatCompletions {
            return try await fastLaneModels(base: settings.activeBaseURL)
        }
        // A Dashboard bot's chat lists its profile's, so the default the list marks is the bot's
        // own model, the one its chat runs on without a pick (GitHub issue 58).
        if conversation.connection == .hermesServe, let profile = conversation.routeProfile, profile != "default" {
            return try await HermesServeClient.shared.modelOptions(forProfile: profile)
        }
        guard let backend = SessionBackend.available(conversation).first else {
            throw TransportError.unreachable(SessionBackend.notConfiguredMessage)
        }
        return try await backend.modelOptions()
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            choices = try await Self.loadChoices(conversation: conversation, settings: settings)
            error = nil
            if !collapsedSeeded {
                collapsedSeeded = true
                collapsed = Set(byProvider.filter { group in
                    !group.provider.hasPrefix("custom") && !group.models.contains(where: isSelected)
                }.map(\.provider))
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// llama-swap lists every model it can load, with the ones already loaded flagged.
    static func fastLaneModels(base: URL?) async throws -> [ModelChoice] {
        guard let base else { throw TransportError.badURL }
        var request = URLRequest(url: base.appending(path: "v1/models"))
        request.timeoutInterval = 6
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        // Named after the server's host, not anyone's machine name.
        let providerName = base.host().map { "llama-swap · \($0)" } ?? "llama-swap"
        return (json["data"]?.array ?? []).compactMap { entry in
            guard let id = entry["id"]?.string else { return nil }
            let loaded = entry["status"]?["value"]?.string == "loaded"
            return ModelChoice(provider: "llama-swap", providerName: providerName, model: id,
                               name: loaded ? String(localized: "\(id)  ·  loaded", comment: "A model already loaded on the server") : id, isCurrent: loaded)
        }
    }
}

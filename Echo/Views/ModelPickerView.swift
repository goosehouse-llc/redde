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
    /// The search box: the server's models first, then, where the server has OpenRouter, the
    /// rest of OpenRouter's (its public list, read when a search first needs it).
    @State private var query = ""
    @State private var catalog: [OpenRouterCatalog.Model] = []
    @State private var catalogError: String?
    @State private var catalogLoading = false

    private var isFastLane: Bool { settings.transport == .chatCompletions }

    /// The conversation whose own switches the menu shows: one that exists on the server, on the
    /// Dashboard connection, which is where a session can be told how to run.
    private var controlledSession: String? {
        #if DEBUG
        if DevHooks.demoChatControls { return DemoChatControls.session }
        #endif
        return settings.transport.isHermes ? conversation.serverSessionID : nil
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
        // (a custom endpoint out on the internet, Venice, is a provider like any: its own section)
        func isLocal(_ key: String) -> Bool {
            key.hasPrefix("custom") && !(grouped[key]?.contains { $0.onThisNetwork == false } ?? false)
        }
        let customKeys = grouped.keys.filter(isLocal).sorted()
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
        for key in grouped.keys.filter({ !isLocal($0) }).sorted() {
            guard let models = grouped[key], let first = models.first else { continue }
            out.append((key, first.providerName, models.sorted { $0.name < $1.name }))
        }
        return out
    }

    /// Whether the models are listed here (and the search box with them), rather than a pointer
    /// to each conversation's own menu.
    private var listsModels: Bool { !fromSettings || isFastLane }

    var body: some View {
        searchableList
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            #if DEBUG
            if let words = DevHooks.value("-echo.modelSearch") { query = words }
            #endif
            if listsModels {
                await load()
                if error == nil { await refreshQuietlyOnce() }
            }
        }
        .task(id: searchWords) { await loadCatalogIfNeeded() }
        .refreshable { await load(refresh: true) }
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
    private var searchableList: some View {
        if listsModels {
            #if os(iOS)
            list.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: Text("Search models", comment: "Model picker: the search box's placeholder"))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            #else
            list.searchable(text: $query, prompt: Text("Search models", comment: "Model picker: the search box's placeholder"))
                .autocorrectionDisabled()
            #endif
        } else {
            list
        }
    }

    private var list: some View {
        List {
            // Pinned first, for switching in a tap (asked 2026-11-07).
            if searchWords.isEmpty, listsModels, !settings.pinnedModelsHere.isEmpty { pinnedSection }
            // (searching, the box's results come straight under it)
            // An ACP agent's effort and switches are its own; Redde only picks the model there.
            if searchWords.isEmpty, settings.transport != .acp { effortAndControls }

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
            } else if !searchWords.isEmpty {
                searchSections
            } else {
                modelSections
            }
        }
    }

    private var pinnedSection: some View {
        Section {
            modelRows(settings.pinnedModelsHere, showingProvider: true)
        } header: {
            Text("Pinned", comment: "Model picker: the models the person pinned, at the top")
        }
    }

    /// A row's long press: Pin, and making it the bot's (or the server's) model (asked 2026-11-07).
    @ViewBuilder
    private func rowMenu(_ choice: ModelChoice) -> some View {
        pinButton(choice)
        if canMakeDefault(choice) {
            Button(String(localized: "Make \(choice.name) \(ownerName)'s Default", comment: "Model picker: makes the picked model a bot's (or the server's) default, e.g. Make GLM 5 Sol's Default"),
                   systemImage: "star") { makingDefault = choice }
        }
    }

    /// On the Dashboard, where a bot's model (the main agent's too) can be changed, and not the
    /// default already.
    private func canMakeDefault(_ choice: ModelChoice) -> Bool {
        !isFastLane && conversation.connection == .hermesServe && owner != nil && !savingDefault
            && !(serverDefault?.model == choice.model && serverDefault?.provider == choice.provider)
    }

    /// Pin or Unpin, for a row's long press and its swipe.
    @ViewBuilder
    private func pinButton(_ choice: ModelChoice) -> some View {
        if settings.isPinned(choice) {
            Button(String(localized: "Unpin", comment: "Model picker: takes a model out of the pinned ones"), systemImage: "pin.slash") {
                withAnimation { settings.togglePin(choice) }
            }
        } else {
            Button(String(localized: "Pin", comment: "Model picker: keeps a model at the top of the list and in the chat header's menu"), systemImage: "pin") {
                withAnimation { settings.togglePin(choice) }
            }
            .tint(.orange)
        }
    }

    /// How hard the model thinks, and the open conversation's own switches.
    @ViewBuilder
    private var effortAndControls: some View {
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
    }

    // MARK: Search

    /// The words typed, lowercased; empty when the box is.
    private var searchWords: [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The server's own models that hold every word typed, in the picker's order.
    private var serverMatches: [ModelChoice] {
        let words = searchWords
        return byProvider.flatMap(\.models).filter { choice in
            let text = (choice.model + " " + choice.name + " " + choice.providerName).lowercased()
            return words.allSatisfy { OpenRouterCatalog.holds($0, in: text) }
        }
    }

    /// The server's OpenRouter, when it has one set up: the slug and name it lists it under.
    private var openRouter: (slug: String, name: String)? {
        choices.first { $0.provider == Self.openRouterSlug }.map { ($0.provider, $0.providerName) }
    }

    static let openRouterSlug = "openrouter"

    /// OpenRouter's models that hold every word typed, less the ones the server lists already.
    private var catalogMatches: [OpenRouterCatalog.Model] {
        guard openRouter != nil else { return [] }
        let listed = Set(choices.map(\.model))
        return OpenRouterCatalog.search(query, in: catalog).filter { !listed.contains($0.id) }
    }

    @ViewBuilder
    private var searchSections: some View {
        let mine = serverMatches
        let more = catalogMatches
        if !mine.isEmpty {
            Section {
                modelRows(mine, showingProvider: true)
            } header: {
                Text("On Your Server", comment: "Model picker search: the server's own models that match")
            }
        }
        if let openRouter {
            Section {
                ForEach(more, id: \.id) { model in
                    Button { selectFromCatalog(model, under: openRouter) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                HStack(spacing: 6) {
                                    Text(model.id).font(.caption.monospaced())
                                    if let context = OpenRouterCatalog.contextLabel(model.context) {
                                        Text(verbatim: "· \(context)").font(.caption)
                                    }
                                }
                                .foregroundStyle(.secondary)
                                if let price = model.price {
                                    Text(price.summary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { rowMenu(Self.choice(model, under: openRouter)) } preview: { ModelDetails(choice: Self.choice(model, under: openRouter)) }
                    .swipeActions(edge: .leading) { pinButton(Self.choice(model, under: openRouter)) }
                }
                if catalogLoading, catalog.isEmpty {
                    ProgressView()
                } else if let catalogError {
                    Label(catalogError, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary).font(.footnote)
                }
            } header: {
                Text("More on \(openRouter.name)", comment: "Model picker search: OpenRouter's models your server doesn't list, e.g. More on OpenRouter")
            } footer: {
                Text("From \(openRouter.name)'s full list: models that can use tools. Your server runs them on its \(openRouter.name) key.",
                     comment: "Model picker search: under OpenRouter's extra models")
            }
        }
        if mine.isEmpty, more.isEmpty, !catalogLoading {
            ContentUnavailableView.search(text: query)
        }
    }

    /// Reads OpenRouter's list the first time a search needs it.
    private func loadCatalogIfNeeded() async {
        guard !searchWords.isEmpty, openRouter != nil, catalog.isEmpty, !catalogLoading else { return }
        catalogLoading = true
        defer { catalogLoading = false }
        do {
            catalog = try await OpenRouterCatalog.shared.models()
            catalogError = nil
        } catch {
            catalogError = String(localized: "Couldn't read OpenRouter's list: \(error.localizedDescription)",
                                  comment: "Model picker search: OpenRouter's model list didn't load")
        }
    }

    /// A model from OpenRouter's list: picked as the server's OpenRouter would list it, and kept
    /// in that section so the checkmark shows once the search is cleared.
    private func selectFromCatalog(_ model: OpenRouterCatalog.Model, under openRouter: (slug: String, name: String)) {
        let choice = Self.choice(model, under: openRouter)
        if !choices.contains(where: { $0.id == choice.id }) { choices.append(choice) }
        collapsed.remove(openRouter.slug)
        select(choice)
        query = ""
    }

    static func choice(_ model: OpenRouterCatalog.Model, under openRouter: (slug: String, name: String)) -> ModelChoice {
        ModelChoice(provider: openRouter.slug, providerName: openRouter.name, model: model.id, name: model.name, isCurrent: false,
                    price: model.price, context: model.context)
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
                VStack(alignment: .leading, spacing: 6) {
                    if !isFastLane { modelFooter }
                    if settings.pinnedModelsHere.isEmpty {
                        Text("Long-press a model to pin it: pinned models come first here.",
                             comment: "Model picker footer: how to pin a model")
                    }
                }
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
    private func modelRows(_ models: [ModelChoice], showingProvider: Bool = false) -> some View {
        ForEach(models) { choice in
                        Button { select(choice) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.name)
                                    if choice.name != choice.model {
                                        Text(choice.model).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    if showingProvider {
                                        Text(choice.provider.hasPrefix("custom") && choice.onThisNetwork != false ? String(localized: "Local", comment: "Models served by your own machines") : choice.providerName)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let price = choice.price {
                                        Text(price.summary).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if !showingProvider, settings.isPinned(choice) {
                                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                                        .accessibilityLabel(String(localized: "Pinned", comment: "Model picker: the models the person pinned, at the top"))
                                }
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
                        .contextMenu { rowMenu(choice) } preview: { ModelDetails(choice: choice) }
                        .swipeActions(edge: .leading) { pinButton(choice) }
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

    /// Switches the open conversation to a model, as a pick here does: from the chat header's
    /// pinned menu.
    static func use(_ choice: ModelChoice, in conversation: Conversation, settings: Settings) async throws {
        if settings.transport == .chatCompletions {
            settings.fastLaneModel = choice.model
            return
        }
        conversation.pickOwnModel(.init(model: choice.model, provider: choice.provider.nilIfEmpty))
        try await conversation.pinOpenSessionModel(choice.model, provider: choice.provider)
    }

    /// Whether the open conversation runs on a model (the checkmark).
    static func isPicked(_ choice: ModelChoice, in conversation: Conversation, settings: Settings) -> Bool {
        if settings.transport == .chatCompletions { return settings.fastLaneModel == choice.model }
        guard let pick = conversation.ownModel else { return false }
        return pick.model == choice.model && (pick.provider == nil || pick.provider == choice.provider)
    }

    /// The active backend's models: llama-swap's on the fast lane, the gateway's otherwise.
    static func loadChoices(conversation: Conversation, settings: Settings, refresh: Bool = false) async throws -> [ModelChoice] {
        #if DEBUG
        if DevHooks.demoModels {
            let local = ["qwen36-splash", "qwen36-35b-q4"].map {
                ModelChoice(provider: "custom:local", providerName: "Local", model: $0, name: $0, isCurrent: $0 == "qwen36-splash")
            }
            let openRouter = [("anthropic/claude-sonnet-4.6", "Claude Sonnet 4.6", 3.0, 15.0), ("google/gemini-3-flash", "Gemini 3 Flash", 0.3, 2.5),
                              ("qwen/qwen3.8-flash", "Qwen3.8 Flash", 0.15, 0.6), ("qwen/qwen3.8-max-0902", "Qwen3.8 Max", 1.2, 6.0)].map {
                ModelChoice(provider: openRouterSlug, providerName: "OpenRouter", model: $0.0, name: $0.1, isCurrent: false,
                            price: ModelPrice(input: $0.2, output: $0.3, cacheRead: $0.2 / 10), context: 262_144)
            }
            let venice = ModelChoice(provider: "custom:venice", providerName: "venice", model: "qwen-3-8-flash", name: "qwen-3-8-flash", isCurrent: false,
                                     price: ModelPrice(input: 0.14, output: 0.49, cacheRead: 0.014), context: 1_000_000, onThisNetwork: false)
            return local + openRouter + [venice]
        }
        #endif
        if settings.transport == .chatCompletions {
            return try await fastLaneModels(base: settings.activeBaseURL)
        }
        // A Dashboard bot's chat lists its profile's, so the default the list marks is the bot's
        // own model, the one its chat runs on without a pick (GitHub issue 58).
        if conversation.connection == .hermesServe, let profile = conversation.routeProfile, profile != "default" {
            return try await HermesServeClient.shared.modelOptions(forProfile: profile, refresh: refresh)
        }
        guard let backend = SessionBackend.available(conversation).first else {
            throw TransportError.unreachable(SessionBackend.notConfiguredMessage)
        }
        return try await backend.modelOptions(refresh: refresh)
    }

    /// `refresh` (pulled down): Hermes reads every provider's list again; otherwise a custom
    /// endpoint not in use shows the list it saved (Venice's lacked a new model, 2026-11-07).
    private func load(refresh: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            choices = Self.keepingPick(pick, in: try await Self.loadChoices(conversation: conversation, settings: settings, refresh: refresh))
            error = nil
            await fillVenicePrices()
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

    private func fillVenicePrices() async {
        guard choices.contains(where: { $0.price == nil && VenicePrices.isVenice($0) }) else { return }
        let venice = await VenicePrices.shared.all()
        choices = choices.map { choice in
            guard choice.price == nil, VenicePrices.isVenice(choice), let known = venice[choice.model] else { return choice }
            var priced = choice
            priced.price = known.price
            priced.context = priced.context ?? known.context
            return priced
        }
    }

    /// Which lists were read again this run (connection and profile): the first open of each asks
    /// Hermes to read every provider again, out of sight. Hermes sends a custom endpoint that
    /// isn't in use (Venice in Ops) with no models until something refreshes it, and a pull-down
    /// in a half-height sheet moves the sheet instead (2026-11-07).
    private static var refreshedThisRun: Set<String> = []

    private func refreshQuietlyOnce() async {
        guard !isFastLane else { return }
        let key = settings.connectionKey + "|" + (conversation.routeProfile ?? "")
        guard Self.refreshedThisRun.insert(key).inserted else { return }
        guard let fresh = try? await Self.loadChoices(conversation: conversation, settings: settings, refresh: true) else {
            Self.refreshedThisRun.remove(key)
            return
        }
        let known = Set(choices.map(\.id))
        guard fresh.contains(where: { !known.contains($0.id) }) else { return }
        let priced = choices.filter { $0.price != nil }
        withAnimation {
            choices = Self.keepingPick(pick, in: fresh).map { choice in
                guard choice.price == nil, let had = priced.first(where: { $0.id == choice.id }) else { return choice }
                var kept = choice
                kept.price = had.price
                kept.context = kept.context ?? had.context
                return kept
            }
        }
        await fillVenicePrices()
    }

    /// A pick from OpenRouter's full list isn't on the server's own: it is added to its provider's
    /// section, so the checkmark has a row to sit on.
    static func keepingPick(_ pick: ConversationModels.Pick?, in choices: [ModelChoice]) -> [ModelChoice] {
        guard let pick, let provider = pick.provider, provider == openRouterSlug,
              !choices.contains(where: { $0.model == pick.model && $0.provider == provider }),
              let group = choices.first(where: { $0.provider == provider }) else { return choices }
        return choices + [ModelChoice(provider: provider, providerName: group.providerName, model: pick.model, name: pick.model, isCurrent: false)]
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

/// A model held up by a long press: what it is and what it costs (asked 2026-11-07).
private struct ModelDetails: View {
    let choice: ModelChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.name).font(.headline)
                Text(choice.model).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(choice.provider.hasPrefix("custom") && choice.onThisNetwork != false
                     ? String(localized: "Local", comment: "Models served by your own machines") : choice.providerName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if let price = choice.price {
                    row(String(localized: "Input", comment: "Model details: price of what the model reads"), ModelPrice.dollars(price.input))
                    row(String(localized: "Output", comment: "Model details: price of what the model writes"), ModelPrice.dollars(price.output))
                    if let cache = price.cacheRead {
                        row(String(localized: "Cached input", comment: "Model details: price of input read again from the provider's cache"), ModelPrice.dollars(cache))
                    }
                } else {
                    GridRow {
                        Text("No price from this provider", comment: "Model details: the provider doesn't say what the model costs")
                            .gridCellColumns(2).foregroundStyle(.secondary)
                    }
                }
                if let context = OpenRouterCatalog.contextLabel(choice.context) {
                    row(String(localized: "Context", comment: "Model details: how many tokens the model reads"),
                        String(localized: "\(context) tokens", comment: "Model details: context size, e.g. 1M tokens"))
                }
            }
            .font(.subheadline)
            if choice.price.map({ !$0.isFree }) ?? false {
                Text("Per million tokens, in US dollars.", comment: "Model details: the unit of the prices")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 320, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

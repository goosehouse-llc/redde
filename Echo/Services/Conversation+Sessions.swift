// Conversation's sessions from the server: loading and adopting them, bots' chats, and answering requests.
import Foundation

extension Conversation {
    /// Resume a session from the Hermes ledger: pull its transcript and continue it here.
    /// Loads a session from the Hermes API server's ledger.
    func loadLedgerSession(_ summary: HermesSessionsAPI.SessionSummary, bot: BotRef? = nil, elsewhere: ProfileRoute? = nil) async throws {
        let api = bot != nil ? ledgerAPI(for: bot) : ledgerAPI(profile: elsewhere?.viaAPI == true ? elsewhere?.profile : nil)
        guard let api else { throw TransportError.noAPIKey }
        let stored = try await api.messages(sessionID: summary.id)
        adopt(serverSession: summary, messages: await Self.readied(stored: stored), bot: bot, elsewhere: elsewhere)
        // A run the app let go of before it ended (another conversation opened, the app closed):
        // taken up again. Over by now, its reply is in the transcript.
        let run = store === ConversationStore.shared ? ChatActivity.shared.run(of: summary.id, settings: settings) : nil
        // Still going by its status, or (the host not saying) by a question left unanswered. A run
        // waiting on an approval has its tool call in the transcript already: the transcript ends
        // on the agent, yet the run waits on the person.
        let going: Bool
        if let run {
            let status = try? await api.runStatus(run)
            going = status.map { ["queued", "running", "waiting_for_approval", "stopping"].contains($0) } ?? endsUnanswered
        } else {
            going = false
        }
        if let run, going, !isStreaming {
            rejoin(run: run, stored: summary.id, api: api)
        } else {
            if run != nil { ChatActivity.shared.turnEnded(sessionID: summary.id, settings: settings) }
            watchForLedgerReply()
        }
    }

    /// Takes up a Hermes API run the app let go of (`HermesRuns`) as the turn on screen: what it
    /// waits on a person for is put to them again, and on Hermes 0.22 the reply plays from its
    /// start; on 0.21.x it comes whole when the run ends. Stop stops the run; leaving lets it go on.
    private func rejoin(run: String, stored: String, api: HermesSessionsAPI) {
        let runs = HermesRuns(baseURL: api.baseURL, apiKey: api.apiKey, headers: api.headers)
        let events = AsyncThrowingStream<TurnEvent, Error> { continuation in
            let task = Task {
                do {
                    try await runs.follow(run) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        let question = messages.last { $0.role == .user && !$0.isSteer }?.text ?? ""
        follow(RejoinedTurn(question: question, events: events, stop: { runs.stop(run) },
                            transcript: { Self.mapStored(try await api.messages(sessionID: stored)) }),
               stored: stored)
        currentRunID = run   // to steer it, and to note it again if it is left
    }

    /// How long after its question a Hermes API conversation without a reply is taken to have
    /// one still coming, and is looked at for it.
    static let replyStillComing: TimeInterval = 10 * 60
    /// How often it is looked at meanwhile.
    static let replyLookEvery: Duration = .seconds(4)

    /// A Hermes API conversation that ends on a question asked lately, with nothing after it: the
    /// agent may still be at work on it (the app left it for another conversation, or was
    /// closed). That API can't be listened to again, so the transcript is fetched every few
    /// seconds while the conversation stays open, until the reply is in it.
    func watchForLedgerReply() {
        ledgerWatch?.cancel()
        guard connection == .hermesSessions, endsUnanswered, let stored = serverSessionID,
              let asked = messages.last?.createdAt, Date.now.timeIntervalSince(asked) < Self.replyStillComing else { return }
        let identity = identity
        statusLine = String(localized: "Your agent is still working on this…")
        ledgerWatch = Task { [weak self] in
            let until = asked.addingTimeInterval(Self.replyStillComing)
            while Date.now < until {
                try? await Task.sleep(for: Self.replyLookEvery)
                guard let self, !Task.isCancelled, self.identity == identity, !self.isStreaming else { return }
                // The end of the transcript first; the whole of it only once the reply is there.
                guard let api = self.ledgerAPI(), let end = try? await api.newestMessages(sessionID: stored, limit: 2),
                      let newest = Self.mapStored(end).last, newest.role == .assistant, !newest.text.isEmpty,
                      let rows = try? await api.messages(sessionID: stored) else { continue }
                guard !Task.isCancelled, self.identity == identity, !self.isStreaming else { return }
                let fetched = Self.mapStored(rows)
                guard let last = fetched.last, last.role == .assistant, !last.text.isEmpty else { continue }
                self.messages = fetched
                self.clearStatus()
                self.resolveReopenedMedia()
                self.persist()
                return
            }
            if let self, self.identity == identity, !self.isStreaming { self.clearStatus() }
        }
    }

    // MARK: - Helpers

    func makeTransport() -> (any HermesTransport)? {
        if let transportOverride { return transportOverride }
        #if DEBUG
        if DemoDay.on { return DemoDayTransport() }   // the day's video: canned answers
        #endif
        guard let url = settings.activeBaseURL else { return nil }
        let key = settings.gatewayAPIKey
        switch connection {
        case .hermesSessions:
            // The app's API, or an API bot's at /p/<profile>/ with its own key.
            guard let api = ledgerAPI() else { return HermesSessionsTransport(baseURL: url, apiKey: key, headers: settings.apiHeaders) }
            return HermesSessionsTransport(baseURL: api.baseURL, apiKey: api.apiKey, headers: api.headers)
        case .hermesServe: return HermesServeTransport(client: dashboard)
        case .chatCompletions: return ChatCompletionsTransport(baseURL: url, apiKey: Keychain.read(.fastLaneAPIKey))
        case .acp: return settings.acpEndpoint(agent: acpAgent).map(AcpTransport.init(endpoint:))
        }
    }

    /// Answer a pending tool approval. On hermes serve the runtime session routes it; on the
    /// sessions ledger the routing token is the run id (POST /v1/runs/{id}/approval).
    func respond(approval choice: String) {
        guard let pendingInterrupt, case let .approval(request) = pendingInterrupt.interrupt else { return }
        clearInterrupt()
        if !isIncognito {
            ApprovalHistory.shared.record(request, choice: choice, agent: bot?.name ?? settings.headerTitle, chat: title)
        }
        #if DEBUG
        if DemoDay.on {   // the day's video: the agent carries on, canned (`DemoDay.approved`)
            Task {
                try? await Task.sleep(for: .seconds(0.9))
                messages.append(Message(role: .assistant, text: DemoDay.approved(choice)))
            }
            return
        }
        #endif
        if connection == .acp {
            // Answered on the agent's link; the bridge tells the other devices.
            AcpClient.current(settings)?.answer(request: request.id, choice: choice)
        } else if connection == .hermesSessions {
            let api = ledgerAPI()
            run {
                guard let api else { throw TransportError.noAPIKey }
                try await api.respondApproval(runID: pendingInterrupt.runtimeSession, requestID: request.id, choice: choice)
            }
        } else {
            run { [dashboard] in try await dashboard.respondApproval(runtimeSession: pendingInterrupt.runtimeSession, requestID: request.id, choice: choice) }
        }
    }

    /// Answer a clarifying question. Batched requests take one answer per question id.
    func respond(clarify answers: [String: String]) {
        guard let pendingInterrupt, case let .clarify(request) = pendingInterrupt.interrupt else { return }
        clearInterrupt()
        // A form or choice of the agent's, answered on its link; the bridge tells the other devices.
        let (shown, next) = connection == .acp ? (AcpClient.current(settings)?.answer(form: request.id, answers: answers) ?? (answers, nil)) : (answers, nil)
        // The question and its answer in the chat, before the reply that asked (GitHub issue 57).
        let rows = AnsweredQuestions.rows(for: request, answers: shown)
        if !rows.isEmpty {
            let at = messages.lastIndex(where: { $0.role == .assistant }) ?? messages.endIndex
            messages.insert(contentsOf: rows, at: at)
            persist()
        }
        if connection == .acp {
            // Words typed in place of the options: the agent was told no, and hears them next.
            if let next { send(next) }
            return
        }
        run { [dashboard] in
            if request.isBatch {
                for (qid, answer) in answers {
                    try await dashboard.respondClarify(runtimeSession: pendingInterrupt.runtimeSession, requestID: request.id, questionID: qid, answer: answer)
                }
            } else {
                try await dashboard.respondClarify(runtimeSession: pendingInterrupt.runtimeSession, requestID: request.id, questionID: nil, answer: answers[""] ?? answers.values.first ?? "")
            }
        }
    }

    func respond(sudoPassword password: String) {
        guard let pendingInterrupt, case let .sudo(id) = pendingInterrupt.interrupt else { return }
        clearInterrupt()
        run { [dashboard] in try await dashboard.respondSudo(runtimeSession: pendingInterrupt.runtimeSession, requestID: id, password: password) }
    }

    func respond(secret value: String) {
        guard let pendingInterrupt, case let .secret(request) = pendingInterrupt.interrupt else { return }
        clearInterrupt()
        run { [dashboard] in try await dashboard.respondSecret(runtimeSession: pendingInterrupt.runtimeSession, requestID: request.id, value: value) }
    }

    /// The stream moved on while an interrupt card was up: someone else answered it (another
    /// client, or the server's approval timeout denied it). Drop the stale card.
    func interruptResolvedElsewhere() {
        guard pendingInterrupt != nil else { return }
        pendingInterrupt = nil
    }

    private func clearInterrupt() {
        pendingInterrupt = nil
        clearStatus()
    }

    /// `@Observable` notifies on every write, equal or not; per-token `nil` over `nil` would
    /// re-evaluate the transcript body and defeat the delta coalescer below.
    func clearStatus() {
        if statusLine != nil { statusLine = nil }
    }

    func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { lastError = error.localizedDescription }
        }
    }

    /// An ACP agent's session: its history as the agent replays it (`session/load`), then the turn
    /// under way in it joined, through the bridge. While a turn runs the bridge won't replay the
    /// history (the two would mix): the copy kept here shows, and the turn is joined.
    func loadAcpSession(_ summary: HermesSessionsAPI.SessionSummary) async throws {
        // Every agent in one list: the chat opens on its agent, as the row, this chat or the copy
        // kept here knows it. Not known (a tapped notification for a chat never opened here), it
        // is looked for with each agent in turn.
        let known = summary.acpAgent ?? (summary.id == serverSessionID ? acpAgent : nil)
            ?? store.summaries.first { $0.serverSessionID == summary.id }?.acpAgent
        AcpAgents.use(known, settings)
        guard let client = AcpClient.current(settings) else { throw TransportError.noAPIKey }
        var messages: [Message]
        do {
            do {
                messages = AcpHistory.messages(try await client.load(summary.id))
            } catch let error as AcpError where !error.isBusy && known == nil && settings.acpAllAgents {
                messages = AcpHistory.messages(try await AcpAgents.find(summary.id, failing: error, settings))
            }
        } catch let error as AcpError where error.isBusy {
            messages = []
            if let kept = store.summaries.first(where: { $0.serverSessionID == summary.id }) {
                if let cached = store.cachedRecord(id: kept.id) { messages = cached.restoredMessages }
                else if let loaded = await store.loadRecord(id: kept.id) { messages = loaded.restoredMessages }
            }
            // The question of the turn under way is the bridge's; the turn joined brings its reply.
            if messages.last?.role == .assistant, let last = messages.indices.last, messages[last].text.isEmpty { messages.removeLast() }
        }
        TodoList.resolve(&messages)
        adopt(serverSession: summary, messages: messages)
        await rejoinIfWaiting()
    }

    /// Resume a stored `hermes serve` session: history via `session.resume`. A bot's chat names
    /// its bot; one this iPhone has kept (opened from a notification, say) is known from its copy.
    func loadServeSession(_ summary: HermesSessionsAPI.SessionSummary, bot: BotRef? = nil, elsewhere: ProfileRoute? = nil,
                          isNew: Bool = false) async throws {
        let kept = store.summaries.first { $0.serverSessionID == summary.id }
        // `session.resume` omits a page turn's hidden user row. Keep the local display sidecar
        // available when the fetched transcript replaces this copy, including after a relaunch.
        let keptMessages: [Message]?
        if let kept {
            if let cached = store.cachedRecord(id: kept.id) {
                keptMessages = cached.restoredMessages
            } else {
                keptMessages = await store.loadRecord(id: kept.id)?.restoredMessages
            }
        } else {
            keptMessages = nil
        }
        let bot = bot ?? kept?.bot
        let elsewhere = bot == nil ? (elsewhere ?? kept?.elsewhere) : nil
        if let profile = bot?.profile ?? elsewhere?.profile { dashboard.noteProfile(profile, forStored: summary.id) }
        // A chat made just now has nothing to fetch, and resuming it would start a second agent on it.
        var messages: [Message] = []
        var workerRun = summary.source == "kanban"
        if !isNew, !workerRun {
            do {
                messages = await Self.readied(serveRows: try await dashboard.history(stored: summary.id))
            } catch where HermesServeClient.refusesWorkerRun(error) {
                workerRun = true
            }
        }
        // A Kanban worker's run: its transcript from the Dashboard's messages page, as the desktop
        // shows it, without resuming it (Hermes refuses that, RPC 4132).
        if workerRun, !isNew { messages = await Self.readied(stored: try await dashboard.transcript(stored: summary.id)) }
        // Serve resume leaves hidden page prompts out. The Dashboard's existing messages route
        // retains them, so use its newest page only as boundary metadata; the resume transcript's
        // rows and content remain authoritative.
        var restoreLocalTurnStarts = !workerRun && keptMessages?.contains(where: { $0.beginsAssistantTurn }) == true
        if restoreLocalTurnStarts, let stored = try? await dashboard.transcript(stored: summary.id) {
            messages = Self.restoringServerTurnStarts(from: await Self.readied(stored: stored), in: messages)
            restoreLocalTurnStarts = false
        }
        // The agent's task list: replayed from the transcript's to-do calls (`readied`, off the
        // main actor), then set against what the host says the list is now.
        TodoList.reconcile(&messages, with: dashboard.hostTodos[summary.id])
        adopt(serverSession: summary, messages: messages, bot: bot, elsewhere: elsewhere,
              localMessages: keptMessages, restoreLocalTurnStarts: restoreLocalTurnStarts)
        isWorkerTranscript = workerRun && !isNew
        // The agent may still be at work in it, or waiting for an answer.
        if !isNew, !isWorkerTranscript { await rejoinIfWaiting() }
    }

    /// Opens a bot's chat (the Dashboard's Bots): its one conversation, found on the server or
    /// made there the first time. `mainName` is what the main profile goes by when it has no name.
    /// A long chat opens in pages (`openLongBotChat`); the main profile's Bot Chat, kept forever,
    /// is the one that gets there.
    func openBot(_ bot: HermesBot, mainName: String) async throws {
        if bot.viaAPI { return try await openAPIBot(bot, mainName: mainName) }
        let (stored, isNew) = try await dashboard.botChat(for: bot)
        let ref = BotRef(profile: bot.name, name: bot.label(mainName: mainName))
        if !isNew, bot.chatIsLong { return try await openLongBotChat(stored: stored, bot: ref) }
        try await loadServeSession(HermesSessionsAPI.SessionSummary(id: stored), bot: ref, isNew: isNew)
    }

    /// A bot's chat too long to resume whole (`HermesBot.chatIsLong`): the runtime is bound with
    /// a resume that leaves the transcript on the host (`omit_messages`, as the Desktop opens a
    /// session), and the transcript's newest page is read from the Dashboard's messages route.
    /// That is the shape a Kanban worker's transcript already opens in (`loadServeSession`'s
    /// `workerRun` branch). Only the newest page shows: older messages stay on the host, and the
    /// agent still has the whole chat.
    private func openLongBotChat(stored: String, bot: BotRef) async throws {
        _ = try await dashboard.resume(stored: stored, withMessages: false)
        let summary = HermesSessionsAPI.SessionSummary(id: stored)
        let page: [HermesSessionsAPI.StoredMessage]
        do {
            page = try await dashboard.transcript(stored: stored)
        } catch {
            // Nothing to read pages from (a bad moment, a host that shouldn't be here): the
            // whole transcript, as any chat opens.
            return try await loadServeSession(summary, bot: bot, isNew: false)
        }
        var messages = await Self.readied(stored: page)
        TodoList.reconcile(&messages, with: dashboard.hostTodos[summary.id])
        adopt(serverSession: summary, messages: messages, bot: bot)
        await rejoinIfWaiting()
    }

    /// An API bot's chat (`APIBot`): its profile's "Bot Chat" at /p/<profile>/, found by its title or
    /// made the first time, as Hermes Desktop and the Dashboard keep a bot's chat, and the same one
    /// they show.
    private func openAPIBot(_ bot: HermesBot, mainName: String) async throws {
        let ref = BotRef(profile: bot.name, name: bot.label(mainName: mainName), viaAPI: true)
        guard let api = ledgerAPI(for: ref) else { throw APIBotProblem.noKey(bot.label(mainName: mainName)) }
        var summary = try await APIBotChat.find(api)
        if summary == nil { summary = try await APIBotChat.make(api) }
        guard let summary else { return }
        try await loadLedgerSession(summary, bot: ref)
    }

    /// This bot's chat, open here while the bot works on what another bot asked (`HandoffStrip`):
    /// read again as each of its steps lands, as opening it would.
    func followHandoff(_ bot: HermesBot) async {
        guard !isStreaming, self.bot?.profile == bot.name, catchingUp == nil else { return }
        try? await openBot(bot, mainName: settings.headerTitle)
    }

    /// "Ask Claude in Redde": the bot that name means on this server, its chat opened. Nil when it
    /// means none (the main profile, a profile with no bot here, the Hermes API, the Bots turned
    /// off): the caller moves the app to that profile instead. The roster as last read, else read now.
    func openBot(asked name: String, mainName: String) async throws -> HermesBot? {
        guard BotDirectory.available(settings) else { return nil }
        var roster = BotDirectory.shared.key == settings.connectionKey ? BotDirectory.shared.roster : nil
        if roster?.asked(name) == nil { roster = try? await BotDirectory.shared.refresh() }
        guard let bot = roster?.asked(name) else { return nil }
        try await openBot(bot, mainName: mainName)
        return bot
    }

    /// A spoken prefix's bot ("Home, …"): its chat opened, or the main agent's for "default"; nothing
    /// to do when it is open already. False when it can't be (not on the Dashboard, Bots off, no
    /// such bot on the server): the message goes where the person already is.
    func goToBot(_ profile: String, mainName: String) async throws -> Bool {
        if let open = bot?.profile, open == profile || BotDirectory.shared.roster?.named(profile)?.name == open { return true }
        guard BotDirectory.available(settings) else { return false }
        var roster = BotDirectory.shared.key == settings.connectionKey ? BotDirectory.shared.roster : nil
        func find(_ roster: BotRoster?) -> HermesBot? {
            profile == "default" ? roster?.bots.first(where: \.isDefault) : roster?.asked(profile)
        }
        if find(roster) == nil { roster = try? await BotDirectory.shared.refresh() }
        guard let bot = find(roster) else { return false }
        try await openBot(bot, mainName: mainName)
        return true
    }

    /// The open bot's chat goes by what `roster` calls its bot now: renamed in Redde or in Hermes
    /// Desktop, the header, the composer and its replies say the new name; its profile renamed on
    /// the server (the chat goes with it), what is sent goes to the new one.
    func followBotName(in roster: BotRoster, mainName: String) {
        guard var ref = bot, let current = roster.named(ref.profile) else { return }
        let name = current.label(mainName: mainName)
        guard name != ref.name || current.name != ref.profile else { return }
        if title == ref.name { title = name }
        ref.name = name
        if current.name != ref.profile, let serverSessionID {
            dashboard.noteProfile(current.name, forStored: serverSessionID)
        }
        ref.profile = current.name
        bot = ref
        persist()
    }

    /// Starts this bot's chat over (`HermesServeClient.startFresh`) and opens the new one, empty.
    func startBotChatFresh(mainName: String) async throws {
        guard let ref = bot else { return }
        // A reply still coming (or one just finishing) is stopped: Start Fresh was asked for, and
        // returning here did nothing at all, so it took a second tap (2026-10-28).
        if isStreaming { cancel() }
        let old = serverSessionID
        let server = settings.activeServerID.uuidString
        if ref.viaAPI == true {
            // Over the API: the chat archived (kept, with its messages), and a new one made.
            guard let api = ledgerAPI(for: ref) else { throw APIBotProblem.noKey(ref.name) }
            if let old {
                try await APIBotChat.putAside(old, api)
                EarlierBotChats.remember(old, profile: ref.profile, server: server)
            }
            let fresh = try await APIBotChat.make(api)
            return try await loadLedgerSession(fresh, bot: ref)
        }
        let client = dashboard
        guard let current = try await client.bots().bots.first(where: { $0.name == ref.profile }) else {
            throw TransportError.malformed(String(localized: "\(ref.name) isn't on this server any more"))
        }
        // The old chat put aside and the new one made in one go (`HermesServeClient.startFresh`):
        // the new one is opened as it is, and the roster read after, for the list.
        let (aside, new) = try await client.startFresh(current)
        if let aside { EarlierBotChats.remember(aside, profile: ref.profile, server: server) }
        try await loadServeSession(HermesSessionsAPI.SessionSummary(id: new), bot: ref, isNew: true)
        Task { _ = try? await BotDirectory.shared.refresh() }
    }

    /// A bot's earlier chats (`EarlierBotChats`), newest first: on the Dashboard every one the
    /// server has; over the Hermes API the ones put aside from Redde.
    func earlierChats(of bot: HermesBot, mainName: String) async throws -> [HermesSessionsAPI.SessionSummary] {
        let server = settings.activeServerID.uuidString
        let incognito = Incognito.sessions(on: server)
        guard bot.viaAPI else {
            return EarlierBotChats.pick(try await dashboard.archivedSessions(profile: bot.name), incognito: incognito)
        }
        let ref = BotRef(profile: bot.name, name: bot.label(mainName: mainName), viaAPI: true)
        guard let api = ledgerAPI(for: ref) else { throw APIBotProblem.noKey(ref.name) }
        let ids = EarlierBotChats.remembered(profile: bot.name, server: server)
        let found = await withTaskGroup(of: HermesSessionsAPI.SessionSummary?.self) { group in
            for id in ids { group.addTask { try? await api.session(id: id) } }
            var all: [HermesSessionsAPI.SessionSummary] = []
            for await row in group { if let row { all.append(row) } }
            return all
        }
        return EarlierBotChats.pick(found.filter { $0.archived == true }, incognito: incognito)
    }

    /// Makes an earlier chat the bot's chat again, the one it has put aside in its place (an earlier
    /// chat then), and opens it.
    func bringBack(_ earlier: HermesSessionsAPI.SessionSummary, as bot: HermesBot, mainName: String) async throws {
        if isStreaming { cancel() }
        let server = settings.activeServerID.uuidString
        let ref = BotRef(profile: bot.name, name: bot.label(mainName: mainName), viaAPI: bot.viaAPI)
        if bot.viaAPI {
            guard let api = ledgerAPI(for: ref) else { throw APIBotProblem.noKey(ref.name) }
            if let current = try await APIBotChat.find(api), current.id != earlier.id {
                try await APIBotChat.putAside(current.id, api)
                EarlierBotChats.remember(current.id, profile: bot.name, server: server)
            }
            try await api.updateSession(id: earlier.id, title: BotChat.title, archived: false, hidden: true)
            EarlierBotChats.forget(earlier.id, profile: bot.name, server: server)
            return try await loadLedgerSession(earlier, bot: ref)
        }
        let aside = try await dashboard.bringBack(earlier.id, for: bot)
        if let aside { EarlierBotChats.remember(aside, profile: bot.name, server: server) }
        EarlierBotChats.forget(earlier.id, profile: bot.name, server: server)
        // As after Start Fresh: the roster read again until it names the chat brought back.
        for attempt in 0 ..< 5 {
            let roster = try await BotDirectory.shared.refresh()
            guard let fresh = roster.bots.first(where: { $0.name == bot.name }) else {
                throw TransportError.malformed(String(localized: "\(ref.name) isn't on this server any more"))
            }
            try await openBot(fresh, mainName: mainName)
            if serverSessionID != aside { return }
            if attempt < 4 { try await Task.sleep(for: .milliseconds(700)) }
        }
        throw TransportError.malformed(String(localized: "Hermes hasn't put the old chat aside yet. Try again in a moment."))
    }

    /// Opens the conversation a Hermes session id names, from the server the app is on: what a
    /// tapped notification from a paired Hermes asks for. The transcript comes from the server,
    /// since the reply being announced arrived while the app wasn't running.
    /// `profile`: the one it is in when not the main one (a bot's workstream, `Workstreams`).
    /// `viaAPI`: where the session is, when not as the app's connection says: a workstream's chat
    /// is the Hermes API's when the gateway runs it, the Dashboard's otherwise (a bot's chat on the
    /// API connection goes by the Dashboard's login, and so do its workstreams).
    func open(serverSession id: String, profile: String? = nil, title: String? = nil, viaAPI: Bool? = nil) async throws {
        let summary = HermesSessionsAPI.SessionSummary(id: id, title: title)
        guard settings.transport != .chatCompletions else {
            throw TransportError.malformed(String(localized: "that conversation is on a Hermes connection"))
        }
        if settings.transport == .acp {
            try await loadAcpSession(summary)
        } else if viaAPI ?? (settings.transport == .hermesSessions) {
            try await loadLedgerSession(summary, elsewhere: profile.map { ProfileRoute(profile: $0, viaAPI: true) })
        } else {
            try await loadServeSession(summary, elsewhere: profile.map { ProfileRoute(profile: $0, viaAPI: false) })
        }
    }

    /// Switches this conversation to a gateway session: keeps (or mints) the matching local
    /// record, swaps in its transcript, and persists. Shared by both ledger transports.
    private func adopt(serverSession summary: HermesSessionsAPI.SessionSummary, messages new: [Message], bot: BotRef? = nil,
                       elsewhere: ProfileRoute? = nil, localMessages: [Message]? = nil,
                       restoreLocalTurnStarts: Bool = false) {
        cancel(leaving: true)
        persist()
        // A bot's chat keeps its copy here when Hermes has compressed it into a new session.
        let server = settings.activeServerID
        let existing = store.summaries.first { $0.serverSessionID == summary.id }
            ?? bot.flatMap { bot in store.summaries.first { $0.bot?.profile == bot.profile && ($0.serverID ?? server) == server } }
        // Asides the agent hasn't been told of yet are only here: kept, where they came.
        let here = serverSessionID == summary.id ? messages
            : (localMessages ?? existing.flatMap { store.cachedRecord(id: $0.id)?.restoredMessages } ?? [])
        let new = Self.keepingAsides(of: here, in: new, restoringTurnStarts: restoreLocalTurnStarts)
        become(id: existing?.id ?? UUID(), createdAt: existing?.createdAt ?? summary.lastActiveDate ?? .now,
               messages: new, serverSessionID: summary.id,
               name: bot?.name ?? Self.name(fromServerTitle: summary.title, firstQuestion: new.first { $0.role == .user && !$0.isSteer }?.text),
               bot: bot, elsewhere: elsewhere)
        persist()
        resolveReopenedMedia()
        // What a note from Hermes said this session waits on is put right from here: joining
        // its turn says so again if it still does.
        StatusWidgets.settled(summary.id, in: widgetDefaults)
        noteSeen()
    }

    /// Everything here so far has been seen: the chat list's Unread mark, kept on the host for
    /// every app (`ChatActivity`). Opening a conversation, leaving it, a reply finishing on
    /// screen and coming back to Redde with it open all say so. Only for the app's own
    /// conversations, not a test's.
    func noteSeen(onlyOnScreen: Bool = false) {
        guard store === ConversationStore.shared, let stored = serverSessionID else { return }
        ChatActivity.shared.markRead(stored, conversation: self, onlyOnScreen: onlyOnScreen, settings: settings)
    }
}

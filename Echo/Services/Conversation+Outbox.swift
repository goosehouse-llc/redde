// Conversation's outbox, waiting requests, cancelling, and switching or resetting the conversation.
import Foundation

extension Conversation {
    // MARK: - Outbox

    /// True when nothing of the reply arrived: no text, reasoning, tools or subagents.
    func replyIsBlank(_ replyID: UUID) -> Bool {
        flushDeltas()
        guard let reply = messages.first(where: { $0.id == replyID }) else { return true }
        return reply.text.isEmpty && reply.reasoning.isEmpty && reply.tools.isEmpty && reply.subagents.isEmpty
            && pendingInterrupt == nil
    }

    /// Takes the turn's question back out of the transcript and puts it at the front of the outbox.
    func hold(userID: UUID, replyID: UUID, queuedAt: Date) {
        guard let message = messages.first(where: { $0.id == userID }) else { return }
        messages.removeAll { $0.id == userID || $0.id == replyID }
        TurnActivity.shared.fail(String(localized: "Waiting for a connection"))
        // Everything behind it waits for the connection too.
        for i in outbox.indices where outbox[i].state == .queued { outbox[i].state = .waitingForConnection }
        outbox.insert(OutboxItem(message: message, state: .waitingForConnection, queuedAt: queuedAt), at: 0)
        lastSendWasHeld = true
        lastError = nil
        persist()
    }

    /// After Stop or a failed turn, nothing more goes out on its own; each waits for Send.
    func pauseQueue() {
        retryTask?.cancel()
        for i in outbox.indices where outbox[i].state == .queued { outbox[i].state = .paused }
        if !outbox.isEmpty { persist() }
    }

    /// Sends the first held message if it's allowed to go now. Called when a reply finishes, when
    /// the network comes back, when the app returns to the foreground, and on the retry schedule.
    func retryOutbox() {
        guard !isStreaming, let head = outbox.first, head.state != .paused else { return }
        if head.state == .waitingForConnection, head.isStale() {
            // Hours old: the reader should decide whether it still makes sense to send.
            for i in outbox.indices { outbox[i].state = .paused }
            persist()
            return
        }
        retryTask?.cancel()
        outbox.removeFirst()
        startTurn(head.message, heldSince: head.queuedAt)
        turnFromOutbox = true
    }

    func scheduleRetry() {
        guard outbox.first?.state == .waitingForConnection else { return }
        retryTask?.cancel()
        let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
        retryAttempt += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.retryOutbox()
        }
    }

    /// The reader asked to send a held message now. Only the first in line can go; it takes
    /// everything behind it off pause too, so they follow in order.
    func sendQueuedNow(_ id: UUID) {
        guard let head = outbox.first, head.id == id else { return }
        // A reply is under way (GitHub issue 60: Send Now did nothing then): the message joins it
        // as a steer where it can, and otherwise says it goes after it.
        if isStreaming {
            if canSteer(head) {
                outbox.removeFirst()
                persist()
                steer(head.message.text, queued: head)
            } else {
                for i in outbox.indices where outbox[i].state == .paused { outbox[i].state = .queued }
                statusLine = String(localized: "It goes as soon as this reply ends.", comment: "Status under a reply: Send Now on a queued message that can't join the reply")
            }
            return
        }
        userSendCount += 1
        for i in outbox.indices where outbox[i].state == .paused { outbox[i].state = .queued }
        outbox[0].queuedAt = .now   // a confirmed send isn't stale
        if outbox[0].state == .waitingForConnection { outbox[0].state = .queued }
        retryAttempt = 0
        retryOutbox()
    }

    /// Removes a held message without sending it. Returns it so the composer can offer it for editing.
    @discardableResult
    func removeQueued(_ id: UUID) -> Message? {
        guard let i = outbox.firstIndex(where: { $0.id == id }) else { return nil }
        let item = outbox.remove(at: i)
        if outbox.isEmpty { retryTask?.cancel() }
        persist()
        return item.message
    }

    /// Puts what the agent stopped for on the "Needs you" widget, under this conversation.
    func noteWaiting(_ interrupt: Interrupt) {
        let kind: WaitingRequest.Kind
        let text: String
        switch interrupt {
        case let .approval(request): (kind, text) = (.approval, request.command)
        case let .clarify(request): (kind, text) = (.question, request.questions.first?.question ?? "")
        case .sudo: (kind, text) = (.sudo, "")
        case let .secret(request): (kind, text) = (.secret, request.prompt.isEmpty ? String(localized: "Value for \(request.envVar)", comment: "What the agent asks for when it needs a secret: an environment variable's value") : request.prompt)
        }
        // A single question's choices, for buttons on the widget, and what it or the command is,
        // so a tap there answers this one and no other.
        var choices: [String]?
        if case let .clarify(request) = interrupt, request.questions.count == 1, let question = request.questions.first, !question.multiSelect {
            let given = question.choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !given.isEmpty, given.count <= 4 { choices = given }
        }
        let key = NeedsYou.key(session: serverSessionID, conversation: id)
        waitingKey = key
        WidgetWriter.agentsChanged()   // Your Agents: needs you
        StatusWidgets.waiting(WaitingRequest(id: key, kind: kind, title: hasMessages ? title : nil,
                                             text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)),
                                             session: serverSessionID, since: .now, until: .now.addingTimeInterval(NeedsYou.lifetime(kind)),
                                             choices: choices, digest: text.isEmpty ? nil : PushNote.digest(of: text)),
                              in: widgetDefaults)
    }

    func settleWaiting() {
        guard let key = waitingKey else { return }
        waitingKey = nil
        WidgetWriter.agentsChanged()
        if !leavingTurn { StatusWidgets.settled(key, in: widgetDefaults) }
    }

    /// The Context widget's reading: the header ring's, when a turn ends or a conversation is
    /// opened. A conversation with no reading yet leaves the one before on the widget.
    func publishContext() {
        guard let contextUsage else { return }
        StatusWidgets.reading(ContextReading(used: contextUsage.used, window: contextUsage.window,
                                             title: settings.requireBiometrics || !hasMessages ? nil : title, date: .now),
                              in: widgetDefaults)
    }

    static func interruptTitle(_ i: Interrupt) -> String {
        switch i {
        case .approval: String(localized: "Redde needs your approval")
        case .clarify: String(localized: "Redde has a question")
        case .sudo: String(localized: "Redde needs a sudo password")
        case .secret: String(localized: "Redde needs a secret")
        }
    }

    static func interruptBody(_ i: Interrupt) -> String {
        switch i {
        case let .approval(r): r.command
        case let .clarify(r): r.questions.first?.question ?? String(localized: "Open Redde to answer.")
        case .sudo: String(localized: "Open Redde to enter it.")
        case let .secret(r): r.prompt.isEmpty ? String(localized: "Value for \(r.envVar)", comment: "What the agent asks for when it needs a secret: an environment variable's value") : r.prompt
        }
    }

    /// Stops the turn. `leaving`: the conversation is being left, not stopped (another one is
    /// opened, or a new one started). On a Hermes connection the turn then goes on on the host,
    /// whether the app started it or only joined it: the reply is there when the conversation is
    /// opened again, and on the Dashboard a turn still running is joined (GitHub issue 12; the
    /// host finishing a turn nobody listens to was checked on Hermes 0.21.0, 0.21.3 and 0.21.5,
    /// `scripts/hermes-lab/lab.sh switch`). The fast lane has no host to go on, so it stops.
    func cancel(leaving: Bool = false) {
        let wasStreaming = isStreaming
        let joined = joinedStop
        joinedStop = nil
        let lettingGo = leaving && connection.hasLedger
        if lettingGo { departure?.leave() }
        // The chat list shows it working until it ends: on the Hermes API by its run, which is
        // all there is to ask after (the Dashboard lists its own turns).
        if lettingGo, wasStreaming, connection == .hermesSessions, store === ConversationStore.shared,
           let stored = serverSessionID, let run = currentRunID {
            ChatActivity.shared.noteLeft(sessionID: stored, runID: run, profile: apiProfile, settings: settings)
        }
        departure = nil
        if !leaving { joined?() }
        streamTask?.cancel()
        streamTask = nil
        clearFollowUps()
        flushDeltas()
        isStreaming = false
        clearStatus()
        leavingTurn = lettingGo
        pendingInterrupt = nil
        leavingTurn = false
        // Only a real Stop pauses the queue; regenerate/load/reset while idle must keep a
        // scheduled retry alive and a queued message queued.
        if wasStreaming {
            if lettingGo { TurnActivity.shared.leave() } else { TurnActivity.shared.fail(String(localized: "Cancelled", comment: "The Live Activity's last word on a reply that was stopped")) }
            pauseQueue()
        }
    }

    /// Drops `messageID` and everything after it. On hermes serve the gateway's history is
    /// rewound by the same number of user turns (`session.undo`); the API-server ledger has no
    /// such call, so there the server keeps its rows and only this transcript is trimmed.
    func truncate(from messageID: UUID) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        cancel()
        let removedTurns = messages[index...].filter { $0.role == .user && !$0.isSteer }.count
        let dropped = Set(messages[index...].flatMap(\.attachments).map(\.id))
        messages.removeSubrange(index...)
        // Attachment bytes live in files only deleted with the conversation; drop the ones
        // nothing references any more, or every regenerate of an image reply leaks its files.
        let stillUsed = Set(messages.flatMap(\.attachments).map(\.id)).union(outbox.flatMap(\.message.attachments).map(\.id))
        for id in dropped.subtracting(stillUsed) { AttachmentFiles.delete(id: id) }
        lastError = nil
        if connection == .hermesServe, let stored = serverSessionID, removedTurns > 0 {
            do {
                let client = dashboard
                try await client.ensureConnected()
                if client.sessionAuthority {
                    // One rewind there to the first message taken back (issue 81).
                    try await client.rewind(stored: stored, turns: removedTurns)
                } else {
                    let (runtime, _) = try await client.openSession(stored: stored)
                    for _ in 0 ..< removedTurns {
                        _ = try await client.call("session.undo", params: .object(["session_id": .string(runtime)]))
                    }
                }
            } catch {
                lastError = String(localized: "Couldn't rewind the gateway session: \(error.localizedDescription)")
            }
        }
        persist()
    }

    /// Replaces `messageID` (a user turn) and everything after it with a new turn.
    func resend(replacing messageID: UUID, text: String, attachments: [Attachment]) async {
        // The attachments' bytes live in files that truncation may delete; hold them in memory first.
        let carried = attachments.map { att -> Attachment in var a = att; a.data = att.data; return a }
        await truncate(from: messageID)
        send(text, attachments: carried)
    }

    /// Asks the question before `replyID` again, replacing the reply.
    func regenerate(replyID: UUID) async {
        guard let i = messages.firstIndex(where: { $0.id == replyID }),
              let userIndex = messages[..<i].lastIndex(where: { $0.role == .user && !$0.isSteer }) else { return }
        let prompt = messages[userIndex]
        await resend(replacing: prompt.id, text: prompt.text, attachments: prompt.attachments)
    }

    /// Wipes every saved conversation and starts empty. Part of "Erase everything" in Settings.
    func eraseAll() {
        cancel()
        store.deleteAll()
        if store === ConversationStore.shared { Drafts.shared.removeAll() }
        become()
    }

    /// Start a fresh conversation; the current one stays in the list if it has any turns.
    func reset() {
        cancel(leaving: true)
        persist()
        become()
    }

    /// New Incognito Chat: the conversation that was open is left as any is, and a new one begins
    /// that is kept nowhere.
    func startIncognito() {
        reset()
        isIncognito = true
    }

    /// Leaving an incognito chat: its reply, if one is under way, stopped, and its session deleted
    /// (closed first on the Dashboard). One that can't be deleted now stays noted until it can.
    private func endIncognito() {
        guard isIncognito else { return }
        isIncognito = false
        guard let stored = serverSessionID, connection != .chatCompletions else { return }
        let entry = Incognito.Pending(session: stored, server: settings.activeServerID.uuidString, transport: connection)
        Incognito.add(entry)
        let api = ledgerAPI()
        if connection == .hermesSessions, let run = currentRunID, let api {
            HermesRuns(baseURL: api.baseURL, apiKey: api.apiKey, headers: api.headers).stop(run)
        }
        let dashboard = dashboard
        Task { if await Incognito.delete(entry, dashboard: dashboard, api: api) { Incognito.remove(entry) } }
    }

    /// Incognito chats left before they could be deleted (the app closed, the server away): when
    /// Redde comes forward, on the server it is on. Not the one open.
    func deleteLeftIncognitoChats() {
        let server = settings.activeServerID.uuidString
        let open = isIncognito ? serverSessionID : nil
        for entry in Incognito.pending() where entry.server == server && entry.session != open && !Self.deletingIncognito.contains(entry.session) {
            Self.deletingIncognito.insert(entry.session)
            let api = entry.transport == .hermesSessions ? ledgerAPI(for: nil) : nil
            let dashboard = dashboard
            Task {
                if await Incognito.delete(entry, dashboard: dashboard, api: api) { Incognito.remove(entry) }
                Self.deletingIncognito.remove(entry.session)
            }
        }
    }
    private static var deletingIncognito: Set<String> = []

    /// Start a fresh conversation on another profile than the selected one, the app staying where
    /// it is: its session is made on that profile, and every later call names it.
    func startElsewhere(_ route: ProfileRoute) {
        cancel(leaving: true)
        persist()
        become(elsewhere: route)
    }

    /// Start a fresh conversation in a project: it works in the project's folder.
    func startNew(in place: ProjectPlace) {
        reset()
        startsIn = place
    }

    /// Switch to a saved conversation. Streaming, if any, is cancelled.
    func load(_ record: ConversationRecord) {
        cancel(leaving: true)
        persist()
        AcpAgents.use(record.acpAgent, settings)
        become(id: record.id, createdAt: record.createdAt, messages: record.restoredMessages,
               outbox: record.outbox ?? [], serverSessionID: record.serverSessionID, name: record.name, bot: record.bot,
               elsewhere: record.elsewhere, acpAgent: record.acpAgent)
        sessionTransport = record.serverSessionID == nil ? nil : record.transport
        // A held message from an earlier launch goes out if it can.
        retryAttempt = 0
        if outbox.first?.state == .waitingForConnection { scheduleRetry() }
    }

    func delete(id recordID: UUID) {
        // A running turn would otherwise re-persist it; and the agent has no more to do for it.
        if recordID == id { cancel() }
        store.delete(id: recordID)
        if store === ConversationStore.shared { Drafts.shared.forget(recordID.uuidString) }
        if recordID == id { become() }
    }

    /// Swaps the whole transcript state in one place, so no path can forget a field.

    func become(id: UUID = UUID(), createdAt: Date = .now, messages: [Message] = [],
                        outbox: [OutboxItem] = [], serverSessionID: String? = nil, name: String? = nil, bot: BotRef? = nil,
                        elsewhere: ProfileRoute? = nil, acpAgent: String? = nil) {
        endIncognito()   // the one being left, if it was one, goes
        noteSeen()   // the one being left
        answeringCall = nil
        quoting = nil   // a quote is for the chat it was taken in
        sideOf = nil   // (a side chat set up after this, in `ContentView.handleSideChat`)
        unsentModel = nil   // the one being left's, never sent
        identity += 1
        ledgerWatch?.cancel()
        ledgerWatch = nil
        if id != self.id { letGoOfAsides() }
        self.id = id
        self.createdAt = createdAt
        self.name = name
        // A transcript read from disk or from the server names the agent's to-do calls as steps;
        // each gets its task list here, so a reply can show it as a checklist.
        var messages = messages
        TodoList.resolve(&messages)
        ReplyCards.resolve(&messages)
        Self.settleAsides(&messages, except: asideAnswer)
        self.messages = messages
        self.outbox = outbox
        self.serverSessionID = serverSessionID
        self.bot = bot
        self.elsewhere = bot == nil ? elsewhere : nil
        // A chat with no agent of its own yet is with the one the server is on (opened from the
        // list, the list has just moved the server to it).
        self.acpAgent = settings.transport == .acp && settings.acpAllAgents ? acpAgent ?? settings.acpAgent.nilIfEmpty : nil
        // Every call about a bot's chat, or another profile's, names that profile, from the first one.
        if let profile = routeProfile, let serverSessionID { dashboard.noteProfile(profile, forStored: serverSessionID) }
        startsIn = nil
        lastError = nil
        isWorkerTranscript = false
        publishContext()
    }

    func persist() {
        // An incognito chat is kept nowhere on the phone.
        guard !isIncognito else { return }
        let kept = messages.filter { $0.error == nil && !($0.text.isEmpty && $0.attachments.isEmpty && $0.tools.isEmpty && $0.reasoning.isEmpty) }
        guard kept.contains(where: { $0.role == .user }) || !outbox.isEmpty else {
            // Truncated to nothing: the saved copy must not outlive the transcript.
            if store.summaries.contains(where: { $0.id == id }) { store.delete(id: id) }
            return
        }
        let turnStarts = Set(kept.filter(\.beginsAssistantTurn).map(\.id))
        let record = ConversationRecord(
            id: id, title: title, createdAt: createdAt, updatedAt: .now,
            transport: sessionTransport ?? settings.transport, serverSessionID: serverSessionID, messages: kept,
            assistantTurnStarts: turnStarts.isEmpty ? nil : turnStarts,
            outbox: outbox.isEmpty ? nil : outbox,
            serverID: settings.transport == .chatCompletions ? nil : settings.activeServerID,
            name: name, bot: bot, elsewhere: elsewhere, acpAgent: acpAgent)
        // Unchanged content keeps its stamp: the list is ordered by updatedAt and relaunch opens
        // the newest, so merely viewing a conversation must not make it "newest".
        if let existing = store.cachedRecord(id: id),
           existing.messages == kept, existing.outbox == record.outbox,
           existing.serverSessionID == serverSessionID, existing.transport == record.transport,
           existing.serverID == record.serverID, existing.name == name, existing.bot == bot, existing.acpAgent == acpAgent { return }
        store.upsert(record)
    }
}

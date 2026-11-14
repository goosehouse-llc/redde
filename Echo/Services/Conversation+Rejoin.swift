// Conversation's turns already under way: rejoining them, the host's own, and other devices' changes.
import Foundation

extension Conversation {
    // MARK: - A turn already under way

    /// Looks whether the open Dashboard conversation has a turn under way on the host that this
    /// run of the app isn't following: the app was closed while the agent worked, or the turn was
    /// started from somewhere else. If so the reply is followed from here on, and whatever the
    /// agent is waiting on a person for gets its card back. That is how an approval announced by
    /// a notification can be answered after the app was closed.
    func rejoinIfWaiting() async {
        guard connection == .hermesServe || connection == .acp, !isStreaming, let stored = serverSessionID, let transport = makeTransport() else { return }
        let identity = identity
        let was = catchingUp
        catchingUp = .rejoining
        let joined = try? await transport.rejoin(stored: stored)
        catchingUp = was
        guard let joined else { return }
        // Another conversation was opened, or a message sent, while the host answered: let go.
        guard self.identity == identity, !isStreaming, serverSessionID == stored else { return }
        follow(joined, stored: stored)
    }

    /// The transcript ends with a question of the person's own and nothing after it, and nothing
    /// is being sent: the state a conversation is in when the app didn't live to see the reply.
    var endsUnanswered: Bool {
        guard !isStreaming, outbox.isEmpty, let last = messages.last(where: { !$0.isAside }) else { return false }
        return last.role == .user && !last.isSteer
    }

    /// When the app comes forward. A Hermes conversation whose last question has no answer here
    /// was cut off, usually by iOS closing the app while the agent worked. The host has gone on
    /// without it: the conversation is fetched again, with the reply if there is one by now, and
    /// on the Dashboard the turn is joined if it is still under way or waiting for an answer.
    /// It is fetched again, too, when the server has moved on past what is here though nothing
    /// was waiting: a turn the host began itself after a reply that arrived (a background job's
    /// end, a delegation's result, a card waking the agent), while the phone slept. Only when the
    /// session says so, so a long chat isn't read again each time Redde comes forward (GitHub
    /// issue 40). And it asks the session itself, by id, not by hunting the session list for its
    /// row: a bot's chat is hidden and every list leaves those out, so for one of those the list
    /// never answered and nothing was fetched at all (GitHub issue 66).
    ///
    /// `always` (asked 2026-11-11: "Can we just have it auto refresh as soon as the app opens"):
    /// when Redde opens, or comes back from the background, the open chat is read again whatever
    /// the host says, so a reply from another device is there without waiting on the check.
    func catchUp(always: Bool = false) async {
        await initialLoad?.value   // at launch the conversation may still be coming off the disk
        guard connection.hasLedger, !isStreaming, let stored = serverSessionID else { return }
        defer { catchingUp = nil }
        // Each while this chat is still the one open: another opened meanwhile isn't left for it.
        let stillHere: @MainActor () throws -> Void = { [weak self] in
            guard let self, self.serverSessionID == stored, !self.isStreaming else { throw CancellationError() }
        }
        if endsUnanswered || always {
            catchingUp = .loading
            try? await Self.untilReachable { try stillHere(); try await self.reloadOpen(stored) }
            return
        }
        catchingUp = .checking
        guard let backend = SessionBackend.current(self),
              let written = try? await Self.untilReachable({ try stillHere(); return try await backend.newestMessageAt(stored) }),
              Self.serverIsAhead(lastActive: written.timeIntervalSince1970,
                                 newest: messages.last(where: { !$0.isAside })?.createdAt),
              serverSessionID == stored, !isStreaming else { return }
        catchingUp = .loading
        try? await reloadOpen(stored)
    }

    /// Reads the open chat again from the host, in the store it lives in: a bot's chat by its bot,
    /// another profile's by that profile, under the name it has. Read again by its id alone, a
    /// bot's chat on the Hermes API was looked for in the main profile, which hasn't got it, and
    /// stayed as it was (2026-11-11, the iPad not showing the newest message).
    func reloadOpen(_ stored: String) async throws {
        let summary = HermesSessionsAPI.SessionSummary(id: stored, title: name)
        if connection == .acp {
            try await loadAcpSession(summary)
        } else if connection == .hermesSessions {
            try await loadLedgerSession(summary, bot: bot, elsewhere: elsewhere)
        } else {
            try await loadServeSession(summary, bot: bot, elsewhere: elsewhere)
        }
    }

    /// Tries again, a little later each time, while what failed was the connection: just after
    /// the app comes forward the first requests often fail while the network, or a VPN such as
    /// Tailscale, wakes up, and catching up then gave up at once and left the chat as it was until
    /// another was opened and this one again (GitHub issue 66). Anything else ends it at once.
    static func untilReachable<T>(waits: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)],
                                  _ attempt: () async throws -> T) async throws -> T {
        var waits = waits[...]
        while true {
            do {
                return try await attempt()
            } catch let error where HermesRuns.isTransient(error) && !waits.isEmpty && !Task.isCancelled {
                try await Task.sleep(for: waits.removeFirst())
            }
        }
    }

    /// What catching up with the host is doing, for the strip over the chat (GitHub issue 59: the
    /// chat looked as if the agent hadn't worked while the person was away, until it had loaded).
    enum CatchingUp: Equatable, Sendable {
        /// Asking whether the host has moved on since this copy.
        case checking
        /// Reading the conversation again, with what came while the app was away.
        case loading
        /// Looking for a reply still under way, or a question waiting, to follow from here.
        case rejoining
    }

    /// The session was last active after the newest message here, by more than the two clocks
    /// may differ.
    nonisolated static func serverIsAhead(lastActive: Double?, newest: Date?) -> Bool {
        guard let lastActive else { return false }
        return lastActive > (newest?.timeIntervalSince1970 ?? 0) + ChatActivity.clockSlack
    }

    /// Watches the open Dashboard conversation, while no turn is being followed, for one the host
    /// starts in it itself: a kanban card the agent made, finished, wakes it, and it may ask before
    /// a command. Joined as it starts, so its question gets its card at once rather than when the
    /// chat is next opened. Started and stopped as the conversation and its turns change.
    func watchHostTurns() {
        guard connection == .hermesServe, let stored = serverSessionID, !isStreaming else {
            stopWatchingHost()
            return
        }
        guard hostWatch?.stored != stored else { return }
        stopWatchingHost()
        guard let transport = makeTransport() else { return }
        Task { [weak self] in
            let stop = await transport.watchHost(stored: stored) { [weak self] in self?.hostTurnStarted(stored) }
            guard let stop else { return }
            guard let self, self.serverSessionID == stored, !self.isStreaming, self.hostWatch == nil else { stop(); return }
            self.hostWatch = (stored, stop)
        }
    }

    // MARK: Other devices

    /// Whether Redde is in front: the open chat is only kept up with while it is (`EchoApp`).
    static var appIsActive = true {
        didSet { if appIsActive, !oldValue { current?.watchOtherDevices() } }
    }

    /// Keeps the open chat up with what another device, or anything else, adds to it: asked of
    /// the host every few seconds while Redde is in front and the chat is idle, and at once when
    /// the Dashboard says its conversations changed or a reply's notification comes for it. A
    /// reply written on the iPad never reached the iPhone's open chat (11-10): an idle chat hears
    /// a turn's events only while its socket is attached to the session, which a reconnect ends,
    /// and the Hermes API has nothing to hear at all.
    func watchOtherDevices() {
        otherDevicesTask?.cancel()
        otherDevicesTask = nil
        guard store === ConversationStore.shared, Self.current === self, connection.isHermes,
              let stored = serverSessionID, Self.appIsActive else { stopListeningForChanges(); return }
        listenForChanges()
        serverSeen = nil
        otherDevicesTask = Task { [weak self] in
            var lastNews = Date.now
            var first = true
            while !Task.isCancelled {
                if !first {
                    // Often while something is happening, then now and then. The Dashboard says at
                    // once when its conversations change (`listenForChanges`), so there the look
                    // is only in case that was missed; Low Power Mode asks less often again.
                    let recent = Date.now.timeIntervalSince(lastNews) < 120
                    let idle: Duration = self?.connection == .hermesServe ? .seconds(60) : .seconds(20)
                    try? await Task.sleep(for: Pace.shared.wait(busy: recent, .seconds(6), idle: idle))
                }
                first = false
                guard let self, !Task.isCancelled, self.serverSessionID == stored, Self.appIsActive else { return }
                if await self.checkOtherDevices(stored) { lastNews = .now }
            }
        }
    }

    /// Asks the host whether the chat has moved on; reads it again when it has. True when it had.
    @discardableResult
    func checkOtherDevices(_ stored: String? = nil) async -> Bool {
        guard let stored = stored ?? serverSessionID, serverSessionID == stored, !isStreaming, outbox.isEmpty,
              catchingUp == nil, let backend = SessionBackend.current(self),
              let written = try? await backend.newestMessageAt(stored) else { return false }
        guard serverSessionID == stored, !isStreaming else { return false }
        // The first answer is where things stand; only what comes after it is news.
        let seen = serverSeen
        serverSeen = max(written, seen ?? .distantPast)
        guard let seen, written > seen else { return false }
        let here = [messages.last(where: { !$0.isAside })?.createdAt, ownTurnEndedAt].compactMap { $0 }.max()
        guard Self.serverIsAhead(lastActive: written.timeIntervalSince1970, newest: here) else { return false }
        try? await reloadOpen(stored)
        return true
    }

    /// The Dashboard tells every connected app when its conversations change, attached or not.
    private func listenForChanges() {
        guard connection == .hermesServe else { stopListeningForChanges(); return }
        let client = HermesServeClient.shared
        guard changesListener?.client !== client else { return }
        stopListeningForChanges()
        let id = client.addListener { [weak self] event in
            guard event.type == "sessions.changed" else { return }
            MainActor.assumeIsolated { self?.changesHeard() }
        }
        changesListener = (client, id)
    }

    private func stopListeningForChanges() {
        if let changesListener { changesListener.client.removeListener(changesListener.id) }
        changesListener = nil
        changeCheck?.cancel()
        changeCheck = nil
    }

    /// One look a moment after the last of a burst of changes.
    private func changesHeard() {
        guard Self.appIsActive, !isStreaming else { return }
        changeCheck?.cancel()
        changeCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.checkOtherDevices()
        }
    }

    private func stopWatchingHost() {
        hostWatch?.stop()
        hostWatch = nil
    }

    private func hostTurnStarted(_ stored: String) {
        guard !isStreaming, !joiningHostTurn, serverSessionID == stored else { return }
        joiningHostTurn = true
        Task {
            await rejoinIfWaiting()
            joiningHostTurn = false
        }
    }

    func follow(_ joined: RejoinedTurn, stored: String) {
        lastError = nil
        clearFollowUps()
        // A turn asked on another device: its question, which isn't here yet, over the reply.
        let asked = joined.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !asked.isEmpty, let lastAsked = messages.last(where: { $0.role == .user && !$0.isAside }),
           lastAsked.text.trimmingCharacters(in: .whitespacesAndNewlines) != asked,
           messages.last?.role != .user || messages.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) != asked {
            messages.append(Message(role: .user, text: joined.question))
        }
        // A turn under way may have put some of itself in the host's transcript already (a tool
        // call waiting on an approval): the reply goes on from it instead of beside it.
        let replyID: UUID
        if let last = messages.last, last.role == .assistant, last.text.isEmpty, last.error == nil {
            replyID = last.id
        } else {
            var reply = Message(role: .assistant, text: "")
            reply.beginsAssistantTurn = true
            reply.metrics = TurnMetrics(sentAt: .now)
            messages.append(reply)
            replyID = reply.id
        }
        update(replyID) { reply in
            if reply.metrics == nil { reply.metrics = TurnMetrics(sentAt: .now) }
        }
        isStreaming = true
        joinedStop = joined.stop
        TurnActivity.shared.start(question: joined.question, agent: answeringName)
        BackgroundTurn.shared.begin(question: joined.question, agent: answeringName)
        turnSerial += 1
        let myTurn = turnSerial
        streamTask = Task { [weak self] in
            guard let self else { return }
            var completed = false
            do {
                for try await event in joined.events { apply(event, to: replyID) }
                try Task.checkCancellation()
                flushDeltas()
                await settle(replyID, stored: stored, transcript: joined.transcript)
                try Task.checkCancellation()
                await resolveServeMedia(replyID)
                try Task.checkCancellation()
                update(replyID) { $0.metrics?.completedAt = .now }
                let replyText = messages.last { $0.id == replyID }?.text ?? ""
                TurnActivity.shared.finish(reply: replyText)
                Notifier.shared.notify(.replied, title: String(localized: "Redde replied"), body: PlainText.display(replyText),
                                       category: Notifier.repliedCategory, userInfo: [Notifier.conversationKey: self.id.uuidString], session: serverSessionID,
                                       messageEntityID: SiriID.message(self.id, replyID))
                persist()
                noteSeen(onlyOnScreen: true)
                completed = true
            } catch is CancellationError {
                flushDeltas()
                if replyIsBlank(replyID) { messages.removeAll { $0.id == replyID } }
                persist()
            } catch {
                if myTurn != turnSerial {
                    update(replyID) { $0.error = error.localizedDescription }
                } else if replyIsBlank(replyID) {
                    // Nothing of it was seen, and nothing here was asked: no failure to report.
                    messages.removeAll { $0.id == replyID }
                    TurnActivity.shared.leave()
                } else {
                    fail(replyID, error.localizedDescription)
                }
            }
            if connection == .hermesSessions, store === ConversationStore.shared, serverSessionID == stored {
                ChatActivity.shared.turnEnded(sessionID: stored, settings: settings)
            }
            if myTurn == turnSerial {
                clearStatus()
                isStreaming = false
                joinedStop = nil
                currentRunID = nil
                settleWaiting()
                publishContext()
                BackgroundTurn.shared.end(success: completed)
                if completed { retryAttempt = 0; retryOutbox() }
            }
        }
    }

    /// A joined turn has ended: what the host recorded fills in what the events couldn't say,
    /// because it happened before the app joined. The reply's text when the record has more of
    /// it, its tool calls and its reasoning when none were heard. What was heard is never taken
    /// away, and a record that can't be fetched changes nothing.
    private func settle(_ replyID: UUID, stored: String, transcript: @Sendable () async throws -> [Message]) async {
        guard let recorded = try? await transcript(), serverSessionID == stored,
              let last = recorded.last, last.role == .assistant else { return }
        // A turn the host started for something delivered into the chat (another bot's message,
        // a bot's reply, a background task done): that, before the reply, as the host has it.
        if recorded.count >= 2, recorded[recorded.count - 2].delivered != nil, let i = messages.firstIndex(where: { $0.id == replyID }),
           !(i > 0 && messages[i - 1].text == recorded[recorded.count - 2].text) {
            messages.insert(recorded[recorded.count - 2], at: i)
        }
        update(replyID) { reply in
            if last.text.count > reply.text.count { reply.text = last.text }
            if reply.tools.isEmpty { reply.tools = last.tools }
            if reply.reasoning.isEmpty { reply.reasoning = last.reasoning }
        }
    }
}

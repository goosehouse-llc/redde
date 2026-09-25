import Foundation
import WidgetKit
import Observation

/// The single conversation the app holds. Owns message history, the streaming task, the
/// outbox and the gateway session id. UI observes this; transports are stateless.
@Observable
final class Conversation {
    /// The app's one conversation, for App Intents (Siri AI), which can't reach the view tree.
    /// Set at launch; MainActor like everything here.
    static weak var current: Conversation?

    private(set) var id = UUID()
    private(set) var createdAt = Date.now
    private(set) var messages: [Message] = []
    private(set) var isStreaming = false
    private(set) var statusLine: String?
    private(set) var lastError: String?

    /// Hermes ledger session id (sessions transport) or stored session id (hermes serve).
    private(set) var serverSessionID: String?
    /// API-server run id of the turn in flight (sessions transport).
    private var currentRunID: String?

    /// Steering is possible while a Hermes turn is streaming.
    var canSteer: Bool { isStreaming && settings.transport.hasLedger }

    /// Nudge the running turn without cancelling it. Shows in the transcript as a steer note.
    func steer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSteer, !trimmed.isEmpty else { return }
        userSendCount += 1
        var note = Message(role: .user, text: trimmed)
        note.isSteer = true
        // Keep the streaming reply last so the live row stays live.
        let insertAt = messages.lastIndex(where: { $0.role == .assistant }) ?? messages.endIndex
        messages.insert(note, at: insertAt)
        let transport = settings.transport
        let stored = serverSessionID
        let runID = currentRunID
        run { [weak self] in
            let accepted: Bool
            switch transport {
            case .hermesServe:
                guard let stored else { throw TransportError.malformed("no session to steer") }
                accepted = try await HermesServeClient.shared.steer(stored: stored, text: trimmed)
            case .hermesSessions:
                guard let runID, let api = self?.ledgerAPI() else { throw TransportError.malformed("no run to steer") }
                accepted = try await api.steer(runID: runID, text: trimmed)
            case .chatCompletions:
                accepted = false
            }
            self?.statusLine = accepted ? "steer queued" : "steer rejected (turn already finishing)"
        }
    }

    /// Bumped on every reader-initiated send (send, steer, send-now). The transcript can't
    /// infer "you just sent something" from the messages array — a normal send appends the
    /// user message and the empty reply in one transaction, and a steer note lands *before*
    /// the streaming reply — so it watches this instead and jumps to the end.
    private(set) var userSendCount = 0

    /// Messages not sent yet, oldest first: queued behind a streaming reply, or held while the
    /// server can't be reached. Only the first one is ever sent; the rest wait their turn.
    private(set) var outbox: [OutboxItem] = []
    /// The last `send` didn't go out now (queued or held offline). The voice loop reads this to
    /// say so instead of waiting for a reply that isn't coming.
    private(set) var lastSendWasHeld = false
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var connectivityToken: UUID?
    /// Test seam: retries fire on this schedule (seconds) instead of the production one.
    var retryDelays: [Double] = [5, 15, 30, 60]

    /// Whatever the gateway is waiting on you for (hermes serve).
    private(set) var pendingInterrupt: (interrupt: Interrupt, runtimeSession: String)?

    private let settings: Settings
    private let store: ConversationStore
    private var streamTask: Task<Void, Never>?
    /// Increments per send; a turn's tail only touches shared state if it is still the current turn.
    private var turnSerial = 0

    /// Tests inject a scripted transport here; production resolves one from Settings per turn.
    private let transportOverride: (any HermesTransport)?

    init(settings: Settings = .shared, store: ConversationStore = .shared, transportOverride: (any HermesTransport)? = nil) {
        self.settings = settings
        self.store = store
        self.transportOverride = transportOverride
        // Pick up where the last session left off, like Messages does. A record already in memory
        // loads now; one on disk decodes off the main actor so the first frame isn't waiting on it.
        if let latest = store.sorted.first {
            if let cached = store.cachedRecord(id: latest.id) {
                load(cached)
            } else {
                let identity = identity
                initialLoad = Task { [weak self, store] in
                    defer { self?.initialLoad = nil }
                    guard let record = await store.loadRecord(id: latest.id), let self,
                          self.identity == identity,                                       // no reset() or switch meanwhile
                          messages.isEmpty, outbox.isEmpty, !isStreaming else { return }   // nothing typed or sent meanwhile
                    load(record)
                }
            }
        }
        connectivityToken = ConnectivityMonitor.shared.onRestored { [weak self] in self?.retryOutbox() }
    }

    isolated deinit {
        if let connectivityToken { ConnectivityMonitor.shared.remove(connectivityToken) }
        streamTask?.cancel()
        retryTask?.cancel()
        flushTask?.cancel()
    }

    #if DEBUG
    /// Seeding seam for ConversationDemo.swift: replaces the visible conversation wholesale.
    func replaceForDemo(id: UUID = UUID(), createdAt: Date = .now, serverSessionID: String? = nil, messages: [Message]) {
        self.id = id
        self.createdAt = createdAt
        self.serverSessionID = serverSessionID
        self.messages = messages
    }

    /// Seeding seam: demo builders edit messages through this, not the private setter.
    func mutateMessagesForDemo(_ body: (inout [Message]) -> Void) { body(&messages) }

    /// Seeding seam: the demo library writes canned records straight into the store.
    var storeForDemo: ConversationStore { store }
    #endif

    /// Test seam: how many messages the store holds for this conversation.
    var persistedMessageCountForTesting: Int { store.record(id: id)?.messages.count ?? 0 }

    var title: String {
        let first = (messages.first { $0.role == .user && !$0.isSteer } ?? outbox.first?.message).map { $0.text.isEmpty ? "\($0.attachments.count) attachment\($0.attachments.count == 1 ? "" : "s")" : $0.text } ?? "New conversation"
        return String(first.prefix(60))
    }

    // MARK: - Actions

    /// Sends one user turn. The returned stream mirrors the transport events for callers that
    /// want them live (the voice loop); the transcript is updated regardless.
    @discardableResult
    func send(_ text: String, attachments: [Attachment] = []) -> AsyncStream<TurnEvent> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return Self.finishedStream() }
        userSendCount += 1
        var userMessage = Message(role: .user, text: trimmed)
        userMessage.attachments = attachments
        // A reply is still streaming, or earlier messages are still waiting: this one goes behind them.
        if isStreaming || !outbox.isEmpty {
            let waiting = outbox.first?.state == .waitingForConnection
            outbox.append(OutboxItem(message: userMessage, state: waiting ? .waitingForConnection : .queued, queuedAt: .now))
            lastSendWasHeld = true
            persist()
            if !isStreaming { retryOutbox() }
            return Self.finishedStream()
        }
        return startTurn(userMessage)
    }

    private static func finishedStream() -> AsyncStream<TurnEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TurnEvent.self)
        continuation.finish()
        return stream
    }

    /// Runs one turn for a user message that isn't in the transcript yet. `heldSince` is when a
    /// message coming out of the outbox was first queued, so holding it again keeps its age.
    @discardableResult
    private func startTurn(_ outgoing: Message, heldSince: Date? = nil) -> AsyncStream<TurnEvent> {
        let (mirror, mirrorContinuation) = AsyncStream.makeStream(of: TurnEvent.self)
        lastSendWasHeld = false
        lastError = nil
        // Only the fast lane sends history; the ledger transports keep theirs on the server.
        let history = settings.transport == .chatCompletions ? messages.filter { $0.error == nil } : []
        var userMessage = outgoing
        userMessage.createdAt = .now   // a held message is stamped when it actually goes out
        let trimmed = userMessage.text
        let attachments = userMessage.attachments
        let userID = userMessage.id
        messages.append(userMessage)
        var reply = Message(role: .assistant, text: "")
        reply.metrics = TurnMetrics(sentAt: .now)
        messages.append(reply)
        let replyID = reply.id

        var request = TurnRequest(
            userText: trimmed,
            history: history,
            sessionID: settings.transport.hasLedger ? serverSessionID : nil,
            model: settings.transport == .chatCompletions ? settings.fastLaneModel : settings.gatewayModel.nilIfEmpty,
            provider: settings.transport == .chatCompletions ? nil : settings.gatewayProvider.nilIfEmpty,
            reasoningEffort: settings.reasoningEffort.nilIfEmpty,
            instructions: nil,
            attachments: attachments
        )
        guard let transport = makeTransport() else {
            fail(replyID, TransportError.badURL.localizedDescription)
            pauseQueue()
            mirrorContinuation.finish()
            return mirror
        }

        isStreaming = true
        TurnActivity.shared.start(question: trimmed)
        BackgroundTurn.shared.begin()
        turnSerial += 1
        let myTurn = turnSerial
        let transportKind = settings.transport
        let fastLaneBase = transportKind == .chatCompletions ? settings.activeBaseURL : nil
        let fastLaneModel = settings.fastLaneModel
        let fallbackWindow = settings.contextWindow
        streamTask = Task { [weak self] in
            guard let self else { return }
            var outcome = TurnOutcome.failed
            // Resolve the context window in parallel with the request; cached after the first turn.
            let windowTask = Task { () -> Int in
                if let fastLaneBase,
                   let detected = await ContextWindowProbe.window(fastLaneBase: fastLaneBase, model: fastLaneModel,
                                                                  apiKey: Keychain.read(.fastLaneAPIKey)) {
                    return detected
                }
                return fallbackWindow
            }
            do {
                // Ledger transport: the session row must exist before the first turn.
                if transportKind == .hermesSessions, request.sessionID == nil {
                    guard let api = ledgerAPI() else { throw TransportError.missingAPIKey }
                    let created = try await api.createSession(title: Self.sessionTitle(from: trimmed),
                                                              model: request.model, provider: request.provider,
                                                              reasoningEffort: request.reasoningEffort)
                    serverSessionID = created.id
                    request.sessionID = created.id
                }
                for try await event in transport.stream(request) {
                    mirrorContinuation.yield(event)
                    switch event {
                    case let .textDelta(delta):
                        clearStatus()
                        interruptResolvedElsewhere()
                        TurnActivity.shared.replyDelta(delta)
                        markFirstToken(replyID)
                        buffer(text: delta, for: replyID)
                    case let .textFinal(text):
                        // Drop the buffered deltas rather than flushing them: this text replaces
                        // them, and appending first would duplicate the whole reply.
                        clearStatus()
                        markFirstToken(replyID)
                        discardPendingText(for: replyID)
                        // Inline data-URL images become photo attachments, like a received MMS.
                        let (clean, images) = InlineImages.extract(from: text)
                        update(replyID) { $0.text = clean; $0.attachments = images }
                    case let .status(status):
                        statusLine = status
                    case let .prefill(processed, total, cached):
                        // Only worth surfacing when the prompt is big enough to take real time;
                        // a short prompt would just flash "100%". Cleared by the first token.
                        if total - cached >= 512 {
                            statusLine = "Processing prompt… \(min(100, processed * 100 / total))%"
                        }
                    case let .usage(usage):
                        // hermes serve ticks this every few hundred ms; it rides the next flush.
                        // Retarget the buffer first: with pendingUsage set, the flush that
                        // retargeting triggers would write this tick onto the previous reply.
                        buffer(for: replyID)
                        pendingUsage = usage
                    case let .reasoningDelta(delta):
                        clearStatus()
                        // Reasoning tokens count toward the reply, so the decode clock starts here too.
                        markFirstToken(replyID)
                        buffer(reasoning: delta, for: replyID)
                    case let .toolStarted(name, preview):
                        flushDeltas()
                        clearStatus()
                        TurnActivity.shared.tool(name)
                        update(replyID) { $0.tools.append(ToolActivity(name: name, preview: preview, status: .running)) }
                    case let .toolFinished(name, failed):
                        interruptResolvedElsewhere()
                        update(replyID) { message in
                            // Match by name when given, else the most recent running tool.
                            if let i = message.tools.lastIndex(where: { $0.status == .running && (name.isEmpty || $0.name == name) }) {
                                message.tools[i].status = failed ? .failed : .completed
                            }
                        }
                    case let .subagent(u):
                        clearStatus()
                        if case .started = u.phase { TurnActivity.shared.tool("delegating") }
                        update(replyID) { message in
                            var row = message.subagents.first { $0.id == u.id }
                                ?? SubagentActivity(id: u.id, goal: u.goal, taskIndex: u.taskIndex, taskCount: u.taskCount, depth: u.depth)
                            if !u.goal.isEmpty { row.goal = u.goal }
                            if let n = u.toolCount { row.toolCount = n }
                            if let s = u.childSessionID { row.childSessionID = s }
                            if let m = u.model { row.model = m }
                            switch u.phase {
                            case .started: row.status = .running
                            case let .tool(name): row.lastTool = name; row.status = .running
                            case let .progress(text): row.lastTool = text.isEmpty ? row.lastTool : text
                            case .dispatched: if row.status == .running { row.status = .dispatched }
                            case let .completed(ok, summary, duration):
                                row.status = ok ? .completed : .failed
                                row.summary = summary
                                row.durationSeconds = duration
                            }
                            if let i = message.subagents.firstIndex(where: { $0.id == u.id }) { message.subagents[i] = row }
                            else { message.subagents.append(row) }
                        }
                    case let .sessionID(id):
                        serverSessionID = id
                    case let .runID(id):
                        currentRunID = id
                    case let .interrupt(interrupt, runtime):
                        flushDeltas()
                        pendingInterrupt = (interrupt, runtime)
                        statusLine = "waiting for you"
                        if case let .approval(request) = interrupt {
                            Notifier.shared.notifyApproval(request)
                        } else if case let .clarify(request) = interrupt {
                            Notifier.shared.notifyClarify(request)
                        } else {
                            Notifier.shared.notify(.interrupt, title: Self.interruptTitle(interrupt), body: Self.interruptBody(interrupt))
                        }
                    case let .interruptExpired(id):
                        if pendingInterrupt?.interrupt.id == id { pendingInterrupt = nil; statusLine = "request expired" }
                    case .done:
                        break
                    }
                }
                // An AsyncThrowingStream ends quietly on cancellation; don't report that as a reply.
                try Task.checkCancellation()
                flushDeltas()
                // Serve hands MEDIA:<path> tags through verbatim, and the sessions API only
                // inlines small images — both daemons share dchermes' filesystem, so the serve
                // file API can fetch what either transport left as a bare path. Runs before the
                // reply is persisted, notified, and mirrored to the widget.
                if transportKind == .hermesServe
                    || (transportKind == .hermesSessions && HermesServeClient.shared.hasCredentials) {
                    await resolveServeMedia(replyID)
                    try Task.checkCancellation()   // Stop during the fetch must not finish the turn
                }
                let window = await windowTask.value
                try Task.checkCancellation()
                update(replyID) { message in
                    message.metrics?.completedAt = .now
                    message.metrics?.characters = message.text.count
                    message.metrics?.contextWindow = window
                }
                let replyText = messages.last { $0.id == replyID }?.text ?? ""
                TurnActivity.shared.finish(reply: replyText)
                if !replyText.isEmpty, !settings.requireBiometrics {   // a locked app shouldn't print replies on the Home Screen
                    WidgetSnapshot.save(question: trimmed, reply: replyText)
                    WidgetCenter.shared.reloadTimelines(ofKind: "com.goosehouse.echo.lastreply")
                }
                Notifier.shared.notify(.replied, title: "Redde replied", body: PlainText.display(replyText),   // autoclosure: only stripped when a banner will post
                                       messageEntityID: SiriID.message(self.id, replyID))
                persist()
                outcome = .completed
            } catch is CancellationError {
                windowTask.cancel()
                flushDeltas()
                persist()
                outcome = .cancelled
            } catch {
                windowTask.cancel()
                if myTurn != turnSerial {
                    // A superseded turn's tail erroring late: record it on its own reply, but
                    // never through fail(), which resets isStreaming/lastError and would let
                    // the UI start a second turn while the live one still streams.
                    update(replyID) { $0.error = error.localizedDescription }
                } else if NetworkFailure.isConnectivity(error), replyIsBlank(replyID) {
                    // Never reached the server: hold the message instead of reporting a failure.
                    hold(userID: userID, replyID: replyID, queuedAt: heldSince ?? .now)
                    outcome = .held
                } else {
                    fail(replyID, error.localizedDescription)
                }
            }
            // Only the current turn may reset shared state; a cancelled turn's tail must not
            // clobber the turn that replaced it.
            if myTurn == turnSerial {
                clearStatus()
                isStreaming = false
                currentRunID = nil
                BackgroundTurn.shared.end()
                switch outcome {
                case .completed: retryAttempt = 0; retryOutbox()
                case .held: scheduleRetry()
                case .cancelled, .failed: pauseQueue()
                }
            }
            mirrorContinuation.finish()
        }
        return mirror
    }

    private enum TurnOutcome { case completed, cancelled, failed, held }

    // MARK: - Outbox

    /// True when nothing of the reply arrived: no text, reasoning, tools or subagents.
    private func replyIsBlank(_ replyID: UUID) -> Bool {
        flushDeltas()
        guard let reply = messages.first(where: { $0.id == replyID }) else { return true }
        return reply.text.isEmpty && reply.reasoning.isEmpty && reply.tools.isEmpty && reply.subagents.isEmpty
            && pendingInterrupt == nil
    }

    /// Takes the turn's question back out of the transcript and puts it at the front of the outbox.
    private func hold(userID: UUID, replyID: UUID, queuedAt: Date) {
        guard let message = messages.first(where: { $0.id == userID }) else { return }
        messages.removeAll { $0.id == userID || $0.id == replyID }
        TurnActivity.shared.fail("Waiting for a connection")
        // Everything behind it waits for the connection too.
        for i in outbox.indices where outbox[i].state == .queued { outbox[i].state = .waitingForConnection }
        outbox.insert(OutboxItem(message: message, state: .waitingForConnection, queuedAt: queuedAt), at: 0)
        lastSendWasHeld = true
        lastError = nil
        persist()
    }

    /// After Stop or a failed turn, nothing more goes out on its own; each waits for Send.
    private func pauseQueue() {
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
    }

    private func scheduleRetry() {
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
        guard outbox.first?.id == id else { return }
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

    private static func interruptTitle(_ i: Interrupt) -> String {
        switch i {
        case .approval: "Redde needs your approval"
        case .clarify: "Redde has a question"
        case .sudo: "Redde needs a sudo password"
        case .secret: "Redde needs a secret"
        }
    }

    private static func interruptBody(_ i: Interrupt) -> String {
        switch i {
        case let .approval(r): r.command
        case let .clarify(r): r.questions.first?.question ?? "Open Redde to answer."
        case .sudo: "Open Redde to enter it."
        case let .secret(r): r.prompt.isEmpty ? "Value for \(r.envVar)" : r.prompt
        }
    }

    func cancel() {
        let wasStreaming = isStreaming
        streamTask?.cancel()
        streamTask = nil
        flushDeltas()
        isStreaming = false
        clearStatus()
        pendingInterrupt = nil
        // Only a real Stop pauses the queue; regenerate/load/reset while idle must keep a
        // scheduled retry alive and a queued message queued.
        if wasStreaming {
            TurnActivity.shared.fail("Cancelled")
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
        if settings.transport == .hermesServe, let stored = serverSessionID, removedTurns > 0 {
            do {
                let client = HermesServeClient.shared
                try await client.ensureConnected()
                let (runtime, _) = try await client.openSession(stored: stored)
                for _ in 0 ..< removedTurns {
                    _ = try await client.call("session.undo", params: .object(["session_id": .string(runtime)]))
                }
            } catch {
                lastError = "Couldn't rewind the gateway session: \(error.localizedDescription)"
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
        become()
    }

    /// Start a fresh conversation; the current one stays in the list if it has any turns.
    func reset() {
        cancel()
        persist()
        become()
    }

    /// Switch to a saved conversation. Streaming, if any, is cancelled.
    func load(_ record: ConversationRecord) {
        cancel()
        persist()
        become(id: record.id, createdAt: record.createdAt, messages: record.messages,
               outbox: record.outbox ?? [], serverSessionID: record.serverSessionID)
        // A held message from an earlier launch goes out if it can.
        retryAttempt = 0
        if outbox.first?.state == .waitingForConnection { scheduleRetry() }
    }

    func delete(id recordID: UUID) {
        if recordID == id { cancel() }   // a running turn would otherwise re-persist it
        store.delete(id: recordID)
        if recordID == id { become() }
    }

    /// Swaps the whole transcript state in one place, so no path can forget a field.
    /// The transcript still decoding at launch. A sender that arrives before it lands (Siri on a
    /// cold "Ask Redde", CarPlay, a notification reply) awaits it, or its message would open a
    /// new server session instead of continuing the latest one.
    private(set) var initialLoad: Task<Void, Never>?
    /// Bumped whenever the conversation becomes another one; the launch load checks it.
    private var identity = 0

    private func become(id: UUID = UUID(), createdAt: Date = .now, messages: [Message] = [],
                        outbox: [OutboxItem] = [], serverSessionID: String? = nil) {
        identity += 1
        self.id = id
        self.createdAt = createdAt
        self.messages = messages
        self.outbox = outbox
        self.serverSessionID = serverSessionID
        lastError = nil
    }

    private func persist() {
        let kept = messages.filter { $0.error == nil && !($0.text.isEmpty && $0.attachments.isEmpty && $0.tools.isEmpty && $0.reasoning.isEmpty) }
        guard kept.contains(where: { $0.role == .user }) || !outbox.isEmpty else {
            // Truncated to nothing: the saved copy must not outlive the transcript.
            if store.summaries.contains(where: { $0.id == id }) { store.delete(id: id) }
            return
        }
        let record = ConversationRecord(
            id: id, title: title, createdAt: createdAt, updatedAt: .now,
            transport: settings.transport, serverSessionID: serverSessionID, messages: kept,
            outbox: outbox.isEmpty ? nil : outbox)
        // Unchanged content keeps its stamp: the list is ordered by updatedAt and relaunch opens
        // the newest, so merely viewing a conversation must not make it "newest".
        if let existing = store.cachedRecord(id: id),
           existing.messages == kept, existing.outbox == record.outbox,
           existing.serverSessionID == serverSessionID, existing.transport == record.transport { return }
        store.upsert(record)
    }

    /// Ledger client for listing/reading sessions. Nil without a gateway URL and key.
    func ledgerAPI() -> HermesSessionsAPI? {
        guard let url = settings.gatewayBaseURL, let key = settings.gatewayAPIKey, !key.isEmpty else { return nil }
        return HermesSessionsAPI(baseURL: url, apiKey: key)
    }

    private static func sessionTitle(from text: String) -> String {
        // Titles must be unique on the gateway; a timestamp keeps repeats ("hi") from colliding.
        let stamp = Date.now.formatted(date: .abbreviated, time: .shortened)
        return "\(text.prefix(48)) · \(stamp)"
    }

    /// Resume a session from the Hermes ledger: pull its transcript and continue it here.
    /// Loads a session from the Hermes API server's ledger.
    func loadLedgerSession(_ summary: HermesSessionsAPI.SessionSummary) async throws {
        guard let api = ledgerAPI() else { throw TransportError.missingAPIKey }
        let stored = try await api.messages(sessionID: summary.id)
        adopt(serverSession: summary, messages: Self.mapStored(stored))
    }

    // MARK: - Helpers

    private func makeTransport() -> (any HermesTransport)? {
        if let transportOverride { return transportOverride }
        guard let url = settings.activeBaseURL else { return nil }
        let key = settings.gatewayAPIKey
        switch settings.transport {
        case .hermesSessions: return HermesSessionsTransport(baseURL: url, apiKey: key)
        case .hermesServe: return HermesServeTransport()
        case .chatCompletions: return ChatCompletionsTransport(baseURL: url, apiKey: Keychain.read(.fastLaneAPIKey))
        }
    }

    /// Answer a pending tool approval. On hermes serve the runtime session routes it; on the
    /// sessions ledger the routing token is the run id (POST /v1/runs/{id}/approval).
    func respond(approval choice: String) {
        guard let pendingInterrupt, case let .approval(request) = pendingInterrupt.interrupt else { return }
        clearInterrupt()
        if settings.transport == .hermesSessions {
            let api = ledgerAPI()
            run {
                guard let api else { throw TransportError.missingAPIKey }
                try await api.respondApproval(runID: pendingInterrupt.runtimeSession, requestID: request.id, choice: choice)
            }
        } else {
            run { try await HermesServeClient.shared.respondApproval(runtimeSession: pendingInterrupt.runtimeSession, requestID: request.id, choice: choice) }
        }
    }

    /// Answer a clarifying question. Batched requests take one answer per question id.
    func respond(clarify answers: [String: String]) {
        guard let pendingInterrupt, case let .clarify(request) = pendingInterrupt.interrupt else { return }
        clearInterrupt()
        run {
            if request.isBatch {
                for (qid, answer) in answers {
                    try await HermesServeClient.shared.respondClarify(runtimeSession: pendingInterrupt.runtimeSession, requestID: request.id, questionID: qid, answer: answer)
                }
            } else {
                try await HermesServeClient.shared.respondClarify(runtimeSession: pendingInterrupt.runtimeSession, requestID: request.id, questionID: nil, answer: answers[""] ?? answers.values.first ?? "")
            }
        }
    }

    func respond(sudoPassword password: String) {
        guard let pendingInterrupt, case let .sudo(id) = pendingInterrupt.interrupt else { return }
        clearInterrupt()
        run { try await HermesServeClient.shared.respondSudo(runtimeSession: pendingInterrupt.runtimeSession, requestID: id, password: password) }
    }

    func respond(secret value: String) {
        guard let pendingInterrupt, case let .secret(request) = pendingInterrupt.interrupt else { return }
        clearInterrupt()
        run { try await HermesServeClient.shared.respondSecret(runtimeSession: pendingInterrupt.runtimeSession, requestID: request.id, value: value) }
    }

    /// The stream moved on while an interrupt card was up: someone else answered it (another
    /// client, or the server's approval timeout denied it). Drop the stale card.
    private func interruptResolvedElsewhere() {
        guard pendingInterrupt != nil else { return }
        pendingInterrupt = nil
    }

    private func clearInterrupt() {
        pendingInterrupt = nil
        clearStatus()
    }

    /// `@Observable` notifies on every write, equal or not; per-token `nil` over `nil` would
    /// re-evaluate the transcript body and defeat the delta coalescer below.
    private func clearStatus() {
        if statusLine != nil { statusLine = nil }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { lastError = error.localizedDescription }
        }
    }

    /// Resume a stored `hermes serve` session: history via `session.resume`.
    func loadServeSession(_ summary: HermesSessionsAPI.SessionSummary) async throws {
        let rows = try await HermesServeClient.shared.history(stored: summary.id)
        adopt(serverSession: summary, messages: Self.messages(fromServeRows: rows))
    }

    /// Switches this conversation to a gateway session: keeps (or mints) the matching local
    /// record, swaps in its transcript, and persists. Shared by both ledger transports.
    private func adopt(serverSession summary: HermesSessionsAPI.SessionSummary, messages new: [Message]) {
        cancel()
        persist()
        let existing = store.summaries.first { $0.serverSessionID == summary.id }
        become(id: existing?.id ?? UUID(), createdAt: existing?.createdAt ?? summary.lastActiveDate ?? .now,
               messages: new, serverSessionID: summary.id)
        persist()
    }

    private func update(_ id: UUID, _ body: (inout Message) -> Void) {
        // The reply being updated is almost always the last message.
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        body(&messages[index])
    }

    // MARK: - Delta coalescing
    //
    // Models emit a token every few milliseconds; applying each one re-renders the transcript
    // (Markdown parse, highlighting, scroll). Buffer them and apply at ~20 fps instead.

    private var pendingText = ""
    private var pendingReasoning = ""
    private var pendingUsage: TokenUsage?
    private var pendingFor: UUID?
    private var flushTask: Task<Void, Never>?
    private var firstTokenMarked: UUID?

    private func markFirstToken(_ id: UUID) {
        guard firstTokenMarked != id else { return }
        firstTokenMarked = id
        update(id) { if $0.metrics?.firstTokenAt == nil { $0.metrics?.firstTokenAt = .now } }
    }

    private func buffer(text: String = "", reasoning: String = "", for id: UUID) {
        if pendingFor != id { flushDeltas(); pendingFor = id }
        pendingText += text
        pendingReasoning += reasoning
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flushDeltas()
        }
    }

    /// A reply that delivers a file carries a bare server path (`MEDIA:` tag, markdown image,
    /// or "[IMAGE: …]"). Fetch each over the serve dashboard file API and attach it — photos
    /// for images, document chips for the rest. Paths that fail to fetch stay in the text.
    private func resolveServeMedia(_ id: UUID) async {
        guard let text = messages.first(where: { $0.id == id })?.text else { return }
        let candidates = ServeMedia.candidates(in: text)
        guard !candidates.isEmpty else { return }
        var attachments: [Attachment] = []
        var fetched: Set<String> = []
        for c in candidates where !fetched.contains(c.path) {
            guard let dataURL = try? await HermesServeClient.shared.readDataURL(path: c.path),
                  let att = ServeMedia.attachment(dataURL: dataURL, name: c.filename) else { continue }
            fetched.insert(c.path)
            attachments.append(att)
        }
        guard !attachments.isEmpty else { return }
        var cleaned = text
        for c in candidates where fetched.contains(c.path) {
            cleaned = cleaned.replacingOccurrences(of: c.whole, with: "")
        }
        update(id) { $0.text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines); $0.attachments += attachments }
    }

    /// Throws away text deltas buffered for this reply, keeping any pending reasoning. Used when
    /// the backend sends its own final text for the turn.
    private func discardPendingText(for id: UUID) {
        guard pendingFor == id else { flushDeltas(); return }
        pendingText = ""
        if pendingReasoning.isEmpty {
            flushTask?.cancel()
            flushTask = nil
        }
    }

    private func flushDeltas() {
        flushTask?.cancel()
        flushTask = nil
        guard let id = pendingFor, !(pendingText.isEmpty && pendingReasoning.isEmpty && pendingUsage == nil) else { return }
        let text = pendingText, reasoning = pendingReasoning, usage = pendingUsage
        pendingText = ""; pendingReasoning = ""; pendingUsage = nil
        update(id) { message in
            message.text += text
            message.reasoning += reasoning
            if let usage { message.metrics?.usage = usage }
        }
    }

    private func fail(_ id: UUID, _ description: String) {
        flushDeltas()
        lastError = description
        TurnActivity.shared.fail(description)
        Notifier.shared.notify(.failed, title: "Redde couldn't reply", body: description)
        update(id) { message in
            message.error = description
            if message.text.isEmpty { message.text = "⚠️ \(description)" }
        }
        isStreaming = false
    }
}

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
    private(set) var messages: [Message] = [] { didSet { refreshHeader() } }
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
    private(set) var outbox: [OutboxItem] = [] { didSet { refreshHeader() } }
    /// The last `send` didn't go out now (queued or held offline). The voice loop reads this to
    /// say so instead of waiting for a reply that isn't coming.
    private(set) var lastSendWasHeld = false
    /// Follow-up questions for the last reply (`FollowUps`), when the setting is on and the
    /// fast lane answered; cleared by the next send.
    private(set) var followUps: [String] = []
    private var followUpTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var connectivityToken: UUID?
    /// Test seam: retries fire on this schedule (seconds) instead of the production one.
    var retryDelays: [Double] = [5, 15, 30, 60]

    /// Whatever the gateway is waiting on you for (hermes serve).
    private(set) var pendingInterrupt: (interrupt: Interrupt, runtimeSession: String)? {
        // However it went (answered, expired, cancelled), the Live Activity stops asking.
        didSet { if oldValue != nil, pendingInterrupt == nil { TurnActivity.shared.approvalSettled() } }
    }

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
        // Only the active server's: another server's session can't be continued from here.
        // OpenAI-compatible chats belong to no server; untagged Hermes chats from before
        // multi-server belong to the first one.
        let active = settings.activeServerID, first = settings.servers.first?.id
        if let latest = store.sorted.first(where: { $0.transport == .chatCompletions || ($0.serverID ?? first) == active }) {
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
        self.name = nil   // a new conversation: not the name of the one it replaces
        var messages = messages
        TodoList.resolve(&messages)
        self.messages = messages
    }

    /// Seeding seam: demo builders edit messages through this, not the private setter.
    func mutateMessagesForDemo(_ body: (inout [Message]) -> Void) { body(&messages) }
    /// Seeding seam: the played demo turn shows as live, the way a real one does.
    func setStreamingForDemo(_ on: Bool) { isStreaming = on }

    /// Seeding seam: the demo library writes canned records straight into the store.
    var storeForDemo: ConversationStore { store }
    #endif
    /// The composer's context chips look through recent conversations' attachments.
    var storeForContext: ConversationStore { store }
    #if DEBUG
    #endif

    /// Test seam: how many messages the store holds for this conversation.
    var persistedMessageCountForTesting: Int { store.record(id: id)?.messages.count ?? 0 }

    /// What the screen around the transcript shows of `messages`, held as values of their own. A
    /// streaming reply rewrites `messages` many times a second, and a view that reads the array
    /// in its body is re-rendered every time: the header did, which rebuilt the navigation
    /// toolbar, the conversation list and the composer on every update. These two change only
    /// when the first message or the emptiness does, so reading them costs nothing while a
    /// reply streams.
    private(set) var title = "New conversation"
    private(set) var hasMessages = false
    /// How full the model's context is, as of the latest reply that says: the header's ring.
    private(set) var contextUsage: ContextUsage?
    /// The name this conversation was given: by Rename, or on the gateway (a session renamed in
    /// the Dashboard, or titled by Hermes). Without one the title is the first question.
    private(set) var name: String? { didSet { refreshHeader() } }

    private func refreshHeader() {
        let first = (messages.first { $0.role == .user && !$0.isSteer } ?? outbox.first?.message).map { $0.text.isEmpty ? "\($0.attachments.count) attachment\($0.attachments.count == 1 ? "" : "s")" : $0.text } ?? "New conversation"
        let title = name ?? String(first.prefix(60))
        // Assigning an equal value would still notify every observer.
        if title != self.title { self.title = title }
        if hasMessages == messages.isEmpty { hasMessages = !messages.isEmpty }
        // The newest reply that knows; nearly always the last message or the one before it.
        let context = messages.reversed().lazy.compactMap { $0.metrics?.context }.first
        if context != contextUsage { contextUsage = context }
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
        clearFollowUps()
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
            attachments: attachments,
            replyLanguage: settings.replyLanguage.nilIfEmpty
        )
        guard let transport = makeTransport() else {
            fail(replyID, settings.isConfigured ? TransportError.badURL.localizedDescription
                                                : "No connection is set up yet. Go to Settings → Connection → Set up connection….")
            pauseQueue()
            mirrorContinuation.finish()
            return mirror
        }

        isStreaming = true
        TurnActivity.shared.start(question: trimmed)
        BackgroundTurn.shared.begin(question: trimmed)
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
                // A new conversation takes its model and provider at create, from a pick that
                // may be older than the host's current providers; later turns are pinned.
                if transportKind.hasLedger, request.sessionID == nil, let model = request.model?.nilIfEmpty {
                    let provider = Self.liveProvider(for: model, saved: request.provider, in: await listedModels())
                    if provider != request.provider {
                        request.provider = provider
                        if settings.gatewayModel == model { settings.gatewayProvider = provider ?? "" }
                    }
                }
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
                    apply(event, to: replyID)
                }
                // An AsyncThrowingStream ends quietly on cancellation; don't report that as a reply.
                try Task.checkCancellation()
                flushDeltas()
                // Serve hands MEDIA:<path> tags through verbatim, and the sessions API only
                // inlines small images — both daemons share the Hermes host's filesystem, so the serve
                // file API can fetch what either transport left as a bare path. Runs before the
                // reply is persisted, notified, and mirrored to the widget.
                if transportKind == .hermesServe
                    || (transportKind == .hermesSessions && HermesServeClient.shared.hasCredentials) {
                    await resolveServeMedia(replyID)
                    try Task.checkCancellation()   // Stop during the fetch must not finish the turn
                }
                if transportKind == .hermesSessions {
                    await settleTodos(replyID)
                    try Task.checkCancellation()
                }
                let window = await windowTask.value
                try Task.checkCancellation()
                update(replyID) { message in
                    message.metrics?.completedAt = .now
                    message.metrics?.characters = message.text.count
                    message.metrics?.contextWindow = window
                    if message.reasoningStartedAt != nil, message.reasoningEndedAt == nil { message.reasoningEndedAt = .now }
                }
                let replyText = messages.last { $0.id == replyID }?.text ?? ""
                TurnActivity.shared.finish(reply: replyText)
                if !replyText.isEmpty, !settings.requireBiometrics {   // a locked app shouldn't print replies on the Home Screen
                    WidgetSnapshot.save(question: trimmed, reply: replyText)
                    WidgetCenter.shared.reloadTimelines(ofKind: "com.goosehouse.echo.lastreply")
                }
                Notifier.shared.notify(.replied, title: "Redde replied", body: PlainText.display(replyText),   // autoclosure: only stripped when a banner will post
                                       category: Notifier.repliedCategory, userInfo: [Notifier.conversationKey: self.id.uuidString],
                                       messageEntityID: SiriID.message(self.id, replyID))
                persist()
                outcome = .completed
                suggestFollowUps(question: trimmed, replyID: replyID, reply: replyText)
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
                } else if transportKind == .chatCompletions, BackgroundTurn.shared.expired, NetworkFailure.isConnectivity(error) {
                    fail(replyID, Self.backgroundCutoff)
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
                BackgroundTurn.shared.end(success: outcome == .completed)
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

    /// One event of a turn, written into its reply.
    private func apply(_ event: TurnEvent, to replyID: UUID) {
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
        case let .toolStarted(name, preview, args):
            flushDeltas()
            clearStatus()
            TurnActivity.shared.tool(name)
            update(replyID) { $0.tools.append(ToolActivity(name: name, preview: preview, status: .running, startedAt: .now, args: args)) }
        case let .toolFinished(name, failed, output):
            interruptResolvedElsewhere()
            var finished: ToolActivity?
            update(replyID) { message in
                // Match by name when given, else the most recent running tool.
                if let i = message.tools.lastIndex(where: { $0.status == .running && (name.isEmpty || $0.name == name) }) {
                    message.tools[i].status = failed ? .failed : .completed
                    message.tools[i].endedAt = .now
                    if let output { message.tools[i].output = output }
                    finished = message.tools[i]
                }
            }
            // The agent's to-do tool: what a finished call wrote, applied to the list so far, is
            // the list now. (The Dashboard says the list itself right after: `.todos`.)
            if let finished, let list = TodoList.after(step: finished, previous: TodoList.latest(in: messages)) {
                update(replyID) { $0.todos = list }
            }
        case let .todos(list):
            update(replyID) { $0.todos = list }
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
            // Saved as soon as the host has a session for it, not only with the reply: if the app
            // doesn't live to see the reply, it can find its way back to it (`catchUp`).
            if questionSavedFor != replyID {
                questionSavedFor = replyID
                persist()
            }
        case let .runID(id):
            currentRunID = id
        case let .interrupt(interrupt, runtime):
            flushDeltas()
            pendingInterrupt = (interrupt, runtime)
            statusLine = "waiting for you"
            if case let .approval(request) = interrupt {
                Notifier.shared.notifyApproval(request)
                TurnActivity.shared.needsApproval(request)
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

    // MARK: - A turn already under way

    /// How to stop the turn on screen when it is one the app joined and didn't start; nil otherwise.
    private var joinedStop: (@Sendable () -> Void)?
    /// The reply whose question has been saved already (see `.sessionID` in `apply`).
    private var questionSavedFor: UUID?

    /// Looks whether the open Dashboard conversation has a turn under way on the host that this
    /// run of the app isn't following: the app was closed while the agent worked, or the turn was
    /// started from somewhere else. If so the reply is followed from here on, and whatever the
    /// agent is waiting on a person for gets its card back. That is how an approval announced by
    /// a notification can be answered after the app was closed.
    func rejoinIfWaiting() async {
        guard settings.transport == .hermesServe, !isStreaming, let stored = serverSessionID, let transport = makeTransport() else { return }
        let identity = identity
        guard let joined = try? await transport.rejoin(stored: stored) else { return }
        // Another conversation was opened, or a message sent, while the host answered: let go.
        guard self.identity == identity, !isStreaming, serverSessionID == stored else { return }
        follow(joined, stored: stored)
    }

    /// The transcript ends with a question of the person's own and nothing after it, and nothing
    /// is being sent: the state a conversation is in when the app didn't live to see the reply.
    var endsUnanswered: Bool {
        guard !isStreaming, outbox.isEmpty, let last = messages.last else { return false }
        return last.role == .user && !last.isSteer
    }

    /// When the app comes forward. A Hermes conversation whose last question has no answer here
    /// was cut off, usually by iOS closing the app while the agent worked. The host has gone on
    /// without it: the conversation is fetched again, with the reply if there is one by now, and
    /// on the Dashboard the turn is joined if it is still under way or waiting for an answer.
    func catchUp() async {
        await initialLoad?.value   // at launch the conversation may still be coming off the disk
        guard settings.transport.hasLedger, endsUnanswered, let stored = serverSessionID else { return }
        try? await open(serverSession: stored)
    }

    private func follow(_ joined: RejoinedTurn, stored: String) {
        lastError = nil
        clearFollowUps()
        let reply = Message(role: .assistant, text: "")
        messages.append(reply)
        let replyID = reply.id
        isStreaming = true
        joinedStop = joined.stop
        TurnActivity.shared.start(question: joined.question)
        BackgroundTurn.shared.begin(question: joined.question)
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
                let replyText = messages.last { $0.id == replyID }?.text ?? ""
                TurnActivity.shared.finish(reply: replyText)
                Notifier.shared.notify(.replied, title: "Redde replied", body: PlainText.display(replyText),
                                       category: Notifier.repliedCategory, userInfo: [Notifier.conversationKey: self.id.uuidString],
                                       messageEntityID: SiriID.message(self.id, replyID))
                persist()
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
            if myTurn == turnSerial {
                clearStatus()
                isStreaming = false
                joinedStop = nil
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
        update(replyID) { reply in
            if last.text.count > reply.text.count { reply.text = last.text }
            if reply.tools.isEmpty { reply.tools = last.tools }
            if reply.reasoning.isEmpty { reply.reasoning = last.reasoning }
        }
    }

    private enum TurnOutcome { case completed, cancelled, failed, held }

    /// A direct (stateless) connection dropped because iOS suspended the app mid-reply.
    static let backgroundCutoff = "Stopped when Redde went to the background. iOS gives an app about 30 seconds there, so keep Redde open (or the screen awake) for long replies."

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

    /// Stops the turn. `leaving`: the conversation is being left, not stopped; a turn the app only
    /// joined (`rejoinIfWaiting`) then goes on on the host, where someone else may be waiting for
    /// it. One the app started is stopped either way, as it always was.
    func cancel(leaving: Bool = false) {
        let wasStreaming = isStreaming
        let joined = joinedStop
        joinedStop = nil
        if !leaving { joined?() }
        streamTask?.cancel()
        streamTask = nil
        clearFollowUps()
        flushDeltas()
        isStreaming = false
        clearStatus()
        pendingInterrupt = nil
        // Only a real Stop pauses the queue; regenerate/load/reset while idle must keep a
        // scheduled retry alive and a queued message queued.
        if wasStreaming {
            if joined != nil, leaving { TurnActivity.shared.leave() } else { TurnActivity.shared.fail("Cancelled") }
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
        if store === ConversationStore.shared { Drafts.shared.removeAll() }
        become()
    }

    /// Start a fresh conversation; the current one stays in the list if it has any turns.
    func reset() {
        cancel(leaving: true)
        persist()
        become()
    }

    /// Switch to a saved conversation. Streaming, if any, is cancelled.
    func load(_ record: ConversationRecord) {
        cancel(leaving: true)
        persist()
        become(id: record.id, createdAt: record.createdAt, messages: record.messages,
               outbox: record.outbox ?? [], serverSessionID: record.serverSessionID, name: record.name)
        // A held message from an earlier launch goes out if it can.
        retryAttempt = 0
        if outbox.first?.state == .waitingForConnection { scheduleRetry() }
    }

    func delete(id recordID: UUID) {
        if recordID == id { cancel(leaving: true) }   // a running turn would otherwise re-persist it
        store.delete(id: recordID)
        if store === ConversationStore.shared { Drafts.shared.forget(recordID.uuidString) }
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
                        outbox: [OutboxItem] = [], serverSessionID: String? = nil, name: String? = nil) {
        identity += 1
        self.id = id
        self.createdAt = createdAt
        self.name = name
        // A transcript read from disk or from the server names the agent's to-do calls as steps;
        // each gets its task list here, so a reply can show it as a checklist.
        var messages = messages
        TodoList.resolve(&messages)
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
            outbox: outbox.isEmpty ? nil : outbox,
            serverID: settings.transport == .chatCompletions ? nil : settings.activeServerID,
            name: name)
        // Unchanged content keeps its stamp: the list is ordered by updatedAt and relaunch opens
        // the newest, so merely viewing a conversation must not make it "newest".
        if let existing = store.cachedRecord(id: id),
           existing.messages == kept, existing.outbox == record.outbox,
           existing.serverSessionID == serverSessionID, existing.transport == record.transport,
           existing.serverID == record.serverID, existing.name == name { return }
        store.upsert(record)
    }

    /// Ledger client for listing/reading sessions. Nil without a gateway URL and key.
    // MARK: - Model switching

    /// Re-pins the open conversation's model on the backend. Both hermes backends pin a
    /// conversation's model once it has one, so a change must move the pin: the Hermes API via
    /// the model-lock route, the Dashboard via `config.set` (session-scoped). Nothing to do on
    /// the fast lane, where the model goes on every request, or before a session exists.
    func pinOpenSessionModel(_ model: String, provider: String?) async throws {
        guard let sid = serverSessionID else { return }
        switch settings.transport {
        case .hermesSessions:
            guard let api = ledgerAPI() else { return }
            try await api.lockSessionModel(id: sid, model: model, provider: provider)
        case .hermesServe:
            try await HermesServeClient.shared.withLiveSession(stored: sid) { runtime in
                try await HermesServeClient.shared.setSessionModel(runtimeSession: runtime, model: model, provider: provider)
            }
        case .chatCompletions:
            break
        }
    }

    /// Switches to a model the way the picker does: the setting changes, so new conversations
    /// and every later fast-lane turn use it, and the open conversation is re-pinned. Sticky:
    /// it stays until the picker or another switch moves it. Used by spoken prefixes.
    func switchModel(_ model: String, provider: String?) async throws {
        if settings.transport == .chatCompletions {
            settings.fastLaneModel = model
            return
        }
        let provider = Self.liveProvider(for: model, saved: provider, in: await listedModels())
        settings.gatewayModel = model
        settings.gatewayProvider = provider ?? ""
        try await pinOpenSessionModel(model, provider: provider)
    }

    /// The provider to send with `model`, checked against what the backend lists right now. A
    /// saved slug is only a memory of a past list: the host may have renamed or removed that
    /// provider, the pick may come from another profile or server, or there is none (a rule made
    /// on the fast lane). Hermes fails the whole turn on a provider it doesn't know, and a model
    /// sent without one goes to the default endpoint, which may not serve it. So:
    /// - the saved provider stays while it still lists the model — except the bare "custom"
    ///   bucket when it isn't the host's current provider and a named endpoint lists the model
    ///   too: that row is a config leftover with no endpoint behind it ("Unknown provider
    ///   'custom:custom'");
    /// - else a provider that lists the model, a named endpoint first;
    /// - else the saved one if it is still there (hidden models serve by name);
    /// - else the host's current provider.
    /// Nothing changes when the list couldn't be read.
    nonisolated static func liveProvider(for model: String, saved: String?, in choices: [ModelChoice]) -> String? {
        guard !choices.isEmpty else { return saved }
        let saved = saved?.nilIfEmpty
        let serving = choices.filter { $0.model == model }
        let named = serving.first { $0.provider != "custom" }
        if let saved, serving.contains(where: { $0.provider == saved }) {
            let bareLeftover = saved == "custom" && !choices.contains { $0.provider == "custom" && $0.isCurrent }
            return bareLeftover ? named?.provider ?? saved : saved
        }
        if let other = named ?? serving.first { return other.provider }
        if let saved, choices.contains(where: { $0.provider == saved }) { return saved }
        return choices.first(where: \.isCurrent)?.provider
    }

    /// What the backend lists right now, or nothing when it can't say within a few seconds: a
    /// spoken turn waits on this, and a slow list must not hold it up.
    private func listedModels() async -> [ModelChoice] {
        guard let backend = SessionBackend.available(self, settings: settings).first else { return [] }
        return await withTaskGroup(of: [ModelChoice]?.self) { group in
            group.addTask { try? await backend.modelOptions() }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    func ledgerAPI() -> HermesSessionsAPI? {
        guard let url = settings.gatewayBaseURL, let key = settings.gatewayAPIKey, !key.isEmpty else { return nil }
        return HermesSessionsAPI(baseURL: url, apiKey: key, headers: settings.customHeaderFields)
    }

    // MARK: Name

    /// Names the conversation. A gateway session is renamed on the gateway first, so the list,
    /// the Dashboard and the header agree; titles there must be unique, so it can refuse. An
    /// empty name takes a local conversation back to its first question (a gateway session
    /// keeps the title it has).
    func rename(to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sessionID = serverSessionID {
            guard !trimmed.isEmpty else { return }
            guard let backend = SessionBackend.current(self, settings: settings) else {
                throw TransportError.malformed(SessionBackend.notConfiguredMessage)
            }
            try await backend.rename(sessionID, to: trimmed)
        }
        setName(trimmed.isEmpty ? nil : trimmed)
    }

    /// The gateway's list of sessions, just loaded: the open session's title there, when it is a
    /// name, is this conversation's name. That picks up a rename made in the list or the
    /// Dashboard, and the title Hermes gives a session by itself.
    func noteServerTitles(_ sessions: [HermesSessionsAPI.SessionSummary]) {
        guard let sessionID = serverSessionID, let session = sessions.first(where: { $0.id == sessionID }) else { return }
        setName(Self.name(fromServerTitle: session.title, firstQuestion: messages.first { $0.role == .user && !$0.isSteer }?.text))
    }

    private func setName(_ new: String?) {
        guard new != name else { return }
        name = new
        persist()
    }

    /// A gateway title as a conversation's name: nil when there is none, and nil for the title
    /// Redde itself gives a new session (`sessionTitle(from:)`: the start of the first question,
    /// " · ", a timestamp), which says nothing the question doesn't.
    nonisolated static func name(fromServerTitle title: String?, firstQuestion: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        if let firstQuestion, title.hasPrefix(firstQuestion.prefix(48) + " · ") { return nil }
        return title
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
        case .hermesSessions: return HermesSessionsTransport(baseURL: url, apiKey: key, headers: settings.customHeaderFields)
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
        var messages = Self.messages(fromServeRows: rows)
        // The agent's task list: replayed from the transcript's to-do calls, then set against
        // what the host says the list is now.
        TodoList.resolve(&messages)
        TodoList.reconcile(&messages, with: HermesServeClient.shared.hostTodos[summary.id])
        adopt(serverSession: summary, messages: messages)
        // The agent may still be at work in it, or waiting for an answer.
        await rejoinIfWaiting()
    }

    /// Opens the conversation a Hermes session id names, from the server the app is on: what a
    /// tapped notification from a paired Hermes asks for. The transcript comes from the server,
    /// since the reply being announced arrived while the app wasn't running.
    func open(serverSession id: String) async throws {
        let summary = HermesSessionsAPI.SessionSummary(id: id)
        switch settings.transport {
        case .hermesServe: try await loadServeSession(summary)
        case .hermesSessions: try await loadLedgerSession(summary)
        case .chatCompletions: throw TransportError.malformed("that conversation is on a Hermes connection")
        }
    }

    /// Switches this conversation to a gateway session: keeps (or mints) the matching local
    /// record, swaps in its transcript, and persists. Shared by both ledger transports.
    private func adopt(serverSession summary: HermesSessionsAPI.SessionSummary, messages new: [Message]) {
        cancel(leaving: true)
        persist()
        let existing = store.summaries.first { $0.serverSessionID == summary.id }
        become(id: existing?.id ?? UUID(), createdAt: existing?.createdAt ?? summary.lastActiveDate ?? .now,
               messages: new, serverSessionID: summary.id,
               name: Self.name(fromServerTitle: summary.title, firstQuestion: new.first { $0.role == .user && !$0.isSteer }?.text))
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
    // (Markdown parse, highlighting, scroll). Buffer them and apply at ~20 fps instead. Thinking
    // alone goes at 5: it is a few grey lines that scroll by, a model can think for minutes, and
    // every update costs the same as one of reply text.

    private static let textFlushInterval: Duration = .milliseconds(50)
    private static let reasoningFlushInterval: Duration = .milliseconds(200)
    /// The waiting flush was scheduled for thinking only.
    private var flushIsSlow = false

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
        let slow = pendingText.isEmpty
        // Reply text doesn't wait out a flush that was scheduled for thinking.
        if flushIsSlow, !slow { flushTask?.cancel(); flushTask = nil }
        guard flushTask == nil else { return }
        flushIsSlow = slow
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: slow ? Self.reasoningFlushInterval : Self.textFlushInterval)
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flushDeltas()
        }
    }

    /// Over the Hermes API a reply's task list is worked out from what its to-do calls wrote,
    /// since that stream gives no answers. The transcript has them, and the tool's own answer is
    /// the list: Hermes 0.21.3 and 0.21.5 start a later turn there on an empty list, so a merge
    /// leaves fewer items than the calls replayed would. Asked only after a reply that touched
    /// the list.
    private func settleTodos(_ id: UUID) async {
        guard let session = serverSessionID, messages.last(where: { $0.id == id })?.todos != nil,
              let answered = await ledgerAPI()?.answeredTodos(sessionID: session) else { return }
        update(id) { if $0.todos != answered { $0.todos = answered } }
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
            if !reasoning.isEmpty, message.reasoningStartedAt == nil { message.reasoningStartedAt = .now }
            if !text.isEmpty, message.reasoningStartedAt != nil, message.reasoningEndedAt == nil { message.reasoningEndedAt = .now }
            if let usage { message.metrics?.usage = usage }
        }
    }

    // MARK: Tool details

    /// Whether `loadToolDetails` has anything to ask: a server session and the Hermes API.
    var canLoadToolDetails: Bool {
        serverSessionID != nil && settings.gatewayBaseURL != nil && !(settings.gatewayAPIKey ?? "").isEmpty
    }

    /// Fills in what a reply's tools were called with and what they returned, from the gateway's
    /// stored transcript. The Hermes API's stream names a finished tool without its result, and
    /// a reopened session's rows leave results out; the stored messages have them. A Dashboard
    /// conversation can use this too when the Hermes API is set up: both write one ledger.
    func loadToolDetails(for id: UUID) async {
        guard let sessionID = serverSessionID, let base = settings.gatewayBaseURL, let key = settings.gatewayAPIKey, !key.isEmpty,
              let local = messages.first(where: { $0.id == id }), !local.tools.isEmpty,
              let stored = try? await HermesSessionsAPI(baseURL: base, apiKey: key, headers: settings.customHeaderFields).messages(sessionID: sessionID),
              let found = Self.storedTools(for: local, in: Self.mapStored(stored)) else { return }
        update(id) { message in
            for (i, tool) in found.enumerated() where i < message.tools.count {
                if message.tools[i].args == nil { message.tools[i].args = tool.args }
                if message.tools[i].output == nil { message.tools[i].output = tool.output }
            }
        }
        persist()
    }

    /// The tools of the stored reply that is `local`: the same tools in the same order, and the
    /// same text when several fit (else the newest of them).
    nonisolated static func storedTools(for local: Message, in stored: [Message]) -> [ToolActivity]? {
        let names = local.tools.map(\.name)
        let fits = stored.filter { $0.role == .assistant && $0.tools.map(\.name) == names }
        let text = local.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (fits.last { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text } ?? fits.last)?.tools
    }

    // MARK: Follow-ups

    func clearFollowUps() {
        followUpTask?.cancel()
        followUpTask = nil
        followUps = []
    }

    /// Ask the fast-lane model for follow-ups to a finished reply; shown only while that reply
    /// is still the last message.
    private func suggestFollowUps(question: String, replyID: UUID, reply: String) {
        guard settings.suggestFollowUps, !reply.isEmpty, let base = Settings.normalizedBase(settings.fastLaneURL),
              !settings.fastLaneModel.isEmpty else { return }
        let (model, key) = (settings.fastLaneModel, Keychain.read(.fastLaneAPIKey))
        followUpTask = Task { [weak self] in
            let suggestions = await FollowUps.suggest(question: question, reply: reply, baseURL: base, apiKey: key, model: model)
            guard let self, !Task.isCancelled, messages.last?.id == replyID, !isStreaming else { return }
            followUps = suggestions
        }
    }

    private func fail(_ id: UUID, _ description: String) {
        flushDeltas()
        lastError = description
        TurnActivity.shared.fail(description)
        Notifier.shared.notify(.failed, title: "Redde couldn't reply", body: description)
        // A paired Hermes will say so too, minutes later: that note then arrives quietly.
        if let serverSessionID { ToldAlready.failed(session: serverSessionID) }
        update(id) { message in
            message.error = description
            if message.text.isEmpty { message.text = "⚠️ \(description)" }
        }
        isStreaming = false
    }
}

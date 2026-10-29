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
    private(set) var isStreaming = false { didSet { if isStreaming != oldValue { watchHostTurns() } } }
    private(set) var statusLine: String?
    private(set) var lastError: String?
    /// A Kanban worker's run, open to read (GitHub issue 37): Hermes won't resume one, since a
    /// second writer on the card's workspace would go unsupervised, so there is no writing to it.
    private(set) var isWorkerTranscript = false

    /// Hermes ledger session id (sessions transport) or stored session id (hermes serve).
    private(set) var serverSessionID: String? { didSet { if serverSessionID != oldValue { watchHostTurns() } } }
    /// The project a new conversation starts in (a project's New Conversation, on the Dashboard):
    /// its first turn opens the session in the project's folder. Gone when it becomes another.
    private(set) var startsIn: ProjectPlace?
    /// The bot this conversation is with, when it is a bot's chat (the Dashboard's Bots): a
    /// session of the bot's own profile, its one conversation, which Redde never renames.
    private(set) var bot: BotRef?
    /// The profile this conversation lives in when it is another than the selected one and not a
    /// bot's chat: opened from the chat list with All Profiles on. Every call about it names it.
    private(set) var elsewhere: ProfileRoute?
    /// An agent's call just answered in this conversation (`AgentCalls`): its line, told to the
    /// agent with what the person says first after it (`CallNote`), within ten minutes. Gone when
    /// another conversation opens.
    @ObservationIgnored var answeringCall: (line: String, at: Date)?
    /// Who answers in this conversation, as the Lock Screen names it: its bot, else the main agent.
    private var answeringName: String { bot?.name ?? settings.headerTitle }
    /// Words to find once this conversation is on screen: set when a message search opens it,
    /// taken by the transcript, which opens Find on them (`TranscriptView`).
    var findRequest: String?
    /// API-server run id of the turn in flight (sessions transport).
    private(set) var currentRunID: String?

    /// The connection this conversation goes by: the app's, but a bot's chat goes by the Dashboard
    /// on either Hermes connection (on the Hermes API with the Dashboard's login saved,
    /// `BotDirectory.reachable`): a bot is a profile of its own, which the Hermes API serves only
    /// with that profile's own key.
    var connection: Transport {
        guard settings.transport == .hermesSessions else { return settings.transport }
        // One added for the Hermes API alone (`APIBot`) goes by the API, at /p/<profile>/.
        if let bot { return bot.viaAPI == true ? .hermesSessions : .hermesServe }
        // Another profile's: by the way it was listed.
        if let elsewhere { return elsewhere.viaAPI ? .hermesSessions : .hermesServe }
        return settings.transport
    }

    /// The profile this conversation's calls name, when not the selected one: its bot's, or the
    /// other profile it lives in.
    var routeProfile: String? { bot?.profile ?? elsewhere?.profile }

    /// The profile it reaches by the Hermes API at /p/<profile>/, with that profile's own key.
    private var apiProfile: String? {
        bot.map { $0.viaAPI == true ? $0.profile : nil } ?? (elsewhere?.viaAPI == true ? elsewhere?.profile : nil)
    }

    /// Steering is possible while a Hermes turn is streaming.
    var canSteer: Bool { isStreaming && connection.hasLedger }

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
        let transport = connection
        let stored = serverSessionID
        let runID = currentRunID
        let dashboard = dashboard
        run { [weak self] in
            let accepted: Bool
            switch transport {
            case .hermesServe:
                guard let stored else { throw TransportError.malformed("no session to steer") }
                accepted = try await dashboard.steer(stored: stored, text: trimmed)
            case .hermesSessions:
                guard let runID, let api = self?.ledgerAPI() else { throw TransportError.malformed("no run to steer") }
                accepted = try await api.steer(runID: runID, text: trimmed)
            case .chatCompletions:
                accepted = false
            }
            self?.statusLine = accepted ? String(localized: "steer queued", comment: "Status under a reply: a message added to the turn is waiting") : String(localized: "steer rejected (turn already finishing)")
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

    /// Test seam: where the status widgets' data is kept (the App Group).
    var widgetDefaults: UserDefaults? = NeedsYou.shared
    /// Test seam: where weather and time cards are looked up when the plugin's answer didn't fill them.
    var cardLookup = CardLookup.shared

    /// Whatever the gateway is waiting on you for (hermes serve).
    private(set) var pendingInterrupt: (interrupt: Interrupt, runtimeSession: String)? {
        // However it went (answered, expired, cancelled), the Live Activity stops asking, and
        // so does the "Needs you" widget.
        didSet {
            guard oldValue != nil, pendingInterrupt == nil else { return }
            TurnActivity.shared.approvalSettled()
            settleWaiting()
        }
    }
    /// This conversation's entry on the "Needs you" widget, while it has one.
    private var waitingKey: String?
    /// A turn is being left to go on on the host (another conversation was opened): what it
    /// waits on, it still waits on, and the widget keeps saying so.
    private var leavingTurn = false

    private let settings: Settings
    private let store: ConversationStore
    private var streamTask: Task<Void, Never>?
    /// Increments per send; a turn's tail only touches shared state if it is still the current turn.
    private var turnSerial = 0

    /// Tests inject a scripted transport here; production resolves one from Settings per turn.
    private let transportOverride: (any HermesTransport)?
    /// The Dashboard this conversation's Dashboard turns, bots and questions go by: the app's,
    /// unless a test gives one of its own.
    let dashboard: HermesServeClient

    init(settings: Settings = .shared, store: ConversationStore = .shared, transportOverride: (any HermesTransport)? = nil,
         dashboard: HermesServeClient = .shared) {
        self.settings = settings
        self.store = store
        self.transportOverride = transportOverride
        self.dashboard = dashboard
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
    func replaceForDemo(id: UUID = UUID(), createdAt: Date = .now, serverSessionID: String? = nil, messages: [Message], bot: BotRef? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.serverSessionID = serverSessionID
        self.bot = bot
        self.name = nil   // a new conversation: not the name of the one it replaces
        var messages = messages
        TodoList.resolve(&messages)
        ReplyCards.resolve(&messages)
        self.messages = messages
    }

    /// Seeding seam: demo builders edit messages through this, not the private setter.
    func mutateMessagesForDemo(_ body: (inout [Message]) -> Void) { body(&messages) }
    /// Seeding seam: the played demo turn shows as live, the way a real one does.
    func setStreamingForDemo(_ on: Bool) { isStreaming = on }
    /// Seeding seam: a question or an approval waiting, as a turn would leave one.
    func setInterruptForDemo(_ interrupt: Interrupt?) { pendingInterrupt = interrupt.map { ($0, "demo") } }

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
    private(set) var title = String(localized: "New conversation")
    private(set) var hasMessages = false
    /// How full the model's context is, as of the latest reply that says: the header's ring.
    private(set) var contextUsage: ContextUsage?
    /// The name this conversation was given: by Rename, or on the gateway (a session renamed in
    /// the Dashboard, or titled by Hermes). Without one the title is the first question.
    private(set) var name: String? { didSet { refreshHeader() } }

    private func refreshHeader() {
        let first = (messages.first { $0.role == .user && !$0.isSteer } ?? outbox.first?.message).map { $0.text.isEmpty ? String(localized: "\($0.attachments.count) attachments") : $0.text } ?? String(localized: "New conversation")
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
    /// `brief`: asked by voice in a car, for an answer short enough to follow there
    /// (`CarBrevity`). `live`: handed over by GPT-Live (`LiveTurn`). A message that has to wait
    /// its turn goes out later as an ordinary one.
    @discardableResult
    func send(_ text: String, attachments: [Attachment] = [], brief: Bool = false, live: LiveTurn? = nil) -> AsyncStream<TurnEvent> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return Self.finishedStream() }
        guard !isWorkerTranscript else {
            lastError = String(localized: "This is a Kanban worker's run. To go on with it, retry or unblock its card on the board.")
            return Self.finishedStream()
        }
        // A normal chat's message that tags bots goes to them (`BotAsides`).
        if bot == nil, attachments.isEmpty, !isIncognito, connection.hasLedger, BotDirectory.available(settings, dashboard: dashboard) {
            let tagged = BotAsides.tagged(in: trimmed, roster: BotDirectory.shared.bots(for: settings.connectionKey), speaking: speakingProfile)
            if !tagged.isEmpty {
                ask(trimmed, of: tagged)
                return Self.finishedStream()
            }
        }
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
        return startTurn(userMessage, brief: brief, live: live)
    }

    /// What a page in a reply sends the agent (`window.hermes.send`, `data-hermes-send`): a turn
    /// with no message of the person's to show, as the desktop app sends one. The agent answers by
    /// writing the page again, so the page is read again once it has (`refreshPage`).
    func sendFromPage(_ prompt: String, page: String, in messageID: UUID) -> PageSend {
        guard connection.hasLedger else { return .unavailable }
        guard !isStreaming, outbox.isEmpty else { return .busy }
        // A page is the agent's, in a conversation it has: never the first message of a new one.
        guard serverSessionID != nil else { return .unavailable }
        startTurn(Message(role: .user, text: prompt), fromPage: PageTurn(message: messageID, path: page))
        return .sent
    }

    private static func finishedStream() -> AsyncStream<TurnEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TurnEvent.self)
        continuation.finish()
        return stream
    }

    /// Runs one turn for a user message that isn't in the transcript yet. `heldSince` is when a
    /// message coming out of the outbox was first queued, so holding it again keeps its age.
    @discardableResult
    private func startTurn(_ outgoing: Message, heldSince: Date? = nil, brief: Bool = false, live: LiveTurn? = nil,
                           fromPage: PageTurn? = nil) -> AsyncStream<TurnEvent> {
        let (mirror, mirrorContinuation) = AsyncStream.makeStream(of: TurnEvent.self)
        lastSendWasHeld = false
        lastError = nil
        clearFollowUps()
        // Only the fast lane sends history; the ledger transports keep theirs on the server.
        let history = connection == .chatCompletions ? messages.filter { $0.error == nil } : []
        var userMessage = outgoing
        userMessage.createdAt = .now   // a held message is stamped when it actually goes out
        let trimmed = userMessage.text
        let attachments = userMessage.attachments
        let userID = userMessage.id
        if fromPage == nil { messages.append(userMessage) }
        var reply = Message(role: .assistant, text: "")
        reply.metrics = TurnMetrics(sentAt: .now)
        messages.append(reply)
        let replyID = reply.id

        var request = TurnRequest(
            userText: trimmed,
            history: history,
            sessionID: connection.hasLedger ? serverSessionID : nil,
            model: settings.transport == .chatCompletions ? settings.fastLaneModel : settings.gatewayModel.nilIfEmpty,
            provider: settings.transport == .chatCompletions ? nil : settings.gatewayProvider.nilIfEmpty,
            reasoningEffort: settings.reasoningEffort.nilIfEmpty,
            instructions: nil,
            attachments: attachments,
            replyLanguage: settings.replyLanguage.nilIfEmpty,
            brief: brief
        )
        if connection == .hermesServe, serverSessionID == nil {
            request.folder = startsIn?.path
            request.profile = bot == nil ? elsewhere?.profile : nil
        }
        request.incognito = isIncognito
        request.fromPage = fromPage != nil
        request.live = live
        if let call = answeringCall, fromPage == nil {
            answeringCall = nil
            if Date.now.timeIntervalSince(call.at) < 600 { request.answeringCall = call.line }
        }
        // The Hermes API's run for this message, should it go again after a dropped connection.
        request.turnKey = userID.uuidString
        // Asides to tagged bots since the agent last heard: told with this message, kept with it on the host.
        if bot == nil, connection.hasLedger, fromPage == nil, let note = AsideNote.note(for: AsideNote.pending(in: messages)) {
            request.userText += note
            for i in messages.indices where messages[i].isAside { messages[i].delivered?.noted = true }
        }
        // On this message alone, last: "Make This a Routine"'s, or a card's answer.
        if let note = pendingNote, fromPage == nil {
            request.userText += note
            pendingNote = nil
        }
        // The conversation's fast mode: the Hermes API keeps none for a session, so each turn asks.
        if connection == .hermesSessions, let stored = serverSessionID, store === ConversationStore.shared {
            request.fast = RunChatControls.shared.isFast(stored)
        }
        // A bot's chat: the other bots the message tags, and the note that says which they are.
        if connection == .hermesServe, let bot {
            let mentioned = BotMentions.mentioned(in: trimmed, roster: BotDirectory.shared.bots(for: settings.connectionKey), to: bot.profile)
            request.mentionNote = BotMentions.note(for: mentioned)
        }
        let departure = TurnDeparture()
        self.departure = departure
        request.departure = departure
        guard let transport = makeTransport() else {
            fail(replyID, settings.isConfigured ? TransportError.badURL.localizedDescription
                                                : String(localized: "No connection is set up yet. Go to Settings → Connection → Set up connection…."))
            pauseQueue()
            mirrorContinuation.finish()
            return mirror
        }

        isStreaming = true
        // An incognito chat's words stay in the app: not on the Lock Screen or in a widget.
        // Both say who is answering: the bot in its chat, else the main agent ("Sol is thinking").
        TurnActivity.shared.start(question: isIncognito ? IncognitoNote.title : trimmed, agent: answeringName)
        BackgroundTurn.shared.begin(question: isIncognito ? IncognitoNote.title : trimmed, agent: answeringName)
        turnSerial += 1
        let myTurn = turnSerial
        let transportKind = connection
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
                    guard let api = ledgerAPI() else { throw TransportError.noAPIKey }
                    let created = try await api.createSession(title: Self.sessionTitle(from: trimmed),
                                                              model: request.model, provider: request.provider,
                                                              reasoningEffort: request.reasoningEffort)
                    serverSessionID = created.id
                    request.sessionID = created.id
                    if isIncognito { Incognito.add(.init(session: created.id, server: settings.activeServerID.uuidString, transport: .hermesSessions)) }
                }
                // The Hermes API takes text and pictures: other files go to the server through the
                // Dashboard's login, and the message says where they are.
                if transportKind == .hermesSessions, request.attachments.contains(where: { $0.kind == .pdf || $0.kind == .other }),
                   await dashboard.canUse() {
                    statusLine = String(localized: "putting the file on the server…")
                    request = try await Self.placingFiles(request)
                }
                // Pictures go in the run itself, but the Hermes API keeps none of them, only a
                // "[screenshot]" in their place, so the chat opened anywhere else had no picture
                // (GitHub issue 18). With the Dashboard's login a copy goes to the server too, and
                // the message names it as Hermes Desktop's pictures are named.
                if transportKind == .hermesSessions, request.attachments.contains(where: { $0.kind == .image }),
                   dashboard.hasCredentials {
                    request = await Self.namingPictures(request)
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
                // (On the Hermes API, the Dashboard is asked only when the reply names a file.)
                var fetchesFiles = transportKind == .hermesServe
                if !fetchesFiles, transportKind == .hermesSessions, replyNamesFiles(replyID) { fetchesFiles = await dashboard.canUse() }
                if fetchesFiles {
                    await resolveServeMedia(replyID)
                    try Task.checkCancellation()   // Stop during the fetch must not finish the turn
                    if let fromPage { await refreshPage(fromPage) }
                }
                if transportKind == .hermesSessions {
                    await settleTodos(replyID)
                    await settleCards(replyID)
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
                TurnActivity.shared.finish(reply: isIncognito ? IncognitoNote.replied : replyText)
                if !replyText.isEmpty, !settings.requireBiometrics, !isIncognito {   // a locked app shouldn't print replies on the Home Screen
                    WidgetSnapshot.save(question: trimmed, reply: replyText)
                    WidgetCenter.shared.reloadTimelines(ofKind: "com.goosehouse.echo.lastreply")
                }
                let incognito = isIncognito
                Notifier.shared.notify(.replied, title: String(localized: "Redde replied"), body: incognito ? IncognitoNote.replied : PlainText.display(replyText),   // autoclosure: only stripped when a banner will post
                                       category: Notifier.repliedCategory, userInfo: [Notifier.conversationKey: self.id.uuidString],
                                       messageEntityID: SiriID.message(self.id, replyID))
                persist()
                outcome = .completed
                noteSeen(onlyOnScreen: true)
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
                } else if fromPage == nil, NetworkFailure.isConnectivity(error), replyIsBlank(replyID) {
                    // Never reached the server: hold the message instead of reporting a failure.
                    hold(userID: userID, replyID: replyID, queuedAt: heldSince ?? .now)
                    outcome = .held
                } else if transportKind == .chatCompletions, BackgroundTurn.shared.expired, NetworkFailure.isConnectivity(error) {
                    fail(replyID, Self.backgroundCutoff)
                } else {
                    fail(replyID, error.localizedDescription)
                }
            }
            // Seen through, failed or stopped here: the run needn't be asked after. Left, it is.
            if transportKind == .hermesSessions, !departure.hasLeft, let stored = request.sessionID, store === ConversationStore.shared {
                ChatActivity.shared.turnEnded(sessionID: stored, settings: settings)
            }
            // Only the current turn may reset shared state; a cancelled turn's tail must not
            // clobber the turn that replaced it.
            if myTurn == turnSerial {
                clearStatus()
                isStreaming = false
                currentRunID = nil
                settleWaiting()   // a turn that is over waits on nothing, whatever became of its card
                publishContext()
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

    /// A turn's files the Hermes API can't take (anything but pictures and text), put in
    /// "Redde attachments" in the server's home through the Dashboard, and named in the message
    /// instead (`AttachedFileNote`): the agent reads them there with its own tools.
    static func placingFiles(_ request: TurnRequest, client: some ServerFileBrowsing = HermesServeClient.shared) async throws -> TurnRequest {
        var request = request
        let files = request.attachments.filter { $0.kind == .pdf || $0.kind == .other }
        guard !files.isEmpty else { return request }
        for placed in try await ServerFiles.place(files, client: client) { request.userText += AttachedFileNote.note(path: placed.path) }
        request.attachments.removeAll { $0.kind == .pdf || $0.kind == .other }
        return request
    }

    /// A turn's pictures, each put on the server through the Dashboard (its own pictures folder,
    /// as the Dashboard's chat puts them) and named on a line of the message (`@image:`), which
    /// is how Hermes keeps a picture with a session for every other client to show. One that
    /// can't be put there still goes with the run, unnamed, as before.
    static func namingPictures(_ request: TurnRequest,
                               upload: (Attachment) async throws -> String = { try await HermesServeClient.shared.uploadPicture($0) }) async -> TurnRequest {
        var request = request
        for picture in request.attachments where picture.kind == .image {
            guard let path = try? await upload(picture) else { continue }
            request.userText += "\n" + ServeMedia.pictureRef(path)
        }
        return request
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
                let share = Double(min(100, processed * 100 / total)) / 100
                statusLine = String(localized: "Processing prompt… \(share.formatted(.percent.precision(.fractionLength(0))))")
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
            // One of the phone's own tools: the plugin is holding a request for this iPhone.
            if settings.phoneTools.on {
                phoneTools.toolStarted(name) { [weak self] picture in self?.update(replyID) { $0.attachments.append(picture) } }
            }
            update(replyID) { message in
                let step = ToolActivity(name: name, preview: preview, status: .running, startedAt: .now, args: args)
                message.tools.append(step)
                // A map, places, the weather: shown as soon as the call is made.
                if let cards = ReplyCards.cards(from: step), !cards.isEmpty { message.cards = (message.cards ?? []) + cards }
            }
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
                    // A card call: the plugin's answer has the weather and the time filled in, and a
                    // call it turned down shows nothing after all.
                    if message.tools[i].name == ReplyCards.tool {
                        let kept = message.tools.compactMap(ReplyCards.cards(from:)).flatMap { $0 }
                        message.cards = kept.isEmpty ? nil : kept
                    }
                }
            }
            if finished?.name == ReplyCards.tool { Task { await fillCards(replyID) } }
            // The agent's to-do tool: what a finished call wrote, applied to the list so far, is
            // the list now. (The Dashboard says the list itself right after: `.todos`.)
            if let finished, let list = TodoList.after(step: finished, previous: TodoList.latest(in: messages)) {
                update(replyID) { $0.todos = list }
                TurnActivity.shared.tasks(list)
            }
        case let .todos(list):
            update(replyID) { $0.todos = list }
            TurnActivity.shared.tasks(list)
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
            // An incognito chat's session, to be deleted however the app goes (`Incognito`).
            if isIncognito { Incognito.add(.init(session: id, server: settings.activeServerID.uuidString, transport: connection)) }
            // Saved as soon as the host has a session for it, not only with the reply: if the app
            // doesn't live to see the reply, it can find its way back to it (`catchUp`).
            if questionSavedFor != replyID {
                questionSavedFor = replyID
                persist()
            }
        case let .runID(id):
            currentRunID = id
            // A run goes on on the host whatever becomes of the app: noted, so it can be taken up
            // again if the app doesn't see it through.
            if connection == .hermesSessions, store === ConversationStore.shared, let stored = serverSessionID {
                ChatActivity.shared.noteRun(sessionID: stored, runID: id, profile: apiProfile, settings: settings)
            }
        case let .interrupt(interrupt, runtime):
            flushDeltas()
            pendingInterrupt = (interrupt, runtime)
            statusLine = String(localized: "waiting for you", comment: "Status under a reply: the agent waits for an answer")
            noteWaiting(interrupt)
            if case let .approval(request) = interrupt {
                Notifier.shared.notifyApproval(request)
                TurnActivity.shared.needsApproval(request)
            } else if case let .clarify(request) = interrupt {
                Notifier.shared.notifyClarify(request)
            } else {
                Notifier.shared.notify(.interrupt, title: Self.interruptTitle(interrupt), body: Self.interruptBody(interrupt))
            }
        case let .interruptExpired(id):
            if pendingInterrupt?.interrupt.id == id { pendingInterrupt = nil; statusLine = String(localized: "request expired", comment: "Status under a reply: the agent's question or approval timed out") }
        case .done:
            break
        }
    }

    // MARK: - A turn already under way

    /// How to stop the turn on screen when it is one the app joined and didn't start; nil otherwise.
    private var joinedStop: (@Sendable () -> Void)?
    /// How the turn on screen that the app started is let go of, when it is left and not stopped.
    private var departure: TurnDeparture?
    /// Looks for the reply to a Hermes API conversation that was left while the agent worked.
    private var ledgerWatch: Task<Void, Never>?
    /// The reply whose question has been saved already (see `.sessionID` in `apply`).
    private var questionSavedFor: UUID?

    /// Looks whether the open Dashboard conversation has a turn under way on the host that this
    /// run of the app isn't following: the app was closed while the agent worked, or the turn was
    /// started from somewhere else. If so the reply is followed from here on, and whatever the
    /// agent is waiting on a person for gets its card back. That is how an approval announced by
    /// a notification can be answered after the app was closed.
    func rejoinIfWaiting() async {
        guard connection == .hermesServe, !isStreaming, let stored = serverSessionID, let transport = makeTransport() else { return }
        let identity = identity
        guard let joined = try? await transport.rejoin(stored: stored) else { return }
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
    /// session list says so, so a long chat isn't read again each time Redde comes forward
    /// (GitHub issue 40).
    func catchUp() async {
        await initialLoad?.value   // at launch the conversation may still be coming off the disk
        guard connection.hasLedger, !isStreaming, let stored = serverSessionID else { return }
        if endsUnanswered {
            try? await open(serverSession: stored)
            return
        }
        guard let backend = SessionBackend.current(self),
              let row = try? await backend.listSessions().first(where: { $0.id == stored }),
              Self.serverIsAhead(lastActive: row.last_active, newest: messages.last(where: { !$0.isAside })?.createdAt),
              serverSessionID == stored, !isStreaming else { return }
        try? await open(serverSession: stored)
    }

    /// The session was last active after the newest message here, by more than the two clocks
    /// may differ.
    nonisolated static func serverIsAhead(lastActive: Double?, newest: Date?) -> Bool {
        guard let lastActive else { return false }
        return lastActive > (newest?.timeIntervalSince1970 ?? 0) + ChatActivity.clockSlack
    }

    /// The open Dashboard conversation's watch, while nothing is being followed, for a turn the
    /// host starts in it (`HermesTransport.watchHost`).
    private var hostWatch: (stored: String, stop: @MainActor @Sendable () -> Void)?
    private var joiningHostTurn = false

    /// Watches the open Dashboard conversation, while no turn is being followed, for one the host
    /// starts in it itself: a kanban card the agent made, finished, wakes it, and it may ask before
    /// a command. Joined as it starts, so its question gets its card at once rather than when the
    /// chat is next opened. Started and stopped as the conversation and its turns change.
    private func watchHostTurns() {
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

    private func follow(_ joined: RejoinedTurn, stored: String) {
        lastError = nil
        clearFollowUps()
        // A turn under way may have put some of itself in the host's transcript already (a tool
        // call waiting on an approval): the reply goes on from it instead of beside it.
        let replyID: UUID
        if let last = messages.last, last.role == .assistant, last.text.isEmpty, last.error == nil {
            replyID = last.id
        } else {
            let reply = Message(role: .assistant, text: "")
            messages.append(reply)
            replyID = reply.id
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
                let replyText = messages.last { $0.id == replyID }?.text ?? ""
                TurnActivity.shared.finish(reply: replyText)
                Notifier.shared.notify(.replied, title: String(localized: "Redde replied"), body: PlainText.display(replyText),
                                       category: Notifier.repliedCategory, userInfo: [Notifier.conversationKey: self.id.uuidString],
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

    private enum TurnOutcome { case completed, cancelled, failed, held }

    /// A direct (stateless) connection dropped because iOS suspended the app mid-reply.
    static let backgroundCutoff = String(localized: "Stopped when Redde went to the background. iOS gives an app about 30 seconds there, so keep Redde open (or the screen awake) for long replies.")

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
        TurnActivity.shared.fail(String(localized: "Waiting for a connection"))
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

    /// Puts what the agent stopped for on the "Needs you" widget, under this conversation.
    private func noteWaiting(_ interrupt: Interrupt) {
        let kind: WaitingRequest.Kind
        let text: String
        switch interrupt {
        case let .approval(request): (kind, text) = (.approval, request.command)
        case let .clarify(request): (kind, text) = (.question, request.questions.first?.question ?? "")
        case .sudo: (kind, text) = (.sudo, "")
        case let .secret(request): (kind, text) = (.secret, request.prompt.isEmpty ? String(localized: "Value for \(request.envVar)", comment: "What the agent asks for when it needs a secret: an environment variable's value") : request.prompt)
        }
        let key = NeedsYou.key(session: serverSessionID, conversation: id)
        waitingKey = key
        StatusWidgets.waiting(WaitingRequest(id: key, kind: kind, title: hasMessages ? title : nil,
                                             text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)),
                                             session: serverSessionID, since: .now, until: .now.addingTimeInterval(NeedsYou.lifetime(kind))),
                              in: widgetDefaults)
    }

    private func settleWaiting() {
        guard let key = waitingKey else { return }
        waitingKey = nil
        if !leavingTurn { StatusWidgets.settled(key, in: widgetDefaults) }
    }

    /// The Context widget's reading: the header ring's, when a turn ends or a conversation is
    /// opened. A conversation with no reading yet leaves the one before on the widget.
    private func publishContext() {
        guard let contextUsage else { return }
        StatusWidgets.reading(ContextReading(used: contextUsage.used, window: contextUsage.window,
                                             title: settings.requireBiometrics || !hasMessages ? nil : title, date: .now),
                              in: widgetDefaults)
    }

    private static func interruptTitle(_ i: Interrupt) -> String {
        switch i {
        case .approval: String(localized: "Redde needs your approval")
        case .clarify: String(localized: "Redde has a question")
        case .sudo: String(localized: "Redde needs a sudo password")
        case .secret: String(localized: "Redde needs a secret")
        }
    }

    private static func interruptBody(_ i: Interrupt) -> String {
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
                let (runtime, _) = try await client.openSession(stored: stored)
                for _ in 0 ..< removedTurns {
                    _ = try await client.call("session.undo", params: .object(["session_id": .string(runtime)]))
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

    /// An incognito chat (`Incognito`): a new conversation, kept nowhere, with the agent told so.
    private(set) var isIncognito = false

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
        become(id: record.id, createdAt: record.createdAt, messages: record.messages,
               outbox: record.outbox ?? [], serverSessionID: record.serverSessionID, name: record.name, bot: record.bot,
               elsewhere: record.elsewhere)
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
    /// The transcript still decoding at launch. A sender that arrives before it lands (Siri on a
    /// cold "Ask Redde", CarPlay, a notification reply) awaits it, or its message would open a
    /// new server session instead of continuing the latest one.
    private(set) var initialLoad: Task<Void, Never>?
    /// Bumped whenever the conversation becomes another one; the launch load checks it.
    private var identity = 0

    private func become(id: UUID = UUID(), createdAt: Date = .now, messages: [Message] = [],
                        outbox: [OutboxItem] = [], serverSessionID: String? = nil, name: String? = nil, bot: BotRef? = nil,
                        elsewhere: ProfileRoute? = nil) {
        endIncognito()   // the one being left, if it was one, goes
        noteSeen()   // the one being left
        answeringCall = nil
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
        // Every call about a bot's chat, or another profile's, names that profile, from the first one.
        if let profile = routeProfile, let serverSessionID { dashboard.noteProfile(profile, forStored: serverSessionID) }
        startsIn = nil
        lastError = nil
        isWorkerTranscript = false
        publishContext()
    }

    private func persist() {
        // An incognito chat is kept nowhere on the phone.
        guard !isIncognito else { return }
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
            name: name, bot: bot, elsewhere: elsewhere)
        // Unchanged content keeps its stamp: the list is ordered by updatedAt and relaunch opens
        // the newest, so merely viewing a conversation must not make it "newest".
        if let existing = store.cachedRecord(id: id),
           existing.messages == kept, existing.outbox == record.outbox,
           existing.serverSessionID == serverSessionID, existing.transport == record.transport,
           existing.serverID == record.serverID, existing.name == name, existing.bot == bot { return }
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
        switch connection {
        case .hermesSessions:
            guard let api = ledgerAPI() else { return }
            try await api.lockSessionModel(id: sid, model: model, provider: provider)
        case .hermesServe:
            try await dashboard.withLiveSession(stored: sid) { runtime in
                try await dashboard.setSessionModel(runtimeSession: runtime, model: model, provider: provider)
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

    func ledgerAPI() -> HermesSessionsAPI? { ledgerAPI(profile: apiProfile) }

    /// The Hermes API as this conversation reaches it: the app's, or an API bot's at
    /// /p/<profile>/ with that profile's own key.
    func ledgerAPI(for bot: BotRef?) -> HermesSessionsAPI? { ledgerAPI(profile: bot?.viaAPI == true ? bot?.profile : nil) }

    /// The Hermes API for a profile at /p/<profile>/ with its own key; nil, the app's.
    func ledgerAPI(profile: String?) -> HermesSessionsAPI? {
        guard let endpoint = settings.gatewayEndpoint(profile: profile) else { return nil }
        return HermesSessionsAPI(baseURL: endpoint.url, apiKey: endpoint.key, headers: settings.apiHeaders)
    }

    // MARK: Name

    /// Names the conversation. A gateway session is renamed on the gateway first, so the list,
    /// the Dashboard and the header agree; titles there must be unique, so it can refuse. An
    /// empty name takes a local conversation back to its first question (a gateway session
    /// keeps the title it has).
    func rename(to newName: String) async throws {
        // A bot's chat is known by its title on the server: renaming it would lose it.
        guard bot == nil else { return }
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
        // A bot's chat goes by its bot, whatever its title ("Bot Chat") says.
        guard bot == nil, let sessionID = serverSessionID, let session = sessions.first(where: { $0.id == sessionID }) else { return }
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
    func loadLedgerSession(_ summary: HermesSessionsAPI.SessionSummary, bot: BotRef? = nil, elsewhere: ProfileRoute? = nil) async throws {
        let api = bot != nil ? ledgerAPI(for: bot) : ledgerAPI(profile: elsewhere?.viaAPI == true ? elsewhere?.profile : nil)
        guard let api else { throw TransportError.noAPIKey }
        let stored = try await api.messages(sessionID: summary.id)
        adopt(serverSession: summary, messages: Self.mapStored(stored), bot: bot, elsewhere: elsewhere)
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

    private func makeTransport() -> (any HermesTransport)? {
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
        if connection == .hermesSessions {
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

    /// Resume a stored `hermes serve` session: history via `session.resume`. A bot's chat names
    /// its bot; one this iPhone has kept (opened from a notification, say) is known from its copy.
    func loadServeSession(_ summary: HermesSessionsAPI.SessionSummary, bot: BotRef? = nil, elsewhere: ProfileRoute? = nil,
                          isNew: Bool = false) async throws {
        let kept = store.summaries.first { $0.serverSessionID == summary.id }
        let bot = bot ?? kept?.bot
        let elsewhere = bot == nil ? (elsewhere ?? kept?.elsewhere) : nil
        if let profile = bot?.profile ?? elsewhere?.profile { dashboard.noteProfile(profile, forStored: summary.id) }
        // A chat made just now has nothing to fetch, and resuming it would start a second agent on it.
        var messages: [Message] = []
        var workerRun = summary.source == "kanban"
        if !isNew, !workerRun {
            do {
                messages = Self.messages(fromServeRows: try await dashboard.history(stored: summary.id))
            } catch where HermesServeClient.refusesWorkerRun(error) {
                workerRun = true
            }
        }
        // A Kanban worker's run: its transcript from the Dashboard's messages page, as the desktop
        // shows it, without resuming it (Hermes refuses that, RPC 4132).
        if workerRun, !isNew { messages = Self.mapStored(try await dashboard.transcript(stored: summary.id)) }
        // The agent's task list: replayed from the transcript's to-do calls, then set against
        // what the host says the list is now.
        TodoList.resolve(&messages)
        ReplyCards.resolve(&messages)
        TodoList.reconcile(&messages, with: dashboard.hostTodos[summary.id])
        adopt(serverSession: summary, messages: messages, bot: bot, elsewhere: elsewhere)
        isWorkerTranscript = workerRun && !isNew
        // The agent may still be at work in it, or waiting for an answer.
        if !isNew, !isWorkerTranscript { await rejoinIfWaiting() }
    }

    /// Opens a bot's chat (the Dashboard's Bots): its one conversation, found on the server or
    /// made there the first time. `mainName` is what the main profile goes by when it has no name.
    func openBot(_ bot: HermesBot, mainName: String) async throws {
        if bot.viaAPI { return try await openAPIBot(bot, mainName: mainName) }
        let (stored, isNew) = try await dashboard.botChat(for: bot)
        try await loadServeSession(HermesSessionsAPI.SessionSummary(id: stored), bot: BotRef(profile: bot.name, name: bot.label(mainName: mainName)),
                                   isNew: isNew)
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
        if let aside = try await client.startFresh(current) { EarlierBotChats.remember(aside, profile: ref.profile, server: server) }
        // Read again: the roster no longer names the chat put aside, so the bot gets a new one.
        // Just after, Hermes could still list the old one, which then opened again, as if nothing
        // had happened: a new chat is waited for, a few seconds at most.
        for attempt in 0 ..< 5 {
            let roster = try await BotDirectory.shared.refresh()
            guard let fresh = roster.bots.first(where: { $0.name == ref.profile }) else {
                throw TransportError.malformed(String(localized: "\(ref.name) isn't on this server any more"))
            }
            try await openBot(fresh, mainName: mainName)
            if serverSessionID != old { return }
            if attempt < 4 { try await Task.sleep(for: .milliseconds(700)) }
        }
        throw TransportError.malformed(String(localized: "Hermes hasn't put the old chat aside yet. Try again in a moment."))
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
    func open(serverSession id: String) async throws {
        let summary = HermesSessionsAPI.SessionSummary(id: id)
        switch settings.transport {
        case .hermesServe: try await loadServeSession(summary)
        case .hermesSessions: try await loadLedgerSession(summary)
        case .chatCompletions: throw TransportError.malformed(String(localized: "that conversation is on a Hermes connection"))
        }
    }

    /// Switches this conversation to a gateway session: keeps (or mints) the matching local
    /// record, swaps in its transcript, and persists. Shared by both ledger transports.
    private func adopt(serverSession summary: HermesSessionsAPI.SessionSummary, messages new: [Message], bot: BotRef? = nil,
                       elsewhere: ProfileRoute? = nil) {
        cancel(leaving: true)
        persist()
        // A bot's chat keeps its copy here when Hermes has compressed it into a new session.
        let server = settings.activeServerID
        let existing = store.summaries.first { $0.serverSessionID == summary.id }
            ?? bot.flatMap { bot in store.summaries.first { $0.bot?.profile == bot.profile && ($0.serverID ?? server) == server } }
        // Asides the agent hasn't been told of yet are only here: kept, where they came.
        let here = serverSessionID == summary.id ? messages : (existing.flatMap { store.cachedRecord(id: $0.id)?.messages } ?? [])
        let new = Self.keepingAsides(of: here, in: new)
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

    // MARK: - Routines (`RoutineNote`)

    /// A note for the next message alone (`RoutineNote`, `CardNote`).
    private var pendingNote: String?

    /// "Make This a Routine": a message asking the agent to keep what it did here as a skill.
    func makeRoutine(name: String, skill: String, when: String?) {
        pendingNote = RoutineNote.note(name: name, skill: skill, when: when)
        _ = send(String(localized: "Make this a routine: “\(name)”.", comment: "The message a chat's Make This a Routine sends, with the routine's name"))
    }

    /// A card answered with a tap: `shown` as the person's message, `said` in its note.
    func answerCard(_ card: ReplyCard, shown: String, said: String) {
        CardAnswers.shared.record(card.key, said: said)
        pendingNote = CardNote.note(key: card.key, said: said)
        _ = send(shown)
    }

    // MARK: - Asides (`BotAsides`)

    /// Asides run one after another; the answer being written.
    private var asideTask: Task<Void, Never>?
    private var asideDeparture: TurnDeparture?
    private var asideAnswer: UUID?

    /// The profile this chat's agent is: the main one, or another profile's.
    private var speakingProfile: String { elsewhere?.profile ?? settings.profileName ?? "default" }

    private func ask(_ text: String, of bots: [HermesBot]) {
        userSendCount += 1
        lastError = nil
        let mainName = settings.headerTitle
        var asked = Message(role: .user, text: text)
        asked.delivered = Delivered(kind: .asked, profile: bots.first?.name, name: bots.first?.label(mainName: mainName))
        messages.append(asked)
        persist()
        let chat = answeringName, identity = identity, before = asideTask
        asideTask = Task { [weak self] in
            await before?.value
            for bot in bots {
                guard let self, self.identity == identity, !Task.isCancelled else { return }
                await self.runAside(text, to: bot, mainName: mainName, chat: chat)
            }
        }
    }

    private func runAside(_ text: String, to bot: HermesBot, mainName: String, chat: String) async {
        let name = bot.label(mainName: mainName)
        var answer = Message(role: .user, text: "")
        answer.delivered = Delivered(kind: .answer, profile: bot.name, name: name)
        answer.metrics = TurnMetrics(sentAt: .now)
        messages.append(answer)
        let id = answer.id
        asideAnswer = id
        defer { if asideAnswer == id { asideAnswer = nil } }
        let departure = TurnDeparture()
        asideDeparture = departure
        var written = ""
        var shown = Date.distantPast
        do {
            let (transport, stored) = try await asideTransport(for: bot, mainName: mainName)
            var request = TurnRequest(userText: text + BotAsides.note(from: chat), history: [], sessionID: stored, model: nil, provider: nil,
                                      reasoningEffort: nil, instructions: nil, attachments: [],
                                      replyLanguage: settings.replyLanguage.nilIfEmpty, brief: false)
            request.departure = departure
            stream: for try await event in transport.stream(request) {
                switch event {
                case let .textDelta(delta): written += delta
                case let .textFinal(final): written = final
                case .interrupt:
                    // It waits on the person: in its own chat, where it can be answered.
                    departure.leave()
                    update(id) { $0.error = String(localized: "\(name) is waiting for you in its chat.") }
                    break stream
                default: continue
                }
                // Drawn ten times a second at most, as a reply's words are.
                if Date.now.timeIntervalSince(shown) > 0.1 {
                    shown = .now
                    update(id) { $0.text = written }
                }
            }
            update(id) { message in
                message.text = written
                message.metrics?.completedAt = .now
                if written.isEmpty, message.error == nil { message.error = String(localized: "\(name) didn't answer.") }
            }
        } catch is CancellationError {
            update(id) { $0.text = written }
        } catch {
            update(id) { $0.text = written; $0.error = error.localizedDescription; $0.metrics?.completedAt = .now }
        }
        persist()
    }

    /// Where a bot's turn goes: its Bot Chat, on the Dashboard or (one added for the Hermes API
    /// alone) at /p/<profile>/ with its own key. A test's transport, for a test.
    private func asideTransport(for bot: HermesBot, mainName: String) async throws -> (any HermesTransport, String) {
        if let transportOverride { return (transportOverride, "aside-" + bot.name) }
        #if DEBUG
        if DemoDay.on { return (DemoDayTransport(), "aside-" + bot.name) }   // the day's video: canned answers
        #endif
        return try await BotTurns.transport(for: bot, mainName: mainName, settings: settings, dashboard: dashboard)
    }

    /// Another chat opened: an aside under way goes on in its bot's chat, unwatched here.
    private func letGoOfAsides() {
        asideDeparture?.leave()
        asideTask?.cancel()
        asideTask = nil
        asideDeparture = nil
        asideAnswer = nil
    }

    /// An answer that was being written when its chat was left: over, and where it went.
    nonisolated static func settleAsides(_ messages: inout [Message], except running: UUID?) {
        for i in messages.indices where messages[i].delivered?.kind == .answer && messages[i].id != running
            && messages[i].metrics != nil && messages[i].metrics?.completedAt == nil {
            var answer = messages[i]
            answer.metrics?.completedAt = answer.createdAt
            if answer.text.isEmpty, answer.error == nil {
                let name = answer.delivered?.name ?? ""
                answer.error = String(localized: "Left before \(name) answered. Its answer is in its chat.")
            }
            messages[i] = answer
        }
    }

    /// The host's transcript, with the asides here it doesn't have yet (not told to the agent)
    /// put back where they came.
    nonisolated static func keepingAsides(of here: [Message], in host: [Message]) -> [Message] {
        var merged = host
        for aside in here where aside.isAside && aside.delivered?.noted != true && !merged.contains(where: { $0.id == aside.id }) {
            let at = merged.firstIndex { $0.createdAt > aside.createdAt && !$0.isAside } ?? merged.endIndex
            merged.insert(aside, at: at)
        }
        return merged
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

    private static let reasoningFlushInterval: Duration = .milliseconds(200)

    /// Reply text goes at 20 fps while the reply is short, and less often as it grows: each
    /// update lays the whole reply out again (SwiftUI's graph and text layout, not Redde's code,
    /// measured 2026-10-20), so a long one cost the same per update and twice as much a second.
    nonisolated static func textFlushInterval(forLength bytes: Int) -> Duration {
        bytes < 4_000 ? .milliseconds(50) : bytes < 16_000 ? .milliseconds(100) : .milliseconds(150)
    }
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
        let wait = slow ? Self.reasoningFlushInterval
            : Self.textFlushInterval(forLength: messages.last(where: { $0.id == id })?.text.utf8.count ?? 0)
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
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

    /// Over the Hermes API a card call (`redde_show`) comes in the stream by its name alone, its
    /// arguments left out: the transcript has them, read once the reply is done. Only the newest
    /// reply's, and only for a reply that made such a call and has no cards yet.
    private func settleCards(_ id: UUID) async {
        guard let session = serverSessionID, let reply = messages.last(where: { $0.id == id }), (reply.cards ?? []).isEmpty,
              reply.tools.contains(where: { $0.name == ReplyCards.tool && $0.status != .failed }),
              let rows = try? await ledgerAPI()?.newestMessages(sessionID: session, limit: 60) else { return }
        var read = Conversation.mapStored(rows)
        ReplyCards.resolve(&read)
        guard let cards = read.last(where: { $0.role == .assistant })?.cards, !cards.isEmpty else { return }
        update(id) { if ($0.cards ?? []).isEmpty { $0.cards = cards } }
        Task { await fillCards(id) }   // not holding up the end of the turn
    }

    /// A reply's weather and time cards that the plugin's answer didn't fill in (a plugin older
    /// than 1.7.0, or its answer not read), looked up on the phone (`CardLookup`). Only a reply
    /// coming in: one read back later keeps what it was saved with.
    private func fillCards(_ id: UUID) async {
        guard let cards = messages.last(where: { $0.id == id })?.cards, cards.contains(where: CardLookup.needsLookup) else { return }
        let filled = await cardLookup.fill(cards)
        guard filled != cards else { return }
        update(id) { if $0.cards == cards { $0.cards = filled } }   // unless another call changed them meanwhile
    }

    /// A reply that delivers a file carries a bare server path (`MEDIA:` tag, markdown image,
    /// or "[IMAGE: …]"). Fetch each over the serve dashboard file API and attach it — photos
    /// for images, document chips for the rest. Paths that fail to fetch stay in the text.
    /// Whether a reply names a file for the phone to fetch: on the Hermes API the Dashboard is only
    /// asked whether it lets this phone in when there is something to fetch.
    private func replyNamesFiles(_ id: UUID) -> Bool {
        messages.first(where: { $0.id == id }).map { ServeMedia.mayName(in: $0.text) } ?? false
    }

    private func resolveServeMedia(_ id: UUID) async {
        guard let text = messages.first(where: { $0.id == id })?.text else { return }
        let candidates = ServeMedia.candidates(in: text)
        guard !candidates.isEmpty else { return }
        var attachments: [Attachment] = []
        var fetched: Set<String> = []
        // A photo the phone handed over in this very reply is in it already (`DeviceToolsService`):
        // the agent naming it as well is no reason to show it twice. Its name on the server ends
        // in the name it has here.
        let shown = messages.first(where: { $0.id == id })?.attachments.map(\.filename) ?? []
        // A page named twice, once to show and once as a file, is shown.
        for c in candidates.filter(\.isPage) + candidates.filter({ !$0.isPage }) where !fetched.contains(c.path) {
            if ServeMedia.isFromThePhone(c.path), shown.contains(where: { c.filename.hasSuffix($0) }) {
                fetched.insert(c.path)
                continue
            }
            guard let dataURL = await fetchServerFile(c.path, fileSource),
                  var att = ServeMedia.attachment(dataURL: dataURL, name: c.filename) else { continue }
            if c.isPage { att = AgentPage.attachment(att, from: c.path) }
            fetched.insert(c.path)
            attachments.append(att)
        }
        guard !fetched.isEmpty else { return }
        var cleaned = text
        for c in candidates where fetched.contains(c.path) {
            cleaned = cleaned.replacingOccurrences(of: c.whole, with: "")
        }
        // The speech tool's request for a voice bubble went with its file.
        if attachments.contains(where: \.isAudio) { cleaned = cleaned.replacingOccurrences(of: ServeMedia.voiceMarker, with: "") }
        // And Hermes's stand-in for a picture's bytes with the picture.
        if candidates.contains(where: { $0.isPicture && fetched.contains($0.path) }) { cleaned = ServeMedia.withoutPlaceholders(cleaned) }
        // The message may have been replaced while its files were on their way (another chat opened).
        guard messages.contains(where: { $0.id == id && $0.text == text }) else { return }
        update(id) { $0.text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines); $0.attachments += attachments }
    }

    /// A page read again after the turn it sent: the agent's answer is the page it wrote. Shown
    /// anew only when it changed.
    private func refreshPage(_ turn: PageTurn) async {
        guard let dataURL = await fetchServerFile(turn.path, fileSource),
              let fetched = ServeMedia.attachment(dataURL: dataURL, name: String(turn.path.split(separator: "/").last ?? "page.html")),
              let shown = messages.first(where: { $0.id == turn.message })?.attachments.first(where: { $0.page == turn.path }),
              fetched.data != shown.data else { return }
        update(turn.message) { message in
            guard let i = message.attachments.firstIndex(where: { $0.page == turn.path }) else { return }
            message.attachments[i] = AgentPage.attachment(fetched, from: turn.path)
        }
    }

    /// Who carries out a phone tool the agent calls in a turn here. Tests put their own.
    var phoneTools = DeviceToolsService.shared

    /// A file on the server as a data URL, over the Dashboard's file API. Tests put their own here.
    var fetchServerFile: (String, FileSource) async -> String? = { try? await HermesServeClient.shared.readDataURL(path: $0, in: $1) }

    /// Where the files this chat's replies name are on the server.
    var fileSource: FileSource { FileSource(sessionID: serverSessionID, profile: routeProfile ?? settings.profileName) }

    /// How many replies of a chat opened from the server have their files fetched again.
    static let reopenedMediaReach = 8
    private var reopenedMedia: Task<Void, Never>?

    /// A chat opened from the server comes back as text: the files its replies delivered are
    /// bare paths again, pictures and sound alike, and the pictures sent with its messages are
    /// `@image:` lines (from Hermes Desktop, or Redde on another device; GitHub issue 18). The
    /// newest of them are fetched once more, newest first; older ones stay as they are written.
    func resolveReopenedMedia() {
        reopenedMedia?.cancel()
        guard settings.transport == .hermesServe || (settings.transport == .hermesSessions && dashboard.hasCredentials) else { return }
        let opened = id
        let replies = messages.reversed().lazy.filter { !ServeMedia.candidates(in: $0.text).isEmpty }
            .prefix(Self.reopenedMediaReach).map(\.id)
        guard !replies.isEmpty else { return }
        reopenedMedia = Task { [weak self] in
            for reply in replies {
                guard let self, !Task.isCancelled, id == opened else { return }
                await resolveServeMedia(reply)
            }
            guard let self, !Task.isCancelled, id == opened else { return }
            persist()
        }
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
              let stored = try? await HermesSessionsAPI(baseURL: base, apiKey: key, headers: settings.apiHeaders).messages(sessionID: sessionID),
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
        Notifier.shared.notify(.failed, title: String(localized: "Redde couldn't reply"), body: description)
        // A paired Hermes will say so too, minutes later: that note then arrives quietly.
        if let serverSessionID { ToldAlready.failed(session: serverSessionID) }
        update(id) { message in
            message.error = description
            if message.text.isEmpty { message.text = "⚠️ \(description)" }
        }
        isStreaming = false
    }
}

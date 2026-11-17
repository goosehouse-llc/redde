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

    var id = UUID()
    var createdAt = Date.now
    var messages: [Message] = [] { didSet { refreshHeader() } }
    var isStreaming = false {
        didSet {
            guard isStreaming != oldValue else { return }
            if !isStreaming { ownTurnEndedAt = .now }
            watchHostTurns()
        }
    }
    var statusLine: String?
    var lastError: String?
    /// An error from outside a turn, shown where a turn's is (the header's pinned-model menu).
    func show(error text: String) { lastError = text }
    /// A Kanban worker's run, open to read (GitHub issue 37): Hermes won't resume one, since a
    /// second writer on the card's workspace would go unsupervised, so there is no writing to it.
    var isWorkerTranscript = false

    /// Hermes ledger session id (sessions transport) or stored session id (hermes serve).
    var serverSessionID: String? {
        didSet {
            guard serverSessionID != oldValue else { return }
            sessionTransport = serverSessionID == nil ? nil : connection
            watchHostTurns()
            watchOtherDevices()
            // A model picked before the first message is kept with the session it made.
            if oldValue == nil, let serverSessionID, let unsentModel {
                models.set(unsentModel, connection: settings.connectionKey, session: serverSessionID)
                self.unsentModel = nil
            }
        }
    }
    /// The kind of connection `serverSessionID` belongs to. A server's connection type can change
    /// under an open chat (Settings → Connection): a Hermes session id then means nothing to an
    /// ACP agent, and the reverse (Claude Code refused one as "not a UUID", 11-12).
    var sessionTransport: Transport?

    /// The chat's session can go on over the connection in use: the same kind, or Hermes either
    /// way (the Dashboard and the Hermes API share one store of sessions).
    var sessionFitsConnection: Bool {
        guard let sessionTransport else { return true }
        return sessionTransport == connection || (sessionTransport.isHermes && connection.isHermes)
    }

    /// With New Chats Use the Server's Model on, a model picked in this conversation before it
    /// has a session on the server; kept with the session once it has one (`ConversationModels`).
    var unsentModel: ConversationModels.Pick?
    /// The project a new conversation starts in (a project's New Conversation, on the Dashboard):
    /// its first turn opens the session in the project's folder. Gone when it becomes another.
    var startsIn: ProjectPlace?
    /// The bot this conversation is with, when it is a bot's chat (the Dashboard's Bots): a
    /// session of the bot's own profile, its one conversation, which Redde never renames.
    var bot: BotRef?
    /// The profile this conversation lives in when it is another than the selected one and not a
    /// bot's chat: opened from the chat list with All Profiles on. Every call about it names it.
    var elsewhere: ProfileRoute?
    /// The bridge agent this chat is with, with every agent in one list (`AcpAgents`); nil
    /// otherwise. The server's agent follows it while the chat is open.
    var acpAgent: String?
    /// An agent's call just answered in this conversation (`AgentCalls`): its line, told to the
    /// agent with what the person says first after it (`CallNote`), within ten minutes. Gone when
    /// another conversation opens.
    @ObservationIgnored var answeringCall: (line: String, at: Date)?
    /// Who answers in this conversation, as the Lock Screen names it: its bot, else the main agent.
    var answeringName: String { bot?.name ?? settings.headerTitle }
    /// Words to find once this conversation is on screen: set when a message search opens it,
    /// taken by the transcript, which opens Find on them (`TranscriptView`).
    var findRequest: String?
    /// Opened from a reply's notification: the transcript starts at the top of the newest reply,
    /// where the notification's words begin, not at its end (GitHub #63). The id of the session
    /// (or of this conversation) the notification was about, so another chat on screen meanwhile
    /// doesn't take it; taken by the transcript once that chat's messages are in.
    var readFromReply: String?
    /// With `readFromReply`: the notification was a finished task's, which may be one the plugin
    /// kept the report of (`TaskReports`): the transcript opens that report, or Hermes's row for it.
    var readFromTask = false
    /// API-server run id of the turn in flight (sessions transport).
    var currentRunID: String?

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
    var apiProfile: String? {
        bot.map { $0.viaAPI == true ? $0.profile : nil } ?? (elsewhere?.viaAPI == true ? elsewhere?.profile : nil)
    }

    /// Bumped on every reader-initiated send (send, steer, send-now). The transcript can't
    /// infer "you just sent something" from the messages array — a normal send appends the
    /// user message and the empty reply in one transaction, and a steer note lands *before*
    /// the streaming reply — so it watches this instead and jumps to the end.
    var userSendCount = 0

    /// Messages not sent yet, oldest first: queued behind a streaming reply, or held while the
    /// server can't be reached. Only the first one is ever sent; the rest wait their turn.
    var outbox: [OutboxItem] = [] { didSet { refreshHeader() } }
    /// The last `send` didn't go out now (queued or held offline). The voice loop reads this to
    /// say so instead of waiting for a reply that isn't coming.
    var lastSendWasHeld = false
    /// Follow-up questions for the last reply (`FollowUps`), when the setting is on and the
    /// fast lane answered; cleared by the next send.
    var followUps: [String] = []
    var followUpTask: Task<Void, Never>?
    /// What the next message quotes (`QuotedText`), shown above the composer until it goes.
    var quoting: QuotedText?
    /// A quoted message to bring on screen: the transcript scrolls to it and marks it a moment.
    var revealRequest: RevealRequest?
    nonisolated struct RevealRequest: Equatable, Sendable { var id: UUID; var count: Int }
    var retryTask: Task<Void, Never>?
    var retryAttempt = 0
    private var connectivityToken: UUID?
    /// Test seam: retries fire on this schedule (seconds) instead of the production one.
    var retryDelays: [Double] = [5, 15, 30, 60]

    /// Test seam: where the status widgets' data is kept (the App Group).
    var widgetDefaults: UserDefaults? = NeedsYou.shared
    /// Test seam: where weather and time cards are looked up when the plugin's answer didn't fill them.
    var cardLookup = CardLookup.shared

    /// Whatever the gateway is waiting on you for (hermes serve).
    var pendingInterrupt: (interrupt: Interrupt, runtimeSession: String)? {
        // However it went (answered, expired, cancelled), the Live Activity stops asking, and
        // so does the "Needs you" widget.
        didSet {
            guard oldValue != nil, pendingInterrupt == nil else { return }
            TurnActivity.shared.approvalSettled()
            settleWaiting()
        }
    }
    /// This conversation's entry on the "Needs you" widget, while it has one.
    var waitingKey: String?
    /// A turn is being left to go on on the host (another conversation was opened): what it
    /// waits on, it still waits on, and the widget keeps saying so.
    var leavingTurn = false

    let settings: Settings
    let store: ConversationStore
    var streamTask: Task<Void, Never>?
    /// Increments per send; a turn's tail only touches shared state if it is still the current turn.
    var turnSerial = 0

    /// Tests inject a scripted transport here; production resolves one from Settings per turn.
    let transportOverride: (any HermesTransport)?
    /// The Dashboard this conversation's Dashboard turns, bots and questions go by: the app's,
    /// unless a test gives one of its own.
    let dashboard: HermesServeClient
    /// Each conversation's own model (`ConversationModels`): the app's, unless a test gives one.
    let models: ConversationModels

    init(settings: Settings = .shared, store: ConversationStore = .shared, transportOverride: (any HermesTransport)? = nil,
         dashboard: HermesServeClient = .shared, models: ConversationModels = .shared) {
        self.settings = settings
        self.store = store
        self.transportOverride = transportOverride
        self.dashboard = dashboard
        self.models = models
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
    var title = String(localized: "New conversation")
    private(set) var hasMessages = false
    /// How full the model's context is, as of the latest reply that says: the header's ring.
    private(set) var contextUsage: ContextUsage?
    /// The name this conversation was given: by Rename, or on the gateway (a session renamed in
    /// the Dashboard, or titled by Hermes). Without one the title is the first question.
    var name: String? { didSet { refreshHeader() } }
    /// The bots a step of the last reply is messaging right now (a `message_agent` call still
    /// running), by the name on its `target:` line, lowercased, without the "@": what a bot's row
    /// in the chat list reads while a reply streams (`ChatActivity.kind`). Held apart from
    /// `messages` like the title: read from the array there, every streamed update re-rendered
    /// the whole chat list, kept built while the panel is closed, once for each bot (2026-11-15).
    private(set) var messagingTargets: Set<String> = []

    private func refreshHeader() {
        let first = (messages.first { $0.role == .user && !$0.isSteer } ?? outbox.first?.message).map { $0.text.isEmpty ? String(localized: "\($0.attachments.count) attachments") : $0.text } ?? String(localized: "New conversation")
        let title = name ?? String(first.prefix(60))
        // Assigning an equal value would still notify every observer.
        if title != self.title { self.title = title }
        if hasMessages == messages.isEmpty { hasMessages = !messages.isEmpty }
        // The newest reply that knows; nearly always the last message or the one before it.
        let context = messages.reversed().lazy.compactMap { $0.metrics?.context }.first
        if context != contextUsage { contextUsage = context }
        let targets = Self.messagingTargets(in: messages.last?.tools ?? [])
        if targets != messagingTargets { messagingTargets = targets }
    }

    /// The bots the running `message_agent` calls among `tools` are messaging (`messagingTargets`).
    nonisolated static func messagingTargets(in tools: [ToolActivity]) -> Set<String> {
        var found: Set<String> = []
        for tool in tools where tool.name == "message_agent" && tool.status == .running {
            if let target = tool.args?.firstMatch(of: targetLine)?.output.1 { found.insert(String(target).lowercased()) }
        }
        return found
    }
    nonisolated(unsafe) private static let targetLine = /(?m)^target: @?([^\s]+)/

    // MARK: - A turn already under way

    /// How to stop the turn on screen when it is one the app joined and didn't start; nil otherwise.
    var joinedStop: (@Sendable () -> Void)?
    /// How the turn on screen that the app started is let go of, when it is left and not stopped.
    var departure: TurnDeparture?
    /// Looks for the reply to a Hermes API conversation that was left while the agent worked.
    var ledgerWatch: Task<Void, Never>?
    /// The reply whose question has been saved already (see `.sessionID` in `apply`).
    var questionSavedFor: UUID?

    var catchingUp: CatchingUp?

    /// The open Dashboard conversation's watch, while nothing is being followed, for a turn the
    /// host starts in it (`HermesTransport.watchHost`).
    var hostWatch: (stored: String, stop: @MainActor @Sendable () -> Void)?
    var joiningHostTurn = false

    // MARK: Other devices

    /// When a turn of this device's ended here: the host stamps a reply as it ends, later than it
    /// started here, and that isn't news from elsewhere.
    var ownTurnEndedAt: Date?
    /// The newest the host had last time it was asked: a change is only acted on once.
    var serverSeen: Date?
    var otherDevicesTask: Task<Void, Never>?
    var changesListener: (client: HermesServeClient, id: UUID)?
    var changeCheck: Task<Void, Never>?

    /// An incognito chat (`Incognito`): a new conversation, kept nowhere, with the agent told so.
    var isIncognito = false

    // MARK: - Outbox

    /// The transcript still decoding at launch. A sender that arrives before it lands (Siri on a
    /// cold "Ask Redde", CarPlay, a notification reply) awaits it, or its message would open a
    /// new server session instead of continuing the latest one.
    private(set) var initialLoad: Task<Void, Never>?
    /// Bumped whenever the conversation becomes another one; the launch load checks it.
    var identity = 0

    // MARK: - Routines (`RoutineNote`)

    /// A note for the next message alone (`RoutineNote`, `CardNote`).
    var pendingNote: String?

    // MARK: - Reactions (`Reactions`)

    /// The question the next message answers, for over it (`answerCard`).
    var pendingAnswering: String?

    // MARK: - Asides (`BotAsides`)

    /// Asides run one after another; the answer being written.
    var asideTask: Task<Void, Never>?
    var asideDeparture: TurnDeparture?
    var asideAnswer: UUID?
    /// Rounds of the agent's own tags passed on since the person last wrote (`relayTags`).
    var relayHops = 0
    /// Told of the agent's reply once the answers it asked for are given back (`relayTags`): voice
    /// mode, while its screen is up, reads it (`VoiceSession.joinFollowOn`).
    @ObservationIgnored var followOn: (@MainActor (UUID) -> Void)?

    // MARK: - Delta coalescing

    /// The waiting flush was scheduled for thinking only.
    var flushIsSlow = false

    var pendingText = ""
    var pendingReasoning = ""
    var pendingUsage: TokenUsage?
    var pendingFor: UUID?
    var flushTask: Task<Void, Never>?
    var firstTokenMarked: UUID?

    /// Who carries out a phone tool the agent calls in a turn here. Tests put their own.
    var phoneTools = DeviceToolsService.shared

    /// A file on the server as a data URL, over the Dashboard's file API. Tests put their own here.
    var fetchServerFile: (String, FileSource) async -> String? = { path, source in
        if let bridge = source.bridge { return await AcpClient.client(for: bridge).readDataURL(path: path, session: source.sessionID) }
        return try? await HermesServeClient.shared.readDataURL(path: path, in: source)
    }

    var reopenedMedia: Task<Void, Never>?
}

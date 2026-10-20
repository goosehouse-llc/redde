import Foundation
import Observation
import UIKit

/// What the chat list marks beside a conversation: the agent at work in it, the agent waiting on
/// the person, or a reply the person hasn't seen. A conversation left while the agent works goes
/// on (GitHub issue 12), and the list is where it shows.
///
/// Where it comes from depends on the connection:
/// - Dashboard: `session.active_list` says which conversations have a turn under way and which of
///   those wait on a person (an approval counts from Hermes 0.21.3; 0.21.0 calls it working).
///   Hermes keeps Unread itself, the same for every app: `unread` in its list, against a read
///   mark the apps set. A conversation nobody has marked never shows unread.
/// - Hermes API: it lists no turns and doesn't say what is unread. A turn the app left mid-way is
///   asked after by its run (`GET /v1/runs/{id}`), and what was last seen of each conversation is
///   kept here, against the time the list gives for its last activity. The read mark is still
///   set on the server, for the Dashboard and the desktop app.
///
/// The open conversation's own state (a reply streaming, a card waiting) comes from it, live.
/// `scripts/hermes-lab/lab.sh status` shows what each Hermes release says.
@MainActor
@Observable
final class ChatActivity {
    static let shared = ChatActivity()

    nonisolated enum Kind: Equatable, Sendable {
        case working, needsYou
    }

    /// A turn the app left mid-way on the Hermes API: its run, and when it was left.
    nonisolated struct LeftTurn: Codable, Equatable, Sendable {
        var runID: String
        var leftAt: Date
        /// An API bot's run: its profile, whose own address and key ask after it (`APIBot`).
        var profile: String?
    }

    /// Conversations with a turn under way, by their id on the server, as last looked at.
    private(set) var live: [String: Kind] = [:]
    /// Group chats a bot is at work in, or waiting on the person in, by room id (`roomKinds`).
    private(set) var liveRooms: [String: Kind] = [:]
    /// The connection `live` belongs to.
    private var liveKey = ""
    /// Bumped when the Dashboard says its conversations changed (`sessions.changed`): the list
    /// fetches them again, now and then.
    private(set) var changes = 0
    /// Turns left mid-way on the Hermes API, by connection, then conversation.
    private var left: [String: [String: LeftTurn]]
    /// What was last seen of each conversation on the Hermes API, by connection, then
    /// conversation: a time on the host's clock (its last activity as the list gave it), on the
    /// phone's (when it was last on screen), or 0 for marked unread.
    private var seen: [String: [String: Double]]
    /// When each conversation was last marked read on the server: opening one and leaving it
    /// a moment later sends one mark, not two.
    @ObservationIgnored private var markedAt: [String: Date] = [:]
    @ObservationIgnored private var listener: UUID?

    private let defaults: UserDefaults
    private static let leftKey = "chatActivity.leftTurns"
    private static let seenKey = "chatActivity.seen"
    /// A turn left longer ago than this isn't asked after any more.
    nonisolated static let leftTurnsLast: TimeInterval = 30 * 60
    /// Activity within this of the time a conversation was seen doesn't count: the phone's clock
    /// and the host's needn't agree to the second.
    nonisolated static let clockSlack: Double = 5

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        left = defaults.data(forKey: Self.leftKey).flatMap { try? decoder.decode([String: [String: LeftTurn]].self, from: $0) } ?? [:]
        seen = defaults.data(forKey: Self.seenKey).flatMap { try? decoder.decode([String: [String: Double]].self, from: $0) } ?? [:]
    }

    // MARK: - What a row shows

    /// The agent at work in the conversation, or waiting on the person. The open conversation
    /// says for itself; on the Hermes API, one opened again while the turn it left goes on is
    /// what its run says.
    func kind(of sessionID: String, open conversation: Conversation, settings: Settings = .shared) -> Kind? {
        if sessionID == conversation.serverSessionID {
            if conversation.pendingInterrupt != nil { return .needsYou }
            if conversation.isStreaming { return .working }
            guard settings.transport == .hermesSessions else { return nil }
        }
        return liveKey == settings.connectionKey ? live[sessionID] : nil
    }

    func isUnread(_ row: HermesSessionsAPI.SessionSummary, open conversation: Conversation, settings: Settings = .shared) -> Bool {
        Self.unread(server: row.unread, lastActive: row.last_active, seen: seen[settings.connectionKey]?[row.id],
                    isOpen: row.id == conversation.serverSessionID,
                    busy: kind(of: row.id, open: conversation, settings: settings) != nil)
    }

    /// Unread: not the open conversation, nothing under way in it (the agent's own activity
    /// while it works isn't a reply yet), and either the host says so or, where it can't (the
    /// Hermes API), activity came after it was last seen here.
    nonisolated static func unread(server: Bool?, lastActive: Double?, seen: Double?, isOpen: Bool, busy: Bool) -> Bool {
        guard !isOpen, !busy else { return false }
        if let server { return server }
        guard let lastActive, let seen else { return false }
        return seen == 0 || lastActive > seen + clockSlack
    }

    // MARK: - Looking

    /// One look at what the host is doing, for the connection the conversation is on. False
    /// when the host couldn't be asked: the caller waits longer before the next.
    @discardableResult
    func look(_ conversation: Conversation, settings: Settings = .shared, dashboard: HermesServeClient = .shared) async -> Bool {
        let key = settings.connectionKey
        switch settings.transport {
        case .hermesServe:
            listenForChanges(dashboard)
            guard let found = try? await dashboard.liveActivity() else { return false }
            guard key == settings.connectionKey else { return true }
            live = found.sessions
            if liveRooms != found.rooms { liveRooms = found.rooms }
            liveKey = key
            return true
        case .hermesSessions:
            guard let main = settings.gatewayEndpoint(profile: nil) else { return false }
            /// Where a left run is asked after: the app's API, or an API bot's own (`APIBot`).
            func api(_ turn: LeftTurn) -> HermesSessionsAPI? {
                guard let endpoint = turn.profile.map({ settings.gatewayEndpoint(profile: $0) }) ?? main else { return nil }
                return HermesSessionsAPI(baseURL: endpoint.url, apiKey: endpoint.key, headers: settings.customHeaderFields)
            }
            var found: [String: Kind] = [:]
            var reached = true
            // The bots' chats and group chats go by the Dashboard here too, when its login is
            // saved: what it says of them, beside the runs this phone left.
            var rooms: [String: Kind] = [:]
            if settings.showBots, BotDirectory.reachable(settings, dashboard: dashboard), let dashboardSays = try? await dashboard.liveActivity() {
                found = dashboardSays.sessions
                rooms = dashboardSays.rooms
            }
            for (session, turn) in left[key] ?? [:] {
                if Date.now.timeIntervalSince(turn.leftAt) > Self.leftTurnsLast {
                    forget(session, key: key)
                    continue
                }
                do {
                    guard let api = api(turn) else { forget(session, key: key); continue }
                    if let status = try await api.runStatus(turn.runID), let kind = Self.kind(runStatus: status) {
                        found[session] = kind
                    } else {
                        // Over (or forgotten by the host): a reply came that nobody has seen,
                        // unless the conversation is on screen.
                        forget(session, key: key)
                        if session != conversation.serverSessionID { mark(session, seenAt: 0, key: key) }
                    }
                } catch {
                    reached = false
                    found[session] = live[session] ?? .working   // can't tell: as it was
                }
            }
            guard key == settings.connectionKey else { return true }
            live = found
            if liveRooms != rooms { liveRooms = rooms }
            liveKey = key
            return reached
        case .chatCompletions:
            live = [:]
            return true
        }
    }

    /// `session.active_list`'s answer, by stored id. "starting" is a turn on its way.
    nonisolated static func kinds(activeList result: JSONValue) -> [String: Kind] {
        var found: [String: Kind] = [:]
        for item in result["sessions"]?.array ?? [] {
            guard let key = item["session_key"]?.string ?? item["id"]?.string else { continue }
            switch item["status"]?.string {
            case "working", "starting": found[key] = .working
            case "waiting": found[key] = .needsYou
            default: break
            }
        }
        return found
    }

    /// The group chats `session.active_list` shows at work: Hermes runs each bot of a room in a
    /// hidden session titled "Group: <room>" (Hermes Desktop, "Group: <room> · <thread>"), working
    /// while it answers and waiting while it asks the person. Keyed by room id: a hosted room's
    /// own, a Desktop one's as Redde names it ("desktop:id:<room>"). Waiting outranks working.
    nonisolated static func roomKinds(activeList result: JSONValue) -> [String: Kind] {
        var found: [String: Kind] = [:]
        for item in result["sessions"]?.array ?? [] {
            guard let title = item["title"]?.string, title.hasPrefix(GroupDraft.sessionTitle("")) else { continue }
            let rest = title.dropFirst(GroupDraft.sessionTitle("").count)
            let kind: Kind
            switch item["status"]?.string {
            case "working", "starting": kind = .working
            case "waiting": kind = .needsYou
            default: continue
            }
            let id = rest.range(of: " · ").map { "desktop:id:" + rest[..<$0.lowerBound] } ?? String(rest)
            if found[id] != .needsYou { found[id] = kind }
        }
        return found
    }

    /// A run's status as a mark; nil once it has ended.
    nonisolated static func kind(runStatus: String) -> Kind? {
        switch runStatus {
        case "queued", "running", "stopping": .working
        case "waiting_for_approval": .needsYou
        default: nil
        }
    }

    /// The Dashboard says when its conversations change; the list fetches them again for it.
    private func listenForChanges(_ dashboard: HermesServeClient) {
        guard listener == nil else { return }
        listener = dashboard.addListener { [weak self] event in
            guard event.type == "sessions.changed" else { return }
            MainActor.assumeIsolated { self?.changes += 1 }
        }
    }

    // MARK: - Telling it

    /// A turn the app left mid-way on the Hermes API (another conversation was opened): asked
    /// after until it ends, and working meanwhile.
    func noteLeft(sessionID: String, runID: String, profile: String? = nil, settings: Settings = .shared) {
        let key = settings.connectionKey
        left[key, default: [:]][sessionID] = LeftTurn(runID: runID, leftAt: .now, profile: profile)
        if liveKey != key {
            live = [:]
            liveKey = key
        }
        live[sessionID] = .working   // at once, before the list next looks
        save()
    }

    /// A Hermes API turn under way here, from the moment its run starts: if the app doesn't see
    /// it through (iOS closes the app, say), the run can be taken up again when the conversation
    /// is next opened, and the row shows it working meanwhile.
    func noteRun(sessionID: String, runID: String, profile: String? = nil, settings: Settings = .shared) {
        noteLeft(sessionID: sessionID, runID: runID, profile: profile, settings: settings)
    }

    // MARK: - Bots' chats

    /// A worker heard from this lately is at work (Hermes Desktop's measure: a worker reports at
    /// least once a minute).
    nonisolated static let workerLive: TimeInterval = 150

    /// What a bot's row shows of it: Hermes running a turn in its chat (the gateway's own list,
    /// which also says when one waits on the person), the bot's chat open here and at work, or
    /// one of its workers (a kanban card) heard from lately.
    func kind(of bot: HermesBot, open conversation: Conversation, settings: Settings = .shared) -> Kind? {
        if conversation.bot?.profile == bot.name {
            if conversation.pendingInterrupt != nil { return .needsYou }
            if conversation.isStreaming { return .working }
        }
        if let chat = bot.chatID, liveKey == settings.connectionKey, let kind = live[chat] { return kind }
        #if DEBUG
        if let kind = demoBots[bot.name] { return kind }
        #endif
        if let worker = bot.workerActive, Date.now.timeIntervalSince(worker) < Self.workerLive { return .working }
        return nil
    }

    /// A bot's chat with something in it since it was last seen here. Kept on the phone, by the
    /// bot (its chat's id changes as Hermes condenses it), against the time its chat was last
    /// active: Hermes lists no read mark for a bot's chat.
    func isUnread(_ bot: HermesBot, open conversation: Conversation, settings: Settings = .shared) -> Bool {
        #if DEBUG
        if demoUnreadBots.contains(bot.name) { return true }
        #endif
        guard bot.chatID != nil else { return false }
        return Self.unread(server: nil, lastActive: bot.lastActive?.timeIntervalSince1970, seen: seen[Self.botsKey(settings)]?[bot.name],
                           isOpen: conversation.bot?.profile == bot.name, busy: kind(of: bot, open: conversation, settings: settings) != nil)
    }

    /// The bots as read: one seen for the first time counts as read up to its chat's last activity.
    func listed(_ bots: [HermesBot], settings: Settings = .shared) {
        let key = Self.botsKey(settings)
        let fresh = bots.filter { seen[key]?[$0.name] == nil }
        guard !fresh.isEmpty else { return }
        for bot in fresh { seen[key, default: [:]][bot.name] = bot.lastActive?.timeIntervalSince1970 ?? Date.now.timeIntervalSince1970 }
        save()
    }

    /// The bot's chat was on screen until now (opened, or left).
    func botSeen(_ name: String, settings: Settings = .shared) {
        mark(name, seenAt: Date.now.timeIntervalSince1970, key: Self.botsKey(settings))
    }

    /// A bot's row's Mark as Unread.
    func markUnread(bot name: String, settings: Settings = .shared) {
        mark(name, seenAt: 0, key: Self.botsKey(settings))
    }

    private static func botsKey(_ settings: Settings) -> String { "bots|" + settings.connectionKey }

    // MARK: - Group chats

    /// What a group chat's row shows of it: a bot at work in it, or one waiting on the person
    /// (Hermes's list of live sessions; where Hermes's gateway runs the room instead of the
    /// Dashboard, it isn't in that list, and the row shows neither).
    func kind(of room: GroupRoom, settings: Settings = .shared) -> Kind? {
        if let kind = demoRooms[room.id] { return kind }
        return liveKey == settings.connectionKey ? liveRooms[room.id] : nil
    }

    /// A group chat with something in it since it was last seen here: its latest event (a
    /// hosted room's number in its log, a Desktop one's time) past the one seen. Kept on the
    /// phone; Hermes keeps no read mark for a room.
    func isUnread(_ room: GroupRoom, isOpen: Bool, settings: Settings = .shared) -> Bool {
        if demoUnreadRooms.contains(room.id) { return true }
        guard !isOpen, kind(of: room, settings: settings) == nil, let mark = room.activityMark,
              let seen = seen[Self.roomsKey(settings)]?[room.id] else { return false }
        return seen == 0 || mark > seen
    }

    /// The group chats as listed: one seen for the first time counts as read up to now.
    func listed(_ rooms: [GroupRoom], settings: Settings = .shared) {
        let key = Self.roomsKey(settings)
        let fresh = rooms.filter { seen[key]?[$0.id] == nil && $0.activityMark != nil }
        guard !fresh.isEmpty else { return }
        for room in fresh { seen[key, default: [:]][room.id] = room.activityMark }
        save()
    }

    /// The group chat was on screen up to `latest` (its latest event seen there).
    func roomSeen(_ id: String, upTo latest: Double?, settings: Settings = .shared) {
        guard let latest else { return }
        let key = Self.roomsKey(settings)
        guard seen[key]?[id] != latest else { return }
        mark(id, seenAt: latest, key: key)
    }

    /// A group chat's row's Mark as Unread.
    func markUnread(room id: String, settings: Settings = .shared) {
        mark(id, seenAt: 0, key: Self.roomsKey(settings))
    }

    private static func roomsKey(_ settings: Settings) -> String { "rooms|" + settings.connectionKey }

    /// The run of a Hermes API turn the app let go of before it ended, if it is still noted.
    func run(of sessionID: String, settings: Settings = .shared) -> String? {
        guard let turn = left[settings.connectionKey]?[sessionID], Date.now.timeIntervalSince(turn.leftAt) <= Self.leftTurnsLast else { return nil }
        return turn.runID
    }

    /// The app saw that conversation's turn through: nothing more to ask after.
    func turnEnded(sessionID: String, settings: Settings = .shared) {
        let key = settings.connectionKey
        guard left[key]?[sessionID] != nil else { return }
        forget(sessionID, key: key)
        if liveKey == key { live[sessionID] = nil }
    }

    /// The list as loaded. On the Hermes API a conversation seen for the first time counts as
    /// read up to its last activity, so the first look at the list doesn't light all of it up.
    func listed(_ rows: [HermesSessionsAPI.SessionSummary], settings: Settings = .shared) {
        guard settings.transport == .hermesSessions else { return }
        let key = settings.connectionKey
        var marks = seen[key] ?? [:]
        let fresh = rows.filter { marks[$0.id] == nil }
        guard !fresh.isEmpty else { return }
        for row in fresh { marks[row.id] = row.last_active ?? row.started_at ?? Date.now.timeIntervalSince1970 }
        if marks.count > 1000 {
            // Kept for what the list holds: one that drops off and comes back starts as read.
            let listed = Set(rows.map(\.id))
            marks = marks.filter { listed.contains($0.key) }
        }
        seen[key] = marks
        save()
    }

    /// Everything in the conversation up to now has been seen: on the host (for every app) and,
    /// on the Hermes API, here. `onlyOnScreen`: not while Redde is in the background, as when a
    /// reply finishes with the phone locked.
    func markRead(_ sessionID: String, conversation: Conversation, onlyOnScreen: Bool = false, settings: Settings = .shared) {
        if onlyOnScreen, UIApplication.shared.applicationState != .active { return }
        guard settings.transport.hasLedger else { return }
        if settings.transport == .hermesSessions { mark(sessionID, seenAt: Date.now.timeIntervalSince1970, key: settings.connectionKey) }
        if let at = markedAt[sessionID], Date.now.timeIntervalSince(at) < 2 { return }
        markedAt[sessionID] = .now
        guard let backend = SessionBackend.current(conversation, settings: settings) else { return }
        Task { try? await backend.setUnread(sessionID, false) }
    }

    /// The row's Mark as Unread.
    func markUnread(_ sessionID: String, conversation: Conversation, settings: Settings = .shared) {
        guard settings.transport.hasLedger else { return }
        if settings.transport == .hermesSessions { mark(sessionID, seenAt: 0, key: settings.connectionKey) }
        markedAt[sessionID] = nil
        guard let backend = SessionBackend.current(conversation, settings: settings) else { return }
        Task { try? await backend.setUnread(sessionID, true) }
    }

    private func mark(_ sessionID: String, seenAt time: Double, key: String) {
        seen[key, default: [:]][sessionID] = time
        save()
    }

    private func forget(_ sessionID: String, key: String) {
        left[key]?[sessionID] = nil
        if left[key]?.isEmpty == true { left[key] = nil }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(left), forKey: Self.leftKey)
        defaults.set(try? encoder.encode(seen), forKey: Self.seenKey)
    }

    #if DEBUG
    /// Dev hook (`-echo.demoMarks`): the demo list's rows as marked, for screenshots.
    func showDemo(_ marks: [String: Kind], bots: [String: Kind] = [:], unreadBots: Set<String> = [], rooms: [String: Kind] = [:],
                  unreadRooms: Set<String> = [], settings: Settings = .shared) {
        demoRooms = rooms
        demoUnreadRooms = unreadRooms
        live = marks
        liveKey = settings.connectionKey
        demoBots = bots
        demoUnreadBots = unreadBots
    }

    private var demoBots: [String: Kind] = [:]
    private var demoRooms: [String: Kind] = [:]
    private var demoUnreadRooms: Set<String> = []
    private var demoUnreadBots: Set<String> = []
    #endif
}

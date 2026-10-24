import Foundation

/// Who has handed work to whom, for the Topology map's arrows (his ask 2026-10-22): a bot's message
/// to another (message_agent), found where it landed ("Message from Sol" in Ops's Bot Chat) or in
/// the answer that came back to the sender; and a kanban card one bot made for another (Sol's
/// claude_card for the claude bot). Hermes keeps no list of these, so they are read from each
/// bot's newest messages and the board.
nonisolated struct BotHandoff: Hashable, Sendable {
    enum Kind: String, Sendable { case message, card }
    var from: String
    var to: String
    var kind: Kind
}

nonisolated enum BotHandoffs {
    struct Tally: Equatable, Sendable {
        var count = 0
        var last: Date?

        mutating func add(_ when: Date?) {
            count += 1
            if let when, when > (last ?? .distantPast) { last = when }
        }
    }

    /// One row of a bot's chat: who said it ("user" for what came in), its words, when.
    struct Row: Sendable {
        var role: String
        var text: String
        var at: Date?
    }

    /// From `bot`'s chat: messages other bots sent it, and answers it got back from those it asked.
    static func reading(chatOf bot: String, rows: [Row], roster: [HermesBot]) -> [BotHandoff: Tally] {
        let known = Set(roster.map(\.name))
        var found: [BotHandoff: Tally] = [:]
        for row in rows where row.role == "user" {
            if let inbound = BotMessages.inbound(row.text) {
                let from = BotMessages.sender(name: inbound.name, handle: inbound.handle, roster: roster).profile
                if from != bot, known.contains(from) { found[BotHandoff(from: from, to: bot, kind: .message), default: Tally()].add(row.at) }
            } else if row.text.hasPrefix("[IMPORTANT: Background process") || row.text.hasPrefix("[Background process"),
                      let (delivered, _) = BotMessages.processNotice(row.text, title: nil, roster: roster),
                      delivered.kind == .reply, let to = delivered.profile, to != bot, known.contains(to) {
                found[BotHandoff(from: bot, to: to, kind: .message), default: Tally()].add(row.at)
            }
        }
        return found
    }

    /// Cards a bot made for another (not those made by hand, "dashboard", or by no one known).
    static func cards(_ tasks: [KanbanTask], roster: [HermesBot]) -> [BotHandoff: Tally] {
        let known = Set(roster.map(\.name))
        var found: [BotHandoff: Tally] = [:]
        for task in tasks {
            guard let from = task.createdBy, let to = task.assignee, from != to, known.contains(from), known.contains(to) else { continue }
            found[BotHandoff(from: from, to: to, kind: .card), default: Tally()].add(task.createdAt)
        }
        return found
    }

    static func merged(_ parts: [[BotHandoff: Tally]]) -> [BotHandoff: Tally] {
        var all: [BotHandoff: Tally] = [:]
        for part in parts {
            for (handoff, tally) in part {
                var kept = all[handoff] ?? Tally()
                kept.count += tally.count
                if let last = tally.last, last > (kept.last ?? .distantPast) { kept.last = last }
                all[handoff] = kept
            }
        }
        return all
    }

    /// A Dashboard message row's words: its text, or its text parts.
    static func text(of content: JSONValue?) -> String {
        if let text = content?.string { return text }
        return (content?.array ?? []).compactMap { $0.string ?? $0["text"]?.string }.joined(separator: "\n")
    }
}

/// The handoffs as last read, for the server and profile they are from: the map reads them again
/// when it opens, at most once a minute.
@MainActor
@Observable
final class BotHandoffStore {
    static let shared = BotHandoffStore()

    private(set) var handoffs: [BotHandoff: BotHandoffs.Tally] = [:]
    private(set) var key = ""
    private var readAt: Date?

    /// How many of a bot's newest messages are read for them.
    static let rowsRead = 150

    func refresh(_ bots: [HermesBot], settings: Settings = .shared, dashboard: HermesServeClient = .shared, force: Bool = false) async {
        let key = settings.connectionKey
        if !force, key == self.key, let readAt, Date.now.timeIntervalSince(readAt) < 60 { return }
        var parts: [[BotHandoff: BotHandoffs.Tally]] = []
        let apiOnly = BotDirectory.apiOnly(settings, dashboard: dashboard)
        for bot in bots {
            guard let chat = bot.chatID else { continue }
            if let rows = await Self.rows(of: bot, chat: chat, apiOnly: apiOnly, settings: settings, dashboard: dashboard) {
                parts.append(BotHandoffs.reading(chatOf: bot.name, rows: rows, roster: bots))
            }
        }
        if !apiOnly, KanbanClient.isAvailable, let board = try? await KanbanClient.board() {
            parts.append(BotHandoffs.cards(board.columns.flatMap(\.tasks), roster: bots))
        }
        guard key == settings.connectionKey else { return }
        handoffs = BotHandoffs.merged(parts)
        self.key = key
        readAt = .now
    }

    /// A bot's newest messages: by the Dashboard (read only, no chat opened for it), or on the
    /// Hermes API alone by its own key at /p/<profile>/.
    private static func rows(of bot: HermesBot, chat: String, apiOnly: Bool, settings: Settings, dashboard: HermesServeClient) async -> [BotHandoffs.Row]? {
        if apiOnly {
            guard let endpoint = settings.gatewayEndpoint(profile: bot.name) else { return nil }
            let api = HermesSessionsAPI(baseURL: endpoint.url, apiKey: endpoint.key, headers: settings.apiHeaders)
            guard let stored = try? await api.newestMessages(sessionID: chat, limit: rowsRead) else { return nil }
            return stored.map { BotHandoffs.Row(role: $0.role, text: $0.content?.text ?? "", at: $0.timestamp.map(Date.init(timeIntervalSince1970:))) }
        }
        let path = HermesServeClient.naming("api/sessions/\(chat)/messages?order=latest&limit=\(rowsRead)&inline_images=false",
                                            profile: bot.isDefault ? nil : bot.name)
        guard let json = try? await dashboard.restJSON("GET", path) else { return nil }
        return (json["messages"]?.array ?? []).map {
            BotHandoffs.Row(role: $0["role"]?.string ?? "", text: BotHandoffs.text(of: $0["content"]),
                            at: $0["timestamp"]?.number.map(Date.init(timeIntervalSince1970:)))
        }
    }
}

#if DEBUG
extension BotHandoffStore {
    /// The sample bots' handoffs (`-echo.demoBots`): Redde asks Scout and hands Fix-it a card;
    /// Scout asks Quill.
    func showDemo(key: String) {
        handoffs = [BotHandoff(from: "default", to: "scout", kind: .message): .init(count: 3, last: .now),
                    BotHandoff(from: "default", to: DevHooks.has("-echo.demoClaudeBot") ? "claude" : "fixit", kind: .card): .init(count: 1, last: .now),
                    BotHandoff(from: "scout", to: "writer", kind: .message): .init(count: 2, last: .now)]
        self.key = key
        readAt = .now
    }
}
#endif

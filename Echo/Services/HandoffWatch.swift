import Foundation
import Observation

/// A bot at work on what another bot asked of it (asked 2026-11-08: "When asking a first bot to do
/// something involving a second bot, I want to see something on screen of the first bot indicating
/// the second bot is working on the task … and switch over to the second bot's screen and see what
/// they're working on").
///
/// Hermes runs the asked bot's turn in a process of its own (`message_agent` → `hermes -p <bot>
/// chat -c "Bot Chat" -Q`), which neither the Dashboard's list of turns nor its socket reports. It
/// does write each round of tools to the bot's chat as it goes (0.22's `turn_tool_round`), so the
/// bot's newest messages are read every few seconds while someone is looking: the message that came
/// in, the steps since, and whether an answer has been written.
nonisolated enum Handoff {
    struct Progress: Equatable, Sendable {
        enum Phase: Equatable, Sendable { case working, answered }
        var phase: Phase
        /// The bot that asked, as the message names it.
        var from: String
        /// What it is doing now: its newest step's tool, as a person would say it.
        var step: String?
        /// How many steps it has taken.
        var steps: Int
        /// When the message came in, and when the chat last took anything.
        var asked: Date?
        var lastActive: Date?
    }

    /// A row of a bot's chat: who wrote it, its words, its tools' names, when.
    struct Row: Equatable, Sendable {
        var role: String
        var text: String
        var tools: [String] = []
        var at: Date?
    }

    /// How long a chat may go quiet in a hand-off before the bot is no longer taken to be at it.
    /// Long: Coder's work is Claude's, outside Hermes's own steps, and writes nothing to its chat
    /// until it answers.
    static let quiet: TimeInterval = 30 * 60

    /// The newest message another bot sent into this chat, from `since` on (a little before, for
    /// the two clocks), and what the bot did with it. Nil when there is none.
    static func progress(_ rows: [Row], since: Date? = nil, now: Date = .now) -> Progress? {
        let rows = rows.enumerated().sorted { ($0.element.at ?? .distantPast, $0.offset) < ($1.element.at ?? .distantPast, $1.offset) }.map(\.element)
        guard let start = rows.lastIndex(where: { $0.role == "user" && BotMessages.inbound($0.text) != nil }),
              let inbound = BotMessages.inbound(rows[start].text) else { return nil }
        if let since, let at = rows[start].at, at < since.addingTimeInterval(-120) { return nil }
        let after = rows[(start + 1)...]
        let tools = after.flatMap(\.tools)
        let last = after.last
        let answered = last.map { $0.role == "assistant" && $0.tools.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let active = after.compactMap(\.at).max() ?? rows[start].at
        if !answered, let active, now.timeIntervalSince(active) > quiet { return nil }
        return Progress(phase: answered ? .answered : .working, from: inbound.name, step: tools.last.map(step), steps: tools.count,
                        asked: rows[start].at, lastActive: active)
    }

    /// A tool's name as what the bot is doing: "Running a command", "Searching the web".
    static func step(_ tool: String) -> String {
        switch tool {
        case "terminal", "execute_code", "process": return String(localized: "Running a command", comment: "A bot at work for another bot: what it is doing now")
        case "web_search", "web_extract", "browser_navigate", "browser_snapshot", "browser_click", "browser_type":
            return String(localized: "Searching the web", comment: "A bot at work for another bot: what it is doing now")
        case "read_file", "search_files": return String(localized: "Reading files", comment: "A bot at work for another bot: what it is doing now")
        case "write_file", "patch": return String(localized: "Writing files", comment: "A bot at work for another bot: what it is doing now")
        case "message_agent": return String(localized: "Asking another bot", comment: "A bot at work for another bot: what it is doing now")
        case "delegate_task": return String(localized: "Handing part of it off", comment: "A bot at work for another bot: what it is doing now")
        case "memory", "session_search": return String(localized: "Checking its memory", comment: "A bot at work for another bot: what it is doing now")
        case "todo": return String(localized: "Planning the steps", comment: "A bot at work for another bot: what it is doing now")
        default:
            let words = tool.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "mcp ", with: "")
            return String(localized: "Using \(words)", comment: "A bot at work for another bot: the tool it is using now")
        }
    }

    /// Tools that hand work to another bot as a kanban card: Hermes's own, and the claude-code
    /// plugin's claude_card (Sol → Coder), which makes one through it.
    static let cardTools: Set<String> = ["kanban_create", "claude_card"]

    /// The cards a reply made for other bots: each card's id where the call or the reply names it
    /// ("t_10e4a128"), its assignee where the call names one, and when it was made.
    static func cards(in message: Message) -> [(id: String?, assignee: String?, at: Date)] {
        var seen = Set<String>()
        var found: [(id: String?, assignee: String?, at: Date)] = []
        let calls = message.tools.filter { cardTools.contains($0.name) && $0.status != .failed }
        for (n, tool) in calls.enumerated() {
            let named = [tool.output, tool.preview].compactMap { $0 }.lazy.compactMap(taskID).first
                // The reply names the card when the call's own answer isn't here: the only one, or in order.
                ?? (message.text.matches(of: taskPattern).dropFirst(n).first.map { String($0.output) })
            if let named, !seen.insert(named).inserted { continue }
            let assignee = tool.args?.firstMatch(of: /(?m)^assignee: @?([^\s]+)/).map { String($0.output.1) }
                ?? (tool.name == "claude_card" ? "claude" : nil)
            found.append((named, assignee, tool.startedAt ?? message.createdAt))
        }
        return found
    }

    private static var taskPattern: Regex<Substring> { /\bt_[0-9a-f]{6,}\b/ }

    static func taskID(_ text: String) -> String? {
        text.firstMatch(of: taskPattern).map { String($0.output) }
    }

    /// The bots a reply handed work to with message_agent, by what each call named: the target,
    /// and when the call was made.
    static func targets(in message: Message) -> [(target: String, at: Date)] {
        var seen = Set<String>()
        return message.tools.compactMap { tool in
            guard tool.name == "message_agent", tool.status != .failed,
                  let target = tool.args?.firstMatch(of: /(?m)^target: @?([^\s]+)/)?.output.1 else { return nil }
            let name = String(target)
            guard seen.insert(name.lowercased()).inserted else { return nil }
            return (name, tool.startedAt ?? message.createdAt)
        }
    }
}

/// Reads the chats of bots someone is looking at a hand-off of, every few seconds, while they are.
@MainActor @Observable
final class HandoffWatch {
    static let shared = HandoffWatch()

    /// What each bot's chat said at its last reading, by profile.
    private(set) var progress: [String: Handoff.Progress] = [:]
    /// When each bot's chat last took anything, so a chat open here is read again only when it moved.
    private(set) var stamp: [String: Date] = [:]
    @ObservationIgnored private var lookers: [String: Int] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var rosterRead: Date?
    #if DEBUG
    @ObservationIgnored var demo = false
    #endif

    static let every: Duration = .seconds(4)

    /// Someone is looking at `profile`'s hand-off: read its chat until they stop (`stop`). `eager`
    /// while one was just made: read often until it is answered. Otherwise often only while the bot
    /// is at it, and now and then to see if it starts.
    func start(_ profile: String, eager: Bool = false) {
        lookers[profile, default: 0] += 1
        if eager { eagerFor[profile, default: 0] += 1 }
        nextRead[profile] = .now
        run()
    }

    private func run() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readDue()
                await self?.readCards()
                try? await Task.sleep(for: Self.every)
            }
        }
    }

    private func idleNow() {
        if lookers.isEmpty, cardLookers.isEmpty { loop?.cancel(); loop = nil }
    }

    // MARK: Cards

    /// Cards someone is looking at the hand-off of (`kanban_create`, `claude_card`), by id, as last read.
    private(set) var cards: [String: KanbanTask] = [:]
    @ObservationIgnored private var cardLookers: [String: Int] = [:]
    @ObservationIgnored private var cardNext: [String: Date] = [:]
    /// Cards found on the board for a call that named none, by the call's time and assignee.
    private(set) var foundCards: [String: String] = [:]

    func startCard(_ id: String) {
        cardLookers[id, default: 0] += 1
        cardNext[id] = .now
        run()
    }

    func stopCard(_ id: String) {
        cardLookers[id, default: 1] -= 1
        if cardLookers[id] ?? 0 <= 0 { cardLookers[id] = nil; cardNext[id] = nil }
        idleNow()
    }

    /// The card a call made when neither it nor the reply named one: the board's card for
    /// `assignee` made nearest `at`, within two minutes. Read once per call.
    func findCard(assignee: String?, at: Date) async -> String? {
        let key = "\(assignee ?? "")|\(Int(at.timeIntervalSince1970))"
        if let found = foundCards[key] { return found }
        guard KanbanClient.isAvailable, let board = try? await KanbanClient.board() else { return nil }
        let near = board.columns.flatMap(\.tasks).filter { task in
            guard let made = task.createdAt, abs(made.timeIntervalSince(at)) < 120 else { return false }
            return assignee == nil || task.assignee == assignee
        }
        guard let card = near.min(by: { abs($0.createdAt!.timeIntervalSince(at)) < abs($1.createdAt!.timeIntervalSince(at)) }) else { return nil }
        foundCards[key] = card.id
        cards[card.id] = card
        return card.id
    }

    /// A card is read every few seconds while it waits or is worked on, and now and then once it is
    /// done (it may be moved back).
    private func readCards() async {
        #if DEBUG
        if demo { return }
        #endif
        guard KanbanClient.isAvailable else { return }
        for id in cardLookers.keys where (cardNext[id] ?? .distantPast) <= .now {
            let settled = ["done", "archived"].contains(cards[id]?.status ?? "")
            cardNext[id] = .now.addingTimeInterval(settled ? 60 : 5)
            if let (task, _, _) = try? await KanbanClient.task(id) { cards[id] = task }
        }
    }

    func stop(_ profile: String, eager: Bool = false) {
        lookers[profile, default: 1] -= 1
        if lookers[profile] ?? 0 <= 0 { lookers[profile] = nil; nextRead[profile] = nil }
        if eager {
            eagerFor[profile, default: 1] -= 1
            if eagerFor[profile] ?? 0 <= 0 { eagerFor[profile] = nil }
        }
        idleNow()
    }

    @ObservationIgnored private var eagerFor: [String: Int] = [:]
    @ObservationIgnored private var nextRead: [String: Date] = [:]
    /// How often a bot that isn't at it is looked at.
    static let idle: TimeInterval = 20

    private func readDue() async {
        #if DEBUG
        if demo { return }
        #endif
        guard !lookers.isEmpty else { return }
        let settings = Settings.shared
        let directory = BotDirectory.shared
        // A bot's chat id changes when Hermes condenses it, and a bot asked for the first time has
        // one only after: the roster is read again now and then while watching.
        if rosterRead.map({ Date.now.timeIntervalSince($0) > 30 }) ?? true {
            rosterRead = .now
            _ = try? await directory.refresh()
        }
        let bots = directory.bots(for: settings.connectionKey)
        for profile in lookers.keys where (nextRead[profile] ?? .distantPast) <= .now {
            let quick = eagerFor[profile] != nil && progress[profile]?.phase != .answered || progress[profile]?.phase == .working
            nextRead[profile] = .now.addingTimeInterval(quick ? 3.5 : Self.idle)
            guard let bot = bots.first(where: { $0.name == profile }), let chat = bot.chatID,
                  let rows = await BotHandoffStore.rows(of: bot, chat: chat, limit: 40) else { continue }
            let read = rows.map { Handoff.Row(role: $0.role, text: $0.text, tools: $0.tools, at: $0.at) }
            progress[profile] = Handoff.progress(read)
            if let newest = read.compactMap(\.at).max(), stamp[profile] != newest { stamp[profile] = newest }
        }
    }

    /// The profile a message_agent target names on this server ("hermes" is the main agent).
    static func profile(named target: String) -> HermesBot? {
        let bots = BotDirectory.shared.bots(for: Settings.shared.connectionKey)
        let ref = BotMessages.sender(name: target, handle: target.lowercased(), roster: bots)
        return bots.first { $0.name == ref.profile }
    }
}

#if DEBUG
extension HandoffWatch {
    /// `-echo.demoHandoff` (with `-echo.demoBots -echo.demoMarks`): Scout at work on what Quill
    /// asked, for the row under Quill's reply, and Quill at work for Scout, for the strip over its
    /// chat; `-echo.demoHandoff answered`: Scout done.
    func showDemo(_ value: String?) {
        demo = true
        let answered = value == "answered"
        progress["scout"] = Handoff.Progress(phase: answered ? .answered : .working, from: "Quill", step: Handoff.step("web_search"), steps: 3,
                                             asked: .now.addingTimeInterval(-40), lastActive: .now.addingTimeInterval(-3))
        var card = KanbanTask(.object(["id": .string("t_10e4a128"), "title": .string("Make the lookout and paper bots"),
                                       "status": .string(answered ? "done" : "running"), "assignee": .string("fixit")]))!
        card.startedAt = .now.addingTimeInterval(-260)
        card.latestSummary = answered ? "Both profiles made; waiting for your approval." : "Writing paper's toolset: Paperless, files, no terminal."
        cards[card.id] = card
        progress["writer"] = Handoff.Progress(phase: .working, from: "Scout", step: Handoff.step("read_file"), steps: 1,
                                              asked: .now.addingTimeInterval(-20), lastActive: .now)
    }
}
#endif

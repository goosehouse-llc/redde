import Foundation

/// What the agent has put on its widget (`phone_widget_set`): a title and a few lines of its own
/// choosing, from a moment and perhaps until one. Several are kept, so the agent can set one for
/// now and others for later in the day and the widget moves on by itself, with Redde closed.
/// What shows is the one that started last and hasn't run out; when that runs out, the one
/// before it shows again.
///
/// Written by the app when the agent's tool runs in a turn it is following, and by the
/// notification extension when the plugin sent it as a note because the phone wasn't.
nonisolated struct AgentBoard: Codable, Sendable, Equatable {
    static let widgetKind = "com.goosehouse.echo.board"
    private static let key = "agentBoard"
    /// How many are kept: the one showing and a day's worth to come.
    static let most = 12
    static let titleLimit = 60
    static let textLimit = 300

    var title: String
    var text: String
    /// From when it shows.
    var from: Date
    /// Until when it holds; nil for until something replaces it.
    var until: Date?

    init(title: String, text: String, from: Date, until: Date? = nil) {
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.titleLimit))
        self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.textLimit))
        self.from = from
        self.until = until
    }

    var isEmpty: Bool { title.isEmpty && text.isEmpty }

    func holds(at moment: Date) -> Bool { from <= moment && (until.map { $0 > moment } ?? true) }

    /// Everything kept, earliest start first, whether or not it has run out.
    static func all(in defaults: UserDefaults? = NeedsYou.shared) -> [AgentBoard] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return ((try? JSONDecoder().decode([AgentBoard].self, from: data)) ?? []).sorted { $0.from < $1.from }
    }

    /// The one on the widget at a moment.
    static func showing(at moment: Date, among boards: [AgentBoard]) -> AgentBoard? {
        boards.filter { $0.holds(at: moment) }.max { $0.from < $1.from }
    }

    /// The moments after `now` at which the widget has to change: something starts, or runs out.
    static func turns(after now: Date, among boards: [AgentBoard]) -> [Date] {
        Array(Set(boards.flatMap { [$0.from, $0.until].compactMap { $0 } }.filter { $0 > now })).sorted()
    }

    /// Keeps one more, in place of any that starts at the same moment. False when what is kept
    /// didn't change.
    @discardableResult
    static func put(_ board: AgentBoard, at now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        let before = all(in: defaults)
        let kept = pruned(before.filter { abs($0.from.timeIntervalSince(board.from)) >= 1 } + [board], at: now)
        // Too many: the furthest off go, since the agent can set those again nearer the time.
        return save(Array(kept.prefix(most)), over: before, in: defaults)
    }

    /// Without what can never show again: what has run out, and what started before one that
    /// has itself started and has no end. Earliest start first.
    static func pruned(_ boards: [AgentBoard], at now: Date) -> [AgentBoard] {
        let covered = boards.filter { $0.until == nil && $0.from <= now }.map(\.from).max()
        return boards.filter { board in
            if let end = board.until, end <= now { return false }
            if let covered, board.from < covered { return false }
            return true
        }.sorted { $0.from < $1.from }
    }

    /// Takes everything off, what was set for later included. False when there was nothing.
    @discardableResult
    static func clear(in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        save([], over: all(in: defaults), in: defaults)
    }

    /// A note the plugin sent for the widget: what it says is put up, or with nothing in it,
    /// everything is taken off. False for any other note, and when nothing changed.
    @discardableResult
    static func take(_ pushed: PushNote, at now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        guard pushed.kind == .widget else { return false }
        // From when: the moment the agent named, else when it was written, which may be a
        // while before the phone heard of it.
        let written = pushed.at.map(Date.init(timeIntervalSince1970:)) ?? now
        let board = AgentBoard(title: pushed.t ?? "", text: pushed.b ?? "",
                               from: pushed.f.flatMap { DeviceDates.parse($0) } ?? min(written, now),
                               until: pushed.u.flatMap { DeviceDates.parse($0) })
        if board.isEmpty { return clear(in: defaults) }
        if let end = board.until, end <= now { return false }   // it arrived after it had run out
        return put(board, at: now, in: defaults)
    }

    private static func save(_ boards: [AgentBoard], over before: [AgentBoard], in defaults: UserDefaults?) -> Bool {
        guard boards != before else { return false }
        if boards.isEmpty { defaults?.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(boards) { defaults?.set(data, forKey: key) }
        return true
    }
}

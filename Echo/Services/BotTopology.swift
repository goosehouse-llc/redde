import CoreGraphics
import Foundation

/// The Bots section's map (his ask 2026-10-22, after another Hermes client's "Topology"): you at the
/// top, your group chats under you, every bot under them, and on the right the model each bot runs
/// on, with lines for who talks to whom. This is only where things go; `BotTopologyView` draws it.
///
/// You talk to every bot in its own chat: a line from you down the left-most lane into each. A
/// group chat has a lane of its own, into each of its bots. A bot's line to its model leaves its
/// right side; bots on one model share its box, and bots that do their work through Claude Code
/// have a second line, to its box. A bot that has handed work to another (a message, a kanban
/// card) has an arrow to it, out of its right side and round into the other's, in the gap before
/// the models.
nonisolated struct BotTopology: Equatable {
    struct Bot: Equatable {
        var name: String
        var model: String?
        var claudeCode = false
    }

    struct Room: Equatable {
        var id: String
        var members: [String]
    }

    struct Handoff: Equatable {
        var from: String
        var to: String
    }

    enum Node: Hashable {
        case you
        case room(String)
        case bot(String)
        case model(String)
        case claudeCode
    }

    enum Link: Equatable {
        /// You and a bot's own chat, or you and a group chat.
        case you(to: Node)
        case room(String, bot: String)
        case model(String, bot: String)
        case claudeCode(bot: String)
        case handoff(from: String, to: String)
    }

    /// A line's points: corners of a run of straight lines, or a curve's start, two control
    /// points and end. A handoff's last two points give the way its arrow points.
    struct Line: Equatable {
        var link: Link
        var points: [CGPoint]
        var isCurve = false
    }

    private(set) var frames: [Node: CGRect] = [:]
    private(set) var lines: [Line] = []
    private(set) var size: CGSize = .zero
    /// The boxes on the right, top to bottom: the models, and Claude Code.
    private(set) var targets: [Node] = []

    static let rowHeight: CGFloat = 56
    static let rowGap: CGFloat = 16
    static let youSize = CGSize(width: 104, height: 40)
    /// Between the lanes on the left, and between the last lane and the boxes.
    static let laneGap: CGFloat = 8
    static let laneToBoxes: CGFloat = 14
    /// Between a bot and its model, and how much wider for each step of the handoffs' arrows.
    static let columnGap: CGFloat = 28
    static let handoffStep: CGFloat = 9
    static let handoffLevels = 4
    /// How far apart the lines coming into one box are.
    static let entrySpread: CGFloat = 28
    /// Where a handoff leaves a bot and comes into one, above and below its middle.
    static let handoffOffset: CGFloat = 17

    /// The lanes' x: you first, then each group chat.
    static func lane(_ index: Int) -> CGFloat { 4 + CGFloat(index) * laneGap }

    init(bots: [Bot], rooms: [Room], handoffs: [Handoff] = [], width: CGFloat) {
        let width = max(width, 280)
        let left = Self.lane(rooms.count) + Self.laneToBoxes
        var y: CGFloat = 0

        let you = CGRect(origin: CGPoint(x: max(left, ((width - Self.youSize.width) / 2).rounded()), y: 0), size: Self.youSize)
        frames[.you] = you
        y = you.maxY + Self.rowGap

        for room in rooms {
            frames[.room(room.id)] = CGRect(x: left + 24, y: y, width: min(width - left - 24, 260), height: Self.rowHeight)
            y += Self.rowHeight + Self.rowGap
        }

        // Each handoff a step out from the bots, the shortest nearest; ones that overlap on
        // different steps.
        let index = Dictionary(bots.enumerated().map { ($0.element.name, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let arrows = handoffs.filter { $0.from != $0.to && index[$0.from] != nil && index[$0.to] != nil }
            .sorted { abs(index[$0.from]! - index[$0.to]!) < abs(index[$1.from]! - index[$1.to]!) }
        var levels: [Int] = []
        var taken: [(range: ClosedRange<Int>, level: Int)] = []
        for arrow in arrows {
            let a = index[arrow.from]!, b = index[arrow.to]!
            let range = min(a, b) ... max(a, b)
            let busy = Set(taken.filter { $0.range.overlaps(range) }.map(\.level))
            let level = (0 ..< Self.handoffLevels).first { !busy.contains($0) } ?? Self.handoffLevels - 1
            levels.append(level)
            taken.append((range, level))
        }
        let gap = Self.columnGap + (arrows.isEmpty ? 0 : Self.handoffStep * CGFloat((levels.max() ?? 0) + 1))

        let hasTargets = bots.contains { $0.model?.isEmpty == false || $0.claudeCode }
        let botWidth = hasTargets ? ((width - left - gap) * 0.54).rounded(.down) : width - left
        let firstBot = y
        for bot in bots {
            frames[.bot(bot.name)] = CGRect(x: left, y: y, width: botWidth, height: Self.rowHeight)
            y += Self.rowHeight + Self.rowGap
        }

        // Each box on the right level with the middle of its bots, pushed down where boxes would
        // overlap.
        let targetX = left + botWidth + gap
        var users: [Node: [String]] = [:]
        var order: [Node] = []
        for bot in bots {
            var wanted: [Node] = []
            if let model = bot.model, !model.isEmpty { wanted.append(.model(model)) }
            if bot.claudeCode { wanted.append(.claudeCode) }
            for node in wanted {
                if users[node] == nil { order.append(node) }
                users[node, default: []].append(bot.name)
            }
        }
        let middles = order.map { node -> CGFloat in
            let ys = users[node, default: []].compactMap { frames[.bot($0)]?.midY }
            return ys.reduce(0, +) / CGFloat(max(ys.count, 1))
        }
        targets = order.indices.sorted { (middles[$0], $0) < (middles[$1], $1) }.map { order[$0] }
        var nextTop = firstBot
        for node in targets {
            let middle = middles[order.firstIndex(of: node)!]
            let top = max((middle - Self.rowHeight / 2).rounded(), nextTop)
            frames[node] = CGRect(x: targetX, y: top, width: width - targetX, height: Self.rowHeight)
            nextTop = top + Self.rowHeight + Self.rowGap
        }

        // The lines. Into a bot: yours, then each of its group chats', spread down its left side.
        let start = CGPoint(x: you.minX, y: you.midY)
        func entries(_ count: Int, into box: CGRect) -> [CGFloat] {
            guard count > 1 else { return [box.midY] }
            let spread = min(Self.entrySpread, box.height - 16)
            return (0 ..< count).map { box.midY - spread / 2 + spread * CGFloat($0) / CGFloat(count - 1) }
        }
        for room in rooms {
            guard let box = frames[.room(room.id)] else { continue }
            let into = box.midY - 6
            lines.append(Line(link: .you(to: .room(room.id)), points: [
                start, CGPoint(x: Self.lane(0), y: start.y), CGPoint(x: Self.lane(0), y: into), CGPoint(x: box.minX, y: into)]))
        }
        for bot in bots {
            guard let box = frames[.bot(bot.name)] else { continue }
            let inRooms = rooms.enumerated().filter { $0.element.members.contains(bot.name) }
            let ys = entries(1 + inRooms.count, into: box)
            lines.append(Line(link: .you(to: .bot(bot.name)), points: [
                start, CGPoint(x: Self.lane(0), y: start.y), CGPoint(x: Self.lane(0), y: ys[0]), CGPoint(x: box.minX, y: ys[0])]))
            for (n, (index, room)) in inRooms.enumerated() {
                guard let roomBox = frames[.room(room.id)] else { continue }
                let lane = Self.lane(index + 1), out = roomBox.midY + 6, into = ys[n + 1]
                lines.append(Line(link: .room(room.id, bot: bot.name), points: [
                    CGPoint(x: roomBox.minX, y: out), CGPoint(x: lane, y: out), CGPoint(x: lane, y: into), CGPoint(x: box.minX, y: into)]))
            }
        }
        // Out of a bot to the right: its model's line, and Claude Code's under it; into each box,
        // one line from each of its bots, top to bottom.
        for node in targets {
            guard let box = frames[node] else { continue }
            let from = bots.filter { bot in
                switch node {
                case let .model(model): bot.model == model
                default: bot.claudeCode
                }
            }
            for (bot, into) in zip(from, entries(from.count, into: box)) {
                guard let botBox = frames[.bot(bot.name)] else { continue }
                let both = bot.model?.isEmpty == false && bot.claudeCode
                let out = both ? botBox.midY + (node == .claudeCode ? 6 : -6) : botBox.midY
                let a = CGPoint(x: botBox.maxX, y: out), b = CGPoint(x: box.minX, y: into)
                let pull = max(Self.columnGap, (b.x - a.x) / 2)
                let link: Link = if case let .model(model) = node { .model(model, bot: bot.name) } else { .claudeCode(bot: bot.name) }
                lines.append(Line(link: link, points: [a, CGPoint(x: a.x + pull, y: a.y), CGPoint(x: b.x - pull, y: b.y), b], isCurve: true))
            }
        }
        // The handoffs: out of the sender above its middle, round, into the other below its middle.
        for (arrow, level) in zip(arrows, levels) {
            guard let a = frames[.bot(arrow.from)], let b = frames[.bot(arrow.to)] else { continue }
            let x = a.maxX + Self.handoffStep * CGFloat(level + 1) + 4
            let out = a.midY - Self.handoffOffset, into = b.midY + Self.handoffOffset
            lines.append(Line(link: .handoff(from: arrow.from, to: arrow.to), points: [
                CGPoint(x: a.maxX, y: out), CGPoint(x: x, y: out), CGPoint(x: x, y: into), CGPoint(x: b.maxX, y: into)]))
        }

        size = CGSize(width: width, height: frames.values.map(\.maxY).max() ?? 0)
    }
}

extension HermesBot {
    /// Does its work through Claude Code (the map's Claude Code box): says so in what it does,
    /// as the butler setup's coding and research bots do ("does each card with Claude Code"), or
    /// is called Claude Code; or is the profile "claude" on a model that isn't Claude's, which
    /// can only be driving Claude Code.
    var worksThroughClaudeCode: Bool {
        if description.localizedCaseInsensitiveContains("claude code") { return true }
        let names = [name, title ?? "", displayName ?? ""].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        if names.contains(where: { $0 == "claude code" || $0 == "claude-code" || $0 == "claudecode" }) { return true }
        return name.lowercased() == "claude" && !(model ?? "").lowercased().contains("claude")
    }
}

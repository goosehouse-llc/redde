import CoreGraphics
import Testing
@testable import Echo

/// The Topology map's layout (`BotTopology`): nothing overlaps, every line starts and ends on its
/// boxes, bots on one model share it.
struct BotTopologyTests {
    private let bots = [
        BotTopology.Bot(name: "default", model: "qwen"), BotTopology.Bot(name: "scout", model: "qwen"),
        BotTopology.Bot(name: "writer", model: "anthropic/claude-sonnet-4.5"), BotTopology.Bot(name: "fixit", model: nil),
    ]
    private let rooms = [BotTopology.Room(id: "hike", members: ["default", "scout", "writer"]),
                         BotTopology.Room(id: "house", members: ["fixit", "default"])]

    @Test func boxesNeverOverlapAndFitTheWidth() {
        for width in [280.0, 361, 700] {
            let map = BotTopology(bots: bots, rooms: rooms, width: width)
            let boxes = Array(map.frames.values)
            for (i, a) in boxes.enumerated() {
                #expect(a.minX >= 0 && a.maxX <= width + 0.5, "box \(a) outside \(width)")
                for b in boxes[(i + 1)...] { #expect(!a.intersects(b), "\(a) overlaps \(b) at \(width)") }
            }
            #expect(map.size.height == boxes.map(\.maxY).max())
        }
    }

    @Test func linesJoinTheirBoxes() throws {
        let map = BotTopology(bots: bots, rooms: rooms, width: 361)
        let you = try #require(map.frames[.you])
        for line in map.lines {
            let first = try #require(line.points.first), last = try #require(line.points.last)
            switch line.link {
            case let .you(to: node):
                #expect(first == CGPoint(x: you.minX, y: you.midY))
                let box = try #require(map.frames[node])
                #expect(last.x == box.minX && box.minY ... box.maxY ~= last.y)
            case let .room(id, bot):
                let room = try #require(map.frames[.room(id)]), box = try #require(map.frames[.bot(bot)])
                #expect(first.x == room.minX && last.x == box.minX && box.minY ... box.maxY ~= last.y)
            case let .model(model, bot):
                let box = try #require(map.frames[.model(model)]), from = try #require(map.frames[.bot(bot)])
                #expect(line.isCurve && first == CGPoint(x: from.maxX, y: from.midY) && last.x == box.minX)
            case .claudeCode, .handoff:
                Issue.record("no Claude Code or handoffs were asked for")
            }
        }
        // You into every bot and every group chat; each group chat into each of its bots.
        #expect(map.lines.filter { if case .you = $0.link { true } else { false } }.count == bots.count + rooms.count)
        #expect(map.lines.filter { if case .room = $0.link { true } else { false } }.count == 5)
    }

    @Test func botsOnOneModelShareItAndOneWithoutHasNone() {
        let map = BotTopology(bots: bots, rooms: [], width: 361)
        #expect(map.targets == [.model("qwen"), .model("anthropic/claude-sonnet-4.5")])
        #expect(map.lines.filter { $0.link == .model("qwen", bot: "default") || $0.link == .model("qwen", bot: "scout") }.count == 2)
        #expect(!map.lines.contains { if case .model(_, "fixit") = $0.link { true } else { false } })
        // Two lines into one box come in apart.
        let ends = map.lines.filter { if case .model("qwen", _) = $0.link { true } else { false } }.compactMap(\.points.last)
        #expect(Set(ends.map(\.y)).count == 2)
    }

    @Test func aBotInGroupChatsHasEachLineComeInApart() throws {
        let map = BotTopology(bots: bots, rooms: rooms, width: 361)
        let into = map.lines.filter {
            switch $0.link {
            case .you(to: .bot("default")), .room(_, "default"): true
            default: false
            }
        }.compactMap(\.points.last)
        #expect(into.count == 3 && Set(into.map(\.y)).count == 3)
    }

    @Test func noBotsLeavesYouAlone() {
        let map = BotTopology(bots: [], rooms: [], width: 361)
        #expect(map.frames.keys.map { $0 } == [.you] && map.lines.isEmpty)
    }

    /// Handoffs: out of the sender's right side, into the other's; ones that overlap a step apart,
    /// and the column wider for them.
    @Test func handoffsGoRightSideToRightSideOnTheirOwnSteps() throws {
        let arrows = [BotTopology.Handoff(from: "default", to: "fixit"), BotTopology.Handoff(from: "default", to: "scout"),
                      BotTopology.Handoff(from: "scout", to: "default"), BotTopology.Handoff(from: "ghost", to: "scout"),
                      BotTopology.Handoff(from: "writer", to: "writer")]
        let map = BotTopology(bots: bots, rooms: [], handoffs: arrows, width: 361)
        let plain = BotTopology(bots: bots, rooms: [], width: 361)
        let drawn = map.lines.filter { if case .handoff = $0.link { true } else { false } }
        #expect(drawn.count == 3, "one not on the map and one to itself are left out")
        let qwen = try #require(map.frames[.model("qwen")])
        let mainBox = try #require(map.frames[.bot("default")]), plainBox = try #require(plain.frames[.bot("default")])
        for line in drawn {
            guard case let .handoff(from, to) = line.link else { continue }
            let a = try #require(map.frames[.bot(from)]), b = try #require(map.frames[.bot(to)])
            #expect(line.points.first?.x == a.maxX && line.points.last?.x == b.maxX)
            #expect(line.points[1].x > a.maxX && line.points[1].x < qwen.minX)
        }
        #expect(Set(drawn.map { $0.points[1].x }).count == 3, "overlapping arrows share a step")
        #expect(mainBox.width < plainBox.width)
        let boxes = Array(map.frames.values)
        for (i, a) in boxes.enumerated() { for b in boxes[(i + 1)...] { #expect(!a.intersects(b)) } }
    }

    @Test func claudeCodeHasItsOwnBoxBesideTheBotsModel() throws {
        var bots = bots
        bots.append(BotTopology.Bot(name: "claude", model: "qwen", claudeCode: true))
        let map = BotTopology(bots: bots, rooms: [], width: 361)
        #expect(map.targets.contains(.claudeCode))
        let lines = map.lines.filter { $0.link == .claudeCode(bot: "claude") || $0.link == .model("qwen", bot: "claude") }
        #expect(lines.count == 2)
        #expect(Set(lines.compactMap { $0.points.first?.y }).count == 2, "its two lines leave it apart")
    }

    @Test func aClaudeCodeBotIsKnownByWhatItDoes() {
        #expect(HermesBot(name: "claude", title: "Claude", description: "Coding worker: does each card with Claude Code.", model: "qwen").worksThroughClaudeCode)
        #expect(HermesBot(name: "research", description: "Researcher: answers through Claude Code, with sources.").worksThroughClaudeCode)
        #expect(HermesBot(name: "claude", model: "qwen3.6").worksThroughClaudeCode)
        #expect(!HermesBot(name: "claude", model: "anthropic/claude-sonnet-4.5").worksThroughClaudeCode, "a bot on a Claude model")
        #expect(!HermesBot(name: "default", isDefault: true, model: "qwen").worksThroughClaudeCode)
        #expect(!HermesBot(name: "ops", description: "Runs the servers").worksThroughClaudeCode)
    }

    /// Read from a bot's chat: a message another bot sent it, and an answer it got back from one it asked.
    @Test func handoffsAreReadFromChatsAndCards() throws {
        let roster = [HermesBot(name: "default", isDefault: true), HermesBot(name: "ops", title: "Ops"), HermesBot(name: "claude", title: "Claude")]
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let inOps = BotHandoffs.reading(chatOf: "ops", rows: [
            .init(role: "user", text: "Message from 🤖 Sol (@hermes): Sam wants to know the Unraid space.", at: when),
            .init(role: "user", text: "Message from 🤖 Sol (@hermes): And the CPU temperature.", at: when.addingTimeInterval(60)),
            .init(role: "assistant", text: "Message from 🤖 Sol (@hermes): not a delivery", at: when),
            .init(role: "user", text: "How much space is left?", at: when),
            .init(role: "user", text: "Message from 🤖 Stranger (@nobody): hi", at: when),
        ], roster: roster)
        #expect(inOps == [BotHandoff(from: "default", to: "ops", kind: .message): .init(count: 2, last: when.addingTimeInterval(60))])

        let notice = "[IMPORTANT: Background process proc_1 exited (exit code 0).\nCommand: python3 tools/bot_mode_dm.py --run-delivery x -p ops chat --in ~ -c \"Bot Chat\"\nOutput:\nThe array has 4.1 TB free.]"
        let inSol = BotHandoffs.reading(chatOf: "default", rows: [.init(role: "user", text: notice, at: when)], roster: roster)
        #expect(inSol.keys.map { $0 } == [BotHandoff(from: "default", to: "ops", kind: .message)])

        var card = try #require(KanbanTask(.object(["id": .string("t_1"), "title": .string("README"), "assignee": .string("claude"),
                                                     "created_by": .string("default"), "created_at": .number(1_800_000_000)])))
        var byHand = card
        byHand.createdBy = "dashboard"
        card.id = "t_2"
        let cards = BotHandoffs.cards([card, byHand], roster: roster)
        #expect(cards == [BotHandoff(from: "default", to: "claude", kind: .card): .init(count: 1, last: when)])
        let all = BotHandoffs.merged([inOps, inSol, cards])
        #expect(all[BotHandoff(from: "default", to: "ops", kind: .message)]?.count == 3)
    }

    @Test func aDashboardRowsTextIsItsTextOrItsParts() {
        #expect(BotHandoffs.text(of: .string("hi")) == "hi")
        #expect(BotHandoffs.text(of: .array([.object(["type": .string("text"), "text": .string("a")]), .string("b")])) == "a\nb")
    }

    @Test func aModelLosesItsProvider() {
        #expect(BotTopologyView.shortName("anthropic/claude-sonnet-4.5") == "claude-sonnet-4.5")
        #expect(BotTopologyView.shortName("qwen3.6-35b-a3b") == "qwen3.6-35b-a3b")
    }
}

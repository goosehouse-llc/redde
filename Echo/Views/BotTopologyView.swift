import SwiftUI

/// The Bots section's map (`BotTopology`): you, your group chats, your bots with what each is doing,
/// and the models they run on. A bot or group chat opens its chat. Kept up to date by the chat
/// list's own watch under it (the bots every fifteen seconds, what each is doing every few).
struct BotTopologyView: View {
    var openBot: (HermesBot) -> Void
    var openRoom: (GroupRoom) -> Void

    @Environment(Conversation.self) private var conversation
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var directory = BotDirectory.shared
    @State private var groups = GroupDirectory.shared
    @State private var activity = ChatActivity.shared
    @State private var handoffStore = BotHandoffStore.shared

    private var bots: [HermesBot] {
        directory.key == settings.connectionKey ? directory.roster?.listed ?? [] : []
    }

    /// Group chats are the Dashboard's: none on the Hermes API alone.
    private var rooms: [GroupRoom] {
        !BotDirectory.apiOnly(settings) && groups.key == settings.connectionKey && groups.supported ? groups.rooms : []
    }

    private var faces: [String: BotFace] { directory.roster?.faces ?? [:] }

    /// Who has handed work to whom, one arrow a pair (messages and cards alike).
    private var handoffs: [BotTopology.Handoff] {
        guard handoffStore.key == settings.connectionKey else { return [] }
        let pairs = Set(handoffStore.handoffs.keys.map { [$0.from, $0.to] })
        return pairs.sorted { $0.joined(separator: " ") < $1.joined(separator: " ") }.map { BotTopology.Handoff(from: $0[0], to: $0[1]) }
    }
    private var accent: Color { settings.resolvedTheme.accent }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView { content(width: proxy.size.width - 32) }
            }
            .navigationTitle("Topology")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await refresh() }
            .refreshable { await refresh(force: true) }
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        let bots = bots, rooms = rooms
        let map = BotTopology(bots: bots.map { BotTopology.Bot(name: $0.name, model: $0.model, claudeCode: $0.worksThroughClaudeCode) },
                              rooms: rooms.map { BotTopology.Room(id: $0.id, members: $0.members.map(\.profile)) },
                              handoffs: handoffs, width: width)
        if width > 0 {
            ZStack(alignment: .topLeading) {
                lines(map, rooms: rooms)
                node(.you, in: map) { you }
                ForEach(rooms) { room in node(.room(room.id), in: map) { roomBox(room) } }
                ForEach(bots) { bot in node(.bot(bot.name), in: map) { botBox(bot) } }
                ForEach(map.targets, id: \.self) { target in
                    switch target {
                    case let .model(model): node(target, in: map) { modelBox(model, users: bots.filter { $0.model == model }) }
                    default: node(target, in: map) { claudeCodeBox(users: bots.filter(\.worksThroughClaudeCode)) }
                    }
                }
            }
            .frame(width: map.size.width, height: map.size.height, alignment: .topLeading)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            key(map)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        if bots.isEmpty {
            ContentUnavailableView("No bots yet", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Make one with New Bot, and it shows here with the model it runs on."))
        }
    }

    private func refresh(force: Bool = false) async {
        #if DEBUG
        if DevHooks.demoBots {   // the sample bots, with no server to read them from
            handoffStore.showDemo(key: settings.connectionKey)
            return
        }
        #endif
        if BotDirectory.apiOnly(settings) {
            activity.listed(await directory.refreshAPI().bots)
        } else {
            if let roster = try? await directory.refresh() { activity.listed(roster.bots) }
            await groups.refresh()
            activity.listed(groups.rooms)
        }
        await handoffStore.refresh(bots, force: force)
    }

    // MARK: - Lines

    /// Yours in the theme's colour, each group chat's in one of its own, a bot's to its model in
    /// the bot's colour.
    private func lines(_ map: BotTopology, rooms: [GroupRoom]) -> some View {
        let roomIndex = Dictionary(rooms.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let faces = faces, accent = accent
        return Canvas { context, _ in
            for line in map.lines {
                let color: Color
                switch line.link {
                case .you: color = accent.opacity(0.55)
                case let .room(id, _): color = Self.roomColors[(roomIndex[id] ?? 0) % Self.roomColors.count].opacity(0.75)
                case let .model(_, bot), let .claudeCode(bot), let .handoff(bot, _):
                    color = BotFace.pair((faces[bot] ?? BotFace(seed: bot)).color).light.opacity(0.85)
                }
                context.stroke(Self.path(line), with: .color(color), style: Self.style(line.link))
                if case .handoff = line.link, let head = Self.arrowhead(line) {
                    context.fill(head, with: .color(color))
                }
            }
        }
        .frame(width: map.size.width, height: map.size.height)
        .accessibilityHidden(true)
    }

    private static let roomColors: [Color] = [.teal, .purple, .orange, .pink, .mint, .indigo]
    /// Claude Code's box and its key.
    private static let claudeCodeTint = Color(red: 0.85, green: 0.47, blue: 0.34)

    /// A model's line solid, Claude Code's dotted, a handoff dashed with an arrow at its end.
    private static func style(_ link: BotTopology.Link) -> StrokeStyle {
        switch link {
        case .claudeCode: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [1, 4])
        case .handoff: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [5, 3])
        default: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        }
    }

    /// The head of a handoff's arrow, at its end, pointing the way its last run goes.
    private static func arrowhead(_ line: BotTopology.Line) -> Path? {
        guard line.points.count >= 2 else { return nil }
        let tip = line.points[line.points.count - 1], from = line.points[line.points.count - 2]
        let angle = atan2(tip.y - from.y, tip.x - from.x), size: CGFloat = 7
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - size * cos(angle - 0.45), y: tip.y - size * sin(angle - 0.45)))
        head.addLine(to: CGPoint(x: tip.x - size * cos(angle + 0.45), y: tip.y - size * sin(angle + 0.45)))
        head.closeSubpath()
        return head
    }

    /// Straight runs with their corners rounded, or a curve.
    private static func path(_ line: BotTopology.Line) -> Path {
        var path = Path()
        guard let first = line.points.first else { return path }
        path.move(to: first)
        if line.isCurve, line.points.count == 4 {
            path.addCurve(to: line.points[3], control1: line.points[1], control2: line.points[2])
            return path
        }
        for index in 1 ..< line.points.count {
            let point = line.points[index]
            if index < line.points.count - 1 {
                let next = line.points[index + 1]
                let room = min(hypot(point.x - line.points[index - 1].x, point.y - line.points[index - 1].y),
                               hypot(next.x - point.x, next.y - point.y)) / 2
                path.addArc(tangent1End: point, tangent2End: next, radius: min(10, room))
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    // MARK: - Boxes

    private func node(_ node: BotTopology.Node, in map: BotTopology, @ViewBuilder content: () -> some View) -> some View {
        let frame = map.frames[node] ?? .zero
        return content()
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }

    private func box(tint: Color, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.45), lineWidth: 1) }
    }

    private var you: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.fill").foregroundStyle(accent)
            Text("You").font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.45), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }

    private func roomBox(_ room: GroupRoom) -> some View {
        let index = rooms.firstIndex(of: room) ?? 0
        let tint = Self.roomColors[index % Self.roomColors.count]
        let state = status(kind: activity.kind(of: room), unread: activity.isUnread(room, isOpen: groups.open?.id == room.id),
                           idle: room.members.count == 1 ? "1 member" : "\(room.members.count) members")
        return Button {
            dismiss()
            openRoom(room)
        } label: {
            box(tint: tint) {
                Image(systemName: "person.3.fill").foregroundStyle(tint).frame(width: 32)
                label(room.name, state)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(room.name), group chat with \(room.members.map(\.label).formatted())")
        .accessibilityValue(state.text)
        .accessibilityHint("Opens the group chat")
    }

    private func botBox(_ bot: HermesBot) -> some View {
        let face = faces[bot.name] ?? BotFace(seed: bot.name)
        let name = bot.label(mainName: settings.headerTitle)
        let state = status(kind: activity.kind(of: bot, open: conversation), unread: activity.isUnread(bot, open: conversation), idle: "Idle")
        return Button {
            dismiss()
            openBot(bot)
        } label: {
            box(tint: BotFace.pair(face.color).light) {
                BotAvatar(face: face, name: name, size: 32)
                label(name, state)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bot.model.map { "\(name), runs on \(Self.shortName($0))" } ?? name)
        .accessibilityValue([state.text, handsTo(bot)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens your chat with this bot")
    }

    private func modelBox(_ model: String, users: [HermesBot]) -> some View {
        box(tint: .orange) {
            Image(systemName: "cpu").foregroundStyle(.orange).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.shortName(model)).font(.footnote.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                Text(users.count == 1 ? "Model" : "Model · \(users.count) bots").font(.caption2).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Model \(Self.shortName(model)), used by \(users.map { $0.label(mainName: settings.headerTitle) }.formatted())")
    }

    private func claudeCodeBox(users: [HermesBot]) -> some View {
        box(tint: Self.claudeCodeTint) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(Self.claudeCodeTint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code").font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(users.count == 1 ? "Does its work" : "Does their work").font(.caption2).foregroundStyle(Self.claudeCodeTint)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claude Code, does the work of \(users.map { $0.label(mainName: settings.headerTitle) }.formatted())")
    }

    /// The names of the bots this one has handed work to, for VoiceOver.
    private func handsTo(_ bot: HermesBot) -> String? {
        let to = handoffs.filter { $0.from == bot.name }.compactMap { arrow in bots.first { $0.name == arrow.to } }
        return to.isEmpty ? nil : "hands work to " + to.map { $0.label(mainName: settings.headerTitle) }.formatted()
    }

    /// What the lines are, under the map: the ones it has.
    @ViewBuilder
    private func key(_ map: BotTopology) -> some View {
        let has = { (test: (BotTopology.Link) -> Bool) in map.lines.contains { test($0.link) } }
        let rows: [(String, StrokeStyle, Color)] = [
            has { if case .model = $0 { true } else { false } } ? ("Runs on", Self.style(.model("", bot: "")), Color.secondary) : nil,
            has { if case .claudeCode = $0 { true } else { false } } ? ("Works through", Self.style(.claudeCode(bot: "")), Self.claudeCodeTint) : nil,
            has { if case .handoff = $0 { true } else { false } } ? ("Hands work to (a message or a card, lately)", Self.style(.handoff(from: "", to: "")), Color.secondary) : nil,
        ].compactMap { $0 }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { row in
                    HStack(spacing: 8) {
                        Canvas { context, size in
                            var line = Path()
                            line.move(to: CGPoint(x: 0, y: size.height / 2))
                            line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                            context.stroke(line, with: .color(row.2), style: row.1)
                        }
                        .frame(width: 28, height: 8)
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
        }
    }

    /// A model's name without its provider's ("anthropic/claude-sonnet-4" → "claude-sonnet-4").
    static func shortName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    private struct Status {
        var text: String
        var color: Color
        var working = false
    }

    private func status(kind: ChatActivity.Kind?, unread: Bool, idle: String) -> Status {
        switch kind {
        case .working: Status(text: "Working", color: accent, working: true)
        case .needsYou: Status(text: "Needs you", color: .orange)
        case nil: unread ? Status(text: "New reply", color: accent) : Status(text: idle, color: .secondary)
        }
    }

    private func label(_ title: String, _ state: Status) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 4) {
                if state.working { ProgressView().controlSize(.mini) }
                Text(state.text).font(.caption).foregroundStyle(state.color).lineLimit(1)
            }
        }
    }
}

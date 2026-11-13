import SwiftUI

// The Board page's look (2026-11-13): the drawer's family for the kanban board. A hero in the
// Board place's hue with what's moving, the columns as coloured pills, and each card with the
// bot it's assigned to and a mark for where it stands. Colours all from the theme (`DrawerTone`).

/// The counts the board's hero shows, worked out from its columns.
nonisolated struct BoardSummary: Equatable {
    /// Cards a worker is on now.
    var working = 0
    /// Cards waiting on the person: for review, or blocked.
    var waiting = 0
    /// Cards finished in the last seven days.
    var doneThisWeek = 0
    var total = 0
    /// The busiest open columns, three at most, in the board's order: the one-line summary.
    var busiest: [(name: String, count: Int)] = []

    static func == (a: Self, b: Self) -> Bool {
        a.working == b.working && a.waiting == b.waiting && a.doneThisWeek == b.doneThisWeek && a.total == b.total
            && a.busiest.map(\.name) == b.busiest.map(\.name) && a.busiest.map(\.count) == b.busiest.map(\.count)
    }

    init(columns: [KanbanColumn], now: Date = .now) {
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        for column in columns {
            let count = column.tasks.count
            total += count
            switch column.name {
            case "running": working += count
            case "review", "blocked": waiting += count
            case "done": doneThisWeek += column.tasks.count(where: { ($0.completedAt ?? $0.createdAt ?? .distantPast) >= weekAgo })
            default: break
            }
        }
        let open = columns.enumerated().filter { !["done", "archived"].contains($0.element.name) && !$0.element.tasks.isEmpty }
        busiest = open.sorted { a, b in
            a.element.tasks.count != b.element.tasks.count ? a.element.tasks.count > b.element.tasks.count : a.offset < b.offset
        }
        .prefix(3)
        .sorted { $0.offset < $1.offset }
        .map { ($0.element.name, $0.element.tasks.count) }
    }

    /// The column a hero counter opens: Working the running cards, Waiting the reviews (or the
    /// blocked ones when there are no reviews), Done the finished ones.
    enum Counter { case working, waiting, done }

    static func column(for counter: Counter, in columns: [KanbanColumn]) -> String? {
        let names = Set(columns.map(\.name))
        func has(_ name: String) -> Bool { columns.first { $0.name == name }?.tasks.isEmpty == false }
        let pick: String? = switch counter {
        case .working: "running"
        case .waiting: has("review") || !has("blocked") ? "review" : "blocked"
        case .done: "done"
        }
        return pick.flatMap { names.contains($0) ? $0 : nil }
    }

    /// Whether a card in this status is one to look at now: in progress, or waiting on the person.
    static func isMoving(_ status: String) -> Bool { status == "running" }
    static func needsYou(_ status: String) -> Bool { status == "review" || status == "blocked" }
}

/// Each status's hue, from the drawer's colours: the board's own for Done, the warm one for
/// what waits on you, the accent for what's running.
struct BoardTone {
    let tone: DrawerTone

    init(_ theme: ResolvedTheme) { tone = DrawerTone(theme) }

    var board: Color { tone.places[2] }

    func hue(_ status: String) -> Color {
        switch status {
        case "todo": tone.places[1]
        case "scheduled": tone.places[0]
        case "ready": tone.places[1].mix(with: tone.places[2], by: 0.5)
        case "running": tone.accent
        case "blocked": tone.warm
        case "review": tone.places[3]
        case "done": tone.places[2]
        default: tone.ink.mix(with: tone.surface, by: 0.4)
        }
    }

    /// A status's hue as a fill under page-coloured words: a step toward the ink, so they read.
    func solid(_ status: String) -> Color { status == "blocked" ? tone.warm : hue(status).mix(with: tone.ink, by: 0.22) }
}

// MARK: - Hero

/// The board's name (a menu of the others when there are more), what's on it in a line, a bar
/// of its columns, and three counters that open their column.
struct BoardHero: View {
    let tone: BoardTone
    let summary: BoardSummary
    let columns: [KanbanColumn]
    /// The board's name, or nil for none known.
    let name: String?
    /// The board switcher, when Hermes keeps more than one.
    var picker: AnyView?
    let open: (BoardSummary.Counter) -> Void

    var body: some View {
        let t = tone.tone
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.3x2.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(t.page)
                    .frame(width: 54, height: 54)
                    .background(tone.board, in: .rect(cornerRadius: 17, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if let picker {
                        picker
                    } else {
                        Text(verbatim: name ?? String(localized: "Board"))
                            .font(.system(.title2, design: t.design, weight: .heavy))
                            .foregroundStyle(t.ink)
                            .lineLimit(1)
                    }
                    Text(verbatim: line)
                        .font(.system(.subheadline, design: t.design, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            if summary.total > 0 {
                BoardBar(columns: columns, tone: tone)
                    .frame(height: 8)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                counter(summary.working, String(localized: "Working", comment: "A workstream's status"), tone.hue("running"), .working)
                counter(summary.waiting, String(localized: "Waiting", comment: "The drawer: a counter's label, how many things wait on you (shown in capitals)"), t.warm, .waiting)
                counter(summary.doneThisWeek, String(localized: "Done this week", comment: "The Board page: a counter's label, how many cards were finished in the last seven days (shown in capitals)"), tone.hue("done"), .done)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    /// "5 To do · 1 Ready · 1 Review": the busiest open columns, else nothing yet.
    private var line: String {
        if !summary.busiest.isEmpty {
            return summary.busiest.map { "\($0.count) \(KanbanStatus.label($0.name))" }.joined(separator: " · ")
        }
        if summary.total > 0 { return "\(summary.total) \(KanbanStatus.label("done"))" }
        return String(localized: "Nothing in \(name ?? String(localized: "Board"))")
    }

    private func counter(_ count: Int, _ label: String, _ color: Color, _ which: BoardSummary.Counter) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button { open(which) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "\(count)")
                    .font(.system(size: 26, weight: .heavy, design: tone.tone.design))
                    .monospacedDigit()
                    .foregroundStyle(count > 0 ? color : Color.secondary)
                    .contentTransition(.numericText())
                Text(verbatim: label.localizedUppercase)
                    .font(.system(size: 10, weight: .bold, design: tone.tone.design))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    // Two lines at most: "Done this week" runs long in a narrow drawer.
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(tone.tone.surface, in: shape)
            .overlay { shape.strokeBorder(color.opacity(count > 0 ? 0.35 : 0.1), lineWidth: 1) }
            .contentShape(shape)
        }
        .buttonStyle(DrawerSquish())
        .accessibilityElement(children: .combine)
    }
}

/// The board at a glance: one segment per column with cards, as wide as its share, in its hue.
/// Drawn, not laid out, so it costs one view.
struct BoardBar: View {
    let columns: [KanbanColumn]
    let tone: BoardTone

    var body: some View {
        let shown = columns.filter { !$0.tasks.isEmpty }
        let total = shown.reduce(0) { $0 + $1.tasks.count }
        let hues = shown.map { tone.hue($0.name) }
        Canvas { context, size in
            guard total > 0 else { return }
            let gap: CGFloat = 3
            let width = size.width - gap * CGFloat(max(0, shown.count - 1))
            var x: CGFloat = 0
            for (i, column) in shown.enumerated() {
                let w = max(size.height, width * CGFloat(column.tasks.count) / CGFloat(total))
                let rect = CGRect(x: x, y: 0, width: min(w, size.width - x), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: size.height / 2), with: .color(hues[i]))
                x += w + gap
            }
        }
    }
}

// MARK: - Columns

/// The columns as coloured pills, each with its count: the one shown filled in its hue.
struct BoardColumnBar: View {
    let columns: [KanbanColumn]
    @Binding var selected: String
    let tone: BoardTone

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(columns) { col in pill(col).id(col.name) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .onChange(of: selected) { _, name in withAnimation(.snappy) { proxy.scrollTo(name, anchor: .center) } }
            // The one shown in sight when the board comes in (it's kept across visits).
            .onChange(of: columns.map(\.name), initial: true) { proxy.scrollTo(selected, anchor: .center) }
        }
    }

    private func pill(_ col: KanbanColumn) -> some View {
        let on = col.name == selected
        let t = tone.tone
        let hue = tone.hue(col.name)
        let fill = tone.solid(col.name)
        return Button {
            withAnimation(.snappy) { selected = col.name }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: KanbanStatus.icon(col.name))
                    .foregroundStyle(on ? t.page : hue)
                Text(KanbanStatus.label(col.name))
                    .foregroundStyle(on ? t.page : t.ink)
                if !col.tasks.isEmpty {
                    Text(verbatim: "\(col.tasks.count)")
                        .font(.system(.caption2, design: t.design, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(on ? fill : hue)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(on ? t.page.opacity(0.9) : hue.opacity(0.16), in: .capsule)
                }
            }
            .font(.system(.footnote, design: t.design, weight: .bold))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(on ? fill : t.surface, in: .capsule)
            .overlay { if !on { Capsule().strokeBorder(hue.opacity(col.tasks.isEmpty ? 0.12 : 0.3), lineWidth: 1) } }
            .contentShape(.capsule)
        }
        .buttonStyle(DrawerSquish())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Cards

/// A card: the face of the bot it's assigned to, its title big, what it says, and a mark for
/// where it stands. One a worker is on, or that waits on you, stands out with an edge in its hue.
struct BoardCard: View {
    let task: KanbanTask
    let tone: BoardTone
    /// The assignee as the app shows it, and its face; nil for an unassigned card.
    let assignee: (name: String, face: BotFace)?

    var body: some View {
        let t = tone.tone
        let hue = tone.hue(task.status)
        let moving = BoardSummary.isMoving(task.status)
        let needs = BoardSummary.needsYou(task.status)
        let edge = needs ? t.warm : hue
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.title)
                        .font(.system(.headline, design: t.design, weight: .bold))
                        .foregroundStyle(task.status == "done" ? Color.secondary : t.ink)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if task.priority != 0 { priority }
                }
                if let s = task.latestSummary ?? task.body, !s.isEmpty {
                    Text(s)
                        .font(.system(.footnote, design: t.design))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    mark(hue)
                    if let a = assignee { Text(verbatim: a.name).lineLimit(1) }
                    if let c = task.createdAt, !moving { Text(verbatim: c.relativeLabel).lineLimit(1) }
                    if task.commentCount > 0 { Label("\(task.commentCount)", systemImage: "text.bubble").labelStyle(.titleAndIcon) }
                    if task.lastFailure != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(t.warm) }
                }
                .font(.system(.caption, design: t.design, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(t.surface)
            if moving || needs { shape.fill(edge.opacity(0.08)) }
        }
        .overlay { shape.strokeBorder(edge.opacity(moving || needs ? 0.5 : 0.1), lineWidth: moving || needs ? 1.5 : 1) }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .contentShape(shape)
    }

    @ViewBuilder private var avatar: some View {
        if let a = assignee {
            BotAvatar(face: a.face, name: a.name, size: 38)
        } else {
            Image(systemName: "person.crop.circle.dashed")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 38, height: 38)
                .accessibilityLabel(String(localized: "Unassigned"))
        }
    }

    private var priority: some View {
        let high = task.priority > 0
        return Text(verbatim: "P\(task.priority)")
            .font(.system(.caption2, design: tone.tone.design, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((high ? tone.tone.warm : Color.secondary).opacity(0.16), in: .capsule)
            .foregroundStyle(high ? tone.tone.warm : Color.secondary)
    }

    /// Where it stands: a ring part-way round while a worker is on it (with how long), a filled
    /// "Needs you" for a review or a block, else the column's own symbol in its hue.
    @ViewBuilder private func mark(_ hue: Color) -> some View {
        let t = tone.tone
        if BoardSummary.isMoving(task.status) {
            HStack(spacing: 4) {
                Circle().trim(from: 0, to: 0.7)
                    .stroke(hue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 11, height: 11)
                Text(verbatim: (task.startedAt ?? task.createdAt).map(\.relativeLabel) ?? KanbanStatus.label(task.status))
            }
            .foregroundStyle(hue)
            .fontWeight(.bold)
        } else if BoardSummary.needsYou(task.status) {
            HStack(spacing: 3) {
                Image(systemName: KanbanStatus.icon(task.status))
                Text("Needs you", comment: "A workstream's status: it waits for the person's approval")
            }
            .font(.system(.caption2, design: t.design, weight: .heavy))
            .foregroundStyle(t.page)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(t.warm, in: .capsule)
        } else {
            Image(systemName: task.status == "done" ? "checkmark.circle.fill" : KanbanStatus.icon(task.status))
                .foregroundStyle(hue)
                .fontWeight(.bold)
                .accessibilityLabel(KanbanStatus.label(task.status))
        }
    }
}

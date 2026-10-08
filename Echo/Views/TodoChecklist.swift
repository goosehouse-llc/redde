import SwiftUI

/// The agent's own task list under a reply, as a checklist: what is done, what it is on now, what
/// is still to come, and what it dropped. The host's own word on the list where the connection
/// gives one, else read out of the to-do tool's calls (`TodoList`); each reply shows the list as
/// that reply left it.
struct TodoChecklist: View {
    let items: [TodoItem]
    /// The reply is still being written: the item in progress is being worked on right now.
    var isLive = false
    @Environment(\.theme) private var theme
    @State private var showAll = false

    /// A long plan shows its start; the rest is one tap away.
    static let shown = 8

    var body: some View {
        let depths = TodoList.depths(items)
        let visible = showAll || items.count <= Self.shown + 1 ? items : Array(items.prefix(Self.shown))
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tasks").font(.footnote.weight(.semibold))
                Spacer(minLength: 8)
                Text(TodoList.summary(items)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(visible) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.symbol(item.status))
                        .font(.footnote)
                        .foregroundStyle(tint(item.status))
                        .symbolEffect(.pulse, isActive: isLive && item.status == .inProgress)
                        .accessibilityHidden(true)
                    Text(item.content)
                        .font(.footnote.weight(item.status == .inProgress ? .medium : .regular))
                        .foregroundStyle(item.status == .inProgress ? .primary : .secondary)
                        .strikethrough(item.status == .cancelled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(min(depths[item.id] ?? 0, 3)) * 18)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Self.spoken(item.status)): \(item.content)")
            }
            if visible.count < items.count {
                Button("Show all \(items.count)") { withAnimation(.snappy(duration: 0.25)) { showAll = true } }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accent.opacity(0.07), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tasks, \(TodoList.summary(items))")
    }

    private func tint(_ status: TodoItem.Status) -> Color {
        switch status {
        case .completed, .inProgress: theme.accent
        case .pending, .cancelled: .secondary
        }
    }

    nonisolated static func symbol(_ status: TodoItem.Status) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted.circle"
        case .pending: "circle"
        case .cancelled: "minus.circle"
        }
    }

    nonisolated static func spoken(_ status: TodoItem.Status) -> String {
        switch status {
        case .completed: "Done"
        case .inProgress: "In progress"
        case .pending: "To do"
        case .cancelled: "Dropped"
        }
    }
}

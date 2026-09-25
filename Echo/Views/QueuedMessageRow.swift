import SwiftUI

/// A message that hasn't gone out yet: a faded bubble with what it's waiting for, a Send button
/// when it needs one, and Edit / Delete in its menu.
struct QueuedMessageRow: View {
    let item: OutboxItem
    /// Only the first message in line can be sent; the rest follow it.
    let isFirst: Bool
    let onSend: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !item.message.attachments.isEmpty {
                Label("\(item.message.attachments.count) attachment\(item.message.attachments.count == 1 ? "" : "s")", systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !item.message.text.isEmpty {
                Text(item.message.text)
                    .font(theme.userFont)
                    .padding(.horizontal, 14)
                    .padding(.vertical, theme.bubbleVerticalPadding)
                    .background(theme.userBubble.opacity(0.45), in: .rect(cornerRadius: theme.bubbleRadius))
                    .foregroundStyle(theme.userBubbleText.opacity(0.85))
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.bubbleRadius)
                            .strokeBorder(theme.userBubble.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
            }
            HStack(spacing: 10) {
                Label(statusText, systemImage: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isFirst, item.state != .queued {
                    Button("Send now", action: onSend)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu {
            if isFirst { Button("Send now", systemImage: "arrow.up.circle", action: onSend) }
            Button("Edit", systemImage: "pencil", action: onEdit)
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.message.text }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Not sent yet: \(item.message.text). \(statusText)")
        .accessibilityActions {
            if isFirst { Button("Send now", action: onSend) }
            Button("Edit", action: onEdit)
            Button("Delete", action: onDelete)
        }
    }

    private var queuedTime: String { item.queuedAt.formatted(date: .omitted, time: .shortened) }

    private var statusText: String {
        switch item.state {
        case .queued: isFirst ? "Sends after this reply" : "Queued"
        case .waitingForConnection: isFirst ? "Waiting for connection · \(queuedTime)" : "Waiting · \(queuedTime)"
        case .paused: item.isStale() ? "Not sent · from \(queuedTime)" : "Not sent"
        }
    }

    private var statusSymbol: String {
        switch item.state {
        case .queued: "clock"
        case .waitingForConnection: "wifi.slash"
        case .paused: "pause.circle"
        }
    }
}

extension OutboxItem {
    /// View identity for a queued row, distinct from the same message's transcript row.
    var rowID: String { "queued-\(id.uuidString)" }
}

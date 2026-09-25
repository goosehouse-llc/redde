import SwiftUI

/// Delegated child agents under a reply: one row per task, nested by depth, with the goal,
/// a live "what it's doing" line, and the summary once it finishes.
struct SubagentRows: View {
    let subagents: [SubagentActivity]
    @Environment(\.theme) private var theme
    @State private var expanded: Set<String> = []
    @State private var watching: SubagentActivity?

    private func canOpen(_ a: SubagentActivity) -> Bool {
        a.childSessionID != nil && Settings.shared.transport == .hermesServe
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(subagents) { agent in
                row(agent)
                    .padding(.leading, CGFloat(min(agent.depth, 3)) * 14)
            }
        }
        .padding(.horizontal, 4)
        .sheet(item: $watching) { SubagentTranscriptView(agent: $0) }   // one presenter for all rows
    }

    private func row(_ agent: SubagentActivity) -> some View {
        let open = expanded.contains(agent.id) && agent.summary?.isEmpty == false
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon(agent.status))
                    .symbolEffect(.pulse, isActive: agent.status == .running)
                    .foregroundStyle(tint(agent.status))
                    .font(.caption)
                Text(agent.goal.isEmpty ? "Delegated task" : agent.goal)
                    .font(.footnote.weight(.medium))
                    .lineLimit(open ? nil : 2)
                Spacer(minLength: 0)
                if agent.taskCount > 1 {
                    Text("\(agent.taskIndex + 1)/\(agent.taskCount)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                if canOpen(agent) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            Text(detail(agent))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(open ? nil : 1)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint(agent.status).opacity(0.08), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .onTapGesture {
            if canOpen(agent) { watching = agent }
            else if expanded.contains(agent.id) { expanded.remove(agent.id) } else { expanded.insert(agent.id) }
        }
        .contextMenu {
            if canOpen(agent) { Button("Open transcript", systemImage: "text.bubble") { watching = agent } }
            Button(expanded.contains(agent.id) ? "Collapse" : "Expand", systemImage: "arrow.up.left.and.arrow.down.right") {
                if expanded.contains(agent.id) { expanded.remove(agent.id) } else { expanded.insert(agent.id) }
            }
            if let summary = agent.summary, !summary.isEmpty {
                Button("Copy summary", systemImage: "doc.on.doc") { UIPasteboard.general.string = summary }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subagent \(agent.goal), \(label(agent.status)). \(detail(agent))")
        .accessibilityHint(canOpen(agent) ? "Opens the subagent's transcript" : "Expands the summary")
    }

    private func detail(_ a: SubagentActivity) -> String {
        switch a.status {
        case .running:
            var parts: [String] = []
            if a.toolCount > 0 { parts.append("\(a.toolCount) tool\(a.toolCount == 1 ? "" : "s")") }
            if let t = a.lastTool, !t.isEmpty { parts.append(t) }
            return parts.isEmpty ? "Working…" : parts.joined(separator: " · ")
        case .dispatched:
            return "Running in the background; results arrive in a later turn"
        case .completed, .failed:
            var parts: [String] = []
            if let d = a.durationSeconds { parts.append(d < 60 ? String(format: "%.0f s", d) : String(format: "%.1f min", d / 60)) }
            if a.toolCount > 0 { parts.append("\(a.toolCount) tools") }
            let head = parts.joined(separator: " · ")
            if let s = a.summary, !s.isEmpty { return head.isEmpty ? s : head + " · " + s }
            return head.isEmpty ? label(a.status) : head
        }
    }

    private func label(_ s: SubagentActivity.Status) -> String {
        switch s {
        case .running: "running"
        case .dispatched: "dispatched"
        case .completed: "done"
        case .failed: "failed"
        }
    }

    private func icon(_ s: SubagentActivity.Status) -> String {
        switch s {
        case .running: "person.2.wave.2"
        case .dispatched: "clock.arrow.2.circlepath"
        case .completed: "checkmark.circle"
        case .failed: "xmark.circle"
        }
    }

    private func tint(_ s: SubagentActivity.Status) -> Color {
        switch s {
        case .running: theme.accent
        case .dispatched: .secondary
        case .completed: .green
        case .failed: .red
        }
    }
}

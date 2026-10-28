import SwiftUI

/// Settings → Agent → Approval History: every approval answered on this device, newest first,
/// by day: what the agent wanted to run, why it had to ask, who asked where, and the answer
/// (`ApprovalHistory`).
struct ApprovalHistoryView: View {
    @State private var history = ApprovalHistory.shared
    @State private var agent: String?
    @State private var confirmingClear = false

    private var agents: [String] { Array(Set(history.entries.map(\.agent))).sorted() }
    private var shown: [ApprovalHistory.Entry] { history.entries.filter { agent == nil || $0.agent == agent } }

    var body: some View {
        List {
            if shown.isEmpty {
                ContentUnavailableView("No approvals yet", systemImage: "checkmark.shield",
                                       description: Text("When your agent asks before running something, your answer is kept here."))
            }
            ForEach(DateGroup.group(shown, by: { $0.at }), id: \.title) { day in
                Section(day.title) {
                    ForEach(day.items) { Row(entry: $0) }
                }
            }
        }
        .navigationTitle("Approval History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if agents.count > 1 {
                        Picker("Asked by", selection: $agent) {
                            Text("Everyone").tag(String?.none)
                            ForEach(agents, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        Divider()
                    }
                    Button("Clear History", systemImage: "trash", role: .destructive) { confirmingClear = true }
                        .disabled(history.entries.isEmpty)
                } label: { Label("More", systemImage: "ellipsis") }
            }
        }
        .confirmationDialog("Clear the approval history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { history.clear() }
        } message: {
            Text("It is kept only on this device. Your agent's own settings don't change.")
        }
    }

    private struct Row: View {
        let entry: ApprovalHistory.Entry

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.command)
                        .font(.footnote.monospaced())
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    answer
                }
                if let reason = entry.reason {
                    Text("Why: \(reason)", comment: "Under an approval: the rule or reason the agent had to ask")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text([entry.agent, entry.chat, entry.at.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }

        private var answer: some View {
            let (label, color): (String, Color) = switch entry.choice {
            case "deny": (String(localized: "Denied", comment: "Approval history: the request was refused"), .red)
            case "session": (String(localized: "This session", comment: "Approval button: allow the command for this session"), .green)
            case "always": (String(localized: "Always", comment: "Approval button: always allow the command"), .green)
            default: (String(localized: "Once", comment: "Approval button: allow the command this one time"), .green)
            }
            return Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(color.opacity(0.12), in: .capsule)
        }
    }
}

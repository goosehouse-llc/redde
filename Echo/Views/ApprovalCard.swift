import SwiftUI

/// "The agent wants to run X." Buttons mirror the gateway's choices.
struct ApprovalCard: View {
    let request: ApprovalRequest
    let respond: (String) -> Void
    /// A request that names a kanban card (the agent putting the claude bot's work in place): its
    /// change, looked at before answering.
    @State private var showingChange = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval needed", systemImage: "hand.raised")
                .font(.subheadline.weight(.semibold))
            Text(request.command)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 8))
            if let description = request.description, !description.isEmpty {
                Text(description).font(.footnote).foregroundStyle(.secondary)
            }
            if request.kanbanCard != nil, KanbanClient.isAvailable {
                Button("View Changes", systemImage: "plus.forwardslash.minus") { showingChange = true }
                    .font(.footnote)
            }
            HStack {
                ForEach(request.choices, id: \.self) { choice in
                    Button(label(for: choice)) { respond(choice) }
                        .buttonStyle(.bordered)
                        .tint(choice == "deny" ? .red : .accentColor)
                }
            }
            .font(.footnote)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 14))
        .sheet(isPresented: $showingChange) {
            if let card = request.kanbanCard { CardChangeSheet(cardID: card) }
        }
    }

    private func label(for choice: String) -> String {
        switch choice {
        case "once": String(localized: "Once", comment: "Approval button: allow the command this one time")
        case "session": String(localized: "This session", comment: "Approval button: allow the command for this session")
        case "always": String(localized: "Always", comment: "Approval button: always allow the command")
        case "deny": String(localized: "Deny", comment: "Approval button: refuse the command")
        default: choice.capitalized
        }
    }
}

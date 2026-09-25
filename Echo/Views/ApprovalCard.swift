import SwiftUI

/// "The agent wants to run X." Buttons mirror the gateway's choices.
struct ApprovalCard: View {
    let request: ApprovalRequest
    let respond: (String) -> Void

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
    }

    private func label(for choice: String) -> String {
        switch choice {
        case "once": "Once"
        case "session": "This session"
        case "always": "Always"
        case "deny": "Deny"
        default: choice.capitalized
        }
    }
}

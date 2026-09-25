import SwiftUI

/// The agent stopped and needs you: a tool approval, a clarifying question, sudo, or a secret.
/// One card, four shapes; answers go back through the conversation.
struct InterruptCard: View {
    let interrupt: Interrupt
    @Environment(Conversation.self) private var conversation

    var body: some View {
        Group {
            switch interrupt {
            case let .approval(request):
                ApprovalCard(request: request) { conversation.respond(approval: $0) }
            case let .clarify(request):
                ClarifyCard(request: request) { conversation.respond(clarify: $0) }
            case .sudo:
                SudoCard { conversation.respond(sudoPassword: $0) }
            case let .secret(request):
                SecretCard(request: request) { conversation.respond(secret: $0) }
            }
        }
    }
}

struct ClarifyCard: View {
    let request: ClarifyRequest
    let respond: ([String: String]) -> Void
    @State private var picked: [String: Set<String>] = [:]
    @State private var freeText: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.questions.count > 1 ? "Redde has a few questions" : "Redde has a question", systemImage: "questionmark.bubble")
                .font(.subheadline.weight(.semibold))
            ForEach(request.questions) { q in
                VStack(alignment: .leading, spacing: 8) {
                    Text(q.question).font(.body)
                    if !q.choices.isEmpty {
                        FlowChips(items: q.choices, selected: picked[q.id] ?? []) { choice in
                            var set = picked[q.id] ?? []
                            if q.multiSelect {
                                if set.contains(choice) { set.remove(choice) } else { set.insert(choice) }
                                picked[q.id] = set
                            } else {
                                picked[q.id] = [choice]
                                if request.questions.count == 1 { send() }   // one tap answers a single question
                            }
                        }
                    }
                    TextField(q.choices.isEmpty ? "Your answer" : "Or type something else", text: binding(for: q.id), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                        .onSubmit { if request.questions.count == 1 { send() } }
                }
            }
            if request.questions.count > 1 || request.questions.contains(where: \.multiSelect) || request.questions.contains(where: { $0.choices.isEmpty }) {
                Button("Send answers", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!allAnswered)
                    .font(.footnote)
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.10), in: .rect(cornerRadius: 14))
    }

    private func binding(for qid: String) -> Binding<String> {
        Binding(get: { freeText[qid] ?? "" }, set: { freeText[qid] = $0 })
    }

    private func answer(for q: ClarifyQuestion) -> String {
        let typed = (freeText[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return (picked[q.id] ?? []).sorted().joined(separator: ", ")
    }

    private var allAnswered: Bool { request.questions.allSatisfy { !answer(for: $0).isEmpty } }

    private func send() {
        var answers: [String: String] = [:]
        for q in request.questions { answers[q.id] = answer(for: q) }
        respond(answers)
    }
}

struct SudoCard: View {
    let respond: (String) -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("sudo password needed", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text("A command on the gateway host needs elevated rights. The password goes straight to that terminal and isn't stored by Redde.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send).buttonStyle(.borderedProminent).disabled(password.isEmpty)
                Button("Cancel") { respond("") }.buttonStyle(.bordered)
            }
            .font(.footnote)
        }
        .padding(12)
        .background(Color.red.opacity(0.10), in: .rect(cornerRadius: 14))
    }

    private func send() {
        guard !password.isEmpty else { return }
        respond(password)
        password = ""
    }
}

struct SecretCard: View {
    let request: SecretRequest
    let respond: (String) -> Void
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Redde needs a secret", systemImage: "key")
                .font(.subheadline.weight(.semibold))
            Text(request.prompt.isEmpty ? "Provide a value for \(request.envVar)." : request.prompt)
                .font(.footnote)
            if !request.envVar.isEmpty {
                Text("Stored on the gateway as \(request.envVar)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                SecureField("Value", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Save", action: send).buttonStyle(.borderedProminent).disabled(value.isEmpty)
                Button("Skip") { respond("") }.buttonStyle(.bordered)
            }
            .font(.footnote)
        }
        .padding(12)
        .background(Color.purple.opacity(0.10), in: .rect(cornerRadius: 14))
    }

    private func send() {
        guard !value.isEmpty else { return }
        respond(value)
        value = ""
    }
}

/// Wrapping row of tappable choice chips.
struct FlowChips: View {
    let items: [String]
    let selected: Set<String>
    let tap: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { tap(item) } label: {
                    Text(item)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(selected.contains(item) ? Color.accentColor : Color.primary.opacity(0.08), in: .capsule)
                        .foregroundStyle(selected.contains(item) ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

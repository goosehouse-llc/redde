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
    @Environment(\.theme) private var theme
    let request: ClarifyRequest
    let respond: ([String: String]) -> Void
    @State private var picked: [String: Set<String>] = [:]
    @State private var freeText: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.questions.count > 1 ? String(localized: "Redde has a few questions") : String(localized: "Redde has a question"),
                  systemImage: "questionmark.bubble")
                .chatFont(.subheadline, weight: .semibold)
            ForEach(request.questions) { q in
                VStack(alignment: .leading, spacing: 8) {
                    Text(q.question).chatFont(.body)
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
                    TextField(q.choices.isEmpty ? String(localized: "Your answer") : String(localized: "Or type something else"),
                              text: binding(for: q.id), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .chatFont(.footnote)
                        .onSubmit { if request.questions.count == 1 { send() } }
                }
            }
            if request.questions.count > 1 || request.questions.contains(where: \.multiSelect) || request.questions.contains(where: { $0.choices.isEmpty }) {
                Button(action: send) { FilledButtonTitle(title: String(localized: "Send answers")) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!allAnswered)
                    .chatFont(.footnote)
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
    @Environment(\.theme) private var theme
    let respond: (String) -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("sudo password needed", systemImage: "lock.shield")
                .chatFont(.subheadline, weight: .semibold)
            Text("A command on the gateway host needs elevated rights. The password goes straight to that terminal and isn't stored by Redde.")
                .chatFont(.footnote).foregroundStyle(.secondary)
            HStack {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) { FilledButtonTitle(title: String(localized: "Send")) }.buttonStyle(.borderedProminent).disabled(password.isEmpty)
                Button("Cancel") { respond("") }.buttonStyle(.bordered)
            }
            .chatFont(.footnote)
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
    @Environment(\.theme) private var theme
    let request: SecretRequest
    let respond: (String) -> Void
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Redde needs a secret", systemImage: "key")
                .chatFont(.subheadline, weight: .semibold)
            Text(request.prompt.isEmpty ? String(localized: "Provide a value for \(request.envVar).") : request.prompt)
                .chatFont(.footnote)
            if !request.envVar.isEmpty {
                Text("Stored on the gateway as \(request.envVar)").chatFont(.caption, design: .monospaced).foregroundStyle(.secondary)
            }
            HStack {
                SecureField("Value", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) { FilledButtonTitle(title: String(localized: "Save")) }.buttonStyle(.borderedProminent).disabled(value.isEmpty)
                Button("Skip") { respond("") }.buttonStyle(.bordered)
            }
            .chatFont(.footnote)
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
    @Environment(\.theme) private var theme
    let items: [String]
    let selected: Set<String>
    let tap: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { tap(item) } label: {
                    Text(item)
                        .chatFont(.footnote, weight: .medium)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(selected.contains(item) ? theme.accent : Color.primary.opacity(0.08), in: .capsule)
                        // The theme's text for accent fills: white on a pale accent is unreadable.
                        .foregroundStyle(selected.contains(item) ? theme.userText : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A filled button's title: the theme's text on its accent, and dimmed text while disabled, when
/// the fill turns grey (white on grey couldn't be read, and didn't look disabled).
struct FilledButtonTitle: View {
    let title: String
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var body: some View { Text(title).foregroundStyle(isEnabled ? theme.userText : Color.secondary) }
}

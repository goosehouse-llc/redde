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

/// The agent stopped to ask (Hermes's clarify): each question, its choices as pills that wrap like
/// words, room to say something else, and one button for all of them. Headed by the agent asking,
/// its face and name (made calmer and clearer 2026-10-28, asked "these look cheap").
struct ClarifyCard: View {
    @Environment(\.theme) private var theme
    @Environment(Conversation.self) private var conversation
    let request: ClarifyRequest
    let respond: ([String: String]) -> Void
    @State private var picked: [String: Set<String>] = [:]
    @State private var freeText: [String: String] = [:]
    @FocusState private var typing: String?

    private var single: Bool { request.questions.count == 1 }
    /// One tap answers: a single question with choices, picked from once.
    private var tapAnswers: Bool { single && request.questions.allSatisfy { !$0.choices.isEmpty && !$0.multiSelect } }

    private var agent: (name: String, face: BotFace) {
        let settings = Settings.shared, directory = BotDirectory.shared
        if let bot = conversation.bot {
            return (bot.name, (directory.key == settings.connectionKey ? directory.roster?.faces[bot.profile] : nil) ?? BotFace(seed: bot.profile))
        }
        return (settings.headerTitle, directory.mainFace)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BotAvatar(face: agent.face, name: agent.name, size: 28)
                Text(single ? String(localized: "\(agent.name) has a question") : String(localized: "\(agent.name) has a few questions"))
                    .chatFont(.subheadline, weight: .semibold)
                Spacer(minLength: 0)
            }
            ForEach(Array(request.questions.enumerated()), id: \.element.id) { index, q in
                if index > 0 { Divider().opacity(0.6) }
                question(q, number: single ? nil : index + 1)
            }
            if !tapAnswers, !(single && request.questions.allSatisfy { $0.choices.isEmpty }) {
                HStack(alignment: .center, spacing: 12) {
                    if !single {
                        Text("\(answeredCount) of \(request.questions.count) answered")
                            .chatFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Button(action: send) {
                        FilledButtonTitle(title: single ? String(localized: "Send") : String(localized: "Send answers"))
                            .chatFont(.subheadline, weight: .semibold)
                            .padding(.horizontal, 18).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(!allAnswered)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private func question(_ q: ClarifyQuestion, number: Int?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let number {
                    Text("\(number)")
                        .chatFont(.caption, weight: .bold).monospacedDigit()
                        .foregroundStyle(theme.userText)
                        .frame(width: 20, height: 20)
                        .background(answer(for: q).isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.5)) : AnyShapeStyle(theme.accent), in: .circle)
                }
                Text(q.question).chatFont(.body, weight: .medium).fixedSize(horizontal: false, vertical: true)
            }
            if !q.choices.isEmpty {
                PillFlow(spacing: 8) {
                    ForEach(q.choices, id: \.self) { choice in
                        let on = picked[q.id]?.contains(choice) == true
                        Button { tap(choice, in: q) } label: {
                            HStack(spacing: 5) {
                                if q.multiSelect || on { Image(systemName: on ? "checkmark" : "plus").font(.caption.weight(.bold)) }
                                Text(choice).chatFont(.subheadline, weight: .medium)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .foregroundStyle(on ? theme.userText : Color.primary)
                            .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.background), in: .capsule)
                            .overlay { Capsule().strokeBorder(on ? Color.clear : Color.primary.opacity(0.12), lineWidth: 1) }
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(q.choices.isEmpty ? String(localized: "Your answer") : String(localized: "Something else…"),
                          text: binding(for: q.id), axis: .vertical)
                    .lineLimit(1 ... 5)
                    .textFieldStyle(.plain)
                    .chatFont(.subheadline)
                    .focused($typing, equals: q.id)
                    .onSubmit { if single { send() } }
                if single, !(freeText[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(typing == q.id ? AnyShapeStyle(theme.accent.opacity(0.6)) : AnyShapeStyle(Color.clear), lineWidth: 1)
            }
        }
    }

    private func tap(_ choice: String, in q: ClarifyQuestion) {
        var set = picked[q.id] ?? []
        if q.multiSelect {
            if set.contains(choice) { set.remove(choice) } else { set.insert(choice) }
            picked[q.id] = set
        } else {
            picked[q.id] = set.contains(choice) ? [] : [choice]
            if tapAnswers, picked[q.id]?.isEmpty == false { send() }   // one tap answers a single question
        }
    }

    private func binding(for qid: String) -> Binding<String> {
        Binding(get: { freeText[qid] ?? "" }, set: { freeText[qid] = $0 })
    }

    private func answer(for q: ClarifyQuestion) -> String {
        let typed = (freeText[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return (picked[q.id] ?? []).sorted().joined(separator: ", ")
    }

    private var answeredCount: Int { request.questions.filter { !answer(for: $0).isEmpty }.count }
    private var allAnswered: Bool { request.questions.allSatisfy { !answer(for: $0).isEmpty } }

    private func send() {
        guard allAnswered else { return }
        var answers: [String: String] = [:]
        for q in request.questions { answers[q.id] = answer(for: q) }
        respond(answers)
    }
}

/// Pills laid out like words: as many on a line as fit, each as wide as its words.
struct PillFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let w = min(size.width, width)
            if !current.items.isEmpty, current.width + spacing + w > width {
                rows.append(current)
                current = ([], 0, 0)
            }
            current.width += (current.items.isEmpty ? 0 : spacing) + w
            current.height = max(current.height, size.height)
            current.items.append(index)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
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

/// A filled button's title: the theme's text on its accent, and dimmed text while disabled, when
/// the fill turns grey (white on grey couldn't be read, and didn't look disabled).
struct FilledButtonTitle: View {
    let title: String
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var body: some View { Text(title).foregroundStyle(isEnabled ? theme.userText : Color.secondary) }
}

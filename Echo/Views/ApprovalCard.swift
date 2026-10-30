import SwiftUI

/// The agent wants to do something that needs a yes: what it would do in plain words, a line a
/// step (`ApprovalSummary`), the command itself under a fold, and the gateway's choices. Headed by
/// the agent asking, as its questions are (redrawn 2026-10-30, asked "make the approval cards
/// nicer to look at" and "list in plain english what it's doing").
struct ApprovalCard: View {
    let request: ApprovalRequest
    /// Who asks, when it isn't the chat's own agent (a bot in a group chat).
    var asker: (name: String, face: BotFace)? = nil
    let respond: (String) -> Void
    @Environment(Conversation.self) private var conversation
    /// A request that names a kanban card (the agent putting the claude bot's work in place): its
    /// change, looked at before answering.
    @State private var showingChange = false
    @State private var showingCommand = false

    private var agent: (name: String, face: BotFace) {
        if let asker { return asker }
        let settings = Settings.shared, directory = BotDirectory.shared
        if let bot = conversation.bot {
            return (bot.name, (directory.key == settings.connectionKey ? directory.roster?.faces[bot.profile] : nil) ?? BotFace(seed: bot.profile))
        }
        return (settings.headerTitle, directory.mainFace)
    }

    private var summary: ApprovalSummary {
        let settings = Settings.shared
        return ApprovalSummary(request, agent: agent.name) { profile in
            if profile == "default" || profile == settings.profileName { return settings.headerTitle }
            return BotDirectory.shared.roster?.named(profile)?.label(mainName: settings.headerTitle) ?? profile.capitalized
        }
    }

    var body: some View {
        let summary = summary
        let warn = summary.risky ? Color.red : Color.orange
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                BotAvatar(face: agent.face, name: agent.name, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.headline).chatFont(.subheadline, weight: .semibold)
                    Text(summary.place ?? String(localized: "Waiting for your OK", comment: "Under an approval card's headline"))
                        .chatFont(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: summary.risky ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                    .chatFont(.subheadline).foregroundStyle(warn)
                    .accessibilityHidden(true)
            }

            if !summary.steps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(summary.steps.enumerated()), id: \.offset) { _, step in
                        Label {
                            Text(step.text).chatFont(.callout, weight: step.risky ? .semibold : nil)
                                .foregroundStyle(step.risky ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: step.symbol)
                                .chatFont(.footnote, weight: .semibold)
                                .foregroundStyle(step.risky ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                                .frame(width: 22)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if summary.size != nil || request.kanbanCard != nil && KanbanClient.isAvailable {
                HStack(spacing: 12) {
                    if let size = summary.size {
                        Text(size).chatFont(.caption, design: .monospaced).foregroundStyle(.secondary)
                    }
                    if request.kanbanCard != nil, KanbanClient.isAvailable {
                        Button("View Changes", systemImage: "plus.forwardslash.minus") { showingChange = true }
                            .chatFont(.caption, weight: .medium)
                            .buttonStyle(.borderless)
                    }
                }
            }

            if summary.reason != nil || summary.command != nil {
                VStack(alignment: .leading, spacing: 8) {
                    // Hermes's rule for asking ("recursive delete").
                    if let reason = summary.reason {
                        Text("Hermes asks first for: \(reason)", comment: "Under an approval: the rule Hermes asked by")
                            .chatFont(.caption).foregroundStyle(.secondary)
                    }
                    if let command = summary.command {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { showingCommand.toggle() }
                        } label: {
                            Label(showingCommand ? String(localized: "Hide the command", comment: "Approval card: folds the command away")
                                  : String(localized: "Show the command", comment: "Approval card: shows the command as sent"),
                                  systemImage: showingCommand ? "chevron.down" : "chevron.right")
                                .chatFont(.caption, weight: .medium)
                        }
                        .buttonStyle(.borderless)
                        if showingCommand {
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(command)
                                    .chatFont(.footnote, design: .monospaced)
                                    .textSelection(.enabled)
                                    .padding(10)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background, in: .rect(cornerRadius: 10))
                            .transition(.opacity)
                        }
                    }
                }
            }

            buttons(risky: summary.risky)
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20).strokeBorder(warn.opacity(summary.risky ? 0.55 : 0.35), lineWidth: summary.risky ? 1 : 0.75)
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .sheet(isPresented: $showingChange) {
            if let card = request.kanbanCard { CardChangeSheet(cardID: card) }
        }
    }

    /// Deny, then Allow (this once) as the one big button, and this session or always behind it.
    private func buttons(risky: Bool) -> some View {
        let more = request.choices.filter { $0 != "once" && $0 != "deny" }
        return HStack(spacing: 10) {
            if request.choices.contains("deny") {
                Button(role: .cancel) { respond("deny") } label: {
                    Text(label(for: "deny")).chatFont(.subheadline, weight: .medium).padding(.horizontal, 10).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
            Spacer(minLength: 0)
            if !more.isEmpty {
                Menu {
                    ForEach(more, id: \.self) { choice in
                        Button(label(for: choice)) { respond(choice) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .chatFont(.subheadline, weight: .semibold)
                        .frame(width: 34, height: 34)
                        .background(.background, in: .circle)
                        .contentShape(.circle)
                }
                .accessibilityLabel(String(localized: "More ways to allow", comment: "Approval card: the menu with This Session and Always"))
            }
            if request.choices.contains("once") {
                Button { respond("once") } label: {
                    FilledButtonTitle(title: String(localized: "Allow Once", comment: "Approval button: allow it this one time"))
                        .chatFont(.subheadline, weight: .semibold)
                        .padding(.horizontal, 14).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(risky ? .red : nil)
            }
        }
    }

    private func label(for choice: String) -> String {
        switch choice {
        case "once": String(localized: "Once", comment: "Approval button: allow the command this one time")
        case "session": String(localized: "Allow for This Session", comment: "Approval menu: allow it for this session")
        case "always": String(localized: "Always Allow", comment: "Approval menu: always allow it")
        case "deny": String(localized: "Deny", comment: "Approval button: refuse the command")
        default: choice.capitalized
        }
    }
}

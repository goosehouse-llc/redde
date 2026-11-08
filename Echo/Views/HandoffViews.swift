import SwiftUI

/// Under a reply that handed work to another bot (`message_agent`): that bot, at work on it or done,
/// a tap from its chat (asked 2026-11-08). Followed live while it is recent (`HandoffWatch`).
struct HandoffRow: View {
    let target: String
    /// When it was asked.
    let at: Date
    @Environment(\.theme) private var theme
    @State private var watch = HandoffWatch.shared

    /// A hand-off older than this is shown as made, not followed.
    static let followed: TimeInterval = 30 * 60

    var body: some View {
        if let bot = HandoffWatch.profile(named: target) {
            let recent = Date.now.timeIntervalSince(at) < Self.followed
            let progress = watch.progress[bot.name].flatMap { found in
                (found.asked ?? .distantPast) >= at.addingTimeInterval(-120) ? found : nil
            }
            Button { LaunchRouter.shared.requestBot(bot.name) } label: {
                row(bot, progress: progress, recent: recent)
            }
            .buttonStyle(.plain)
            .onAppear { if recent { watch.start(bot.name, eager: true) } }
            .onDisappear { if recent { watch.stop(bot.name, eager: true) } }
        }
    }

    private func row(_ bot: HermesBot, progress: Handoff.Progress?, recent: Bool) -> some View {
        let name = bot.label(mainName: Settings.shared.headerTitle)
        let face = BotDirectory.shared.roster?.faces[bot.name] ?? .main
        let working = progress?.phase == .working
        let answered = progress?.phase == .answered
        return HStack(spacing: 10) {
            BotAvatar(face: face, name: name, size: 30)
                .overlay(alignment: .bottomTrailing) {
                    if answered {
                        Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                            .background(Circle().fill(theme.pageColor)).offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if answered {
                        Text("\(name) answered", comment: "Under a reply that asked another bot: that bot has written its answer")
                    } else if working {
                        Text("\(name) is working on it", comment: "Under a reply that asked another bot: that bot is at work on it now")
                    } else if recent {
                        Text("Waiting for \(name)", comment: "Under a reply that asked another bot: it hasn't started yet")
                    } else {
                        Text("Asked \(name)", comment: "Under an older reply that asked another bot")
                    }
                }
                .chatFont(.subheadline, weight: .semibold)
                .lineLimit(1)
                if working, let progress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(detail(progress)).lineLimit(1)
                    }
                    .chatFont(.caption).foregroundStyle(.secondary)
                } else if recent, progress == nil {
                    Text("Starting…", comment: "Under a reply that asked another bot: its turn hasn't begun yet")
                        .chatFont(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Text(answered || !recent ? "Open" : "Watch", comment: "Under a reply that asked another bot: opens that bot's chat")
                .chatFont(.caption, weight: .semibold).foregroundStyle(theme.accent)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(working ? 0.07 : 0.045), in: .rect(cornerRadius: 14))
        .overlay {
            if working { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.accent.opacity(0.35), lineWidth: 1) }
        }
        .contentShape(.rect)
        .animation(.easeOut(duration: 0.2), value: progress?.phase)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens \(name)'s chat", comment: "Under a reply that asked another bot: what tapping does"))
    }

    private func detail(_ progress: Handoff.Progress) -> String {
        guard let step = progress.step else { return String(localized: "Reading what it was asked", comment: "A bot at work for another bot, before its first step") }
        return progress.steps > 1 ? String(localized: "\(step) · \(progress.steps) steps", comment: "A bot at work for another bot: what it is doing now, and how many steps so far") : step
    }
}

/// Under a reply that made a kanban card for another bot (`kanban_create`, Sol's `claude_card` for
/// Coder): the card's bot at work on it, waiting, stuck or done, followed live; a tap opens the card
/// (asked 2026-11-08, of Sol's card for Coder: "I have no idea if coder is doing anything").
struct HandoffCardRow: View {
    let named: String?
    let assignee: String?
    let at: Date
    @Environment(\.theme) private var theme
    @State private var watch = HandoffWatch.shared
    @State private var id: String?
    @State private var showing = false

    var body: some View {
        let card = id.flatMap { watch.cards[$0] }
        let profile = card?.assignee ?? assignee
        let bot = profile.flatMap { name in BotDirectory.shared.bots(for: Settings.shared.connectionKey).first { $0.name == name } }
        let name = bot?.label(mainName: Settings.shared.headerTitle) ?? profile ?? String(localized: "The board", comment: "A kanban card with no one on it, as who has it")
        let face = bot.flatMap { BotDirectory.shared.roster?.faces[$0.name] }
        Button { if id != nil { showing = true } } label: { row(card, name: name, face: face) }
            .buttonStyle(.plain)
            .task(id: named) {
                // The card's id: named by the call or the reply, else found on the board by its time.
                let found: String?
                if let named { found = named } else { found = await watch.findCard(assignee: assignee, at: at) }
                guard let found else { return }
                id = found
                watch.startCard(found)
                await withTaskCancellationHandler {
                    try? await Task.sleep(for: .seconds(365 * 86_400))
                } onCancel: {
                    Task { @MainActor in HandoffWatch.shared.stopCard(found) }
                }
            }
            .sheet(isPresented: $showing) {
                if let id { KanbanCardDetail(taskID: id) {} }
            }
    }

    private func row(_ card: KanbanTask?, name: String, face: BotFace?) -> some View {
        let status = card?.status ?? ""
        let working = status == "running"
        let finished = ["done", "review", "archived"].contains(status)
        let stuck = status == "blocked"
        return HStack(spacing: 10) {
            Group {
                if let face { BotAvatar(face: face, name: name, size: 30) } else {
                    Image(systemName: "rectangle.stack").font(.body).foregroundStyle(theme.accent).frame(width: 30, height: 30)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if finished || stuck {
                    Image(systemName: stuck ? "exclamationmark.circle.fill" : "checkmark.circle.fill").font(.caption)
                        .foregroundStyle(stuck ? .orange : .green)
                        .background(Circle().fill(theme.pageColor)).offset(x: 3, y: 3)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if working {
                        Text("\(name) is working on it", comment: "Under a reply that made a card for another bot: that bot is at work on it now")
                    } else if finished {
                        Text("\(name) finished", comment: "Under a reply that made a card for another bot: the card is done")
                    } else if stuck {
                        Text("\(name) is stuck", comment: "Under a reply that made a card for another bot: the card is blocked")
                    } else if card != nil {
                        Text("Waiting for \(name) to start", comment: "Under a reply that made a card for another bot: the card waits on the board")
                    } else {
                        Text("Handed to \(name)", comment: "Under a reply that made a card for another bot, before the card is read")
                    }
                }
                .chatFont(.subheadline, weight: .semibold)
                .lineLimit(1)
                HStack(spacing: 6) {
                    if working { ProgressView().controlSize(.mini) }
                    Text(detail(card)).lineLimit(2)
                }
                .chatFont(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if card != nil {
                Text("Card", comment: "Under a reply that made a card for another bot: opens the card")
                    .chatFont(.caption, weight: .semibold).foregroundStyle(theme.accent)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(working ? 0.07 : 0.045), in: .rect(cornerRadius: 14))
        .overlay {
            if working { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.accent.opacity(0.35), lineWidth: 1) }
        }
        .contentShape(.rect)
        .animation(.easeOut(duration: 0.2), value: status)
        .accessibilityElement(children: .combine)
    }

    /// What the card's bot last said of it, else how long it has been at it, else the card's title.
    private func detail(_ card: KanbanTask?) -> String {
        guard let card else { return named ?? String(localized: "A card on the board", comment: "Under a reply that made a card for another bot, before the card is read") }
        if card.status == "blocked", let why = card.lastFailure ?? card.latestSummary, !why.isEmpty { return why }
        if let summary = card.latestSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty { return PlainText.display(summary) }
        if card.status == "running", let started = card.startedAt {
            let minutes = max(1, Int(Date.now.timeIntervalSince(started) / 60))
            return String(localized: "\(card.title) · \(minutes) min", comment: "A card being worked on: its title and for how long")
        }
        return card.title
    }
}

/// Over a bot's chat while it works on what another bot asked (`HandoffWatch`): who for and what it
/// is doing, and the chat read again as each of its steps lands.
struct HandoffStrip: View {
    let conversation: Conversation
    @State private var watch = HandoffWatch.shared
    @State private var watching: String?

    var body: some View {
        let profile = conversation.isStreaming ? nil : conversation.bot?.profile
        Group {
            if let profile, let progress = watch.progress[profile], progress.phase == .working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Working for \(progress.from)", comment: "Over a bot's chat: it is at work on what another bot asked of it")
                        .fontWeight(.semibold)
                    if let step = progress.step {
                        Text(verbatim: "·")
                        Text(step).lineLimit(1)
                    }
                }
                .chatFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeOut(duration: 0.2), value: profile.flatMap { watch.progress[$0]?.phase })
        .onAppear { follow(profile) }
        .onDisappear { follow(nil) }
        .onChange(of: profile) { _, new in follow(new) }
        .onChange(of: profile.flatMap { watch.stamp[$0] }) { _, newest in
            // Its chat moved while it works, or as it answers: read again, so its steps show.
            guard let profile, let newest, let progress = watch.progress[profile],
                  progress.phase == .working || Date.now.timeIntervalSince(progress.lastActive ?? .distantPast) < 60,
                  newest > (conversation.messages.last?.createdAt ?? .distantPast).addingTimeInterval(2),
                  let bot = BotDirectory.shared.bots(for: Settings.shared.connectionKey).first(where: { $0.name == profile }) else { return }
            Task { await conversation.followHandoff(bot) }
        }
    }

    private func follow(_ profile: String?) {
        guard profile != watching else { return }
        if let watching { watch.stop(watching) }
        watching = profile
        if let profile { watch.start(profile) }
    }
}

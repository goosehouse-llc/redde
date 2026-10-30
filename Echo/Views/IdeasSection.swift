import SwiftUI

/// The agents' ideas on this phone (`AgentIdea`), for the chat list: read again when Redde comes
/// to the front and when a note of ideas arrives with it open.
@MainActor
@Observable
final class IdeasInbox {
    static let shared = IdeasInbox()
    private(set) var ideas: [AgentIdea] = []

    init() {
        #if DEBUG
        // `-echo.demoDay ideas`: the day's video's (`DemoDay`).
        if DemoDay.on {
            ideas = DemoDay.scene == "ideas" ? DemoDay.ideas : []
            return
        }
        // `-echo.demoIdeas`: three made-up ideas, for screenshots.
        if DevHooks.has("-echo.demoIdeas") {
            ideas = [AgentIdea(id: "demo/0", profile: "default", agent: "Sol", title: "Book the vet for Pickles",
                               why: "His jab is due Friday and Thursday afternoon is free", request: "Book Pickles in at the vet on Thursday afternoon", at: .now),
                     AgentIdea(id: "demo/1", profile: "default", agent: "Sol", title: "Move the dentist to next week",
                               why: "It clashes with the school play at 3", request: "Ask the dentist to move my appointment to next week", at: .now),
                     AgentIdea(id: "demo/2", profile: "ops", agent: "Home", title: "Turn the heating down while you're away",
                               why: "Nobody's home until Sunday", request: "Set the heating to 15° until Sunday evening", at: .now)]
            return
        }
        #endif
        ideas = AgentIdea.showing()
        wakeForNextBack()
    }

    private var waking: Task<Void, Never>?

    func reload() {
        #if DEBUG
        if DevHooks.has("-echo.demoIdeas") || DemoDay.on { return }
        #endif
        let now = AgentIdea.showing()
        if now != ideas { withAnimation(.snappy) { ideas = now } }
        wakeForNextBack()
    }

    /// With Redde open, one put off comes back into the deck when its time comes.
    private func wakeForNextBack() {
        waking?.cancel()
        guard let back = AgentIdea.nextBack() else { return }
        waking = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, back.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// Put off until `until`, with a quiet notification when it's back.
    func later(_ idea: AgentIdea, until: Date) {
        #if DEBUG
        if DemoDay.on || DevHooks.has("-echo.demoIdeas") { ideas.removeAll { $0.id == idea.id }; return }
        #endif
        AgentIdea.snooze(idea.id, until: until)
        LaterReminder.idea(idea, at: until)
        reload()
    }

    /// More Like This, or Fewer Like This (which puts it away too).
    func said(_ idea: AgentIdea, liked: Bool) {
        FeedbackFold.said(.idea, title: idea.title, agent: idea.agent, liked: liked)
        if !liked { remove(idea) }
    }

    /// Taken or put away.
    func remove(_ idea: AgentIdea) {
        #if DEBUG
        if DemoDay.on { ideas.removeAll { $0.id == idea.id }; return }
        #endif
        AgentIdea.remove(idea.id)
        LaterReminder.cancel(idea.id)
        reload()
    }
}

/// "Ideas for you", at the top of the chat list: the cards an agent offered (`suggest_to_user`), as
/// a deck. Drag the top one right, or Do It, and its request goes to that agent as the person's
/// message; left, or Not Now, it is put away; Done, for one they saw to themselves. Each card wears
/// the face and colour of the agent that offered it, the face looking the way it is dragged (asked
/// 2026-10-28: "a bit more fun", after OpenDuet's suggestion cards). Under Reduce Motion the cards
/// don't tilt or fly; they fade.
struct IdeasSection: View {
    let take: (AgentIdea) -> Void
    @State private var inbox = IdeasInbox.shared

    var body: some View {
        if !inbox.ideas.isEmpty {
            Section {
                IdeaDeck(ideas: inbox.ideas, take: take, put: { idea in inbox.remove(idea) },
                         later: { inbox.later($0, until: $1) }, said: { inbox.said($0, liked: $1) })
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } header: {
                Text("Ideas for you")
            }
        }
    }
}

private struct IdeaDeck: View {
    let ideas: [AgentIdea]
    let take: (AgentIdea) -> Void
    /// Put away: Not Now, or Done.
    let put: (AgentIdea) -> Void
    /// Hold a card: Later, and More or Fewer Like This (asked 2026-10-28, "Proactive").
    let later: (AgentIdea, Date) -> Void
    let said: (AgentIdea, Bool) -> Void
    @State private var noted = 0
    @Environment(\.theme) private var theme

    var body: some View {
        SwipeDeck(
            items: ideas,
            right: .init(stamp: String(localized: "Do It"), color: .green, act: take),
            left: .init(stamp: String(localized: "Not Now"), color: .red, act: put),
            // Not Now in red on the left, Do It in the middle and larger, Done on the right (his
            // order, 2026-10-28); the bolt says "let's do it" more than sparkles did.
            buttons: [.init(symbol: "xmark", label: String(localized: "Not Now"), color: .red, fly: -1, act: put),
                      .init(symbol: "bolt.fill", label: String(localized: "Do It"), color: .green, size: 64, fly: 1, act: take),
                      .init(symbol: "checkmark", label: done, color: .blue, fly: -1, act: put)],
            actions: [(String(localized: "Later"), { later($0, Later.soon()) }),
                      (String(localized: "More Like This"), { said($0, true); noted += 1 }),
                      (String(localized: "Fewer Like This"), { said($0, false) })],
            face: { idea, isTop, moved in cardFace(idea, isTop: isTop, moved: moved) },
            menu: { menu($0) },
            footer: {
                if ideas.count > 1 {
                    Text("\(1) of \(ideas.count) · Hold a card for more").monospacedDigit()
                } else {
                    Text("Hold the card for more")
                }
            })
        .sensoryFeedback(.success, trigger: noted)
    }

    private func cardFace(_ idea: AgentIdea, isTop: Bool, moved: CGFloat) -> some View {
        let face = DeckCard.face(profile: idea.profile)
        return VStack(alignment: .leading, spacing: 10) {
            DeckCardHeader(face: face, name: idea.agent, subtitle: Text("has an idea", comment: "Under an agent's name on an idea card"),
                           symbol: "lightbulb.max.fill", isTop: isTop, moved: moved, bounce: idea.id)
            Text(idea.title)
                .chatFont(.title3, weight: .bold, design: .rounded)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
            if let why = idea.why {
                Text(why).chatFont(.subheadline).opacity(0.75).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .deckCard(face, theme: theme)
    }

    @ViewBuilder private func menu(_ idea: AgentIdea) -> some View {
        Section("Later") {
            ForEach(Later.choices(), id: \.0) { choice, when in
                Button { later(idea, when) } label: { Label { Text(choice.label) } icon: { Image(systemName: choice.symbol) } }
            }
        }
        // Heard the next time the agent thinks of ideas (`FeedbackFold`).
        Section("Tell Your Agent") {
            Button("More Like This", systemImage: "hand.thumbsup") { said(idea, true); noted += 1 }
            Button("Fewer Like This", systemImage: "hand.thumbsdown") { said(idea, false) }
        }
    }

    /// "Done" as a thing finished, the word a finished task and the Kanban column have.
    private var done: String {
        String(localized: "task.done", defaultValue: "Done", comment: "A task, finished (not the Done button): a ticked checklist item, the agent's finished task, the Kanban column, the title after a plugin change")
    }
}

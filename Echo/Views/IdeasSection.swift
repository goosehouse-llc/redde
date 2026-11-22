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
        touched(idea)
        #if DEBUG
        if DemoDay.on || DevHooks.has("-echo.demoIdeas") { ideas.removeAll { $0.id == idea.id }; return }
        #endif
        AgentIdea.snooze(idea.id, until: until)
        LaterReminder.idea(idea, at: until)
        reload()
    }

    /// More Like This, or Fewer Like This (which puts it away too).
    func said(_ idea: AgentIdea, liked: Bool) {
        touched(idea)
        FeedbackFold.said(.idea, title: idea.title, agent: idea.agent, liked: liked)
        if !liked { remove(idea) }
    }

    /// The agents whose cards were touched lately, and when: told to the plugin once an hour each.
    @ObservationIgnored private var told: [String: Date] = [:]

    /// One of an agent's cards taken, put away, put off or answered (plugin 1.36): that agent's
    /// ideas, quiet after sets left alone, notify again.
    private func touched(_ idea: AgentIdea) {
        #if DEBUG
        if DemoDay.on || DevHooks.has("-echo.demoIdeas") { return }
        #endif
        let profile = idea.profile.isEmpty ? "default" : idea.profile
        if let last = told[profile], last.timeIntervalSinceNow > -3_600 { return }
        told[profile] = .now
        Task { _ = try? await PushService.command(over: .shared)("ideas touched \(profile)") }
    }

    /// Don't Suggest This (plugin 1.36): put away, heard as Fewer Like This, and its heading kept
    /// on the Hermes so no agent offers its like again (`IdeasBlocked`).
    func block(_ idea: AgentIdea) {
        FeedbackFold.said(.idea, title: idea.title, agent: idea.agent, liked: false)
        remove(idea)
        #if DEBUG
        if DemoDay.on || DevHooks.has("-echo.demoIdeas") { return }
        #endif
        let title = idea.title
        Task { _ = await IdeasBlocked.block(title) }
    }

    /// Taken or put away.
    func remove(_ idea: AgentIdea) {
        touched(idea)
        #if DEBUG
        if DemoDay.on { ideas.removeAll { $0.id == idea.id }; return }
        #endif
        AgentIdea.remove(idea.id)
        LaterReminder.cancel(idea.id)
        reload()
    }
}

/// What the person said not to suggest (Don't Suggest This on an idea, plugin 1.36), kept on the
/// Hermes for every agent: `/redde-push ideas block|unblock <heading>` and `ideas blocked`, the
/// headings base64url, over either connection.
enum IdeasBlocked {
    @MainActor
    static func block(_ title: String) async -> Bool {
        await say("block", title) == "redde-push ideas blocked"
    }

    @MainActor
    static func unblock(_ title: String) async -> Bool {
        await say("unblock", title) == "redde-push ideas unblocked"
    }

    /// Nil when the Hermes can't say (an older plugin, or out of reach).
    @MainActor
    static func list() async -> [String]? {
        guard let reply = try? await PushService.command(over: .shared)("ideas blocked") else { return nil }
        return parse(reply)
    }

    static func parse(_ reply: String) -> [String]? {
        let prefix = "redde-push ideas blocked "
        guard reply.hasPrefix(prefix), let data = PushSeal.data(base64URL: String(reply.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    static func line(_ verb: String, _ title: String) -> String {
        "ideas \(verb) \(PushSeal.base64URL(Data(title.utf8)))"
    }

    @MainActor
    private static func say(_ verb: String, _ title: String) async -> String? {
        (try? await PushService.command(over: .shared)(line(verb, title)))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Morning Ideas › Not Suggested: what the person said not to suggest, each to let back in.
struct NotSuggestedSection: View {
    @State private var titles: [String]?
    @State private var problem: String?

    var body: some View {
        Group {
            if let titles, !titles.isEmpty {
                Section {
                    ForEach(titles, id: \.self) { Text($0) }
                        .onDelete { rows in
                            for title in rows.map({ titles[$0] }) { allow(title) }
                        }
                } header: {
                    Text("Not Suggested", comment: "Morning Ideas: the list of ideas the person said not to suggest again")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("You said not to suggest these (Don't Suggest This on an idea). Your agents leave out ideas like them. Swipe one away to let it back in.",
                             comment: "Morning Ideas: under Not Suggested")
                        if let problem { Text(problem).foregroundStyle(.red) }
                    }
                }
            }
        }
        .task { titles = await IdeasBlocked.list() }
    }

    private func allow(_ title: String) {
        titles?.removeAll { $0 == title }
        problem = nil
        Task {
            if await !IdeasBlocked.unblock(title) {
                problem = String(localized: "Couldn't reach your Hermes. Try again in a moment.", comment: "A goal's step couldn't be ticked: the server didn't answer")
                titles = await IdeasBlocked.list()
            }
        }
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
    @AppStorage(ChatListCard.ideas.foldKey) private var isOpen = true

    var body: some View {
        if !inbox.ideas.isEmpty {
            Section {
                if isOpen {
                    IdeaDeck(ideas: inbox.ideas, take: take, put: { idea in inbox.remove(idea) },
                             later: { inbox.later($0, until: $1) }, said: { inbox.said($0, liked: $1) }, block: { inbox.block($0) })
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } header: {
                FoldingHeader(title: ChatListCard.ideas.title, count: inbox.ideas.count, isOpen: $isOpen)
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
    /// Don't Suggest This (plugin 1.36).
    let block: (AgentIdea) -> Void
    @State private var noted = 0
    /// The idea tapped, read in full before it is done or put away (`IdeaDetail`).
    @State private var reading: AgentIdea?
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
                      (String(localized: "Fewer Like This"), { said($0, false) }),
                      (dontSuggest, { block($0) })],
            tap: { reading = $0 },
            face: { idea, isTop, moved in cardFace(idea, isTop: isTop, moved: moved) },
            menu: { menu($0) },
            footer: {
                // The same shape as the Briefings deck's: its swipe, then hold (2.4 tidy).
                if ideas.count > 1 {
                    Text("\(1) of \(ideas.count) · Tap to read, swipe right to do it", comment: "Under the ideas deck: which card of how many, and its gestures").monospacedDigit()
                } else {
                    Text("Tap to read, swipe right to do it", comment: "Under the ideas deck with one card: its gestures")
                }
            })
        .sensoryFeedback(.success, trigger: noted)
        .sheet(item: $reading) { idea in
            IdeaDetail(idea: idea, take: take, put: put, later: later, block: block)
        }
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
            Button(dontSuggest, systemImage: "nosign", role: .destructive) { block(idea) }
        }
    }

    private var dontSuggest: String {
        String(localized: "Don't Suggest This", comment: "An idea card's menu: put it away and never offer ideas like it again")
    }

    /// "Done" as a thing finished, the word a finished task and the Kanban column have.
    private var done: String {
        String(localized: "task.done", defaultValue: "Done", comment: "A task, finished (not the Done button): a ticked checklist item, the agent's finished task, the Kanban column, the title after a plugin change")
    }
}

/// An idea in full, from a tap on its card (asked 2026-11-22: "allow to tap on the card to see what it
/// says before making me dismiss or push it"): the card cuts its words at three lines and never showed
/// what Do It sends. Here: who offered it and when, every word of it, the message Do It sends that
/// agent, and Do It, Not Now, Done and Later.
private struct IdeaDetail: View {
    let idea: AgentIdea
    let take: (AgentIdea) -> Void
    let put: (AgentIdea) -> Void
    let later: (AgentIdea, Date) -> Void
    let block: (AgentIdea) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        let face = DeckCard.face(profile: idea.profile)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        DeckCardHeader(face: face, name: idea.agent,
                                       subtitle: Text("has an idea · \(idea.at.relativeLabel)", comment: "Under an agent's name on an opened idea: when it was offered, e.g. has an idea · 2 hours ago"),
                                       symbol: "lightbulb.max.fill")
                        Text(idea.title)
                            .chatFont(.title2, weight: .bold, design: .rounded)
                            .fixedSize(horizontal: false, vertical: true)
                        if let why = idea.why, !why.isEmpty {
                            Text(why).chatFont(.body).opacity(0.8).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .deckCard(face, theme: theme)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Do It sends \(idea.agent.isEmpty ? String(localized: "Your agent") : idea.agent) this", comment: "Over the message an idea's Do It sends, on the opened idea: the agent's name")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(idea.request)
                            .chatFont(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 14))
                            .accessibilityIdentifier("idea-request")
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { choices }
            .navigationTitle(Text("Idea", comment: "The title of an opened idea card"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(Later.choices(), id: \.0) { choice, when in
                            Button { act { later(idea, when) } } label: { Label { Text(choice.label) } icon: { Image(systemName: choice.symbol) } }
                        }
                        Divider()
                        Button(role: .destructive) { act { block(idea) } } label: {
                            Label { Text("Don't Suggest This", comment: "An idea card's menu: put it away and never offer ideas like it again") } icon: { Image(systemName: "nosign") }
                        }
                        .accessibilityIdentifier("idea-dont-suggest")
                    } label: {
                        Label { Text("Later") } icon: { Image(systemName: "clock") }
                    }
                }
            }
        }
        // Tall enough for a card, its message and the buttons; drag up for a long one.
        .presentationDetents([.fraction(0.72), .large])
    }

    /// Not Now, Done and Do It, as the deck's buttons have them.
    private var choices: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) { act { put(idea) } } label: {
                Text("Not Now").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityIdentifier("idea-not-now")
            Button { act { put(idea) } } label: {
                Text(verbatim: done).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button { act { take(idea) } } label: {
                Label { Text("Do It") } icon: { Image(systemName: "bolt.fill") }.frame(maxWidth: .infinity)
            }
            .prominentButton(tint: .green)
            .accessibilityIdentifier("idea-do-it")
        }
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// The sheet goes first, then the choice, so the deck moves on under it.
    private func act(_ choice: @escaping () -> Void) {
        dismiss()
        choice()
    }

    private var done: String {
        String(localized: "task.done", defaultValue: "Done", comment: "A task, finished (not the Done button): a ticked checklist item, the agent's finished task, the Kanban column, the title after a plugin change")
    }
}


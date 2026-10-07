import SwiftUI

/// What an empty conversation shows: the app's mark, a greeting for the time of day, and up to
/// three things to start from, each one tap.
///
/// - The calendar: the next event today or tomorrow, when Redde already has calendar access;
///   tapping asks about that day with its events attached. Before access was ever asked, the card
///   offers the question instead and the tap asks for access. Nothing here asks on its own.
/// - The last conversation, to carry on with.
/// - Home, when the gateway says the agent has Home Assistant.
///
/// The pieces come in one after another. The mark's pulse is scale and opacity only, and the
/// screen is gone once there is a message, so none of this runs beside a transcript.
struct StartScreen: View {
    @Environment(Conversation.self) private var conversation
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = ConversationStore.shared
    @State private var settings = Settings.shared

    @State private var calendarAccess = ComposerContext.calendarAccess
    @State private var upcoming: StartCards.Upcoming?
    @State private var home = false
    /// A card's tap is being carried out (the calendar is read, access asked for).
    @State private var busy: String?
    /// How many of the pieces have come in.
    @State private var shown = 0
    @State private var pulse = false
    /// Where the "Continue" card is on screen, for its conversation to open out of.
    @State private var continueFrame = CGRect.zero

    /// Opens the last conversation out of its card: given the card's frame and the load to run
    /// once it is covered. Without it (and under Reduce Motion) the conversation just appears.
    var openFromCard: ((_ card: CGRect, _ title: String, _ load: @escaping @MainActor () -> Void) -> Void)?

    /// Whether the agent has Home Assistant, per connection: asked of the gateway once.
    private static var homeByConnection: [String: Bool] = [:]

    private struct Card: Identifiable {
        var id: String
        var symbol: String
        var title: String
        var subtitle: String
        var hint: String
        var action: () -> Void
    }

    private var cards: [Card] {
        var cards: [Card] = []
        if let upcoming {
            cards.append(Card(id: "calendar", symbol: "calendar", title: upcoming.title, subtitle: upcoming.subtitle,
                              hint: "Asks about that day, with its events attached") {
                askAboutCalendar(day: upcoming.day, question: upcoming.question)
            })
        } else if calendarAccess == .notAsked {
            cards.append(Card(id: "calendar", symbol: "calendar", title: "What's on my calendar today?", subtitle: "Attaches today's events",
                              hint: "Asks for calendar access, then asks about today") {
                askAboutCalendar(day: .now, question: "What's on my calendar today?")
            })
        }
        if let last = store.sorted.first(where: { $0.id != conversation.id && $0.turnCount > 0 }) {
            cards.append(Card(id: "continue", symbol: "bubble.left.and.text.bubble.right", title: "Continue: \(last.title)",
                              subtitle: last.updatedAt.relativeLabel, hint: "Opens your most recent conversation") {
                guard let record = store.record(id: last.id) else { return }
                let (conversation, frame) = (conversation, continueFrame)
                if let openFromCard, !reduceMotion, frame != .zero {
                    openFromCard(frame, "Continue: \(last.title)") { conversation.load(record) }
                } else {
                    conversation.load(record)
                }
            })
        }
        if home {
            cards.append(Card(id: "home", symbol: "lightbulb", title: "What's on at home?", subtitle: "Home Assistant is connected",
                              hint: "Asks what is on at home") {
                conversation.send("What's on at home right now?")
            })
        }
        return cards
    }

    var body: some View {
        let cards = cards
        AboveMiddle(lift: Self.windowHeight * 0.06) {
            VStack(spacing: 24) {
                mark.modifier(Arriving(index: 0, shown: shown))
                VStack(spacing: 6) {
                    Text(Self.greeting(for: .now))
                        .font(.system(.title, weight: .bold))
                        .modifier(Arriving(index: 1, shown: shown))
                    Text("What should \(settings.headerTitle) look into?")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .modifier(Arriving(index: 2, shown: shown))
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                // No "connect" button here: the greeting and the composer already say what to do, and
                // setup opens on first launch and from Settings → Connection.
                VStack(spacing: 10) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        cardView(card)
                            .modifier(Arriving(index: 3 + index, shown: shown))
                            .transition(.opacity.combined(with: .offset(y: 10)))
                    }
                }
                .animation(.easeOut(duration: 0.35), value: cards.map(\.id))
            }
            .frame(maxWidth: .infinity)
        }
        .containerRelativeFrame(.vertical) { height, _ in max(0, height - 60) }
        .task {
            upcoming = StartCards.upcoming(ComposerContext.eventsTodayAndTomorrow(), now: .now)
            // One piece every 90 ms; all at once under Reduce Motion.
            for count in 1 ... 6 {
                if !reduceMotion { try? await Task.sleep(for: .milliseconds(count == 1 ? 60 : 90)) }
                shown = count
            }
        }
        .task(id: settings.connectionKey) { await findHome() }
    }

    /// The height of the app's window: what "6% higher" is 6% of, to the eye. The room the start
    /// screen is laid out in is shorter, by the title bar and the message field.
    private static var windowHeight: CGFloat {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.height }.first ?? 0
    }

    // MARK: Pieces

    /// The app's waveform on the accent, with a ring widening off it.
    private var mark: some View {
        ZStack {
            Circle()
                .strokeBorder(theme.accent, lineWidth: 1.5)
                .frame(width: 44, height: 44)
                .scaleEffect(pulse ? 1.7 : 0.9)
                .opacity(pulse ? 0 : 0.55)
            Circle()
                .fill(theme.accent)
                .frame(width: 44, height: 44)
                .overlay { WaveformPulse(color: theme.userText, height: 20, spacing: 2.5, still: true) }
        }
        .frame(width: 64, height: 64)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityHidden(true)
    }

    private func cardView(_ card: Card) -> some View {
        Button(action: card.action) {
            HStack(spacing: 12) {
                Image(systemName: card.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.body.weight(.medium)).lineLimit(1)
                    Text(card.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if busy == card.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surfaceColor, in: .rect(cornerRadius: 16))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .accessibilityHint(card.hint)
        .background {
            // Only the one card that opens something is measured.
            if card.id == "continue" {
                Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { continueFrame = $0 }
            }
        }
    }

    // MARK: Actions

    /// Reads that day's events (asking for access the first time) and asks about them. Refused,
    /// the card goes away.
    private func askAboutCalendar(day: Date, question: String) {
        busy = "calendar"
        Task {
            if let events = await ComposerContext.calendarAttachment(for: day) {
                conversation.send(question, attachments: [events])
            }
            calendarAccess = ComposerContext.calendarAccess
            busy = nil
        }
    }

    private func findHome() async {
        // The OpenAI-compatible connection is a bare model: no tools to offer.
        guard settings.transport != .chatCompletions else { home = false; return }
        let key = settings.connectionKey
        if let known = Self.homeByConnection[key] { home = known; return }
        let toolsets: [HermesSessionsAPI.Toolset]?
        if HermesServeClient.shared.hasCredentials {
            toolsets = try? await HermesServeClient.shared.dashboardToolsets()
        } else {
            toolsets = try? await conversation.ledgerAPI()?.toolsets()
        }
        guard let toolsets, key == settings.connectionKey else { return }
        Self.homeByConnection[key] = StartCards.hasHomeAssistant(toolsets)
        home = Self.homeByConnection[key] ?? false
    }

    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning."
        case 12..<17: "Good afternoon."
        case 17..<22: "Good evening."
        default: "Hello."
        }
    }
}

/// Where the start screen sits in the room it is given: well above the middle. A third of the
/// spare room would go over it and two thirds under; it sits higher than that again by `lift`
/// points. Dead centre it sat low, between the title and a message field at the bottom. Content
/// with no room to spare starts at the top and runs on below.
private nonisolated struct AboveMiddle: Layout {
    var lift: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let content = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? content.width, height: max(proposal.height ?? content.height, content.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let size = content.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let top = max(0, (bounds.height - size.height) / 3 - lift)
        content.place(at: CGPoint(x: bounds.midX, y: bounds.minY + top), anchor: .top,
                      proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

/// A piece of the start screen coming in: up a little and out of nothing, when its turn comes.
private struct Arriving: ViewModifier {
    let index: Int
    let shown: Int

    func body(content: Content) -> some View {
        content
            .opacity(shown > index ? 1 : 0)
            .offset(y: shown > index ? 0 : 10)
            .animation(.easeOut(duration: 0.4), value: shown > index)
    }
}

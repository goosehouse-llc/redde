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
        ideas = AgentIdea.all()
    }

    func reload() {
        #if DEBUG
        if DevHooks.has("-echo.demoIdeas") || DemoDay.on { return }
        #endif
        let now = AgentIdea.all()
        if now != ideas { ideas = now }
    }

    /// Taken or put away.
    func remove(_ idea: AgentIdea) {
        #if DEBUG
        if DemoDay.on { ideas.removeAll { $0.id == idea.id }; return }
        #endif
        AgentIdea.remove(idea.id)
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
                IdeaDeck(ideas: inbox.ideas, take: take, put: { idea in inbox.remove(idea) })
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

    @State private var drag: CGFloat = 0
    /// The card on its way off, and which way (1 right, -1 left).
    @State private var leaving: CGFloat = 0
    @State private var armed: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// How far a card goes before letting go of it is a choice.
    private static let threshold: CGFloat = 100
    private static let shown = 3

    private var top: AgentIdea? { ideas.first }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(Array(ideas.prefix(Self.shown).enumerated()).reversed(), id: \.element.id) { depth, idea in
                    card(idea, depth: depth)
                }
            }
            .frame(height: 196)
            .frame(maxWidth: .infinity)
            buttons
            if ideas.count > 1 {
                Text("\(1) of \(ideas.count)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.top, 2)
    }

    // MARK: The cards

    private func card(_ idea: AgentIdea, depth: Int) -> some View {
        let isTop = depth == 0
        let moved = isTop ? drag + leaving : 0
        let colors = BotAvatar.colors(of: face(idea), theme: theme)
        let ink = Color(red: 0.09, green: 0.09, blue: 0.13)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BotAvatar(face: face(idea), name: idea.agent, size: 40,
                          pose: isTop ? BotPose(look: CGPoint(x: max(-1, min(1, moved / 90)), y: -0.2)) : nil)
                    .padding(5)
                    .background(Circle().fill(seat(for: colors.deep)))
                    .overlay(Circle().stroke(colors.deep.opacity(0.45), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(idea.agent.isEmpty ? String(localized: "Your agent") : idea.agent).font(.subheadline.weight(.bold))
                    Text("has an idea", comment: "Under an agent's name on an idea card").font(.caption)
                        .opacity(0.7)
                }
                Spacer(minLength: 0)
                Image(systemName: "lightbulb.max.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow, ink.opacity(0.25))
                    .symbolEffect(.bounce, value: isTop ? idea.id : "")
            }
            Text(idea.title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .lineLimit(3)
                .minimumScaleFactor(0.85)
            if let why = idea.why {
                Text(why).font(.subheadline).opacity(0.75).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(ink)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            // A pastel of the agent's colour, so dark words read on any of them and its face,
            // in the colour itself, stands out.
            LinearGradient(colors: [colors.deep.mix(with: .white, by: 0.82), colors.deep.mix(with: .white, by: 0.64)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 22))
        // The stamp lands in the corner the card leaves behind, where the finger isn't (asked 2026-10-28).
        .overlay(alignment: .topLeading) { if isTop { stamp(String(localized: "Do It"), color: .green, angle: -12).opacity(Double(max(0, moved) / Self.threshold)) } }
        .overlay(alignment: .topTrailing) { if isTop { stamp(String(localized: "Not Now"), color: .red, angle: 12).opacity(Double(max(0, -moved) / Self.threshold)) } }
        .shadow(color: .black.opacity(isTop ? 0.14 : 0.06), radius: isTop ? 10 : 4, y: isTop ? 5 : 2)
        // The deck behind: smaller, lower, a little askew.
        .scaleEffect(1 - CGFloat(depth) * 0.05)
        .offset(y: CGFloat(depth) * 9)
        .rotationEffect(.degrees(reduceMotion ? 0 : Double(depth) * (depth.isMultiple(of: 2) ? -1.5 : 1.5)))
        // The top one follows the finger, tilting.
        .offset(x: reduceMotion ? 0 : moved)
        .rotationEffect(.degrees(reduceMotion ? 0 : Double(moved / 18)), anchor: .bottom)
        .opacity(isTop && reduceMotion && leaving != 0 ? 0 : 1)
        .allowsHitTesting(isTop)
        .simultaneousGesture(isTop ? dragging(idea) : nil)
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!isTop)
        .accessibilityAction(named: Text("Do It")) { take(idea) }
        .accessibilityAction(named: Text(done)) { put(idea) }
        .accessibilityAction(named: Text("Not Now")) { put(idea) }
    }

    /// What the face sits on, so it stands out from a card in its own colour: white, or ink for a
    /// light colour (amber, lime, white, a pale theme's bubble), which white would swallow.
    private func seat(for color: Color) -> Color {
        let skin = color.resolve(in: EnvironmentValues())
        let lightness = 0.2126 * skin.linearRed + 0.7152 * skin.linearGreen + 0.0722 * skin.linearBlue
        return lightness > 0.62 ? Color(red: 0.09, green: 0.09, blue: 0.13).opacity(0.85) : .white
    }

    private func stamp(_ word: String, color: Color, angle: Double) -> some View {
        Text(word)
            .font(.system(.headline, design: .rounded, weight: .heavy))
            .textCase(.uppercase)
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
            .rotationEffect(.degrees(angle))
            .padding(18)
    }

    private func dragging(_ idea: AgentIdea) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Sideways only: a drag up or down is the list scrolling.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                drag = value.translation.width
                let now: CGFloat = abs(drag) >= Self.threshold ? (drag > 0 ? 1 : -1) : 0
                if now != armed { armed = now; if now != 0 { haptic.impactOccurred() } }
            }
            .onEnded { value in
                armed = 0
                if drag >= Self.threshold { send(idea, to: 1) } else if drag <= -Self.threshold { send(idea, to: -1) } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { drag = 0 }
                }
            }
    }

    /// Off it goes, right to be done, left to be put away; then the deck closes up.
    private func send(_ idea: AgentIdea, to direction: CGFloat, done: Bool = false) {
        withAnimation(.easeIn(duration: 0.22)) { leaving = direction * 560 - drag; if reduceMotion { drag = 0 } }
        Task {
            try? await Task.sleep(for: .milliseconds(230))
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { drag = 0; leaving = 0 }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                if direction > 0, !done { take(idea) } else { put(idea) }
            }
        }
    }

    // MARK: The buttons

    private var buttons: some View {
        HStack(spacing: 26) {
            // Not Now in red on the left, Do It in the middle and larger, Done on the right (his
            // order, 2026-10-28); the bolt says "let's do it" more than sparkles did.
            round("xmark", label: String(localized: "Not Now"), color: .red, size: 50) { if let top { send(top, to: -1) } }
            round("bolt.fill", label: String(localized: "Do It"), color: .green, size: 64) { if let top { send(top, to: 1) } }
            round("checkmark", label: done, color: .blue, size: 50) { if let top { send(top, to: -1, done: true) } }
        }
        .disabled(top == nil)
    }

    private func round(_ symbol: String, label: String, color: Color, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(Circle().fill(color.opacity(0.14)))
                .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// "Done" as a thing finished, the word a finished task and the Kanban column have.
    private var done: String {
        String(localized: "task.done", defaultValue: "Done", comment: "A task, finished (not the Done button): a ticked checklist item, the agent's finished task, the Kanban column, the title after a plugin change")
    }

    private func face(_ idea: AgentIdea) -> BotFace {
        let bots = BotDirectory.shared
        return idea.profile == "default" ? bots.mainFace : (bots.roster?.faces[idea.profile] ?? BotFace(seed: idea.profile))
    }
}

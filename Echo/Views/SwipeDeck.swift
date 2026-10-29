import SwiftUI

/// A deck of cards at the top of the chat list, the ideas' and the briefings' (asked 2026-10-29:
/// "display the week ahead, daily reports, in the same visual format as the ideas"). The top card
/// follows the finger, tilting; let go past the threshold, it flies off that way and its side's
/// action is done; the buttons under it do the same. The cards behind sit smaller, lower, a
/// little askew. Under Reduce Motion the cards don't tilt or fly; they fade.
struct SwipeDeck<Item: Identifiable & Equatable, Face: View, Menu: View, Footer: View>: View {
    /// What a swipe one way does, and the stamp that says so as the card goes.
    struct Side {
        var stamp: String
        var color: Color
        var act: (Item) -> Void
    }

    /// A button under the deck: which way it sends the top card, and what it does then.
    struct Choice {
        var symbol: String
        var label: String
        var color: Color
        var size: CGFloat = 50
        /// 1 right, -1 left.
        var fly: CGFloat
        var act: (Item) -> Void
    }

    let items: [Item]
    var height: CGFloat = 196
    let right: Side
    let left: Side
    let buttons: [Choice]
    /// More for VoiceOver, beyond the buttons'.
    var actions: [(String, (Item) -> Void)] = []
    /// The top card, tapped.
    var tap: ((Item) -> Void)?
    /// A card: the item, whether it's on top, how far it's dragged.
    @ViewBuilder let face: (Item, Bool, CGFloat) -> Face
    /// The top card, held.
    @ViewBuilder let menu: (Item) -> Menu
    @ViewBuilder let footer: () -> Footer

    @State private var drag: CGFloat = 0
    /// The card on its way off, and which way (1 right, -1 left).
    @State private var leaving: CGFloat = 0
    @State private var armed: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// How far a card goes before letting go of it is a choice.
    private static var threshold: CGFloat { 100 }
    private static var shown: Int { 3 }

    private var top: Item? { items.first }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(Array(items.prefix(Self.shown).enumerated()).reversed(), id: \.element.id) { depth, item in
                    card(item, depth: depth)
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            HStack(spacing: 26) {
                ForEach(buttons.indices, id: \.self) { i in
                    let choice = buttons[i]
                    round(choice) { if let top { send(top, to: choice.fly, then: choice.act) } }
                }
            }
            .disabled(top == nil)
            footer().font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private func card(_ item: Item, depth: Int) -> some View {
        let isTop = depth == 0
        let moved = isTop ? drag + leaving : 0
        return face(item, isTop, moved)
            #if os(iOS)
            .contentShape(.contextMenuPreview, .rect(cornerRadius: 22))
            #endif
            .contextMenu { if isTop { menu(item) } }
            // The stamp lands in the corner the card leaves behind, where the finger isn't (asked 2026-10-28).
            .overlay(alignment: .topLeading) { if isTop { stamp(right.stamp, color: right.color, angle: -12).opacity(Double(max(0, moved) / Self.threshold)) } }
            .overlay(alignment: .topTrailing) { if isTop { stamp(left.stamp, color: left.color, angle: 12).opacity(Double(max(0, -moved) / Self.threshold)) } }
            .shadow(color: .black.opacity(isTop ? 0.14 : 0.06), radius: isTop ? 10 : 4, y: isTop ? 5 : 2)
            .scaleEffect(1 - CGFloat(depth) * 0.05)
            .offset(y: CGFloat(depth) * 9)
            .rotationEffect(.degrees(reduceMotion ? 0 : Double(depth) * (depth.isMultiple(of: 2) ? -1.5 : 1.5)))
            .offset(x: reduceMotion ? 0 : moved)
            .rotationEffect(.degrees(reduceMotion ? 0 : Double(moved / 18)), anchor: .bottom)
            .opacity(isTop && reduceMotion && leaving != 0 ? 0 : 1)
            .allowsHitTesting(isTop)
            .onTapGesture { if isTop, let tap { tap(item) } }
            .simultaneousGesture(isTop ? dragging(item) : nil)
            .accessibilityElement(children: .combine)
            .accessibilityHidden(!isTop)
            .accessibilityActions {
                ForEach(buttons.indices, id: \.self) { i in
                    Button(buttons[i].label) { buttons[i].act(item) }
                }
                ForEach(actions.indices, id: \.self) { i in
                    Button(actions[i].0) { actions[i].1(item) }
                }
            }
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

    private func dragging(_ item: Item) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Sideways only: a drag up or down is the list scrolling.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                drag = value.translation.width
                let now: CGFloat = abs(drag) >= Self.threshold ? (drag > 0 ? 1 : -1) : 0
                if now != armed { armed = now; if now != 0 { haptic.impactOccurred() } }
            }
            .onEnded { _ in
                armed = 0
                if drag >= Self.threshold { send(item, to: 1, then: right.act) } else if drag <= -Self.threshold { send(item, to: -1, then: left.act) } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { drag = 0 }
                }
            }
    }

    /// Off it goes, then its action; then the deck closes up.
    private func send(_ item: Item, to direction: CGFloat, then act: @escaping (Item) -> Void) {
        withAnimation(.easeIn(duration: 0.22)) { leaving = direction * 560 - drag; if reduceMotion { drag = 0 } }
        Task {
            try? await Task.sleep(for: .milliseconds(230))
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { drag = 0; leaving = 0 }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { act(item) }
        }
    }

    private func round(_ choice: Choice, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: choice.symbol)
                .font(.system(size: choice.size * 0.38, weight: .bold))
                .foregroundStyle(choice.color)
                .frame(width: choice.size, height: choice.size)
                .background(Circle().fill(choice.color.opacity(0.14)))
                .overlay(Circle().stroke(choice.color.opacity(0.35), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.label)
    }
}

/// A deck card's top: the agent's face on its seat, its name, a line under it, a symbol.
struct DeckCardHeader: View {
    let face: BotFace
    let name: String
    let subtitle: Text
    let symbol: String
    var symbolColor: Color = .yellow
    var isTop = true
    var moved: CGFloat = 0
    /// Bounces the symbol when it changes (the top card's id).
    var bounce = ""
    @Environment(\.theme) private var theme

    var body: some View {
        let colors = BotAvatar.colors(of: face, theme: theme)
        HStack(spacing: 10) {
            BotAvatar(face: face, name: name, size: 40,
                      pose: isTop ? BotPose(look: CGPoint(x: max(-1, min(1, moved / 90)), y: -0.2)) : nil)
                .padding(5)
                .background(Circle().fill(Self.seat(for: colors.deep)))
                .overlay(Circle().stroke(colors.deep.opacity(0.45), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(name.isEmpty ? String(localized: "Your agent") : name).font(.subheadline.weight(.bold))
                subtitle.font(.caption).opacity(0.7)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(symbolColor, DeckCard.ink.opacity(0.25))
                .symbolEffect(.bounce, value: isTop ? bounce : "")
        }
    }

    /// What the face sits on, so it stands out from a card in its own colour: white, or ink for a
    /// light colour (amber, lime, white, a pale theme's bubble), which white would swallow.
    static func seat(for color: Color) -> Color {
        let skin = color.resolve(in: EnvironmentValues())
        let lightness = 0.2126 * skin.linearRed + 0.7152 * skin.linearGreen + 0.0722 * skin.linearBlue
        return lightness > 0.62 ? DeckCard.ink.opacity(0.85) : .white
    }
}

enum DeckCard {
    /// Dark words, which read on every pastel.
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.13)

    /// The face an agent wears on a card: the main one's, or a bot's by its profile.
    @MainActor
    static func face(profile: String?) -> BotFace {
        let bots = BotDirectory.shared
        guard let profile, profile != "default" else { return bots.mainFace }
        return bots.roster?.faces[profile] ?? BotFace(seed: profile)
    }
}

extension View {
    /// A deck card's ground: a pastel of the agent's colour, so dark words read on any of them and
    /// its face, in the colour itself, stands out.
    func deckCard(_ face: BotFace, theme: ResolvedTheme) -> some View {
        let deep = BotAvatar.colors(of: face, theme: theme).deep
        return self
            .foregroundStyle(DeckCard.ink)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LinearGradient(colors: [deep.mix(with: .white, by: 0.82), deep.mix(with: .white, by: 0.64)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 22))
    }
}

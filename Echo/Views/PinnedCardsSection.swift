import SwiftUI

/// "Pinned", at the top of the chat list: cards pinned out of their chats (`PinnedCards`), a tap
/// opening each whole, to tick off without finding its chat.
struct PinnedCardsSection: View {
    @State private var pins = PinnedCards.shared
    @State private var answers = CardAnswers.shared

    var body: some View {
        if !pins.pins.isEmpty {
            Section {
                ForEach(pins.pins) { pin in
                    Button { pins.open = pin } label: { row(pin) }
                        .buttonStyle(.plain)
                        .swipeActions { Button("Unpin", systemImage: "pin.slash", role: .destructive) { pins.unpin(pin.key) } }
                }
            } header: {
                Text("Pinned")
            }
        }
    }

    private func row(_ pin: PinnedCards.Pin) -> some View {
        HStack(spacing: 12) {
            if case let .checklist(list) = pin.card {
                Text(list.emoji ?? "✅").chatFont(.title2).frame(width: 32)
                let done = answers.ticks[pin.key].map(Set.init) ?? Set(list.items.indices.filter { list.items[$0].done })
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.title).chatFont(.body, weight: .semibold).lineLimit(1)
                    Text("\(done.count) of \(list.items.count) done").chatFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 6)
                let part = list.items.isEmpty ? 0 : Double(done.count) / Double(list.items.count)
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                    Circle().trim(from: 0, to: part).stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            } else {
                Image(systemName: "pin.fill").foregroundStyle(.tint).frame(width: 32)
                Text(pin.title).chatFont(.body, weight: .semibold).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .contentShape(.rect)
    }
}

/// A pinned card, whole, over the chat list; its chat one tap away.
struct PinnedCardSheet: View {
    let pin: PinnedCards.Pin
    var openChat: ((UUID) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ReplyCardsView(cards: [pin.card])
                    .environment(\.pinnedCard, true)
                    .padding()
            }
            .navigationTitle(pin.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let id = pin.conversation, let openChat {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Open Chat", systemImage: "bubble.left.and.bubble.right") { dismiss(); openChat(id) }
                    }
                }
            }
        }
    }
}

extension EnvironmentValues {
    /// A card shown pinned, away from its chat (`PinnedCardSheet`).
    @Entry var pinnedCard: Bool = false
}

/// The pinned card's sheet over the app.
struct PinnedCardSheets: ViewModifier {
    @State private var pins = PinnedCards.shared
    var openChat: (UUID) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { pins.open }, set: { pins.open = $0 })) { pin in
            PinnedCardSheet(pin: pin, openChat: openChat)
        }
    }
}

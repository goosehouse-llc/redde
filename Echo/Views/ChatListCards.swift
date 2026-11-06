import SwiftUI

/// The cards above the conversations in the chat list (2.4 tidy, asked 2026-11-05): Pinned, Inbox,
/// Goals, Ideas and Briefings could stack until the chats were off the screen. Each can be left out
/// (Settings → Appearance → Top of the Chat List, `Settings.hiddenChatListCards`, synced), and each
/// with a header folds away to its header and a count, the way Bots does (`FoldingHeader`).
enum ChatListCard: String, CaseIterable, Identifiable {
    case pinned, inbox, goals, ideas, briefings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: String(localized: "Pinned", comment: "The chat list's section of pinned cards")
        case .inbox: String(localized: "Inbox", comment: "The chat list's row for email")
        case .goals: String(localized: "Goals", comment: "The chat list's section of the person's goals, and its page in Settings")
        case .ideas: String(localized: "Ideas for you", comment: "The chat list's deck of the agent's ideas")
        case .briefings: String(localized: "Briefings", comment: "The chat list's deck of briefings")
        }
    }

    var detail: String {
        switch self {
        case .pinned: String(localized: "Cards you pinned from a reply, like a checklist.", comment: "Settings › Top of the Chat List: under Pinned")
        case .inbox: String(localized: "Your email, once an account is set up.", comment: "Settings › Top of the Chat List: under Inbox")
        case .goals: String(localized: "Each goal's progress.", comment: "Settings › Top of the Chat List: under Goals")
        case .ideas: String(localized: "Morning Ideas to take or put away.", comment: "Settings › Top of the Chat List: under Ideas for you")
        case .briefings: String(localized: "Heads-ups, wrap-ups and your jobs' answers.", comment: "Settings › Top of the Chat List: under Briefings")
        }
    }

    var symbol: String {
        switch self {
        case .pinned: "pin"
        case .inbox: "envelope"
        case .goals: "flag.checkered"
        case .ideas: "lightbulb"
        case .briefings: "doc.text"
        }
    }

    /// Shown at the top of the chat list (the person's choice).
    var isShown: Bool { !Settings.shared.hiddenChatListCards.contains(rawValue) }

    func show(_ shown: Bool) {
        var hidden = Settings.shared.hiddenChatListCards.filter { $0 != rawValue }
        if !shown { hidden.append(rawValue) }
        Settings.shared.hiddenChatListCards = hidden
    }

    /// The key its folded state is kept under, on this device.
    var foldKey: String { "chatList.open.\(rawValue)" }
}

/// A chat list section's header that folds the section away: its title, a count while folded, a
/// chevron, and anything after it (Goals's New Goal).
struct FoldingHeader<Accessory: View>: View {
    let title: String
    let count: Int
    @Binding var isOpen: Bool
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                    if !isOpen {
                        Text("\(count)").chatFont(.caption2, weight: .semibold).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .chatFont(.caption, weight: .semibold)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOpen ? String(localized: "Hide \(title.localizedLowercase)", comment: "VoiceOver: folds a section of the list away, e.g. “Hide bots”")
                                       : String(localized: "Show \(title.localizedLowercase)", comment: "VoiceOver: opens a folded section of the list, e.g. “Show bots”"))
            .accessibilityAddTraits(.isHeader)
            accessory()
        }
    }
}

extension FoldingHeader where Accessory == EmptyView {
    init(title: String, count: Int, isOpen: Binding<Bool>) {
        self.init(title: title, count: count, isOpen: isOpen) { EmptyView() }
    }
}

/// Settings → Appearance → Top of the Chat List: which cards show above the conversations.
struct ChatListCardsSettingsView: View {
    @State private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                ForEach(ChatListCard.allCases) { card in
                    Toggle(isOn: Binding(get: { _ = settings.hiddenChatListCards; return card.isShown }, set: { card.show($0) })) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.title)
                                Text(card.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: card.symbol) }
                    }
                }
            } footer: {
                Text("Each shows only when it has something in it. Tap a section's title in the chat list to fold it away to a count.",
                     comment: "Settings › Top of the Chat List: footer")
            }
        }
        .navigationTitle(Text("Top of the Chat List", comment: "Settings › Appearance: which cards show above the conversations"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

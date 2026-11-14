import SwiftUI

/// The cards above the conversations in the chat list (2.4 tidy, asked 2026-11-05): Pinned, Inbox,
/// Goals, Ideas and Briefings could stack until the chats were off the screen. Each can be left out
/// (Settings → Appearance → Top of the Chat List, `Settings.hiddenChatListCards`, synced), and each
/// with a header folds away to its header and a count, the way Bots does (`FoldingHeader`).
enum ChatListCard: String, CaseIterable, Identifiable {
    case pinned, inbox, lists, goals, ideas, briefings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: String(localized: "Pinned", comment: "The chat list's section of pinned cards")
        case .inbox: String(localized: "Inbox", comment: "The chat list's row for email")
        case .lists: String(localized: "Lists", comment: "The chat list's tiles of the person's to-do lists")
        case .goals: String(localized: "Goals", comment: "The chat list's section of the person's goals, and its page in Settings")
        case .ideas: String(localized: "Ideas for you", comment: "The chat list's deck of the agent's ideas")
        case .briefings: String(localized: "Briefings", comment: "The chat list's deck of briefings")
        }
    }

    var detail: String {
        switch self {
        case .pinned: String(localized: "Cards you pinned from a reply, like a checklist.", comment: "Settings › Top of the Chat List: under Pinned")
        case .inbox: String(localized: "Your email, once an account is set up.", comment: "Settings › Top of the Chat List: under Inbox")
        case .lists: String(localized: "To-do lists and the like, once you ask an agent for one.", comment: "Settings › Top of the Chat List: under Lists")
        case .goals: String(localized: "Each goal's progress.", comment: "Settings › Top of the Chat List: under Goals")
        case .ideas: String(localized: "Morning Ideas to take or put away.", comment: "Settings › Top of the Chat List: under Ideas for you")
        case .briefings: String(localized: "Heads-ups, wrap-ups and your jobs' answers.", comment: "Settings › Top of the Chat List: under Briefings")
        }
    }

    var symbol: String {
        switch self {
        case .pinned: "pin"
        case .inbox: "envelope"
        case .lists: "checklist"
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
    @State private var addsReminders = true
    @State private var listName = ""
    /// Turning on Up Next found calendar access refused.
    @State private var calendarRefused = false

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
            // The next event on the calendar as a Today tile (2026-11-12), off until it's wanted.
            Section {
                Toggle(isOn: Binding(get: { settings.todayUpNext }, set: { on in
                    settings.todayUpNext = on
                    guard on else { return }
                    // Back on the Today page too, if its hold menu hid it there.
                    UserDefaults.standard.set(false, forKey: "today.page.calendarHidden")
                    Task {
                        calendarRefused = !(await CalendarUpNext.shared.ask())
                        CalendarUpNext.shared.refresh()
                    }
                })) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Up Next", comment: "Today strip: the tile with the next event on the calendar")
                            Text("The next event on your calendars, as a Today tile.", comment: "Settings › Top of the Chat List: under Up Next")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "calendar") }
                }
            } footer: {
                if settings.todayUpNext, calendarRefused {
                    Text("Up Next needs full access to your calendars. Allow it in Settings, under Privacy & Security › Calendars.",
                         comment: "Settings › Top of the Chat List: Up Next is on but calendar access was refused")
                }
            }
            // Apple Reminders onto a list on their day (2026-11-09).
            Section {
                Toggle(isOn: Binding(get: { addsReminders }, set: { addsReminders = $0; TodayLists.shared.addsReminders = $0 })) {
                    Text("Reminders on Their Day", comment: "Settings › Top of the Chat List: put Apple Reminders on a list when they're due")
                }
                if addsReminders {
                    TextField(String(localized: "List", comment: "Settings › Top of the Chat List: which list reminders go on"),
                              text: Binding(get: { listName }, set: { listName = $0; TodayLists.shared.remindersList = $0 }),
                              prompt: Text(TodayLists.remindersListDefault))
                        .textInputAutocapitalization(.words)
                }
            } footer: {
                Text("A reminder from Apple Reminders goes on this list on the day it's due, and one that's overdue stays until it's done. Tick it on either and it's ticked on both. Your iPhone or Mac adds them when Redde opens, as Reminders lives there.",
                     comment: "Settings › Top of the Chat List: under Reminders on Their Day")
            }
        }
        .onAppear {
            calendarRefused = settings.todayUpNext && !CalendarUpNext.shared.canRead
            addsReminders = TodayLists.shared.addsReminders
            listName = TodayLists.shared.remindersList
        }
        .navigationTitle(Text("Top of the Chat List", comment: "Settings › Appearance: which cards show above the conversations"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

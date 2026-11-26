import SwiftUI

extension TodayList {
    /// The list's colour; a list from a plugin older than 1.37 is the checklists' green.
    var color: Color { hue?.color ?? ColorScheme.checklistGreen }
}

extension TodayList.Hue {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: ColorScheme.checklistGreen
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    /// Its name, for VoiceOver.
    var name: Text {
        switch self {
        case .red: Text("Red", comment: "A list's colour")
        case .orange: Text("Orange", comment: "A list's colour")
        case .yellow: Text("Yellow", comment: "A list's colour")
        case .green: Text("Green", comment: "A list's colour")
        case .mint: Text("Mint", comment: "A list's colour")
        case .teal: Text("Teal", comment: "A list's colour")
        case .blue: Text("Blue", comment: "A list's colour")
        case .indigo: Text("Indigo", comment: "A list's colour")
        case .purple: Text("Purple", comment: "A list's colour")
        case .pink: Text("Pink", comment: "A list's colour")
        case .brown: Text("Brown", comment: "A list's colour")
        case .gray: Text("Gray", comment: "A list's colour")
        }
    }
}

extension TodayList.Kind {
    var name: Text {
        switch self {
        case .watch: Text("Films & Shows", comment: "A list's kind: films and series to watch, shown as posters")
        case .todo: Text("To-Do", comment: "A list's kind")
        case .shopping: Text("Shopping", comment: "A list's kind")
        case .reading: Text("Reading", comment: "A list's kind")
        case .packing: Text("Packing", comment: "A list's kind")
        case .gifts: Text("Gifts", comment: "A list's kind")
        case .other: Text("Other", comment: "A list's kind")
        }
    }

    var symbol: String {
        switch self {
        case .watch: "popcorn"
        case .todo: "checklist"
        case .shopping: "cart"
        case .reading: "books.vertical"
        case .packing: "suitcase"
        case .gifts: "gift"
        case .other: "list.bullet"
        }
    }
}

extension Settings.TodoLayout {
    var name: Text {
        switch self {
        case .byWhen: Text("By When", comment: "A to-do list's layout: grouped into Overdue, Today, This Week, Later and Anytime")
        case .nextUp: Text("Next Up", comment: "A to-do list's layout: the next thing to do large, the rest after it")
        case .help: Text("Agent Can Help", comment: "A to-do list's layout: what the agent can do part of, apart from what's just yours")
        case .week: Text("Week", comment: "A to-do list's layout: a week strip and a timeline of what's on each day")
        case .notepad: Text("Notepad", comment: "A to-do list's layout: a yellow legal pad, things crossed off by hand")
        }
    }

    var symbol: String {
        switch self {
        case .byWhen: "calendar.day.timeline.left"
        case .nextUp: "arrow.right.circle"
        case .help: "bolt"
        case .week: "calendar"
        case .notepad: "pencil.and.list.clipboard"
        }
    }
}

/// A list's look (2026-11-23): its emoji, its colour and its kind, the same 'style' an agent gives
/// with `redde_list`. Each pick goes at once.
struct ListLookSheet: View {
    let list: TodayList
    @State private var lists = TodayLists.shared
    @State private var typed = ""
    @State private var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss

    private static let emojis = ["🎄", "🎃", "🎉", "🍿", "🎬", "📺", "🛒", "🥦", "✅", "🧹", "📚", "🧳",
                                 "🎁", "🏖️", "⛺️", "🏡", "💪", "🐶", "🌱", "🍳", "💡", "🎮", "🎵", "❤️"]

    /// The list as it is now: a pick shows at once.
    private var shown: TodayList { lists.lists.first { $0.id == list.id } ?? list }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
                        ForEach(Self.emojis, id: \.self) { emoji in
                            Button { lists.style(shown, emoji: emoji) } label: {
                                Text(verbatim: emoji)
                                    .font(.system(size: 30))
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(shown.emoji == emoji ? shown.color.opacity(0.25) : .clear, in: .rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(shown.emoji == emoji ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                    TextField(String(localized: "Or type one", comment: "A list's look: a field for any emoji"), text: $typed)
                        .onChange(of: typed) { _, now in
                            guard let last = now.last, String(last).unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x238C }) else { return }
                            lists.style(shown, emoji: String(last))
                            typed = ""
                        }
                } header: {
                    Text("Emoji", comment: "A list's look: its emoji")
                }

                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                        ForEach(TodayList.Hue.allCases, id: \.self) { hue in
                            Button { lists.style(shown, hue: hue) } label: {
                                Circle()
                                    .fill(hue.color.gradient)
                                    .frame(width: 38, height: 38)
                                    .overlay {
                                        if shown.hue == hue {
                                            Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(hue.name)
                            .accessibilityAddTraits(shown.hue == hue ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Color", comment: "A list's look: its colour")
                }

                Section {
                    Picker(selection: Binding(get: { shown.kind ?? .other }, set: { lists.style(shown, kind: $0) })) {
                        ForEach(TodayList.Kind.allCases, id: \.self) { kind in
                            Label { kind.name } icon: { Image(systemName: kind.symbol) }.tag(kind)
                        }
                    } label: {
                        Text("Kind", comment: "A list's look: what the list is for")
                    }
                } footer: {
                    Text("Films & Shows lists show each title with its poster.", comment: "A list's look: under the kind picker")
                }

                // A watch list as a clean list or as tickets (2026-11-25), on every device of theirs.
                if shown.kind == .watch {
                    Section {
                        Picker(selection: Binding(get: { settings.filmLayout(forList: shown.id) },
                                                  set: { settings.setFilmLayout($0, forList: shown.id) })) {
                            Text("List", comment: "A watch list's layout: small posters in rows").tag(Settings.FilmLayout.list)
                            Text("Ticket Stubs", comment: "A watch list's layout: each film a ticket to tear off, watched ones a pile of used stubs")
                                .tag(Settings.FilmLayout.tickets)
                            Text("Shelf", comment: "A watch list's layout: one large poster at a time, swiped through")
                                .tag(Settings.FilmLayout.shelf)
                        } label: {
                            Text("Layout", comment: "A list's look: how a watch list is drawn")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("list-layout")
                    } header: {
                        Text("Layout", comment: "A list's look: how a watch list is drawn")
                    }
                }

                // A to-do list in one of five layouts (2026-11-25, "build the todo list mockups too").
                if shown.groupsByWhen {
                    Section {
                        Picker(selection: Binding(get: { settings.todoLayout(forList: shown.id) },
                                                  set: { settings.setTodoLayout($0, forList: shown.id) })) {
                            ForEach(Settings.TodoLayout.allCases, id: \.self) { layout in
                                Label { layout.name } icon: { Image(systemName: layout.symbol) }.tag(layout)
                            }
                        } label: {
                            Text("Layout", comment: "A list's look: how a watch list is drawn")
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .accessibilityIdentifier("todo-layout")
                    } header: {
                        Text("Layout", comment: "A list's look: how a watch list is drawn")
                    }
                }
            }
            .navigationTitle(Text("Change Look", comment: "A to-do list: choose its emoji, colour and kind"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .tint(shown.color)
        }
        .presentationDetents([.medium, .large])
    }
}

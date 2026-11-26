import SwiftUI

/// One of the person's lists, opened from its tile on the Today row (`TodayLists`, 2026-11-09).
/// Drawn as its own page (asked 2026-11-14: "make the to do list nicer to look at"; a card inside
/// the sheet before): the list's name large beside a ring of how much is done, what's left on one
/// panel with a line to add to it, and what's done below, folded away with a tap. Tap to check an
/// item off, swipe or hold one to remove it or change its words; Clear Done, Rename and Delete in the menu. The same
/// changes an agent makes with `redde_list`, kept on the Hermes.
///
/// From 2026-11-23 ("make these lists a bit more fun"): the list's colour washes the top of the
/// page and fills its ring and ticks, its emoji sits by its name, a tick springs, a finished list
/// throws its emoji about. Change Look picks the emoji, the colour and the kind. A watch list is a
/// clean list of small posters under a thin progress bar (`FilmRow`; picked 2026-11-23 over the wall
/// of posters it first was), or, picked in Change Look, tickets to tear off (`TicketRow`, 2026-11-25).
struct TodayListView: View {
    @State private var lists = TodayLists.shared
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmingDelete = false
    @State private var adding = ""
    @State private var doneFolded = false
    @State private var styling = false
    @State private var dating: TodayList.Item?
    @State private var editing: TodayList.Item?
    @State private var settings = Settings.shared
    @State private var stubsOpen = false
    /// The Week layout's day picked on its strip: only that day's to-dos.
    @State private var weekDay: Date?
    /// Sends words to the agent in a new conversation and opens it (the Agent Can Help layout's
    /// help lines); nil where that can't be done from here.
    var ask: ((String) -> Void)? = nil
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let list = lists.shown {
            content(list)
        } else {
            ContentUnavailableView {
                Label { Text("List Deleted", comment: "A to-do list's sheet after the list was deleted") } icon: { Image(systemName: "checklist") }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// A watch list drawn as tickets (its Change Look's Layout).
    private func tickets(_ list: TodayList) -> Bool {
        list.kind == .watch && settings.filmLayout(forList: list.id) == .tickets
    }

    /// A watch list drawn as a shelf of large posters.
    private func shelf(_ list: TodayList) -> Bool {
        list.kind == .watch && settings.filmLayout(forList: list.id) == .shelf
    }

    /// A to-do list's layout; nil for a list of another kind.
    private func todoLayout(_ list: TodayList) -> Settings.TodoLayout? {
        list.groupsByWhen ? settings.todoLayout(forList: list.id) : nil
    }

    /// The marks: the list's colour, else the checklists' "done" green.
    private var mark: Color { lists.shown?.color ?? ColorScheme.checklistGreen }

    private func content(_ list: TodayList) -> some View {
        listBody(list)
            .sheet(item: $dating) { item in
                DateSheet(item: item, mark: mark) { lists.setDate($0, for: item, in: list) }
            }
            .sheet(item: $editing) { item in
                EditItemSheet(item: item, mark: mark) { lists.edit(item, to: $0, in: list) }
            }
    }

    private func listBody(_ list: TodayList) -> some View {
        List {
            Section {
                header(list)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 6, trailing: 4))
                if let problem = lists.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .chatFont(.footnote)
                        .foregroundStyle(.orange)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
            }
            .listSectionSeparator(.hidden)

            openItems(list)

            if !list.finished.isEmpty, tickets(list) || shelf(list) {
                Section {
                    if stubsOpen {
                        ForEach(list.finished) { row($0, in: list) }
                    } else if shelf(list) {
                        WatchedRow(items: list.finished)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    } else {
                        StubPile(items: list.finished)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                } header: {
                    stubsHeader(list)
                }
            } else if !list.finished.isEmpty, todoLayout(list) != .notepad {   // (the pad keeps them, crossed off)
                Section {
                    if !doneFolded {
                        ForEach(list.finished) { row($0, in: list) }
                    }
                } header: {
                    doneHeader(list)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background {
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground)
                LinearGradient(colors: [mark.opacity(scheme == .dark ? 0.34 : 0.22), mark.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 380)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            ListBurst(emoji: list.emoji ?? "🎉", trigger: !list.items.isEmpty && list.open.isEmpty)
                .padding(.top, 70)
        }
        // A watch list's posters come a moment after its titles: looked again once.
        .task(id: list.id) {
            guard list.kind == .watch, list.items.contains(where: { $0.poster == nil }) else { return }
            try? await Task.sleep(for: .seconds(6))
            await lists.refresh()
        }
        .sheet(isPresented: $styling) { ListLookSheet(list: list) }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .listSectionSpacing(14)
        // The name close under the bar: a grouped list's first section keeps about 35 points
        // above it, which left the top of the sheet empty (asked 2026-11-24).
        .contentMargins(.top, 4, for: .scrollContent)
        #endif
        .scrollDismissesKeyboard(.interactively)
        .animation(.snappy(duration: 0.3), value: list.items)
        .animation(.snappy(duration: 0.25), value: doneFolded)
        .sensoryFeedback(.success, trigger: list.open.isEmpty && !list.items.isEmpty) { _, now in now }
        // The name is the page's own, large, under the bar.
        .navigationTitle(list.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { menu(list) }
        }
        // Typed and not yet added when the sheet closes: it still goes on.
        .onDisappear { addTyped(to: list) }
        .alert(String(localized: "Rename List", comment: "A to-do list: the title of the rename box"), isPresented: $renaming) {
            TextField(String(localized: "Name", comment: "A to-do list: the rename box's field"), text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button(String(localized: "Rename", comment: "A to-do list: give it a new name")) { lists.rename(list, to: newTitle) }
        }
        .confirmationDialog(String(localized: "Delete \(list.title)?", comment: "A to-do list: asked before deleting it"),
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(role: .destructive) { lists.delete(list) } label: {
                Text("Delete List", comment: "A to-do list: delete the whole list")
            }
        } message: {
            Text("It goes for every bot and device, and its tile leaves the chat list.", comment: "A to-do list: under the question before deleting it")
        }
    }

    // MARK: Pieces

    /// What's left, then the line to add to it. A to-do list with dates comes in groups by when;
    /// with none, or any other kind of list, it's one panel.
    @ViewBuilder
    private func openItems(_ list: TodayList) -> some View {
        let groups = list.groupsByWhen ? list.openByWhen() : []
        if tickets(list) {
            Section {
                if list.open.isEmpty, !list.items.isEmpty { allDone }
                ForEach(list.open) { ticketRow($0, in: list) }
            }
            Section { addRow(list) }
        } else if shelf(list) {
            Section {
                if list.open.isEmpty, !list.items.isEmpty { allDone }
                if !list.open.isEmpty {
                    FilmShelf(items: list.open, mark: mark, plan: { dating = $0 }, watched: { lists.toggle($0, in: list) }) { item in
                        ListItemActions(item: item, list: list, tickets: true, editing: $editing, dating: $dating)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                }
            }
            Section { addRow(list) }
        } else if let layout = todoLayout(list), layout != .byWhen {
            switch layout {
            case .nextUp: nextUp(list)
            case .help: helpItems(list)
            case .week: weekItems(list)
            default: notepad(list)
            }
        } else if groups.contains(where: { $0.when != .anytime }) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item, in: list, group: group.when)
                            .listRowBackground(group.when == .today ? mark.opacity(scheme == .dark ? 0.22 : 0.14) : nil)
                    }
                } header: {
                    whenHeader(group.when)
                }
            }
            Section { addRow(list) }
        } else {
            Section {
                if list.open.isEmpty, !list.items.isEmpty { allDone }
                ForEach(list.open) { row($0, in: list) }
                addRow(list)
            }
        }
    }

    private func whenHeader(_ when: TodayList.When) -> some View {
        Group {
            switch when {
            case .overdue: Text("Overdue", comment: "A to-do list: the group of items whose day has passed")
            case .today: Text("Today", comment: "An agenda card's day")
            case .thisWeek: Text("This week")
            case .later: Text("Later")
            case .anytime: Text("Anytime", comment: "A to-do list: the group of items with no day")
            }
        }
        .chatFont(.title3, weight: .bold)
        .foregroundStyle(when == .overdue ? AnyShapeStyle(CardInk.readable(.orange, drawnIn: scheme)) : when == .today ? AnyShapeStyle(CardInk.readable(mark, drawnIn: scheme)) : AnyShapeStyle(.primary))
        .textCase(nil)
    }

    /// The name, large, how it stands, and the ring (a watch or to-do list: a thin bar under them).
    private func header(_ list: TodayList) -> some View {
        let done = list.finished.count, total = list.items.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                if let emoji = list.emoji {
                    Button { styling = true } label: {
                        Text(verbatim: emoji)
                            .font(.system(size: 40))
                            .frame(width: 64, height: 64)
                            .background(mark.opacity(scheme == .dark ? 0.24 : 0.16), in: .rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Change Look", comment: "A to-do list: choose its emoji, colour and kind"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(list.title)
                        .chatFont(.largeTitle, weight: .bold)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .accessibilityAddTraits(.isHeader)
                    Group {
                        if total > 0, done == total {
                            Text("All done", comment: "Today strip: a to-do list with every item checked off")
                                .foregroundStyle(mark)
                        } else if shelf(list) {
                            // "3 to watch · 5 watched".
                            Text(verbatim: [String(localized: "\(total - done) to watch", comment: "Today strip: how many films or series on a watch list aren't watched yet"),
                                            String(localized: "\(done) watched", comment: "Shelf: under a watch list's name, after the films to watch: how many are watched")]
                                .joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        } else if todoLayout(list) == .help {
                            // "6 left · can help with 3".
                            Text(verbatim: [String(localized: "\(total - done) left", comment: "Agent Can Help: under a to-do list's name, how many to-dos are still to do"),
                                            String(localized: "can help with \(list.open.filter { $0.help != nil }.count)", comment: "Agent Can Help: under a to-do list's name, after the to-dos left: how many the agent could do part of")]
                                .joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        } else if tickets(list) {
                            // "3 tickets left · 5 used".
                            Text(verbatim: [String(localized: "\(total - done) tickets left", comment: "Ticket Stubs: under a watch list's name, how many films aren't watched yet"),
                                            String(localized: "\(done) used", comment: "Ticket Stubs: under a watch list's name, after the tickets left: how many films are watched")]
                                .joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(done) of \(total) done", comment: "The agent's task list: tasks done of all tasks")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chatFont(.subheadline, weight: .medium)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(done)))
                }
                Spacer(minLength: 8)
                if total > 0, list.kind != .watch, !list.groupsByWhen {
                    BigRing(done: done, total: total, mark: mark)
                        .accessibilityHidden(true)
                }
            }
            if total > 0, list.kind == .watch && settings.filmLayout(forList: list.id) == .list || list.groupsByWhen {
                ThinBar(done: done, total: total, mark: mark)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, 4)
        .animation(.snappy(duration: 0.3), value: done)
    }

    /// Where the open items were, once every one is checked off.
    private var allDone: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26))
                .symbolRenderingMode(.palette)
                .foregroundStyle(scheme == .dark ? Color.black : .white, mark)
            Text("All done", comment: "Today strip: a to-do list with every item checked off")
                .chatFont(.body, weight: .semibold)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func row(_ item: TodayList.Item, in list: TodayList, group: TodayList.When? = nil) -> some View {
        Button { lists.toggle(item, in: list) } label: {
            Group {
                if list.kind == .watch {
                    FilmRow(item: item, mark: mark)
                } else if list.groupsByWhen {
                    DatedRow(item: item, group: group, mark: mark)
                } else {
                    HStack(spacing: 14) {
                        ListTick(on: item.done, mark: mark)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text)
                                .chatFont(.body)
                                .strikethrough(item.done, color: .secondary)
                                .foregroundStyle(item.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            if let plan = item.plan {
                                Label(plan, systemImage: "calendar")
                                    .chatFont(.caption, weight: .medium)
                                    .foregroundStyle(item.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(mark))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 3)
                    .frame(minHeight: 44)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(trigger: item.done) { _, now in now ? .impact(weight: .light) : .selection }
        .modifier(ListItemActions(item: item, list: list, tickets: tickets(list), editing: $editing, dating: $dating))
    }

    /// A film still to watch on a list drawn as tickets: a tap plans its night, its stub's tick
    /// tears it off.
    private func ticketRow(_ item: TodayList.Item, in list: TodayList) -> some View {
        TicketRow(item: item, mark: mark, plan: { dating = item }, tear: { lists.toggle(item, in: list) })
            .modifier(ListItemActions(item: item, list: list, tickets: true, editing: $editing, dating: $dating))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
    }
}

/// What every item has, whatever its row looks like: swipe or hold to remove it, hold to change
/// its words (a film's pages too, and a date where the list keeps them), and the same for VoiceOver.
struct ListItemActions: ViewModifier {
    let item: TodayList.Item
    let list: TodayList
    let tickets: Bool
    @Binding var editing: TodayList.Item?
    @Binding var dating: TodayList.Item?
    /// The row checks it off when tapped (a card with buttons of its own doesn't).
    var toggles = true
    @State private var lists = TodayLists.shared
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { lists.remove([item], from: list) } label: {
                Label { Text("Remove", comment: "A to-do list: take one item off it") } icon: { Image(systemName: "trash") }
            }
        }
        .contextMenu {
            // Out to a film's or a series' pages (asked 2026-11-24): its IMDb, its Wikipedia, where it's on.
            if list.kind == .watch {
                Section {
                    ForEach(FilmLookUp.allCases) { site in
                        Button { openURL(site.url(for: item)) } label: {
                            Label { site.title } icon: { Image(systemName: site.symbol) }
                        }
                    }
                }
            }
            // New words for it (asked 2026-11-24: "Allow to edit the todo items with a long press").
            Button { editing = item } label: {
                Label { Text("Edit") } icon: { Image(systemName: "pencil") }
            }
            .accessibilityIdentifier("list-edit")
            if list.groupsByWhen || tickets, !item.done {
                Button { dating = item } label: {
                    Label {
                        if item.when == nil {
                            Text("Set Date", comment: "A to-do's long-press menu: give it a day and time")
                        } else {
                            Text("Change Date", comment: "A to-do's long-press menu: move it to another day or time")
                        }
                    } icon: { Image(systemName: "calendar") }
                }
                .accessibilityIdentifier("list-set-date")
                if item.when != nil {
                    Button { lists.setDate(nil, for: item, in: list) } label: {
                        Label { Text("Remove Date", comment: "A to-do: take its day and time off") } icon: { Image(systemName: "calendar.badge.minus") }
                    }
                    .accessibilityIdentifier("list-remove-date")
                }
            }
            Button(role: .destructive) { lists.remove([item], from: list) } label: {
                Label { Text("Remove", comment: "A to-do list: take one item off it") } icon: { Image(systemName: "trash") }
            }
        }
        .accessibilityAddTraits(toggles ? .isToggle : [])
        .accessibilityValue(!toggles ? Text(verbatim: "") : !item.done ? Text("Not done")
                            : list.kind == .watch ? Text("Watched", comment: "A watch list: the stamp on a film or series already seen")
                            : Text("Done"))
        .accessibilityHint(!toggles ? Text(verbatim: "")
                           : item.done ? Text("Puts it back on the list", comment: "VoiceOver hint: a checked-off to-do item")
                                       : Text("Checks it off", comment: "VoiceOver hint: a to-do item"))
        .accessibilityAction(named: Text("Edit")) { editing = item }
        .accessibilityAction(named: Text("Remove", comment: "A to-do list: take one item off it")) { lists.remove([item], from: list) }
    }
}

extension TodayListView {
    private func addRow(_ list: TodayList) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 24))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, mark)
                .opacity(typing || !adding.isEmpty ? 1 : 0.85)
                .accessibilityHidden(true)
            TextField(String(localized: "Add an item", comment: "A to-do list: the field to type a new item in"), text: $adding)
                .chatFont(.body)
                .focused($typing)
                .submitLabel(.done)
                .onSubmit { addTyped(to: list) }
        }
        .padding(.vertical, 3)
        .frame(minHeight: 44)
        .contentShape(.rect)
        .onTapGesture { typing = true }
    }

    /// "Done · 2", folding the checked-off items away with a tap, and Clear Done beside it.
    private func doneHeader(_ list: TodayList) -> some View {
        HStack(spacing: 8) {
            Button { doneFolded.toggle() } label: {
                HStack(spacing: 6) {
                    if list.kind == .watch {
                        Text("Watched", comment: "A watch list: the stamp on a film or series already seen")
                    } else {
                        Text("Done", comment: "Closes the Work sheet")
                    }
                    Text(list.finished.count, format: .number)
                        .monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .rotationEffect(.degrees(doneFolded ? -90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(doneFolded ? Text("\(list.finished.count) of \(list.items.count) done") : Text(verbatim: ""))
            Spacer()
            Button { lists.clearDone(in: list) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Clear Done", comment: "A to-do list: remove the items checked off"))
        }
        .chatFont(.subheadline, weight: .semibold)
        .foregroundStyle(.secondary)
        .textCase(nil)
    }

    /// "Used Stubs" over the pile (a shelf's "Watched" over its row), See All to have them as rows
    /// (to put one back), and Clear Done.
    private func stubsHeader(_ list: TodayList) -> some View {
        HStack(spacing: 12) {
            if shelf(list) {
                Text("Watched", comment: "A watch list: the stamp on a film or series already seen")
            } else {
                Text("Used Stubs", comment: "Ticket Stubs: the heading over the films already watched, shown as torn-off stubs")
            }
            Spacer()
            Button { stubsOpen.toggle() } label: {
                if stubsOpen {
                    Text("Show Less", comment: "Watches: folds a watch's report back to a few lines")
                } else {
                    Text("See All \(list.finished.count)", comment: "Ticket Stubs: shows every watched film as a row, beside the pile of used stubs")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(CardInk.readable(mark, drawnIn: scheme))
            .accessibilityIdentifier("stubs-see-all")
            Button { lists.clearDone(in: list) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Clear Done", comment: "A to-do list: remove the items checked off"))
        }
        .chatFont(.subheadline, weight: .semibold)
        .foregroundStyle(.secondary)
        .textCase(nil)
    }

    private func menu(_ list: TodayList) -> some View {
        Menu {
            Button { styling = true } label: {
                Label { Text("Change Look", comment: "A to-do list: choose its emoji, colour and kind") } icon: { Image(systemName: "paintpalette") }
            }
            Button {
                newTitle = list.title
                renaming = true
            } label: {
                Label { Text("Rename", comment: "A to-do list: give it a new name") } icon: { Image(systemName: "pencil") }
            }
            if !list.finished.isEmpty {
                Button { lists.clearDone(in: list) } label: {
                    Label { Text("Clear Done", comment: "A to-do list: remove the items checked off") } icon: { Image(systemName: "checkmark.circle.badge.xmark") }
                }
            }
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label { Text("Delete List", comment: "A to-do list: delete the whole list") } icon: { Image(systemName: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel(Text("More", comment: "A to-do list: the menu of what else can be done with it"))
        }
    }

    /// What's typed goes on the list, and the field stays ready for the next.
    private func addTyped(to list: TodayList) {
        let text = adding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lists.add(text, to: list)
        adding = ""
        typing = true
    }
}

/// An open to-do and the group it's in by when (its row's day badge goes by it).
private struct Placed: Identifiable {
    let when: TodayList.When
    let item: TodayList.Item
    var id: String { item.id }

    static func all(_ list: TodayList) -> [Placed] {
        list.openByWhen().flatMap { group in group.items.map { Placed(when: group.when, item: $0) } }
    }
}

/// A to-do list's other layouts (`Settings.TodoLayout`; the pieces are in TodoLayouts.swift).
extension TodayListView {
    /// Next Up: the soonest to-do large, Mark Done or Later on it, then the rest.
    @ViewBuilder
    fileprivate func nextUp(_ list: TodayList) -> some View {
        let order = Placed.all(list)
        if let first = order.first {
            Section {
                NextUpCard(item: first.item, mark: mark, done: { lists.toggle(first.item, in: list) },
                           tomorrow: { if let day = Self.tomorrow(for: first.item) { lists.setDate(day, for: first.item, in: list) } },
                           pick: { dating = first.item })
                    .modifier(ListItemActions(item: first.item, list: list, tickets: false, editing: $editing, dating: $dating, toggles: false))
                    .id(first.item.id)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .scale(scale: 0.9).combined(with: .opacity)))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(order.dropFirst()) { row($0.item, in: list, group: $0.when) }
                addRow(list)
            } header: {
                if order.count > 1 {
                    Text("After That", comment: "Next Up: the heading over the to-dos after the next one")
                        .chatFont(.title3, weight: .bold)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        } else {
            Section {
                if !list.items.isEmpty { allDone }
                addRow(list)
            }
        }
    }

    /// Later on Next Up: tomorrow, at its own time or nine.
    fileprivate static func tomorrow(for item: TodayList.Item, now: Date = .now) -> Date? {
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
        let time = item.when.map { calendar.dateComponents([.hour, .minute], from: $0) }
        return calendar.date(bySettingHour: time?.hour ?? 9, minute: time?.minute ?? 0, second: 0, of: day)
    }

    /// Agent Can Help: the to-dos the agent can do part of, each with what it would do, a tap
    /// away; then the ones that are just yours.
    @ViewBuilder
    fileprivate func helpItems(_ list: TodayList) -> some View {
        let order = Placed.all(list)
        let helped = order.filter { $0.item.help != nil }, yours = order.filter { $0.item.help == nil }
        Section {
            ForEach(helped) { placed in
                let item = placed.item
                HelpCard(item: item, mark: mark, toggle: { lists.toggle(item, in: list) },
                         ask: ask.map { ask in { ask(Self.helpWords(item, in: list)) } })
                    .modifier(ListItemActions(item: item, list: list, tickets: false, editing: $editing, dating: $dating, toggles: false))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
            }
            if !lists.helps {
                Text("Help lines need the Redde plugin 1.46 or later on your Hermes.", comment: "Agent Can Help: under its heading when the server's plugin is too old for it")
                    .chatFont(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            } else if let ask, !order.isEmpty {
                Button { ask(Self.lookOverWords(list)) } label: {
                    Label {
                        Text("Ask \(settings.headerTitle) What It Can Help With", comment: "Agent Can Help: has the agent go over the list and say what it could do (%@ is the agent's name)")
                    } icon: { Image(systemName: "sparkles") }
                        .chatFont(.subheadline, weight: .semibold)
                        .foregroundStyle(CardInk.readable(mark, drawnIn: scheme))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(CardInk.readable(mark, drawnIn: scheme).opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
                        .contentShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("help-look-over")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
            }
        } header: {
            Label { Text("Agent Can Help", comment: "A to-do list's layout: what the agent can do part of, apart from what's just yours") } icon: { Image(systemName: "bolt.fill") }
                .chatFont(.title3, weight: .bold)
                .foregroundStyle(CardInk.readable(mark, drawnIn: scheme))
                .textCase(nil)
        }
        Section {
            if order.isEmpty, !list.items.isEmpty { allDone }
            ForEach(yours) { row($0.item, in: list, group: $0.when) }
            addRow(list)
        } header: {
            if !yours.isEmpty {
                Text("Just You", comment: "Agent Can Help: the heading over the to-dos only the person can do")
                    .chatFont(.title3, weight: .bold)
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
        }
    }

    /// What a tap on a help line says to the agent.
    fileprivate static func helpWords(_ item: TodayList.Item, in list: TodayList) -> String {
        String(localized: "“\(item.text)” is on my \(list.title) list, and you offered to help: \(item.help ?? ""). Please go ahead.",
               comment: "Agent Can Help: sent to the agent when a to-do's help line is tapped (the to-do, the list's name, the help line)")
    }

    /// What Ask … What It Can Help With says to the agent.
    fileprivate static func lookOverWords(_ list: TodayList) -> String {
        String(localized: "Please look over my \(list.title) list. Give each to-do you could do part of yourself a help line (redde_list 'help'), and say which you took on.",
               comment: "Agent Can Help: sent to the agent to go over a to-do list; keep redde_list 'help' as it is")
    }

    /// Week: this week's strip, a timeline of what has a day, and the to-dos with none.
    @ViewBuilder
    fileprivate func weekItems(_ list: TodayList) -> some View {
        let calendar = Calendar.current
        let dated = list.open.filter { $0.when != nil }.sorted { ($0.when ?? .distantFuture) < ($1.when ?? .distantFuture) }
        let shown = weekDay.map { day in dated.filter { $0.when.map { calendar.isDate($0, inSameDayAs: day) } ?? false } } ?? dated
        let loose = list.open.filter { $0.when == nil }
        Section {
            TodoWeekStrip(days: Self.weekDays(), busy: Set(dated.compactMap { $0.when.map(calendar.startOfDay) }), picked: $weekDay, mark: mark)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
        }
        Section {
            if list.open.isEmpty, !list.items.isEmpty { allDone }
            if shown.isEmpty, let day = weekDay {
                Text("Nothing on \(day.formatted(.dateTime.weekday(.wide)))", comment: "Week: a day picked on the strip with no to-dos (%@ is the day)")
                    .chatFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { n, item in
                TimelineRow(item: item, mark: mark, first: n == 0, last: n == shown.count - 1, toggle: { lists.toggle(item, in: list) })
                    .modifier(ListItemActions(item: item, list: list, tickets: false, editing: $editing, dating: $dating))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
            }
        } header: {
            if !shown.isEmpty {
                Group {
                    if let weekDay {
                        Text(weekDay, format: .dateTime.weekday(.wide).month(.wide).day())
                    } else {
                        Text("Coming Up", comment: "Agent Activity's first tab: what the agents will do on their own")
                    }
                }
                .chatFont(.title3, weight: .bold)
                .foregroundStyle(.primary)
                .textCase(nil)
            }
        }
        if !loose.isEmpty, weekDay == nil {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(loose) { item in
                        LooseCard(item: item, mark: mark, plan: { dating = item }, toggle: { lists.toggle(item, in: list) })
                            .modifier(ListItemActions(item: item, list: list, tickets: false, editing: $editing, dating: $dating, toggles: false))
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            } header: {
                Text("No Day Yet", comment: "Week: the heading over the to-dos with no day; a tap on one gives it a day")
                    .chatFont(.title3, weight: .bold)
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
        }
        Section { addRow(list) }
    }

    /// The seven days of this calendar week, each at its start.
    fileprivate static func weekDays(now: Date = .now) -> [Date] {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        return (0 ..< 7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Notepad: the list written on a yellow pad, in its own order, things crossed off where they are.
    fileprivate func notepad(_ list: TodayList) -> some View {
        Section {
            PadBinding()
                .listRowBackground(PadPaper.binding)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            ForEach(list.items) { item in
                Button { lists.toggle(item, in: list) } label: { PadRow(item: item).contentShape(.rect) }
                    .buttonStyle(.plain)
                    .sensoryFeedback(trigger: item.done) { _, now in now ? .impact(weight: .light) : .selection }
                    .modifier(ListItemActions(item: item, list: list, tickets: false, editing: $editing, dating: $dating))
                    .listRowBackground(PadRowBackground())
                    .listRowInsets(EdgeInsets())
                    .listRowSeparatorTint(PadPaper.rule)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }
            HStack(spacing: 0) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(PadPaper.faded)
                    .frame(width: PadPaper.marginX)
                    .accessibilityHidden(true)
                TextField(text: $adding, prompt: Text("add something…", comment: "Notepad: the line at the bottom of the pad to write a new to-do on").foregroundStyle(PadPaper.faded)) {
                    Text("Add an item", comment: "A to-do list: the field to type a new item in")
                }
                .font(PadPaper.hand(21))
                .foregroundStyle(PadPaper.ink)
                .tint(PadPaper.red)
                .focused($typing)
                .submitLabel(.done)
                .onSubmit { addTyped(to: list) }
                .padding(.leading, 14)
            }
            .frame(minHeight: 54)
            .contentShape(.rect)
            .onTapGesture { typing = true }
            .listRowBackground(PadRowBackground())
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
    }
}

/// The page's ring: how much is done, filled in green, "2/5" in it.
private struct BigRing: View {
    var done: Int
    var total: Int
    var mark: Color

    var body: some View {
        ZStack {
            Circle().stroke(mark.opacity(0.18), lineWidth: 7)
            Circle().trim(from: 0, to: total == 0 ? 0 : Double(done) / Double(total))
                .stroke(mark, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if done == total {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(mark)
                    .transition(.scale.combined(with: .opacity))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(done, format: .number).font(.system(size: 19, weight: .bold, design: .rounded))
                        .contentTransition(.numericText(value: Double(done)))
                    Text(verbatim: "/\(total)").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
        }
        .frame(width: 64, height: 64)
        .padding(4)
        .animation(.snappy(duration: 0.3), value: done)
    }
}

/// A watch list's progress, under its name.
private struct ThinBar: View {
    var done: Int
    var total: Int
    var mark: Color

    var body: some View {
        Capsule()
            .fill(mark.opacity(0.22))
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { size in
                    Capsule()
                        .fill(mark)
                        .frame(width: size.size.width * CGFloat(done) / CGFloat(max(total, 1)))
                }
            }
            .animation(.snappy(duration: 0.3), value: done)
    }
}

/// Picks a to-do's day and time, from now to the 60 days ahead the plugin can plan.
private struct DateSheet: View {
    let item: TodayList.Item
    let mark: Color
    let save: (Date?) -> Void
    private let range: ClosedRange<Date>
    @State private var date: Date
    @Environment(\.dismiss) private var dismiss

    init(item: TodayList.Item, mark: Color, save: @escaping (Date?) -> Void) {
        self.item = item
        self.mark = mark
        self.save = save
        let range = TodayList.planRange()
        self.range = range
        _date = State(initialValue: item.suggestedDate().clamped(to: range))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(selection: $date, in: range, displayedComponents: .date) { Text("Date") }
                        .datePickerStyle(.graphical)
                    DatePicker(selection: $date, in: range, displayedComponents: .hourAndMinute) { Text("Time") }
                } footer: {
                    Text("Redde will remind you that day and check in afterward.",
                         comment: "A to-do's date picker: what setting a date does")
                }
                if item.when != nil {
                    Section {
                        Button(role: .destructive) { finish(nil) } label: {
                            Text("Remove Date", comment: "A to-do: take its day and time off")
                        }
                        .accessibilityIdentifier("date-sheet-remove")
                    }
                }
            }
            .tint(mark)
            .navigationTitle(Text(verbatim: item.text))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { finish(date) }
                        .accessibilityIdentifier("date-sheet-save")
                }
            }
        }
        .presentationDetents([.height(650), .large])
        #if os(iOS)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        #endif
    }

    private func finish(_ picked: Date?) {
        save(picked)
        dismiss()
    }
}

/// An item's words to change, in a field that grows with them (a long one like "Black Friday sale
/// starts 11/26 7PM EST (runs to 11/29 7PM EST)" needs more than an alert's one line). Return saves.
private struct EditItemSheet: View {
    let item: TodayList.Item
    let mark: Color
    let save: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(item: TodayList.Item, mark: Color, save: @escaping (String) -> Void) {
        self.item = item
        self.mark = mark
        self.save = save
        _text = State(initialValue: item.text)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                TextField(text: $text, axis: .vertical) { Text(verbatim: item.text) }
                    .chatFont(.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .submitLabel(.done)
                    .accessibilityIdentifier("edit-item-field")
            }
            .tint(mark)
            .navigationTitle(Text("Edit Item", comment: "A to-do list: the title of the sheet that changes one item's words"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { finish() }
                        .fontWeight(.semibold)
                        .disabled(trimmed.isEmpty)
                        .accessibilityIdentifier("edit-item-save")
                }
            }
            // An item is one line: Return saves it rather than starting another.
            .onChange(of: text) { _, now in
                guard now.contains("\n") else { return }
                text = now.replacing("\n", with: " ")
                finish()
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        #if os(iOS)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        #endif
        .macSheetSize(width: 460, height: 260)
    }

    private func finish() {
        guard !trimmed.isEmpty else { return }
        save(trimmed)
        dismiss()
    }
}

private extension Date {
    func clamped(to range: ClosedRange<Date>) -> Date { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

/// A to-do on a list sorted by when: its day on a small badge unless it's today, its time and who
/// it's with, and the tick at the end.
private struct DatedRow: View {
    let item: TodayList.Item
    let group: TodayList.When?
    let mark: Color
    @Environment(\.colorScheme) private var scheme

    /// Today's row has a tinted panel behind it, where the list's colour wouldn't read.
    private var detailStyle: AnyShapeStyle {
        switch group {
        case .overdue: AnyShapeStyle(CardInk.readable(.orange, drawnIn: scheme))
        case .today: AnyShapeStyle(.primary)
        default: AnyShapeStyle(CardInk.readable(mark, drawnIn: scheme))
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if !item.done, let date = item.when, let group, group != .today, group != .anytime {
                DayBadge(date: date, showsMonth: group != .thisWeek, tint: group == .overdue ? CardInk.readable(.orange, drawnIn: scheme) : .primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .chatFont(.body, weight: item.done ? .regular : .semibold)
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if !item.done, let detail = item.timeAndCompany {
                    Text(verbatim: detail)
                        .chatFont(.footnote, weight: .medium)
                        .foregroundStyle(detailStyle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ListTick(on: item.done, mark: mark)
        }
        .padding(.vertical, 3)
        .frame(minHeight: 44)
        // The task first for VoiceOver, then when: the badge comes first on screen.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.done ? item.text : [item.text, item.plan].compactMap { $0 }.joined(separator: ", ")))
    }
}

/// "FRI 27" this week, "DEC 7" further off or overdue.
private struct DayBadge: View {
    let date: Date
    let showsMonth: Bool
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(date, format: showsMonth ? Date.FormatStyle().month(.abbreviated) : Date.FormatStyle().weekday(.abbreviated))
                .chatFont(.caption2, weight: .bold)
                .textCase(.uppercase)
                .foregroundStyle(tint == .primary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            Text(date, format: Date.FormatStyle().day())
                .chatFont(.title3, weight: .heavy)
                .foregroundStyle(tint)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(minWidth: 42)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(date, format: Date.FormatStyle().weekday(.wide).month(.wide).day()))
    }
}

/// A film's or a series' pages out on the web, from its long press on a watch list (asked
/// 2026-11-24, "search out to get details on the movie"): its IMDb, its Wikipedia, and where it's
/// on (the TV app's search, as a show card's tap). Each is a search by its name and year, which
/// the site's own page is a tap from: a list item keeps no page of its own, and opening a site's
/// search needs no key, where reading IMDb's or TMDb's data from the server would.
enum FilmLookUp: CaseIterable, Identifiable {
    case imdb, wikipedia, watch

    var id: Self { self }

    var title: Text {
        switch self {
        case .imdb: Text(verbatim: "IMDb")
        case .wikipedia: Text(verbatim: "Wikipedia")
        case .watch: Text("Where can I watch it?", comment: "A chip under a show card: asks the agent where it streams")
        }
    }

    var symbol: String {
        switch self {
        case .imdb: "star"
        case .wikipedia: "book"
        case .watch: "play.tv"
        }
    }

    /// Its search, by its name and year ("Home Alone 1990"); Wikipedia's in the phone's language.
    func url(for item: TodayList.Item, language: String = Locale.current.language.languageCode?.identifier ?? "en") -> URL {
        let named = [item.name, item.year.map(String.init)].compactMap(\.self).joined(separator: " ")
        var parts: URLComponents
        switch self {
        case .imdb:
            parts = URLComponents(string: "https://www.imdb.com/find/")!
            parts.queryItems = [URLQueryItem(name: "q", value: named), URLQueryItem(name: "s", value: "tt")]
        case .wikipedia:
            let site = language.allSatisfy(\.isLetter) && !language.isEmpty ? language : "en"
            parts = URLComponents(string: "https://\(site).wikipedia.org/w/index.php")!
            parts.queryItems = [URLQueryItem(name: "search", value: named)]
        case .watch:
            parts = URLComponents(string: "https://tv.apple.com/search")!
            parts.queryItems = [URLQueryItem(name: "term", value: item.name)]
        }
        return parts.url!
    }
}

/// A film or a series on a watch list, one row: a small poster (or a film strip while it has none),
/// its name, its year and any plan, and the tick at the end. Once watched: smaller, grey, the year
/// at the end, so a long list stays easy to scan.
private struct FilmRow: View {
    let item: TodayList.Item
    let mark: Color
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    /// "2019 · Thu, Nov 26, 7:30 PM · with Robin".
    private var details: String {
        [item.year.map(String.init), item.plan].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        let width = (item.done ? 30 : 38) * min(scale, 1.5)
        HStack(spacing: 12) {
            let picture = CardPicture(url: item.poster.flatMap(URL.init(string:)), symbol: "film", width: width, height: width * 1.48,
                                      fill: true, corner: 6, pixels: 180)
            // Greyed only once watched: a saturation filter, even at 1, was one more pass per row.
            if item.done {
                picture.saturation(0).opacity(0.7)
            } else {
                picture
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .chatFont(item.done ? .subheadline : .body, weight: .semibold)
                    .lineLimit(2)
                    .foregroundStyle(item.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if !item.done, !details.isEmpty {
                    Text(verbatim: details)
                        .chatFont(.footnote)
                        .lineLimit(2)
                        .foregroundStyle(item.plan == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(mark))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.done, let year = item.year {
                Text(verbatim: String(year))
                    .chatFont(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ListTick(on: item.done, mark: mark)
        }
        .padding(.vertical, 1)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [item.name, item.year.map(String.init), item.plan].compactMap { $0 }.joined(separator: ", ")))
    }
}

/// A finished list's emoji thrown out from under the bar, once, when its last item is ticked.
private struct ListBurst: View {
    let emoji: String
    let trigger: Bool
    @State private var flying = false
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var still

    private static let count = 16

    var body: some View {
        ZStack {
            if shown {
                ForEach(0 ..< Self.count, id: \.self) { n in
                    let angle = Double(n) / Double(Self.count) * 2 * .pi + Double(n % 3) * 0.2
                    let reach = 90 + Double((n * 37) % 70)
                    Text(verbatim: emoji)
                        .font(.system(size: 22 + Double((n * 13) % 14)))
                        .offset(x: flying ? cos(angle) * reach : 0, y: flying ? sin(angle) * reach + 40 : 0)
                        .scaleEffect(flying ? 1 : 0.3)
                        .rotationEffect(.degrees(flying ? Double((n * 47) % 90) - 45 : 0))
                        .opacity(flying ? 0 : 1)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, now in
            guard now, !still else { return }
            flying = false
            shown = true
            withAnimation(.easeOut(duration: 1.2)) { flying = true }
            Task {
                try? await Task.sleep(for: .seconds(1.3))
                shown = false
                flying = false
            }
        }
    }
}

/// An item's circle on the page: open, or filled green with a tick.
struct ListTick: View {
    var on: Bool
    var mark: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if on {
                Circle().fill(mark)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(scheme == .dark ? Color.black : .white)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.75)
            }
        }
        .frame(width: 24, height: 24)
        .animation(.snappy(duration: 0.2), value: on)
        // A tick springs.
        .keyframeAnimator(initialValue: 1.0, trigger: on) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(on ? 1.3 : 0.85, duration: 0.1)
            SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
        }
    }
}

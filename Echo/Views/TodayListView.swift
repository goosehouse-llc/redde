import SwiftUI

/// One of the person's lists, opened from its tile on the Today row (`TodayLists`, 2026-11-09).
/// Drawn as its own page (asked 2026-11-14: "make the to do list nicer to look at"; a card inside
/// the sheet before): the list's name large beside a ring of how much is done, what's left on one
/// panel with a line to add to it, and what's done below, folded away with a tap. Tap to check an
/// item off, swipe or hold one to remove it; Clear Done, Rename and Delete in the menu. The same
/// changes an agent makes with `redde_list`, kept on the Hermes.
///
/// From 2026-11-23 ("make these lists a bit more fun"): the list's colour washes the top of the
/// page and fills its ring and ticks, its emoji sits by its name, a tick springs, a finished list
/// throws its emoji about, and a watch list is a wall of posters, each stamped once watched.
/// Change Look picks the emoji, the colour and the kind.
struct TodayListView: View {
    @State private var lists = TodayLists.shared
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmingDelete = false
    @State private var adding = ""
    @State private var doneFolded = false
    @State private var styling = false
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

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

    /// The marks: the list's colour, else the checklists' "done" green.
    private var mark: Color { lists.shown?.color ?? ColorScheme.checklistGreen }

    private func content(_ list: TodayList) -> some View {
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

            Section {
                if list.open.isEmpty, !list.items.isEmpty { allDone }
                if list.kind == .watch {
                    if !list.open.isEmpty { posters(list.open, in: list) }
                } else {
                    ForEach(list.open) { row($0, in: list) }
                }
                addRow(list)
            }

            if !list.finished.isEmpty {
                Section {
                    if !doneFolded {
                        if list.kind == .watch {
                            posters(list.finished, in: list)
                        } else {
                            ForEach(list.finished) { row($0, in: list) }
                        }
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

    /// The name, large, how it stands, and the ring.
    private func header(_ list: TodayList) -> some View {
        let done = list.finished.count, total = list.items.count
        return HStack(alignment: .center, spacing: 14) {
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
            if total > 0 {
                BigRing(done: done, total: total, mark: mark)
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

    private func row(_ item: TodayList.Item, in list: TodayList) -> some View {
        Button { lists.toggle(item, in: list) } label: {
            HStack(spacing: 14) {
                Tick(on: item.done, mark: mark)
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
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(trigger: item.done) { _, now in now ? .impact(weight: .light) : .selection }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { lists.remove([item], from: list) } label: {
                Label { Text("Remove", comment: "A to-do list: take one item off it") } icon: { Image(systemName: "trash") }
            }
        }
        .contextMenu {
            Button(role: .destructive) { lists.remove([item], from: list) } label: {
                Label { Text("Remove", comment: "A to-do list: take one item off it") } icon: { Image(systemName: "trash") }
            }
        }
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(item.done ? Text("Done") : Text("Not done"))
        .accessibilityHint(item.done ? Text("Puts it back on the list", comment: "VoiceOver hint: a checked-off to-do item")
                                     : Text("Checks it off", comment: "VoiceOver hint: a to-do item"))
        .accessibilityAction(named: Text("Remove", comment: "A to-do list: take one item off it")) { lists.remove([item], from: list) }
    }

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
                    Text("Done", comment: "Closes the Work sheet")
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

    /// A watch list's titles: posters, as many across as fit; tap one to mark it watched.
    private func posters(_ items: [TodayList.Item], in list: TodayList) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 12, alignment: .top)], alignment: .leading, spacing: 16) {
            ForEach(items) { item in
                PosterTile(item: item, mark: mark) { lists.toggle(item, in: list) }
                    .contextMenu {
                        Button(role: .destructive) { lists.remove([item], from: list) } label: {
                            Label { Text("Remove", comment: "A to-do list: take one item off it") } icon: { Image(systemName: "trash") }
                        }
                    }
                    .accessibilityAction(named: Text("Remove", comment: "A to-do list: take one item off it")) { lists.remove([item], from: list) }
            }
        }
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
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

/// A film or a series on a watch list: its poster (or a film strip while it has none), its name and
/// year under it; once watched, greyed with a stamp in the list's colour.
private struct PosterTile: View {
    let item: TodayList.Item
    let mark: Color
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay {
                        GeometryReader { size in
                            CardPicture(url: item.poster.flatMap(URL.init(string:)), symbol: "film", width: size.size.width, height: size.size.height,
                                        fill: true, corner: 12, pixels: 360)
                        }
                    }
                    .saturation(item.done ? 0 : 1)
                    .opacity(item.done ? 0.55 : 1)
                    .overlay(alignment: .center) {
                        if item.done {
                            Label { Text("Watched", comment: "A watch list: the stamp on a film or series already seen") } icon: { Image(systemName: "checkmark") }
                                .font(.system(.caption, design: .rounded, weight: .heavy))
                                .textCase(.uppercase)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(.white)
                                .background(mark, in: .rect(cornerRadius: 6))
                                .rotationEffect(.degrees(-12))
                                .transition(.scale(scale: 1.6).combined(with: .opacity))
                        }
                    }
                    .shadow(color: .black.opacity(item.done ? 0 : 0.18), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .chatFont(.footnote, weight: .semibold)
                        .lineLimit(2)
                        .foregroundStyle(item.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    if let year = item.year {
                        Text(verbatim: String(year)).chatFont(.caption2).foregroundStyle(.secondary)
                    }
                    if let plan = item.plan {
                        Label(plan, systemImage: "calendar")
                            .chatFont(.caption2, weight: .semibold)
                            .foregroundStyle(item.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(mark))
                            .lineLimit(2)
                    }
                }
            }
            .contentShape(.rect)
            .animation(.spring(duration: 0.35, bounce: 0.4), value: item.done)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(trigger: item.done) { _, now in now ? .impact(weight: .medium) : .selection }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [item.name, item.year.map(String.init), item.plan].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits([.isButton, .isToggle])
        .accessibilityValue(item.done ? Text("Watched", comment: "A watch list: the stamp on a film or series already seen") : Text("Not done"))
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
private struct Tick: View {
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

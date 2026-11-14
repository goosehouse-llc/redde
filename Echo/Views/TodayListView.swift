import SwiftUI

/// One of the person's lists, opened from its tile on the Today row (`TodayLists`, 2026-11-09).
/// Drawn as its own page (asked 2026-11-14: "make the to do list nicer to look at"; a card inside
/// the sheet before): the list's name large beside a ring of how much is done, what's left on one
/// panel with a line to add to it, and what's done below, folded away with a tap. Tap to check an
/// item off, swipe or hold one to remove it; Clear Done, Rename and Delete in the menu. The same
/// changes an agent makes with `redde_list`, kept on the Hermes.
struct TodayListView: View {
    @State private var lists = TodayLists.shared
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmingDelete = false
    @State private var adding = ""
    @State private var doneFolded = false
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

    /// The marks: the checklists' "done" green.
    private let mark = ColorScheme.checklistGreen

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
                ForEach(list.open) { row($0, in: list) }
                addRow(list)
            }

            if !list.finished.isEmpty {
                Section {
                    if !doneFolded {
                        ForEach(list.finished) { row($0, in: list) }
                    }
                } header: {
                    doneHeader(list)
                }
            }
        }
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
        return HStack(alignment: .center, spacing: 16) {
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
                Text(item.text)
                    .chatFont(.body)
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: item.done)
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
    }
}

import SwiftUI

/// One of the person's lists, opened from its tile on the Today row (`TodayLists`, 2026-11-09):
/// tap to check an item off, type to add one, swipe to remove; the done ones gather under the
/// rest, to clear in one go. The same changes an agent makes with `redde_list`, kept on the Hermes.
struct TodayListView: View {
    @State private var lists = TodayLists.shared
    @State private var adding = ""
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmingDelete = false
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

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

    private func content(_ list: TodayList) -> some View {
        List {
            if let problem = lists.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .chatFont(.footnote)
                    .foregroundStyle(.orange)
            }
            Section {
                ForEach(list.open) { row($0, in: list) }
                    .onDelete { lists.remove($0.map { list.open[$0] }, from: list) }
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    TextField(String(localized: "Add an item", comment: "A to-do list: the field to type a new item in"), text: $adding)
                        .chatFont(.body)
                        .focused($typing)
                        .submitLabel(.done)
                        .onSubmit { addTyped(to: list) }
                }
            }
            if !list.finished.isEmpty {
                Section {
                    ForEach(list.finished) { row($0, in: list) }
                        .onDelete { lists.remove($0.map { list.finished[$0] }, from: list) }
                } header: {
                    HStack {
                        // (Their own keys: "Done" is the button's word elsewhere, "Clear" the weather's.)
                        Text(String(localized: "list.done", defaultValue: "Done", comment: "A to-do list: the heading over the items checked off"))
                        Spacer()
                        Button { lists.clearDone(in: list) } label: {
                            Text(String(localized: "list.clear", defaultValue: "Clear", comment: "A to-do list: the button by the Done heading that removes the items checked off"))
                        }
                        .chatFont(.footnote, weight: .semibold)
                        .textCase(nil)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: list.items)
        .sensoryFeedback(.success, trigger: list.finished.count) { old, new in new > old }
        .navigationTitle(list.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    addTyped(to: list)
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarLeading) {
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
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel(Text("More", comment: "A to-do list: the menu of what else can be done with it"))
                }
            }
        }
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

    private func row(_ item: TodayList.Item, in list: TodayList) -> some View {
        Button { lists.toggle(item, in: list) } label: {
            HStack(spacing: 12) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(item.text)
                    .chatFont(.body)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(item.done ? .isSelected : [])
        .accessibilityHint(item.done ? Text("Puts it back on the list", comment: "VoiceOver hint: a checked-off to-do item")
                                     : Text("Checks it off", comment: "VoiceOver hint: a to-do item"))
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

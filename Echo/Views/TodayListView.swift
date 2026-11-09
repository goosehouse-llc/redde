import SwiftUI

/// One of the person's lists, opened from its tile on the Today row (`TodayLists`, 2026-11-09):
/// drawn as a checklist card (`TodayListCard`): tap to check an item off, type to add one, hold
/// one to remove it; Clear Done, Rename and Delete in the menu. The same changes an agent makes
/// with `redde_list`, kept on the Hermes.
struct TodayListView: View {
    @State private var lists = TodayLists.shared
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let problem = lists.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .chatFont(.footnote)
                        .foregroundStyle(.orange)
                }
                TodayListCard(list: list).cardInk()
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(list.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
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
}

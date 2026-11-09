import SwiftUI

/// A message or a reply to put on one of the person's lists (asked 2026-11-09: "add it to a list"
/// for a single message), from its menu: the sheet opens over the chat with the text to trim and
/// the lists to pick from, or a new one.
@MainActor
@Observable
final class ListDraft {
    static let shared = ListDraft()
    var text: String?

    /// An item is one line of at most 200 characters on the Hermes (`lists.py`), so a long reply
    /// starts cut down, to be trimmed in the sheet.
    static let most = 200

    func start(_ text: String) {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.text = String(line.prefix(Self.most))
    }
}

/// The Add to a List sheet a message's menu asks for, over the chat (`ContentView`).
struct ListDraftSheet: ViewModifier {
    @State private var draft = ListDraft.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { draft.text != nil }, set: { if !$0 { draft.text = nil } })) {
            NavigationStack { AddToListView(text: draft.text ?? "") }
                .presentationDetents([.medium, .large])
        }
    }
}

struct AddToListView: View {
    @State private var lists = TodayLists.shared
    @State private var text: String
    /// The list it goes on; nil is a new one, named in `newTitle`.
    @State private var pick: String?
    @State private var newTitle = ""
    @State private var working = false
    @State private var problem: String?
    /// The list's name once it's on: said for a moment before the sheet closes.
    @State private var added: String?
    @Environment(\.dismiss) private var dismiss

    init(text: String) {
        _text = State(initialValue: text)
        _pick = State(initialValue: TodayLists.shared.lists.first?.id)
    }

    private var item: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool {
        !item.isEmpty && !working && (pick != nil || !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "The item", comment: "Add to a List: the field with the text that goes on the list"),
                          text: $text, axis: .vertical)
                    .lineLimit(2...6)
                    .onChange(of: text) { _, now in
                        if now.count > ListDraft.most { text = String(now.prefix(ListDraft.most)) }
                    }
            } footer: {
                Text("\(item.count) of \(ListDraft.most) characters",
                     comment: "Add to a List: how long the item is, of the most a list item can be")
                    .monospacedDigit()
            }
            Section {
                ForEach(lists.lists) { list in
                    Button { pick = list.id } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(list.title).foregroundStyle(.primary)
                                    Text("\(list.open.count) to do", comment: "Today strip: how many items on a to-do list aren't checked off")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "checklist") }
                            Spacer()
                            if pick == list.id { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(pick == list.id ? .isSelected : [])
                }
                Button { pick = nil } label: {
                    HStack {
                        Label(String(localized: "New List", comment: "Add to a List: the choice that makes a new list"), systemImage: "plus")
                            .foregroundStyle(.primary)
                        Spacer()
                        if pick == nil { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(pick == nil ? .isSelected : [])
                if pick == nil {
                    TextField(String(localized: "List name", comment: "Add to a List: the new list's name"), text: $newTitle)
                        .textInputAutocapitalization(.words)
                }
            } header: {
                Text("List", comment: "Add to a List: the heading over the lists to pick from")
            } footer: {
                Text("Your lists are on your Hermes, as tiles on the Today row at the top of your chats. Any bot can read them and add to them.",
                     comment: "Add to a List: where lists live")
            }
            if let added {
                Label(String(localized: "Added to \(added)", comment: "Add to a List: done, with the list's name"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle(Text("Add to a List", comment: "A message's menu, and the sheet it opens: put the message on one of your lists"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if working { ProgressView() } else { Button("Add") { add() }.disabled(!canAdd || added != nil) }
            }
        }
    }

    private func add() {
        let item = self.item
        if let pick, let list = lists.lists.first(where: { $0.id == pick }) {
            lists.add(item, toList: pick)
            done(list.title)
            return
        }
        working = true
        problem = nil
        Task {
            let made = await lists.make(newTitle, items: [(text: item, done: false)])
            working = false
            switch made {
            case .made(let title), .added(let title):
                done(title)
            case .failed(let why):
                problem = why
            }
        }
    }

    private func done(_ title: String) {
        added = title
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            dismiss()
        }
    }
}

import SwiftUI

/// Settings › Email › Piles (asked 2026-11-14: "my inbox in Redde needs more categories as the 4
/// we have do not catch everything"): the seven piles every inbox has, and the person's own, each a
/// name and a line of what goes in it, which their agent sorts new mail by. Plugin 1.31.0.
struct MailPilesView: View {
    @State private var center = MailCenter.shared
    @State private var editing: MailPile?
    @State private var adding = false
    @State private var problem: String?
    @State private var saving = false

    private var own: [MailPile] { center.status?.ownPiles ?? MailPiles.shared.own }

    var body: some View {
        List {
            Section {
                ForEach(own) { pile in
                    Button { editing = pile } label: { row(pile.bucket, about: pile.about) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { Task { await save(own.filter { $0.id != pile.id }) } } label: {
                                Label { Text("Delete", comment: "Email tagging rule: delete it") } icon: { Image(systemName: "trash") }
                            }
                        }
                }
                .onMove { from, to in
                    var moved = own
                    moved.move(fromOffsets: from, toOffset: to)
                    Task { await save(moved) }
                }
                if own.count < Self.most {
                    Button { adding = true } label: {
                        Label { Text("Add Pile", comment: "Email piles: make a new pile of the person's own") } icon: { Image(systemName: "plus.circle") }
                    }
                    .accessibilityIdentifier("piles.add")
                }
            } header: {
                Text("Your Piles", comment: "Email piles: the section of piles the person made")
            } footer: {
                Text("Your agent puts a new email in one of your piles when it fits what you wrote, ahead of the ones every inbox has; receipts stay in Receipts. A rule can put mail in a pile too.", comment: "Email piles: how the person's own piles are sorted into")
            }
            .disabled(saving)

            Section {
                ForEach(MailBucket.fixed) { row($0, about: $0.about) }
            } header: {
                Text("Every Inbox Has", comment: "Email piles: the section of the seven piles every inbox has")
            }

            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(Text("Piles", comment: "Email piles page: title"))
        #if os(iOS)
        .toolbar { if !own.isEmpty { EditButton() } }
        #endif
        .sheet(item: $editing) { pile in
            MailPileEditor(pile: pile, taken: names(except: pile.id), save: { edited in await save(own.map { $0.id == pile.id ? edited : $0 }) },
                           remove: { await save(own.filter { $0.id != pile.id }) })
        }
        .sheet(isPresented: $adding) {
            MailPileEditor(pile: nil, taken: names(except: nil), save: { await save(own + [$0]) }, remove: nil)
        }
        .task { await center.refreshStatus() }
    }

    /// The plugin keeps at most this many of the person's own.
    static let most = 8

    private func names(except id: String?) -> Set<String> {
        Set((MailBucket.fixed.map(\.label) + own.filter { $0.id != id }.map(\.name)).map { $0.lowercased() })
    }

    private func row(_ bucket: MailBucket, about: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: bucket.symbol + ".fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(bucket.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(bucket.label).font(.body)
                if !about.isEmpty {
                    Text(about).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .contentShape(.rect)
    }

    /// Done on the Hermes; true when it took it.
    @discardableResult
    private func save(_ piles: [MailPile]) async -> Bool {
        saving = true
        defer { saving = false }
        do {
            try await center.setPiles(piles)
            problem = nil
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }
}

/// A pile of the person's own, new or changed: its name and what goes in it.
struct MailPileEditor: View {
    let pile: MailPile?
    /// Names in use already, in lower case.
    let taken: Set<String>
    let save: (MailPile) async -> Bool
    let remove: (() async -> Bool)?

    @State private var name = ""
    @State private var about = ""
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var clash: Bool { taken.contains(trimmed.lowercased()) }
    private var fine: Bool { !trimmed.isEmpty && trimmed.count <= 24 && !trimmed.contains("/") && !trimmed.contains("\"") && !clash }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Name", comment: "A to-do list: the rename box's field"), text: $name)
                        .accessibilityIdentifier("pile.name")
                    TextField(String(localized: "What goes in it, e.g. the kids' school, teachers and class news", comment: "Email piles: the description field of a pile, with an example"),
                              text: $about, axis: .vertical)
                        .lineLimit(2 ... 5)
                        .accessibilityIdentifier("pile.about")
                } footer: {
                    if clash {
                        Text("There's already a pile called \(trimmed).", comment: "Email piles: the name is in use")
                    } else {
                        Text("Your agent reads this to decide what goes in the pile, so say who it's from or what it's about.", comment: "Email piles: under a pile's description")
                    }
                }
                if let remove {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                busy = true
                                if await remove() { dismiss() }
                                busy = false
                            }
                        } label: {
                            Text("Delete Pile", comment: "Email piles: delete one of the person's own piles")
                        }
                    } footer: {
                        Text("Its mail is sorted again into the other piles.", comment: "Email piles: what deleting a pile does")
                    }
                }
            }
            .navigationTitle(pile == nil ? Text("New Pile", comment: "Email piles: the new pile sheet's title")
                                         : Text("Edit Pile", comment: "Email piles: the edit pile sheet's title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            busy = true
                            let made = MailPile(id: pile?.id ?? "", name: trimmed, about: about.trimmingCharacters(in: .whitespacesAndNewlines))
                            if await save(made) { dismiss() }
                            busy = false
                        }
                    }
                    .disabled(!fine || busy)
                }
            }
            .disabled(busy)
        }
        .onAppear {
            name = pile?.name ?? ""
            about = pile?.about ?? ""
        }
    }
}

extension MailBucket {
    /// What goes in each of the seven, in the Piles page.
    var about: String {
        switch self {
        case .important: String(localized: "A person or matter you'd want to see soon.", comment: "Email piles: what the Important pile holds")
        case .needsReply: String(localized: "Someone is waiting on your answer.", comment: "Email piles: what the Needs Reply pile holds")
        case .fyi: String(localized: "Worth knowing, nothing to answer.", comment: "Email piles: what the FYI pile holds")
        case .receipts: String(localized: "Orders, invoices, payments, shipping and bookings.", comment: "Email piles: what the Receipts pile holds")
        case .notifications: String(localized: "Sign-in codes, security alerts, account and app notices.", comment: "Email piles: what the Notifications pile holds")
        case .promotions: String(localized: "Sales, offers and marketing.", comment: "Email piles: what the Promotions pile holds")
        case .newsletters: String(localized: "Newsletters and digests you signed up to read.", comment: "Email piles: what the Newsletters pile holds")
        default: ""
        }
    }
}

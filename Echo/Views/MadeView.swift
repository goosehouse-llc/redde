import SwiftUI

/// Something an agent made, found in one of its replies kept on this device: a page it wrote for
/// the chat (`::preview`), a picture, a document, or a file it named on the server.
nonisolated struct MadeItem: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case page, picture, document, serverFile }

    var id: String
    var kind: Kind
    var name: String
    var attachment: Attachment?
    /// Where it is on the server, for a page or a file the reply named.
    var path: String?
    var conversationID: UUID
    var chat: String
    var agent: String?
    var at: Date

    /// What a conversation's replies made, newest first. Pictures the person sent, and their
    /// messages, are not the agent's.
    static func found(in record: ConversationRecord, agent: String?) -> [MadeItem] {
        var items: [MadeItem] = []
        for message in record.messages where message.role == .assistant {
            var named = Set<String>()
            for attachment in message.attachments {
                named.insert(attachment.filename)
                if let page = attachment.page { named.insert(page) }
                let kind: Kind = attachment.page != nil ? .page : attachment.kind == .image ? .picture : .document
                items.append(MadeItem(id: "\(record.id)/\(attachment.id)", kind: kind, name: attachment.filename,
                                      attachment: attachment, path: attachment.page, conversationID: record.id,
                                      chat: record.title, agent: agent, at: message.createdAt))
            }
            // What it handed over (`MEDIA:`, `::preview`, a document's path), as the chat shows
            // them as files.
            for file in ServeMedia.candidates(in: message.text) where !file.isPicture && !named.contains(file.path) && !named.contains(file.filename) {
                named.insert(file.path)
                items.append(MadeItem(id: "\(record.id)/\(message.id)/\(file.path)", kind: file.isPage ? .page : .serverFile,
                                      name: file.filename, path: file.path, conversationID: record.id,
                                      chat: record.title, agent: agent, at: message.createdAt))
            }
        }
        return items.reversed()
    }
}

/// The chat list's Made tab: everything the agents made, from the replies kept on this device,
/// newest first (asked 2026-10-28, after OpenDuet's Make tab). Read again each time it opens.
@MainActor
@Observable
final class MadeIndex {
    static let shared = MadeIndex()

    private(set) var items: [MadeItem] = []
    private(set) var looking = false
    /// How many conversations are read, newest first: enough for months, quick to go through.
    static let conversations = 400

    func refresh(store: ConversationStore = .shared) async {
        guard !looking else { return }
        looking = true
        defer { looking = false }
        var found: [MadeItem] = []
        for summary in store.sorted.prefix(Self.conversations) {
            guard let record = await store.loadRecord(id: summary.id) else { continue }
            found += MadeItem.found(in: record, agent: summary.bot?.name)
        }
        items = found.sorted { $0.at > $1.at }
    }
}

struct MadeView: View {
    var topRow: AnyView?
    /// Opens the chat a thing was made in.
    let openChat: (UUID) -> Void

    @State private var index = MadeIndex.shared
    @State private var kind: MadeItem.Kind?
    @State private var previewing: Attachment?

    private var shown: [MadeItem] { index.items.filter { kind == nil || $0.kind == kind } }

    var body: some View {
        List {
            if let topRow { topRow }
            Section {
                Picker("Show", selection: $kind) {
                    Text("All").tag(MadeItem.Kind?.none)
                    ForEach(MadeItem.Kind.allCases, id: \.self) { Text(Self.title($0)).tag(MadeItem.Kind?.some($0)) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if shown.isEmpty {
                if index.looking {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView("Nothing made yet", systemImage: "square.stack",
                                           description: Text("Pages, pictures and files your agents put in their replies show here."))
                }
            }
            ForEach(DateGroup.group(shown, by: { $0.at }), id: \.title) { day in
                Section(day.title) {
                    ForEach(day.items) { item in
                        Button { open(item) } label: { row(item) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open Chat", systemImage: "bubble.left") { openChat(item.conversationID) }
                                if let attachment = item.attachment, item.kind != .page {
                                    Button("Look", systemImage: "eye") { previewing = attachment }
                                }
                            }
                    }
                }
            }
        }
        .refreshable { await index.refresh() }
        .task { await index.refresh() }
        .sheet(item: $previewing) { DocumentPreview(attachment: $0).ignoresSafeArea() }
    }

    static func title(_ kind: MadeItem.Kind) -> String {
        switch kind {
        case .page: String(localized: "Pages", comment: "Made tab: pages the agent wrote for the chat")
        case .picture: String(localized: "Pictures", comment: "Made tab: pictures the agent made or sent")
        case .document: String(localized: "Files", comment: "Made tab: documents the agent sent")
        case .serverFile: String(localized: "On Server", comment: "Made tab: files the agent named on the server")
        }
    }

    private static func symbol(_ kind: MadeItem.Kind) -> String {
        switch kind {
        case .page: "globe"
        case .picture: "photo"
        case .document: "doc.text"
        case .serverFile: "externaldrive"
        }
    }

    private func row(_ item: MadeItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(item.kind))
                .chatFont(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).chatFont(.body).lineLimit(1).truncationMode(.middle)
                Text([item.agent, item.chat, item.at.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                    .chatFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(item.attachment != nil && item.kind != .page ? Text("Shows it") : Text("Opens the chat it was made in"))
    }

    /// A picture or a document is looked at here; a page lives in its reply, and a file on the
    /// server is fetched there: both open the chat.
    private func open(_ item: MadeItem) {
        if let attachment = item.attachment, item.kind == .picture || item.kind == .document {
            previewing = attachment
        } else {
            openChat(item.conversationID)
        }
    }
}

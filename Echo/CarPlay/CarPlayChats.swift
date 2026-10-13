import Foundation

/// One row of the car screen's Chats tab: a conversation that can be carried on by voice.
nonisolated struct CarPlayChat: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// A session on the Hermes server (either Hermes connection).
        case session(HermesSessionsAPI.SessionSummary)
        /// A conversation saved on this phone (the OpenAI-compatible connection).
        case local(UUID)
    }

    var title: String
    /// When it was last used, or that it is the one open now.
    var detail: String
    var isCurrent: Bool
    var source: Source
}

/// The conversations behind CarPlay's Chats tab: the phone's own list, in its order, cut to
/// what a car screen shows. A row is a name and a time. Nothing a reply said goes on the car's
/// screen, so a session nobody named gets a plain label and never the preview of its last message.
enum CarPlayChats {
    static let untitled = "Untitled chat"
    static let currentDetail = "The chat you are in"

    /// Server sessions as rows: pinned first, then the most recently used, like the phone's list.
    static func rows(sessions: [HermesSessionsAPI.SessionSummary], currentSessionID: String?, limit: Int,
                     now: Date = .now) -> [CarPlayChat] {
        let ordered = sessions.sorted { a, b in
            if (a.pinned ?? false) != (b.pinned ?? false) { return a.pinned ?? false }
            return (a.lastActiveDate ?? .distantPast) > (b.lastActiveDate ?? .distantPast)
        }
        return ordered.prefix(limit).map { session in
            let isCurrent = session.id == currentSessionID
            let when = session.lastActiveDate.map { DateGroup.rowTime($0, now: now) }
            let detail = isCurrent ? currentDetail : [session.pinned == true ? "Pinned" : nil, when].compactMap { $0 }.joined(separator: " · ")
            return CarPlayChat(title: session.title?.nilIfEmpty ?? untitled, detail: detail, isCurrent: isCurrent, source: .session(session))
        }
    }

    /// Conversations saved on the phone as rows, newest first as the store keeps them.
    static func rows(records: [ConversationSummary], currentID: UUID, limit: Int, now: Date = .now) -> [CarPlayChat] {
        records.prefix(limit).map { record in
            let isCurrent = record.id == currentID
            return CarPlayChat(title: record.title.nilIfEmpty ?? untitled,
                               detail: isCurrent ? currentDetail : DateGroup.rowTime(record.updatedAt, now: now),
                               isCurrent: isCurrent, source: .local(record.id))
        }
    }

    /// The list to show now. A Hermes connection asks the server, as the phone's list does; the
    /// OpenAI-compatible connection's conversations live on the phone.
    static func load(for conversation: Conversation, settings: Settings = .shared, store: ConversationStore = .shared,
                     limit: Int) async throws -> [CarPlayChat] {
        guard settings.transport.hasLedger else {
            return rows(records: store.sorted, currentID: conversation.id, limit: limit)
        }
        guard let backend = SessionBackend.current(conversation, settings: settings) else {
            throw TransportError.malformed(SessionBackend.notConfiguredMessage)
        }
        let sessions = try await backend.listSessions()
        conversation.noteServerTitles(sessions)
        return rows(sessions: sessions, currentSessionID: conversation.serverSessionID, limit: limit)
    }

    /// Makes `chat` the conversation the phone has open, transcript and all, so the next thing
    /// said carries it on. The one already open is left as it is.
    static func open(_ chat: CarPlayChat, in conversation: Conversation, settings: Settings = .shared,
                     store: ConversationStore = .shared) async throws {
        guard !chat.isCurrent else { return }
        switch chat.source {
        case .session(let session):
            if settings.transport == .hermesServe {
                try await conversation.loadServeSession(session)
            } else {
                try await conversation.loadLedgerSession(session)
            }
        case .local(let id):
            guard let record = await store.loadRecord(id: id) else {
                throw TransportError.malformed("That conversation is no longer on this phone.")
            }
            conversation.load(record)
        }
    }
}

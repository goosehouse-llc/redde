import Foundation
import Observation
import os

/// One saved conversation. Stored locally only; nothing here leaves the phone except as prompt
/// history to your own servers.
nonisolated struct ConversationRecord: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var transport: Transport
    /// Hermes ledger session id, when this conversation lives on the gateway.
    var serverSessionID: String?
    var messages: [Message]
    /// Messages not yet sent (queued or waiting for a connection). Absent in older files.
    var outbox: [OutboxItem]? = nil
    /// The Hermes server this conversation belongs to. Absent for OpenAI-compatible chats and in
    /// files from before multi-server (which belong to the first server).
    var serverID: UUID? = nil

    var turnCount: Int { messages.filter { $0.role == .user && !$0.isSteer }.count }
}

/// What the list shows: a record without its messages.
nonisolated struct ConversationSummary: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var transport: Transport
    var serverSessionID: String?
    var turnCount: Int
    var serverID: UUID?

    init(_ record: ConversationRecord) {
        serverID = record.serverID
        id = record.id
        title = record.title
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        transport = record.transport
        serverSessionID = record.serverSessionID
        turnCount = record.turnCount
    }
}

/// One JSON file per conversation under Application Support/conversations, plus a small index
/// with what the list needs. Launch reads the index only; a transcript is decoded when it is
/// opened and written only when it changes, so a long history costs nothing at startup.
@Observable
final class ConversationStore {
    static let shared = ConversationStore()

    private(set) var summaries: [ConversationSummary] = []
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "store")
    private let directory: URL
    /// Records read or written this session.
    private var cache: [UUID: ConversationRecord] = [:]
    /// Records changed since the last write.
    private var pending: [UUID: ConversationRecord] = [:]
    private var saveTask: Task<Void, Never>?

    init(directory: URL? = nil) {
        let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        self.directory = directory ?? (support ?? URL.temporaryDirectory).appending(path: "conversations")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        load()
    }

    /// Newest first. `summaries` is kept in this order by `upsert`, so this is free.
    var sorted: [ConversationSummary] { summaries }

    /// The full record, read from disk the first time it is asked for. Synchronous: decodes on
    /// the caller's (main) thread; prefer `loadRecord(id:)` wherever an await is possible.
    func record(id: UUID) -> ConversationRecord? {
        if let cached = cache[id] { return cached }
        let record = Self.read(id, in: directory)
        cache[id] = record
        return record
    }

    /// The record if it has already been read or written this session; never touches disk.
    func cachedRecord(id: UUID) -> ConversationRecord? { cache[id] }

    /// The full record, decoded off the main actor. A long transcript is hundreds of KB of JSON
    /// with a date parse per message; the launch path must not block the first frame on it.
    func loadRecord(id: UUID) async -> ConversationRecord? {
        if let cached = cache[id] { return cached }
        let directory = directory
        let record = await Task.detached(priority: .userInitiated) { Self.read(id, in: directory) }.value
        // A write may have landed while decoding; the in-memory copy is the newer one.
        if let cached = cache[id] { return cached }
        if let record { cache[id] = record }
        return record
    }

    func upsert(_ record: ConversationRecord) {
        cache[record.id] = record
        pending[record.id] = record
        let summary = ConversationSummary(record)
        summaries.removeAll { $0.id == record.id }
        // Keep newest first, by stamp rather than blindly at the front: demo and test records
        // can carry old dates.
        summaries.insert(summary, at: summaries.firstIndex { $0.updatedAt < summary.updatedAt } ?? summaries.endIndex)
        scheduleSave()
        if self === Self.shared { SiriHooks.conversationChanged(record.id) }
    }

    func delete(id: UUID) {
        let record = record(id: id)
        if let record {
            for message in record.messages { for att in message.attachments { AttachmentFiles.delete(id: att.id) } }
        }
        if self === Self.shared { SiriHooks.conversationDeleted(id, messageIDs: record?.messages.map(\.id) ?? []) }
        cache[id] = nil
        pending[id] = nil
        summaries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.recordURL(id, in: directory))
        scheduleSave()
    }

    /// Removes every conversation and its attachments.
    func deleteAll() {
        // The whole attachments folder goes, orphans included; no need to decode a transcript
        // to learn which files it had.
        AttachmentFiles.deleteAll()
        saveTask?.cancel(); saveTask = nil
        summaries = []; cache = [:]; pending = [:]
        if self === Self.shared { SiriHooks.allConversationsDeleted() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Waits for a pending debounced save to finish writing. Tests use it instead of sleeping.
    func flush() async { await saveTask?.value }

    /// Writes everything outstanding now. Called as the app goes to the background, where a
    /// debounced write might never get its 250 ms.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let records = Array(pending.values)
        pending = [:]
        Self.write(records: records, index: summaries, in: directory)
    }

    // MARK: - Disk

    private func load() {
        if let data = try? Data(contentsOf: Self.indexURL(in: directory)) {
            do {
                // Older indexes were written unordered; sort once here, upsert keeps it so.
                summaries = try Self.decoder().decode([ConversationSummary].self, from: data)
                    .sorted { $0.updatedAt > $1.updatedAt }
            } catch {
                log.error("could not read the conversation index: \(error.localizedDescription)")
            }
            return
        }
        migrateLegacyArchive()
    }

    /// Before per-record files, everything lived in one conversations.json beside the folder.
    private func migrateLegacyArchive() {
        let legacy = directory.deletingLastPathComponent().appending(path: "conversations.json")
        guard let data = try? Data(contentsOf: legacy) else { return }
        do {
            let records = try Self.decoder().decode([ConversationRecord].self, from: data)
            summaries = records.map(ConversationSummary.init).sorted { $0.updatedAt > $1.updatedAt }
            Self.write(records: records, index: summaries, in: directory)
            try FileManager.default.removeItem(at: legacy)
            log.info("migrated \(records.count) conversations to per-record files")
        } catch {
            log.error("could not migrate conversations: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let records = Array(pending.values)
        let index = summaries
        let directory = directory
        saveTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            Self.write(records: records, index: index, in: directory)
            await self?.didWrite(records)
        }
    }

    /// Drops written records from the pending set unless they changed again meanwhile.
    private func didWrite(_ records: [ConversationRecord]) {
        for record in records where pending[record.id] == record { pending[record.id] = nil }
    }

    nonisolated private static func indexURL(in directory: URL) -> URL { directory.appending(path: "index.json") }
    nonisolated private static func recordURL(_ id: UUID, in directory: URL) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    nonisolated private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    nonisolated private static func read(_ id: UUID, in directory: URL) -> ConversationRecord? {
        guard let data = try? Data(contentsOf: recordURL(id, in: directory)) else { return nil }
        do {
            return try decoder().decode(ConversationRecord.self, from: data)
        } catch {
            Logger(subsystem: "com.goosehouse.echo", category: "store")
                .error("could not read conversation \(id.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    /// Not `.completeFileProtection`: the debounced save at the end of a background turn can
    /// fire after the phone has locked, and class-A files can't be created then, which would
    /// drop the turn. Until-first-unlock still keeps the transcript encrypted at rest.
    nonisolated private static let protection: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    nonisolated private static func write(records: [ConversationRecord], index: [ConversationSummary], in directory: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            // `delete`/`deleteAll` cancel the save task; a write already past its sleep must
            // stop between files, or it recreates what was just erased.
            for record in records {
                guard !Task.isCancelled else { return }
                // Attachment bytes go to the store explicitly (encode is metadata-only and pure).
                for message in record.messages {
                    for attachment in message.attachments { attachment.persistToStore() }
                }
                try encoder.encode(record).write(to: recordURL(record.id, in: directory), options: protection)
            }
            guard !Task.isCancelled else { return }
            try encoder.encode(index).write(to: indexURL(in: directory), options: protection)
        } catch {
            Logger(subsystem: "com.goosehouse.echo", category: "store")
                .error("could not save conversations: \(error.localizedDescription)")
        }
    }
}

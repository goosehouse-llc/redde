import Foundation
import Testing
@testable import Echo

struct ConversationStoreTests {
    private func tempDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "echo-test-\(UUID().uuidString)").appending(path: "conversations")
    }

    private func sample() -> ConversationRecord {
        ConversationRecord(
            id: UUID(), title: "What's the weather", createdAt: .now, updatedAt: .now,
            transport: .chatCompletions, serverSessionID: nil,
            messages: [Message(role: .user, text: "What's the weather"), Message(role: .assistant, text: "Sunny.")])
    }

    @Test func roundTripsRecords() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = ConversationStore(directory: dir)
        var record = sample()
        store.upsert(record)
        record.messages.append(Message(role: .user, text: "And tomorrow?"))
        record.updatedAt = .now
        store.upsert(record)
        await store.flush()
        let reloaded = ConversationStore(directory: dir)
        #expect(reloaded.summaries.count == 1)
        #expect(reloaded.summaries.first?.turnCount == 2)
        #expect(reloaded.record(id: record.id)?.messages.count == 3)
        reloaded.delete(id: record.id)
        #expect(reloaded.summaries.isEmpty)
        #expect(reloaded.record(id: record.id) == nil)
    }

    @Test func deleteAllLeavesAnEmptyStore() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = ConversationStore(directory: dir)
        store.upsert(sample()); store.upsert(sample())
        store.saveNow()
        store.deleteAll()
        #expect(store.summaries.isEmpty)
        #expect(ConversationStore(directory: dir).summaries.isEmpty)
    }

    @Test func saveNowWritesWithoutWaitingForTheDebounce() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = ConversationStore(directory: dir)
        let record = sample()
        store.upsert(record)
        store.saveNow()
        #expect(ConversationStore(directory: dir).record(id: record.id)?.messages.count == 2)
    }

    @Test func migratesTheSingleFileArchive() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let legacy = dir.deletingLastPathComponent().appending(path: "conversations.json")
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = sample()
        try encoder.encode([record]).write(to: legacy)

        let store = ConversationStore(directory: dir)
        #expect(store.summaries.map(\.id) == [record.id])
        #expect(store.record(id: record.id)?.messages.count == 2)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(ConversationStore(directory: dir).summaries.count == 1, "the index was written during migration")
    }
}

struct SessionUsageTests {
    @Test func formatsUsageLine() throws {
        let json = #"{"id":"s","input_tokens":8234,"output_tokens":1120,"estimated_cost_usd":0.0123}"#
        let s = try JSONDecoder().decode(HermesSessionsAPI.SessionSummary.self, from: Data(json.utf8))
        #expect(s.usageLine == "▲ 8.2k ▼ 1.1k · $0.012")
        #expect(s.totalTokens == 9354)
        let local = try JSONDecoder().decode(HermesSessionsAPI.SessionSummary.self, from: Data(#"{"id":"l","input_tokens":500,"output_tokens":20,"estimated_cost_usd":0}"#.utf8))
        #expect(local.usageLine == "▲ 500 ▼ 20")
        #expect(try JSONDecoder().decode(HermesSessionsAPI.SessionSummary.self, from: Data(#"{"id":"e"}"#.utf8)).usageLine == nil)
    }
}


struct BaseURLTests {
    @Test func normalizesDocumentedProviderBases() {
        #expect(Settings.normalizedBase("https://openrouter.ai/api/v1")?.absoluteString == "https://openrouter.ai/api")
        #expect(Settings.normalizedBase("https://api.groq.com/openai/v1/")?.absoluteString == "https://api.groq.com/openai")
        #expect(Settings.normalizedBase("http://host:11500")?.absoluteString == "http://host:11500")
        #expect(Settings.normalizedBase("http://host:11500/")?.absoluteString == "http://host:11500")
        #expect(Settings.normalizedBase("  ") == nil)
    }
}

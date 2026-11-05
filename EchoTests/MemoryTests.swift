import Compression
import Foundation
import Testing
@testable import Echo

/// "Memory you can see" (2.4): Hermes's memory files read and written entry by entry, a reply's
/// memory call named under it, and memory imported from a ChatGPT or Claude export.
struct MemoryTests {
    // MARK: The files

    @Test func entriesSplitAndJoinAsHermesDoes() {
        let raw = "Vegetarian.\n§\nLives in Lisbon.\n§\n\n§\nVegetarian.\n§\nUses § in a note"
        let entries = AgentMemory.entries(raw)
        #expect(entries == ["Vegetarian.", "Lives in Lisbon.", "Uses § in a note"], "empty and repeated entries dropped, a bare § kept")
        #expect(AgentMemory.joined(entries) == "Vegetarian.\n§\nLives in Lisbon.\n§\nUses § in a note")
        #expect(AgentMemory.entries(AgentMemory.joined(entries)) == entries)
        #expect(AgentMemory.entries("") == [])
    }

    @Test func sizeIsCountedInCodePointsWithTheDelimiter() {
        #expect(AgentMemory.size(["abc", "de"]) == 3 + 3 + 2)
        #expect(AgentMemory.size(["👨‍👩‍👧"]) == 5, "Python's len counts code points, not what Swift counts as one character")
    }

    @Test func aSaveKeepsWhatTheAgentAddedMeanwhile() {
        let changes: [AgentMemory.Change] = [.replace("Lives in Porto.", with: "Lives in Lisbon."), .remove("Has a cat."), .add("Allergic to cats.")]
        let (merged, conflicts) = AgentMemory.apply(changes, to: ["Lives in Porto.", "Has a cat.", "Prefers metric."])
        #expect(merged == ["Lives in Lisbon.", "Prefers metric.", "Allergic to cats."])
        #expect(conflicts.isEmpty)
    }

    @Test func anEntryTheAgentChangedMeanwhileIsAConflict() {
        let (merged, conflicts) = AgentMemory.apply([.replace("Lives in Porto.", with: "Lives in Lisbon.")], to: ["Lives in Porto, Portugal."])
        #expect(conflicts == ["Lives in Porto."])
        #expect(merged == ["Lives in Porto, Portugal."], "the agent's version stays")
        // Removing one that's already gone is what was wanted; adding one twice adds it once.
        #expect(AgentMemory.apply([.remove("gone"), .add("x"), .add("x")], to: ["a"]).entries == ["a", "x"])
        #expect(AgentMemory.apply([.replace("a", with: "b")], to: ["a", "b"]).entries == ["b"], "an edit into an entry already there merges")
    }

    @Test func theLimitIsKeptButNeverMadeWorse() {
        #expect(AgentMemory.fits(["12345"], limit: 5, before: []))
        #expect(!AgentMemory.fits(["123456"], limit: 5, before: []))
        #expect(AgentMemory.fits(["1234567"], limit: 5, before: ["12345678"]), "already over, and this makes it smaller")
    }

    @Test func thePageTurnsItsRowsIntoChanges() {
        typealias Row = AgentMemoryModel.Row
        var edited = Row(original: "a", text: "a2")
        var removed = Row(original: "b", text: "b")
        removed.deleted = true
        let added = Row(original: nil, text: "  c  ")
        var addedThenDeleted = Row(original: nil, text: "d")
        addedThenDeleted.deleted = true
        edited.text = "a2"
        let blanked = Row(original: "e", text: " ")
        #expect(AgentMemoryModel.changes([edited, removed, added, addedThenDeleted, Row(original: "f", text: "f"), blanked])
                == [.replace("a", with: "a2"), .remove("b"), .add("c"), .remove("e")])
    }

    // MARK: Under a reply

    @Test func aReplysMemoryCallIsNamed() {
        func tool(_ args: String, _ status: ToolActivity.Status = .completed) -> ToolActivity {
            ToolActivity(name: "memory", preview: nil, status: status, args: args)
        }
        let kept = AgentMemory.change(in: [tool("action: add\ncontent: Allergic to cats.\ntarget: user")])
        #expect(kept == .init(kind: .remembered, target: .user, text: "Allergic to cats."))
        let forgot = AgentMemory.change(in: [tool("action: remove\nold_text: Lives in Porto\ntarget: user")])
        #expect(forgot == .init(kind: .forgot, target: .user, text: "Lives in Porto"))
        let long = AgentMemory.change(in: [tool("action: add\ncontent:\nLine one\nLine two\ntarget: memory")])
        #expect(long?.text == "Line one\nLine two")
        #expect(AgentMemory.change(in: [tool("action: add\ncontent: x\ntarget: user", .failed)]) == nil)
        #expect(AgentMemory.change(in: [ToolActivity(name: "web_search", preview: nil, status: .completed)]) == nil)
        #expect(AgentMemory.change(in: [tool("action: batch\ntarget: memory")])?.kind == .changed)
    }

    @Test func rememberThisIsOneMessageTheNoteKnows() {
        #expect(AgentMemory.rememberMessage("  I'm vegetarian ") == "Remember that: I'm vegetarian")
        #expect(AgentMemory.rememberMessage(String(repeating: "a", count: 700)).count == "Remember that: ".count + 601)
    }

    // MARK: Import

    @Test func chatGPTsExportGivesWhatThePersonSaidAboutThemselves() throws {
        let export: [[String: Any]] = [[
            "title": "Dinner", "mapping": [
                "a": ["message": ["author": ["role": "user"], "create_time": 1.0, "content": ["content_type": "text", "parts": ["I'm vegetarian. What should I cook tonight?"]]]],
                "b": ["message": ["author": ["role": "assistant"], "content": ["parts": ["I'm an assistant who loves soup."]]]],
                "c": ["message": ["author": ["role": "user"], "create_time": 2.0, "content": ["parts": ["My daughter is Mia and she's 7. I'm vegetarian."]]]],
                "d": ["message": NSNull()],
            ]]]
        let url = try write(JSONSerialization.data(withJSONObject: export), name: "conversations.json")
        let (source, said) = MemoryImport.userMessages(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        #expect(source == .chatGPT)
        #expect(said.count == 2, "only the person's own messages")
        let picked = MemoryImport.candidates(saved: [], said: said)
        #expect(picked.first?.text == "I'm vegetarian", "said twice, so first")
        #expect(picked.first?.count == 2)
        #expect(picked.map(\.text).contains("My daughter is Mia and she's 7"))
        #expect(!picked.map(\.text).contains { $0.contains("cook") }, "a question isn't a fact")
    }

    @Test func claudesExportAndSavedMemoriesInAZip() async throws {
        let conversations: [[String: Any]] = [[
            "uuid": "1", "name": "Trip", "chat_messages": [
                ["sender": "human", "text": "", "content": [["type": "text", "text": "I live in Lisbon and work from home on Fridays."]]],
                ["sender": "assistant", "text": "I live in the cloud."],
            ]]]
        let memories: [String: Any] = ["memories": [["content": "Prefers short answers"], ["content": "Uses metric units"]]]
        let zip = try zipFile([("export/conversations.json", JSONSerialization.data(withJSONObject: conversations), true),
                               ("export/memories.json", JSONSerialization.data(withJSONObject: memories), false),
                               ("export/users.json", Data("[]".utf8), false)])
        let url = try write(zip, name: "claude-export.zip")
        let result = try await read([url])
        #expect(result.source == .claude)
        #expect(result.candidates.prefix(2).map(\.text) == ["Prefers short answers", "Uses metric units"], "saved memories first")
        #expect(result.candidates.prefix(2).allSatisfy { $0.saved })
        #expect(result.candidates.map(\.text).contains("I live in Lisbon and work from home on Fridays"))
        #expect(!result.candidates.map(\.text).contains { $0.contains("cloud") })
    }

    // MARK: Claude's export from Nov 2026

    @Test func claudesEmailFileListsTheDownloadsOnly() async throws {
        let manifest: [String: Any] = [
            "instructions": "Download each file.", "created_at": "2026-11-03T09:00:00.123Z", "total_files": 4, "version": "1.0",
            "data_files": [
                ["batch_index": 0, "export_url": "https://claude.ai/export/abc/download/01ff", "category": "memories", "part": 0, "filename": "memories-000.zip"],
                ["batch_index": 0, "export_url": "https://claude.ai/export/abc/download/02ff", "category": "conversations", "part": 0, "filename": "conversations-000.zip"],
                ["batch_index": 0, "export_url": "https://evil.example.com/export/x", "category": "projects", "part": 0, "filename": "projects-000.zip"],
                ["batch_index": 0, "export_url": "http://claude.ai/export/abc/download/03", "category": "frames", "part": 0, "filename": "frames-000.zip"],
            ]]
        let url = try write(JSONSerialization.data(withJSONObject: manifest), name: "claude-export.json")
        guard case let .manifest(found) = try await MemoryImport.read([url]) else { Issue.record("not read as a manifest"); return }
        #expect(found.parts.map(\.category) == ["memories", "conversations"], "only https://claude.ai/export/ links")
        #expect(found.part("memories")?.url.absoluteString == "https://claude.ai/export/abc/download/01ff")
        #expect(found.expiresAt == MemoryImport.isoDate("2026-11-04T09:00:00.123Z"))
    }

    @Test func claudesMemoriesGiveFactsProjectLinesAndNotes() async throws {
        let memories: [String: Any] = [
            "account_uuid": "u1",
            "conversations_memory": "**Work context**\nAlex is a nurse who works night shifts. They live in Porto with a partner.\n\n**Preferences**\n- Prefers metric units\n- Likes short answers\n# Heading",
            "project_memories": ["p1": "- The garden plan uses raised beds\n- Seeds ordered in March"],
            "memory_files": [
                ["path": "/people/dana-ruiz.md", "content": "Dana waters the plants.\n\n- Allergic to bees", "updated_at": "2026-10-01T00:00:00Z"],
                ["path": "/areas/health.md", "content": "Runs on Tuesdays.", "updated_at": "2026-10-01T00:00:00Z"],
                ["path": "/topics/home-network.md", "content": "Mesh in three rooms.", "updated_at": "2026-10-01T00:00:00Z"],
                ["path": "/projects/0c1d/plan.md", "content": "Phase one.", "updated_at": "2026-10-01T00:00:00Z"],
                ["path": "/reading.md", "content": String(repeating: "word ", count: 5_000), "updated_at": "2026-10-01T00:00:00Z"],
                ["path": "/empty.md", "content": "  ", "updated_at": "2026-10-01T00:00:00Z"],
            ]]
        // As Safari leaves it: a memories folder holding one <uuid>.json.
        let folder = FileManager.default.temporaryDirectory.appending(path: "memory-tests-\(UUID().uuidString)/memories")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: memories).write(to: folder.appending(path: "3f2a9c1e-0000-4000-8000-000000000000.json"))
        let result = try await read([folder])
        #expect(result.source == .claude)
        let facts = result.candidates.filter(\.saved).map(\.text)
        #expect(facts == ["Alex is a nurse who works night shifts", "They live in Porto with a partner", "Prefers metric units", "Likes short answers"])
        #expect(result.candidates.filter { $0.kind == .projectMemory }.map(\.text) == ["The garden plan uses raised beds", "Seeds ordered in March"])
        let notes = result.candidates.filter { $0.kind == .note }
        #expect(notes.map(\.text) == ["Person: Dana Ruiz", "Area: Health", "Topic: Home network", "Project: Plan", "Reading"])
        #expect(notes.map { $0.folder ?? "" } == ["people", "areas", "topics", "projects", ""])
        #expect(notes.first?.body == "Dana waters the plants.\n\n- Allergic to bees")
        #expect((notes.last?.body?.count ?? 0) == MemoryImport.longestNote)
        #expect(notes.allSatisfy(\.isNote) && !result.candidates.filter(\.saved).contains(where: \.isNote))
    }

    @Test func claudesNewConversationsReadOnlyThePersonsTextParts() async throws {
        let conversations: [[String: Any]] = [[
            "uuid": "c1", "name": "Plans", "summary": "Talked about plans.", "created_at": "2026-10-01T10:00:00.000000Z",
            "updated_at": "2026-10-01T11:00:00.000000Z", "account": ["uuid": "u1"],
            "chat_messages": [
                ["uuid": "m1", "sender": "human", "created_at": "2026-10-01T10:00:00.000000Z", "text": "I work nights at the hospital. Thinking: my name is Fake.",
                 "content": [["type": "text", "text": "I work nights at the hospital."],
                             ["type": "thinking", "thinking": "x", "text": "My name is Fake."],
                             ["type": "injected_prompt_block", "text": "I am a system prompt."],
                             ["type": "tool_result", "text": "I have root access."]]],
                ["uuid": "m2", "sender": "assistant", "content": [["type": "text", "text": "I'm Claude."]]],
                ["uuid": "m3", "sender": "human", "created_at": "2026-10-02T10:00:00Z", "text": "My dog is called Pip.", "content": []],
            ]]]
        let zip = try zipFile([("conversations.json", JSONSerialization.data(withJSONObject: conversations), true)])
        let memories: [String: Any] = ["conversations_memory": "- Has a dog called Pip", "project_memories": [:], "memory_files": []]
        let result = try await read([try write(zip, name: "conversations-000.zip"),
                                     try write(try zipFile([("x.json", JSONSerialization.data(withJSONObject: memories), false)]), name: "memories-000.zip")])
        let texts = result.candidates.map(\.text)
        #expect(texts.contains("I work nights at the hospital"))
        #expect(texts.contains("My dog is called Pip"), "a message without content parts reads its text")
        #expect(texts.contains("Has a dog called Pip"), "merged with the memories file")
        #expect(!texts.contains { $0.contains("Fake") || $0.contains("system prompt") || $0.contains("root") || $0.contains("Claude") })
        #expect(result.messagesRead == 2)
    }

    @Test func notAnExportSaysSo() async throws {
        let url = try write(Data("{\"hello\": 1}".utf8), name: "conversations.json")
        await #expect(throws: MemoryImport.Failure.self) { try await MemoryImport.read(url) }
        let junk = try write(Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3]), name: "broken.zip")
        await #expect(throws: MemoryImport.Failure.self) { try await MemoryImport.read(junk) }
    }

    @Test func theSelfStatementPatternLeavesOutCodeLinksAndPages() {
        #expect(MemoryImport.facts(in: "I use vim. My setup is a Mac mini.") == ["I use vim", "My setup is a Mac mini"])
        #expect(MemoryImport.facts(in: "I use https://example.com daily.").isEmpty)
        #expect(MemoryImport.facts(in: "I have a = b; in my code.").isEmpty)
        #expect(MemoryImport.facts(in: "The weather is nice. We went out.").isEmpty)
    }

    @Test func theAgentGetsACappedList() {
        let message = MemoryImport.agentMessage(Array(repeating: String(repeating: "x", count: 100), count: 100), from: .chatGPT)
        #expect(message.hasPrefix("Remember that: these are things I told ChatGPT."))
        #expect(message.count < 4_400)
    }

    // MARK: Long-term memory

    @Test func theStoreIsTheProviderThenAServerThenANotesFile() {
        #expect(LongTermMemory.pick(provider: "honcho", pluginBest: nil, mcpServers: ["basic-memory"]) == .provider(id: "honcho", name: "Honcho"))
        #expect(LongTermMemory.pick(provider: "mem0", pluginBest: nil, mcpServers: []).buttonTitle == "Save to Mem0")
        let best: JSONValue = .object(["kind": .string("basic-memory"), "name": .string("Basic Memory"), "server": .string("basic_memory")])
        #expect(LongTermMemory.pick(provider: "", pluginBest: best, mcpServers: []) == .server(kind: "basic-memory", name: "Basic Memory", server: "basic_memory"))
        #expect(LongTermMemory.pick(provider: nil, pluginBest: nil, mcpServers: ["github", "Basic Memory"]).buttonTitle == "Save to Basic Memory")
        #expect(LongTermMemory.pick(provider: nil, pluginBest: nil, mcpServers: ["memory"]).name == "Memory Graph")
        let none = LongTermMemory.pick(provider: nil, pluginBest: nil, mcpServers: ["github", "home-assistant"])
        #expect(none == .notesFile)
        #expect(none.buttonTitle == "Save as a Notes File")
        #expect(LongTermMemory.providerName("qdrant-memory") == "Qdrant Memory")
        #expect(LongTermMemory.providerName("brand_new-thing") == "Brand New Thing")
    }

    @Test func aProvidersFactsGoInOneMessageThePluginKnows() {
        let message = LongTermMemory.agentMessage(["Vegetarian", "Line\nbreak"], store: .provider(id: "honcho", name: "Honcho"), from: .claude)
        #expect(message.hasPrefix("Save to long-term memory (Honcho): what I told Claude.\n"))
        #expect(message.hasSuffix("- Vegetarian\n- Line break\n"))
        #expect(!message.hasPrefix("Remember"), "not the USER.md note")
        let many = LongTermMemory.agentMessage(Array(repeating: String(repeating: "x", count: 200), count: 100), store: .notesFile, from: .chatGPT)
        #expect(many.count < 4_200)
    }

    @Test func whatTheSaveCommandSaid() {
        #expect(LongTermMemory.readSave(.object(["stored": .number(3)])) == .stored(3))
        #expect(LongTermMemory.readSave(.object(["error": .string("not_loaded")])) == .useAgent)
        #expect(LongTermMemory.readSave(.object(["error": .string("failed"), "message": .string("disk full")])) == .failed("disk full"))
        #expect(LongTermMemoryModel.parse("redde-push memory {\"stored\": 2}")?["stored"]?.int == 2)
        #expect(LongTermMemoryModel.parse("something else") == nil)
    }

    @Test func theNotesFileSaysItIsntLoaded() {
        let day = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let text = LongTermMemory.notesFile(["Vegetarian", "Runs on Tuesdays"], from: .chatGPT, on: day)
        #expect(text.hasPrefix("# Imported from ChatGPT\n\nSaved by Redde on 2026-11-03. Not loaded into conversations"))
        #expect(text.hasSuffix("- Vegetarian\n- Runs on Tuesdays\n"))
        #expect(LongTermMemory.fileSource(.claude) == "claude")
    }

    @Test func notesGoWholeToLongTermMemory() {
        let picked = [MemoryImport.Candidate(text: "Vegetarian", saved: true),
                      MemoryImport.Candidate(text: "Person: Dana", kind: .note, body: "Waters the plants.", folder: "people"),
                      MemoryImport.Candidate(text: "Raised beds", kind: .projectMemory)]
        let (facts, notes) = LongTermMemory.split(picked)
        #expect(facts == ["Vegetarian", "Raised beds"])
        #expect(notes == [.init(title: "Person: Dana", content: "Waters the plants.", folder: "people")])
        let big = (0..<20).map { LongTermMemory.Note(title: "N\($0)", content: String(repeating: "x", count: 3_000), folder: "") }
        let message = LongTermMemory.agentMessage(facts, notes: big, store: .provider(id: "mem0", name: "Mem0"), from: .claude)
        #expect(message.count < 9_600, "capped")
        #expect(message.contains("more notes didn't fit"))
        let file = LongTermMemory.notesFile(facts, notes: notes, from: .claude)
        #expect(file.contains("\n## Person: Dana\n\nWaters the plants.\n"))
    }

    // MARK: Helpers

    private func read(_ urls: [URL]) async throws -> MemoryImport.Result {
        guard case let .result(result) = try await MemoryImport.read(urls) else { throw MemoryImport.Failure.unreadable }
        return result
    }


    private func write(_ data: Data, name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "memory-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// A zip with each file stored or deflated (raw deflate, as zip has it).
    private func zipFile(_ files: [(name: String, data: Data, deflate: Bool)]) throws -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        for file in files {
            var packed = file.data
            if file.deflate {
                var buffer = [UInt8](repeating: 0, count: file.data.count + 1024)
                let n = file.data.withUnsafeBytes { source in
                    compression_encode_buffer(&buffer, buffer.count, source.bindMemory(to: UInt8.self).baseAddress!, file.data.count, nil, COMPRESSION_ZLIB)
                }
                packed = Data(buffer.prefix(n))
            }
            let name = Data(file.name.utf8), offset = out.count, method = file.deflate ? 8 : 0
            let local: [Data] = [le32(0x0403_4B50), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                                 le32(packed.count), le32(file.data.count), le16(name.count), le16(0), name, packed]
            local.forEach { out.append($0) }
            let header: [Data] = [le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                                  le32(packed.count), le32(file.data.count), le16(name.count), le16(0), le16(0), le16(0), le16(0),
                                  le32(0), le32(offset), name]
            header.forEach { central.append($0) }
        }
        let start = out.count
        out += central
        let end: [Data] = [le32(0x0605_4B50), le16(0), le16(0), le16(files.count), le16(files.count), le32(central.count), le32(start), le16(0)]
        end.forEach { out.append($0) }
        return out
    }
}

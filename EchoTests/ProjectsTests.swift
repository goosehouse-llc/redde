import Foundation
import Testing
@testable import Echo

/// Projects on the Dashboard: which ones the list shows, the folder a name makes, the project the
/// header names, and a new conversation that starts in a project's folder. What Hermes does with
/// them is checked against real Hermes in `HermesLabProjectsTests`.
@MainActor
struct ProjectsTests {
    private func project(_ json: String) throws -> HermesServeClient.Project {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try #require(HermesServeClient.Project(value))
    }

    @Test func theListShowsAProjectSomeoneMadeEvenBeforeItsFirstConversation() throws {
        let made = try project(#"{"id":"p_1","label":"Garden","path":"/home/u/Projects/Garden","isAuto":false,"sessionCount":0,"lastActive":0}"#)
        let found = try project(#"{"id":"/home/u/src/old","label":"old","path":"/home/u/src/old","isAuto":true,"sessionCount":0,"lastActive":0}"#)
        let busy = try project(#"{"id":"/home/u/src/app","label":"app","path":"/home/u/src/app","isAuto":true,"sessionCount":3,"lastActive":1773000000}"#)
        let none = try project(#"{"id":"__no_project__","label":"No project","isNoProject":true,"isAuto":false,"sessionCount":5,"lastActive":1772000000}"#)
        #expect(made.isOwn && !found.isOwn && !none.isOwn)
        #expect(HermesServeClient.Project.listed([made, found, busy, none]).map(\.id) == ["__no_project__", "/home/u/src/app", "p_1"],
                "conversations in no project first, then by use; a found repository without conversations stays out")
    }

    @Test func aProjectHermesDoesNotLabelCountsAsFound() throws {
        let unlabelled = try project(#"{"id":"/srv/x","label":"x","path":"/srv/x","sessionCount":0}"#)
        #expect(unlabelled.isAuto && HermesServeClient.Project.listed([unlabelled]).isEmpty)
    }

    @Test func aNameMakesAFolderName() {
        #expect(HermesServeClient.projectFolderName(for: "  Trip to Japan ") == "Trip to Japan")
        #expect(HermesServeClient.projectFolderName(for: "Taxes 2026/27") == "Taxes 2026-27")
        #expect(HermesServeClient.projectFolderName(for: "a:b") == "a-b")
        #expect(HermesServeClient.projectFolderName(for: ".hidden") == "hidden", "a leading dot would hide the folder")
        #expect(HermesServeClient.projectFolderName(for: "two\nlines") == "two lines")
        #expect(HermesServeClient.projectFolderName(for: " ... ") == nil)
        #expect(HermesServeClient.projectFolderName(for: "") == nil)
        #expect(HermesServeClient.projectFolderName(for: String(repeating: "x", count: 200))?.count == 80)
    }

    @Test func theHeaderLearnsTheProjectFromTheSessionsInfo() {
        let store = ChatControlStore()
        #expect(store.project(for: "s1") == nil, "nothing said yet")
        store.note(.object(["yolo": .bool(false), "project": .object(["id": .string("p_1"), "name": .string("Garden")])]), for: "s1")
        #expect(store.project(for: "s1")?.name == "Garden")
        store.note(.object(["fast": .bool(true)]), for: "s1")
        #expect(store.project(for: "s1")?.name == "Garden", "an info that doesn't mention the project leaves it")
        store.note(.object(["project": .null]), for: "s1")
        #expect(store.project(for: "s1") != nil && store.project(for: "s1")?.name == nil, "in no project, which is known")
        store.removeAll()
        #expect(store.project(for: "s1") == nil)
    }

    /// Keeps what it was sent; each turn gets the same session back.
    final class RecordingTransport: HermesTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [TurnRequest] = []
        var requests: [TurnRequest] { lock.withLock { kept } }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            lock.withLock { kept.append(request) }
            return AsyncThrowingStream { continuation in
                continuation.yield(.sessionID("stored-1"))
                continuation.yield(.textDelta("Done."))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    private func conversation(_ transport: RecordingTransport, on kind: Transport = .hermesServe) -> Conversation {
        let settings = Settings(defaults: UserDefaults(suiteName: "projects-\(UUID().uuidString)")!)
        settings.transport = kind
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "projects-\(UUID().uuidString)"))
        return Conversation(settings: settings, store: store, transportOverride: transport)
    }

    private func ask(_ conversation: Conversation, _ transport: RecordingTransport, _ text: String) async throws -> TurnRequest {
        let before = transport.requests.count
        _ = conversation.send(text)
        for _ in 0 ..< 200 where transport.requests.count == before || conversation.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(transport.requests.last)
    }

    @Test func aNewConversationInAProjectStartsInItsFolder() async throws {
        let transport = RecordingTransport()
        let conversation = conversation(transport)
        let garden = ProjectPlace(name: "Garden", path: "/home/u/Projects/Garden")
        conversation.startNew(in: garden)
        #expect(conversation.startsIn == garden)
        let first = try await ask(conversation, transport, "What should I plant in May?")
        #expect(first.folder == garden.path && first.sessionID == nil)
        let second = try await ask(conversation, transport, "And in June?")
        #expect(second.sessionID == "stored-1" && second.folder == nil, "the session is in the folder already")
        conversation.reset()
        #expect(conversation.startsIn == nil, "a new conversation after it starts outside any project")
        let third = try await ask(conversation, transport, "Something else.")
        #expect(third.folder == nil)
    }

    @Test func onlyTheDashboardHasFolders() async throws {
        let transport = RecordingTransport()
        let conversation = conversation(transport, on: .chatCompletions)
        conversation.startNew(in: ProjectPlace(name: "Garden", path: "/home/u/Projects/Garden"))
        let first = try await ask(conversation, transport, "Hello.")
        #expect(first.folder == nil)
    }
}

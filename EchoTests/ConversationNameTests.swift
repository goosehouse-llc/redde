import Foundation
import Testing
@testable import Echo

/// A conversation's name: what the header and the list show in place of the first question.
@MainActor
struct ConversationNameTests {
    private func makeConversation(store: ConversationStore) -> Conversation {
        let settings = Settings(defaults: UserDefaults(suiteName: "name-\(UUID().uuidString)")!)
        settings.transport = .chatCompletions
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        let transport = ConversationLifecycleTests.ScriptedTransport([.textDelta("Thursday the 24th."), .done])
        return Conversation(settings: settings, store: store, transportOverride: transport)
    }

    private func makeStore() -> ConversationStore {
        ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "name-\(UUID().uuidString)"))
    }

    private func finish(_ conversation: Conversation) async throws {
        for _ in 0 ..< 200 where conversation.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aNameReplacesTheFirstQuestionAndIsSavedWithTheConversation() async throws {
        let store = makeStore()
        let conversation = makeConversation(store: store)
        conversation.send("When can the countertop crew template?")
        try await finish(conversation)
        #expect(conversation.title == "When can the countertop crew template?")
        #expect(conversation.name == nil)

        try await conversation.rename(to: "  Countertop schedule ")
        #expect(conversation.title == "Countertop schedule")
        let saved = try #require(store.record(id: conversation.id))
        #expect(saved.name == "Countertop schedule")
        #expect(saved.title == "Countertop schedule")   // what the list shows

        // Another conversation, then back: the name comes back with it.
        conversation.reset()
        #expect(conversation.title == "New conversation")
        #expect(conversation.name == nil)
        conversation.load(saved)
        #expect(conversation.title == "Countertop schedule")
    }

    @Test func anEmptyNameGoesBackToTheFirstQuestion() async throws {
        let store = makeStore()
        let conversation = makeConversation(store: store)
        conversation.send("When can the countertop crew template?")
        try await finish(conversation)
        try await conversation.rename(to: "Countertop schedule")
        try await conversation.rename(to: "   ")
        #expect(conversation.name == nil)
        #expect(conversation.title == "When can the countertop crew template?")
        #expect(store.record(id: conversation.id)?.name == nil)
    }

    /// The title Redde gives a new gateway session is the question and a timestamp: not a name.
    @Test func theGatewaysTitleIsANameOnlyWhenSomeoneGaveIt() {
        let question = "Is the cabinet order still on track for the 20th, and what about the tile?"
        let automatic = "\(question.prefix(48)) · Oct 3, 2026 at 9:41 PM"
        #expect(Conversation.name(fromServerTitle: automatic, firstQuestion: question) == nil)
        #expect(Conversation.name(fromServerTitle: "Cabinet order", firstQuestion: question) == "Cabinet order")
        #expect(Conversation.name(fromServerTitle: " Cabinet order\n", firstQuestion: nil) == "Cabinet order")
        #expect(Conversation.name(fromServerTitle: nil, firstQuestion: question) == nil)
        #expect(Conversation.name(fromServerTitle: "  ", firstQuestion: question) == nil)
        // A short question: "hi · stamp" is automatic too.
        #expect(Conversation.name(fromServerTitle: "hi · Oct 3, 2026 at 9:41 PM", firstQuestion: "hi") == nil)
    }

    /// Records saved before names existed still load.
    @Test func olderRecordsHaveNoName() throws {
        let json = #"{"id":"6F1C8E2A-0000-4000-8000-000000000001","title":"Old","createdAt":0,"updatedAt":0,"transport":"chatCompletions","messages":[]}"#
        let record = try JSONDecoder().decode(ConversationRecord.self, from: Data(json.utf8))
        #expect(record.name == nil)
        #expect(record.title == "Old")
    }
}

import Foundation
import Testing
@testable import Echo

/// An incognito chat is kept nowhere: not saved on the phone, its session noted for deleting
/// until it is gone, and the note that tells the agent hidden from the transcript.
@MainActor
struct IncognitoTests {
    @Test func anIncognitoChatIsKeptNowhere() async throws {
        let settings = Settings(defaults: try #require(UserDefaults(suiteName: "incognito-\(UUID().uuidString)")))
        settings.transport = .hermesServe
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "incognito-\(UUID().uuidString)"))
        let session = "incog-\(UUID().uuidString.prefix(8))"
        let noServer = HermesServeClient(settings: settings, password: { nil }, tokens: HermesServeClientTests.TokenBox().store)
        defer { Incognito.setPending(Incognito.pending().filter { $0.session != session }) }
        let c = Conversation(settings: settings, store: store,
                             transportOverride: ConversationLifecycleTests.ScriptedTransport([.sessionID(session), .textDelta("Hi."), .done]),
                             dashboard: noServer)
        c.startIncognito()
        #expect(c.isIncognito)
        _ = c.send("something private")
        for _ in 0 ..< 200 where c.isStreaming || c.messages.last?.text != "Hi." { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.messages.last?.text == "Hi.")
        #expect(store.summaries.isEmpty, "not saved on the phone")
        #expect(Incognito.pending().contains { $0.session == session }, "its session noted, to be deleted however the app goes")

        c.reset()
        #expect(!c.isIncognito && c.messages.isEmpty, "left: a new conversation, not incognito")
        try await Task.sleep(for: .milliseconds(200))
        #expect(Incognito.pending().contains { $0.session == session }, "with no server to delete it from, it stays noted until there is")
    }

    @Test func theNoteToTheAgentIsHidden() {
        let said = "something private" + IncognitoNote.note
        #expect(IncognitoNote.strip(said) == "something private")
        #expect(ReplyLanguage.stripNote(said) == "something private")
        #expect(IncognitoNote.strip("plain [brackets]") == "plain [brackets]")
    }
}

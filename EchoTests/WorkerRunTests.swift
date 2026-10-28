import Foundation
import Testing
@testable import Echo

/// A Kanban worker's session (GitHub issue 37): Hermes refuses to resume it, so Redde reads its
/// transcript from the Dashboard's messages page and opens it to read only.
struct WorkerRunTests {
    typealias C = HermesServeClient

    @Test func theKanbanRefusalIsKnown() {
        #expect(C.refusesWorkerRun(C.RPCError(code: 4132, message: "Session abc is a Kanban worker transcript.")))
        #expect(C.refusesWorkerRun(C.RPCError(code: 4000, message: "Session abc is a Kanban worker transcript. Resuming it here…")))
        #expect(!C.refusesWorkerRun(C.RPCError(code: 4007, message: "session not found")))
        #expect(!C.refusesWorkerRun(URLError(.timedOut)))
    }

    @Test func theTranscriptIsReadFromTheSessionsProfile() {
        let path = "api/sessions/abc/messages?order=latest&limit=500"
        #expect(C.profilePlacement(method: "GET", path: path) == .query)
        #expect(C.scoped(method: "GET", path: path, body: nil, profile: "coder").0 == path + "&profile=coder")
        #expect(C.profilePlacement(method: "DELETE", path: "api/sessions/abc") == .none)
    }

    @Test func storedRowsBecomeATranscript() throws {
        let page = Data("""
            {"session_id": "abc", "messages": [
              {"id": 1, "role": "user", "content": "Fix the login test", "timestamp": 1700000000},
              {"id": 2, "role": "assistant", "content": "Done: the test passes.", "timestamp": 1700000060}]}
            """.utf8)
        struct Page: Decodable { var messages: [HermesSessionsAPI.StoredMessage] }
        let messages = Conversation.mapStored(try JSONDecoder().decode(Page.self, from: page).messages)
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages.last?.text == "Done: the test passes.")
    }
}

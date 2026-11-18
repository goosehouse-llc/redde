import Foundation
import Testing
@testable import Echo

/// Answers Hermes gives that the replay tests (HermesReplayTests) found the app reading wrong.
struct HermesAnswersTests {
    @Test func pinnedAndUnreadAsSQLitesNumbers() throws {
        let json = #"{"id":"s1","pinned":1,"unread":0}"#
        let row = try JSONDecoder().decode(HermesSessionsAPI.SessionSummary.self, from: Data(json.utf8))
        #expect(row.pinned == true && row.unread == false)
        let words = try JSONDecoder().decode(HermesSessionsAPI.SessionSummary.self, from: Data(#"{"id":"s2","pinned":true}"#.utf8))
        #expect(words.pinned == true && words.unread == nil)
    }

    @Test func aChatStillAtWorkIsSaidAsWhatToDo() {
        let body = #"{"error":{"code":"session_active_turn","message":"session 'x' has an active turn lease"}}"#
        #expect(ChatBusyError.isBusy(TransportError.http(status: 409, body: body)))
        #expect(!ChatBusyError.isBusy(TransportError.http(status: 409, body: #"{"error":"conflict"}"#)))
        #expect(!ChatBusyError.isBusy(TransportError.http(status: 500, body: body)))
        #expect(HermesServeClient.isBusy(.init(code: 4001, message: "session_busy")))
        #expect(!HermesServeClient.isBusy(.init(code: 4007, message: "not_found")))
        #expect(ChatBusyError().errorDescription?.contains("Stop it") == true)
    }

    @Test func aTakenTitleOnTheCanonicalOwner() {
        #expect(HermesServeClient.isTitleTaken(.init(code: -32602, message: "Title 'Sol' is already in use"), canonical: false))
        #expect(HermesServeClient.isTitleTaken(.init(code: -32603, message: "internal error"), canonical: true))
        #expect(!HermesServeClient.isTitleTaken(.init(code: -32603, message: "internal error"), canonical: false))
    }
}

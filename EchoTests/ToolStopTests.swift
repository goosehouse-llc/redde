import Foundation
import Testing
@testable import Echo

/// Why Hermes stopped a turn, under the reply (2026-11-06).
struct ToolStopTests {
    private let stopped = "I stopped retrying because I kept running redde_mail 8 times without making progress. The last result above shows what blocked it. Tell me how you'd like to proceed, or send `continue` and I'll try a different approach."

    private func reply(_ text: String, tools: [(String, String?)] = []) -> Message {
        var m = Message(role: .assistant, text: text)
        m.tools = tools.map { ToolActivity(name: $0.0, preview: nil, status: .completed, output: $0.1) }
        return m
    }

    @Test func aFailureSaysWhatTheToolSaid() {
        let before = reply("One at a time.", tools: [("redde_mail", #"{"error": "not_allowed", "message": "That sender only unsubscribes on its web page."}"#)])
        let why = ToolStop.reason(reply(stopped), earlier: [before])
        #expect(why?.contains("failed 8 times") == true)
        #expect(why?.contains("That sender only unsubscribes on its web page.") == true)
    }

    @Test func anAnswerThatWorkedIsSaidToHaveWorked() {
        let before = reply("One at a time.", tools: [("redde_mail", #"{"done": ["main:INBOX:978"], "failed": [], "log": "m1"}"#)])
        let why = ToolStop.reason(reply(stopped), earlier: [before])
        #expect(why?.contains("didn't fail") == true)
    }

    @Test func theLastCallOfThatToolCounts() {
        let before = reply("…", tools: [("redde_mail", #"{"error": "x", "message": "Old"}"#), ("web_search", #"{"error": "y", "message": "Other tool"}"#),
                                        ("redde_mail", #"{"error": "x", "message": "Newest"}"#)])
        #expect(ToolStop.reason(reply(stopped), earlier: [before])?.contains("Newest") == true)
    }

    @Test func noOutputStillSaysTheRule() {
        #expect(ToolStop.reason(reply(stopped), earlier: []) == "Hermes ends a turn once a tool has failed 8 times.")
    }

    @Test func anyOtherReplyHasNone() {
        #expect(ToolStop.reason(reply("All done."), earlier: []) == nil)
        #expect(ToolStop.reason(Message(role: .user, text: stopped), earlier: []) == nil)
    }
}

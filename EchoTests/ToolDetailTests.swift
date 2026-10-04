import Foundation
import Testing
@testable import Echo

/// What a tool step shows when opened: what it was called with and what came back.
struct ToolDetailTests {
    @Test func anObjectReadsAsItsFieldsWithTextInFull() {
        let result = JSONValue.object(["exit_code": .number(0), "output": .string("total 8\ndrwxr-xr-x  plan.md")])
        #expect(ToolActivity.detail(result) == "exit_code: 0\noutput:\ntotal 8\ndrwxr-xr-x  plan.md")
        #expect(ToolActivity.detail(JSONValue.string("  done\n")) == "done")
        #expect(ToolActivity.detail(JSONValue.array([.number(1), .number(2)])) == "[1,2]")
    }

    @Test func nothingToShowIsNil() {
        #expect(ToolActivity.detail(JSONValue.null) == nil)
        #expect(ToolActivity.detail(JSONValue.object([:])) == nil)
        #expect(ToolActivity.detail("  \n ") == nil)
        #expect(ToolActivity.detail(nil as String?) == nil)
    }

    @Test func aLongResultIsCutWithANoteOfWhatIsMissing() throws {
        let cut = try #require(ToolActivity.detail(String(repeating: "x", count: ToolActivity.detailCap + 250)))
        #expect(cut.hasSuffix("… (250 more characters)"))
        #expect(cut.count < ToolActivity.detailCap + 40)
    }

    @Test func argumentsThatArriveAsJSONTextAreParsed() {
        #expect(ToolActivity.detail(json: #"{"date":"tomorrow","limit":5}"#) == "date: tomorrow\nlimit: 5")
        #expect(ToolActivity.detail(json: "not json") == "not json")
        #expect(ToolActivity.detail(json: "{}") == nil)
    }

    /// The Hermes API's stream names a finished tool but not what it returned.
    @Test func theAPIStreamCarriesTheCallButNotTheResult() throws {
        func event(_ name: String, _ data: String) -> SSEEvent { SSEEvent(event: name, data: data) }
        let started = try HermesSessionsTransport.decode(event("tool.started", #"{"tool_name":"calendar","preview":"list","args":{"date":"tomorrow"}}"#)).events
        #expect(started == [.toolStarted(name: "calendar", preview: "list", args: "date: tomorrow")])
        let finished = try HermesSessionsTransport.decode(event("tool.completed", #"{"tool_name":"calendar","preview":null,"args":null}"#)).events
        #expect(finished == [.toolFinished(name: "calendar", failed: false, output: nil)])
    }

    /// The stored transcript has both: the call's arguments on the assistant row, the result on
    /// the tool row after it. Results go to the calls in order, through a folded reply.
    @Test func storedRowsGiveEachCallItsArgumentsAndResult() throws {
        let json = #"""
        {"data":[
          {"id":1,"role":"user","content":"What's on tomorrow, and remind me to call the vet?"},
          {"id":2,"role":"assistant","content":"","tool_calls":[
            {"id":"c1","function":{"name":"calendar","arguments":"{\"date\":\"tomorrow\"}"}},
            {"id":"c2","function":{"name":"reminders","arguments":{"title":"Call the vet"}}}]},
          {"id":3,"role":"tool","content":"09:30 Standup\n12:15 Lunch","tool_call_id":"c1","tool_name":"calendar"},
          {"id":4,"role":"tool","content":"{\"created\":true}","tool_call_id":"c2","tool_name":"reminders"},
          {"id":5,"role":"assistant","content":"Two things, and the reminder is set."}
        ]}
        """#
        struct Envelope: Decodable { var data: [HermesSessionsAPI.StoredMessage] }
        let messages = Conversation.mapStored(try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).data)
        #expect(messages.map(\.role) == [.user, .assistant])
        let tools = messages[1].tools
        #expect(tools.map(\.name) == ["calendar", "reminders"])
        #expect(tools.map(\.args) == ["date: tomorrow", "title: Call the vet"])
        #expect(tools.map(\.output) == ["09:30 Standup\n12:15 Lunch", #"{"created":true}"#])
        #expect(messages[1].text == "Two things, and the reminder is set.")
    }

    @Test func aReplyFindsItsOwnToolsInTheStoredTranscript() {
        func reply(_ text: String, _ tools: [(String, String?)]) -> Message {
            var message = Message(role: .assistant, text: text)
            message.tools = tools.map { ToolActivity(name: $0.0, preview: nil, status: .completed, output: $0.1) }
            return message
        }
        let stored = [reply("First.", [("calendar", "one")]), Message(role: .user, text: "again"),
                      reply("Second.", [("calendar", "two")]), reply("Other.", [("web", "page")])]
        #expect(Conversation.storedTools(for: reply("First.", [("calendar", nil)]), in: stored)?.first?.output == "one")
        // Text that doesn't match (a rewritten reply): the newest reply with the same tools.
        #expect(Conversation.storedTools(for: reply("Changed.", [("calendar", nil)]), in: stored)?.first?.output == "two")
        #expect(Conversation.storedTools(for: reply("x", [("terminal", nil)]), in: stored) == nil)
    }

    /// The Dashboard's history rows carry the call, and the result only for the edit tools.
    @Test func dashboardHistoryRowsCarryTheCall() {
        let rows: [JSONValue] = [
            .object(["role": .string("user"), "text": .string("hi")]),
            .object(["role": .string("assistant"), "text": .string("Done.")]),
            .object(["role": .string("tool"), "name": .string("terminal"), "context": .string("ls"),
                     "args": .object(["command": .string("ls -la")])]),
            .object(["role": .string("tool"), "name": .string("write_file"), "context": .string("plan.md"),
                     "content": .string("wrote 12 lines")]),
        ]
        let tools = Conversation.messages(fromServeRows: rows)[1].tools
        #expect(tools.map(\.args) == ["command: ls -la", nil])
        #expect(tools.map(\.output) == [nil, "wrote 12 lines"])
    }

    @Test func theOpenedStepShowsOnlyItsFirstLines() {
        let text = (1 ... 40).map { "line \($0)" }.joined(separator: "\n")
        #expect(MessageRow.head(of: text, lines: 3) == "line 1\nline 2\nline 3")
        #expect(MessageRow.head(of: String(repeating: "x", count: 5000), lines: 2).count == 320)
    }
}

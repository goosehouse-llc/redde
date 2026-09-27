import Foundation
import Testing
@testable import Echo

/// The Hermes API's `/api/sessions/{id}/messages`: the gateway's database rows, nearly as-is.
struct StoredMessageTests {
    /// Row ids are numbers. Read as text, one row failed the whole transcript ("The data couldn't
    /// be read because it isn't in the correct format", on every session).
    @Test func decodesTheGatewaysRows() throws {
        let json = #"""
        {"object":"list","session_id":"s1","data":[
          {"id":101,"session_id":"s1","role":"user","content":"What's on tomorrow?","tool_call_id":null,"tool_calls":null,
           "tool_name":null,"timestamp":1790429287.5,"token_count":7,"finish_reason":null,"reasoning":null,"reasoning_content":null},
          {"id":102,"session_id":"s1","role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function",
           "function":{"name":"calendar","arguments":"{}"}}],"timestamp":1790429288,"token_count":12,"finish_reason":"tool_calls"},
          {"id":103,"session_id":"s1","role":"tool","content":"{\"events\":2}","tool_call_id":"c1","tool_name":"calendar","timestamp":1790429289},
          {"id":104,"session_id":"s1","role":"assistant","content":[{"type":"text","text":"Two things."}],"timestamp":"1790429290",
           "reasoning":"Check the calendar.","display_metadata":{"kind":"x"},"something_new":[1,2,3]}
        ],"pagination":{"limit":500,"offset":0,"order":"oldest","returned":4}}
        """#
        struct Envelope: Decodable { var data: [HermesSessionsAPI.StoredMessage] }
        let stored = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).data
        #expect(stored.count == 4)
        #expect(stored[0].id == "101")
        #expect(stored[3].timestamp == 1790429290)

        let messages = Conversation.mapStored(stored)
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages[0].text == "What's on tomorrow?")
        #expect(messages[1].text == "Two things.")
        #expect(messages[1].tools.map(\.name) == ["calendar"])
    }

    /// A field of an unexpected type costs that field, not the transcript.
    @Test func oddFieldsAreSkipped() throws {
        let json = #"{"data":[{"id":"x","role":"user","content":{"weird":true},"timestamp":true,"tool_calls":"[]"},{"role":"assistant","content":"ok"}]}"#
        struct Envelope: Decodable { var data: [HermesSessionsAPI.StoredMessage] }
        let stored = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).data
        #expect(stored.count == 2)
        #expect(stored[0].content == nil)
        #expect(Conversation.mapStored(stored).last?.text == "ok")
    }
}

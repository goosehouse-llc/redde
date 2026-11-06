import Foundation
import Testing
@testable import Echo

/// GitHub #64: a skill typed as a slash command on the Dashboard came back as its own words.
@MainActor
struct SlashOutcomeTests {
    private func outcome(_ json: String) throws -> HermesServeTransport.SlashOutcome {
        HermesServeTransport.outcome(of: try JSONValue.parse(Data(json.utf8)))
    }

    @Test func aSkillIsSentAsTheTurnNotShownAsTheReply() throws {
        let result = try outcome(#"{"type":"skill","name":"humanizer","message":"[skill body] on the last paragraph","display":"/humanizer on the last paragraph"}"#)
        guard case let .submit(message, notice) = result else { Issue.record("shown, not sent: \(result)"); return }
        #expect(message == "[skill body] on the last paragraph")
        #expect(notice == nil)
    }

    @Test func aSendKeepsItsNotice() throws {
        guard case let .submit(message, notice) = try outcome(#"{"type":"send","message":"Plan this","notice":"Planning mode"}"#) else {
            Issue.record("not sent"); return
        }
        #expect(message == "Plan this")
        #expect(notice == "Planning mode")
    }

    @Test func outputIsShown() throws {
        guard case let .shown(events) = try outcome(#"{"output":"Commands: /help"}"#),
              case let .textDelta(text) = events.first else { Issue.record("not shown"); return }
        #expect(text == "Commands: /help")
    }
}

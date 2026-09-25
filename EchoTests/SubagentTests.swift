import Foundation
import Testing
@testable import Echo

struct SubagentTests {
    @Test func parsesServeSubagentFrames() throws {
        let start = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"goal":"research pricing","task_count":3,"task_index":1,"subagent_id":"sa-1","child_session_id":"c1","depth":0,"tool_count":0}
        """.utf8))
        let u = try #require(HermesServeTransport.parseSubagent("subagent.start", start))
        #expect(u.id == "sa-1" && u.goal == "research pricing" && u.taskIndex == 1 && u.taskCount == 3)
        #expect(u.phase == .started && u.childSessionID == "c1")

        let done = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"goal":"research pricing","subagent_id":"sa-1","status":"success","summary":"Three tiers.","duration_seconds":12.5,"tool_count":7}
        """.utf8))
        let d = try #require(HermesServeTransport.parseSubagent("subagent.complete", done))
        #expect(d.phase == .completed(succeeded: true, summary: "Three tiers.", duration: 12.5))
        #expect(d.toolCount == 7)
    }

    @Test func synthesizesGoalsFromDelegateArgs() throws {
        let args = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"tasks":[{"goal":"a"},{"goal":"b"}]}
        """.utf8))
        let rows = HermesSessionsTransport.delegatedGoals(args, runID: "r1")
        #expect(rows.map(\.goal) == ["a", "b"])
        #expect(rows.map(\.id) == ["delegate:r1:0", "delegate:r1:1"])
        #expect(rows.allSatisfy { $0.taskCount == 2 })
    }
}

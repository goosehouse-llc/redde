import Foundation
import Testing
@testable import Echo

/// Agent Activity and watches that bring another agent in (asked 2026-10-28, after Muse and Grok Bot).
struct AgentActivityTests {
    private func job(_ name: String, last: Date?, status: String = "ok", profile: String? = nil, deliver: String = "local") throws -> CronJob {
        var fields: [String: JSONValue] = ["id": .string(name), "name": .string(name), "schedule": .string("0 * * * *"),
                                           "last_status": .string(status), "deliver": .string(deliver)]
        if let last { fields["last_run_at"] = .number(last.timeIntervalSince1970) }
        if let profile { fields["profile"] = .string(profile) }
        return try #require(CronJob(.object(fields)))
    }

    private func note(_ json: [String: Any]) throws -> PushNote {
        try JSONDecoder().decode(PushNote.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func notesThatReachedThePhoneAreLogged() throws {
        let at = 1_800_000_000.0
        let ideas = try #require(AgentActivityNote.made(from: try note(["v": 1, "k": "ideas", "at": at, "p": "ops", "d": "Home", "i": "o1",
                                                                        "y": [["t": "Close the garage"], ["r": "Order filters"]]])))
        #expect(ideas.kind == .ideas && ideas.detail == "Close the garage · Order filters" && ideas.profile == "ops")
        let brief = try #require(AgentActivityNote.made(from: try note(["v": 1, "k": "routine", "at": at, "t": "Evening wrap-up", "x": "brief", "b": "Done: x"])))
        #expect(brief.kind == .brief && brief.profile == "default")
        #expect(AgentActivityNote.made(from: try note(["v": 1, "k": "replied", "at": at])) == nil, "a reply the person waited for isn't on its own")
    }

    @Test func runsNotesAndTheBoardMakeOneTimeline() throws {
        let now = Date(timeIntervalSince1970: 1_800_100_000)
        let calendar = Calendar(identifier: .gregorian)
        let watch = try job("[redde-watch:w1] Garage door", last: now.addingTimeInterval(-600), profile: "ops", deliver: "bot-chat:default")
        let wrap = try job("[redde-notify] Evening wrap-up", last: now.addingTimeInterval(-3600))
        let broken = try job("[redde] Heads-ups", last: now.addingTimeInterval(-7200), status: "error")
        let looks = (1 ... 5).map { now.addingTimeInterval(Double(-600 * $0)) }
        let said = AgentActivityNote(id: "w", kind: .watch, profile: "ops", agent: "Home", title: "Garage door",
                                     detail: "Open since 22:10", at: looks[0].addingTimeInterval(20), failed: false)
        let told = AgentActivityNote(id: "b", kind: .brief, profile: "default", agent: "Sol", title: "Evening wrap-up",
                                     detail: "Done: the vet.", at: now.addingTimeInterval(-3590), failed: false)
        let entries = AgentActivity.merge(jobs: [watch, wrap, broken], runs: ["[redde-watch:w1] Garage door": looks],
                                          tasks: [], notes: [said, told], now: now, calendar: calendar)
        let garage = entries.filter { $0.title == "Garage door" }
        #expect(garage.contains { $0.detail == "Open since 22:10" }, "a look that found something, with what it said")
        #expect(garage.contains { $0.detail.contains("4") }, "the four that found nothing: one line")
        #expect(garage.count == 2)
        #expect(entries.first { $0.title == "Evening wrap-up" }?.detail == "Done: the vet.", "a briefing's run with its answer, once")
        #expect(entries.filter { $0.title == "Evening wrap-up" }.count == 1)
        #expect(entries.first { $0.title == "Heads-ups" }?.failed == true)
        #expect(entries.map(\.at) == entries.map(\.at).sorted(by: >), "newest first")
    }

    @Test func aWatchCanBeHandedToAnotherAgent() throws {
        let handed = Watches.prompt("w2", what: "the garage door at night", then: .hand("default", "Sol"))
        #expect(handed.contains("[SILENT]") && handed.contains("goes to Sol"))
        #expect(Watches.Then.hand("default", "Sol").deliver == "bot-chat:default" && Watches.Then.call.deliver == "local")
        #expect(Watches.prompt("w2", what: "x", then: .call).contains("call_user"))
        #expect(Watches.prompt("w2", what: "x").contains("NOTHING NEW"))
        #expect(Watches.handedTo(try job("[redde-watch:w2] x", last: nil, deliver: "bot-chat:ops")) == "ops")
        #expect(Watches.handedTo(try job("[redde-watch:w2] x", last: nil)) == nil)
    }
}

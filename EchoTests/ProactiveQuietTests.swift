import Foundation
import Testing
@testable import Echo

/// Quiet hours and their digest, and what a place tells an agent (asked 2026-10-28, "Proactive").
struct ProactiveQuietTests {
    private let calendar = Calendar(identifier: .gregorian)
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 28) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func note(_ json: [String: Any]) throws -> PushNote {
        try JSONDecoder().decode(PushNote.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func quietHoursRunAcrossMidnight() {
        let quiet = QuietHours(on: true, start: 22 * 60, end: 7 * 60)
        #expect(quiet.covers(at(23), calendar: calendar) && quiet.covers(at(3), calendar: calendar))
        #expect(!quiet.covers(at(7), calendar: calendar) && !quiet.covers(at(12), calendar: calendar))
        #expect(quiet.ends(after: at(23), calendar: calendar) == at(7, day: 29))
        #expect(quiet.ends(after: at(3), calendar: calendar) == at(7))
        #expect(!QuietHours(on: false).covers(at(23), calendar: calendar), "off is off")
        let day = QuietHours(on: true, start: 13 * 60, end: 14 * 60)
        #expect(day.covers(at(13, 30), calendar: calendar) && !day.covers(at(14), calendar: calendar))
    }

    @Test func onlyWhatAgentsSendOnTheirOwnWaits() throws {
        #expect(QuietHours.waits(try note(["v": 1, "k": "ideas"])))
        #expect(QuietHours.waits(try note(["v": 1, "k": "watch"])))
        #expect(QuietHours.waits(try note(["v": 1, "k": "routine"])))
        #expect(!QuietHours.waits(try note(["v": 1, "k": "approval"])), "what waits on the person comes through")
        #expect(!QuietHours.waits(try note(["v": 1, "k": "call"])))
    }

    @Test func theDigestSaysWhatCame() throws {
        let defaults = UserDefaults(suiteName: "quiet-\(UUID().uuidString)")!
        HeldNote.hold(try note(["v": 1, "k": "routine", "x": "brief", "t": "Heads-up: Dentist"]), in: defaults)
        HeldNote.hold(try note(["v": 1, "k": "ideas", "d": "Sol"]), in: defaults)
        let held = HeldNote.hold(try note(["v": 1, "k": "watch", "t": "Garage door"]), in: defaults)
        #expect(held.count == 3)
        let words = HeldNote.digest(held)
        #expect(words.body.contains("Heads-up: Dentist") && words.body.contains("Garage door"))
        HeldNote.clear(in: defaults)
        #expect(HeldNote.all(in: defaults).isEmpty)
    }

    @Test func aPlaceSaysWhereTheUserIsAndNothingMore() {
        let home = WatchedPlace(name: "Home", latitude: 40.7, longitude: -74, arrive: PlaceAction(profile: "ops", message: "Turn on the hall light."))
        let arrived = home.message(arrived: true)
        #expect(arrived?.text == "Turn on the hall light." && arrived?.note.contains("arrived at Home") == true)
        #expect(arrived?.note.contains("40.7") == false, "where they are stays on the phone")
        #expect(home.message(arrived: false) == nil, "nothing set for leaving")
    }

    @MainActor
    @Test func beforeActingIsToldToThePluginPerAgent() {
        let defaults = UserDefaults(suiteName: "autonomy-\(UUID().uuidString)")!
        #expect(AgentAutonomy.level("default", defaults: defaults) == .ask && AgentAutonomy.command(defaults: defaults) == nil)
        AgentAutonomy.set("ops", .act, defaults: defaults)
        AgentAutonomy.set("default", .routine, defaults: defaults)
        #expect(AgentAutonomy.command(defaults: defaults) == "autonomy default=routine ops=act")
        #expect(AgentAutonomy.level("ops", defaults: defaults) == .act)
    }

    @Test func weeklyJobsRunOnSundays() {
        #expect(WeekAhead.job.days == "0" && RoutineSuggestions.job.days == "0" && EveningWrapUp.job.days == "*")
        #expect(WeekAhead.name.hasPrefix("[redde-notify] "), "the week ahead reaches the phone")
        #expect(!RoutineSuggestions.name.hasPrefix("[redde-notify]"), "suggestions come as idea cards, not as its answer")
        #expect(RoutineSuggestions.prompt.contains("suggest_to_user"))
    }
}

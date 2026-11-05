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
        #expect(RoutineSuggestions.prompt.contains("\"IDEA: <title> | <why> | <the request>\""), "written lines, not a tool call (11-04)")
    }

    /// How Near goes up to a mile (asked 2026-10-31), in whole units either way, and a place saved
    /// at the old 150 m default lands on a choice.
    @Test func placesReachAMile() {
        #expect(WatchedPlace.radii(us: true).last == 1609.344)
        #expect(WatchedPlace.radii(us: false).last == 1600)
        #expect(MeasureUnits.distance(WatchedPlace.radii(us: true)[3], us: true).hasPrefix("0.5"))
        #expect(MeasureUnits.distance(WatchedPlace.radii(us: true)[4], us: true).hasPrefix("1"))
        #expect(WatchedPlace.nearestRadius(150, us: true) == 100 || WatchedPlace.nearestRadius(150, us: true) == 200)
        #expect(WatchedPlace.nearestRadius(800, us: true) == 804.672, "a metric half mile, in US units")
        #expect(WatchedPlace(name: "Gym", latitude: 0, longitude: 0).radius == 200)
    }

    /// Each crossing is a line in Agent Activity (asked 2026-10-31): when iOS saw it, how long
    /// before Redde was woken, the circle, and what came of it.
    @Test func aCrossingIsALineInAgentActivity() {
        let home = WatchedPlace(name: "Home", latitude: 40.7, longitude: -74, radius: 804.672,
                                arrive: PlaceAction(profile: "ops", message: "Turn on the hall light."))
        let saw = Date(timeIntervalSince1970: 1_793_480_000)
        let line = Places.crossing(home, arrived: true, reported: saw, woken: saw.addingTimeInterval(42), profile: "ops",
                                   outcome: "Your agent was told and answered.", failed: false)
        #expect(line.kind == .place && line.profile == "ops" && line.at == saw)
        #expect(line.title.contains("Home"))
        #expect(line.detail.contains("42"), "the gap is iOS's, and shown")
        #expect(line.detail.contains("Your agent was told and answered."))
        let quick = Places.crossing(home, arrived: false, reported: saw, woken: saw.addingTimeInterval(1), profile: "ops",
                                    outcome: "x", failed: false)
        #expect(!quick.detail.contains(" s later"), "a woken-at-once crossing has no gap to show")
        #expect(quick.id != line.id || quick.title != line.title)
        let entries = AgentActivity.merge(jobs: [], runs: [:], tasks: [], notes: [line], now: saw.addingTimeInterval(60))
        #expect(entries.first?.source == .place)
    }
}

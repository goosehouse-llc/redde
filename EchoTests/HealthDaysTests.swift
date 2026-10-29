import Foundation
import Testing
@testable import Echo

/// Health-aware days (asked 2026-10-28, "Proactive"): off until turned on; a one-line summary of
/// sleep, steps and workouts in the jobs that hear it, and nothing once off or a day old.
struct HealthDaysTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "health-\(UUID().uuidString)")! }

    private func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 28 + dayOffset, hour: hour, minute: minute))!
    }

    @Test func theLineSaysTheDayInAFewWords() throws {
        let summary = HealthSummary(slept: 6 * 3600 + 10 * 60, fellAsleep: at(23, 40, dayOffset: -1), woke: at(6, 5),
                                    stepsToday: 1240, stepsYesterday: 8930, workouts: ["32-minute run yesterday"], at: at(7, 12))
        let line = try #require(summary.line)
        #expect(line.hasPrefix("From the user's iPhone (Apple Health, shared at their choice, as of 7:12 AM): slept 6 h 10 min last night (11:40 PM–6:05 AM); 1,240 steps so far today, 8,930 yesterday; workouts: 32-minute run yesterday."))
        #expect(HealthSummary(at: at(7, 0)).line == nil, "nothing read, nothing said")
        #expect(HealthSummary(slept: 600, at: at(7, 0)).line == nil, "a nap isn't a night")
        #expect(HealthSummary(stepsYesterday: 5000, at: at(7, 0)).line?.contains("5,000 steps yesterday") == true)
    }

    @Test func offOrStaleSaysNothing() {
        let store = defaults()
        let summary = HealthSummary(stepsToday: 3000, at: at(7, 0))
        summary.save(in: store)
        #expect(HealthSummary.note(in: store, now: at(8, 0)) == nil, "off by default")
        HealthSummary.setOn(true, in: store)
        summary.save(in: store)
        #expect(HealthSummary.note(in: store, now: at(8, 0))?.contains("3,000 steps") == true)
        #expect(HealthSummary.note(in: store, now: at(7, 0, dayOffset: 1)) == nil, "a day old: not said")
        HealthSummary.setOn(false, in: store)
        #expect(HealthSummary.load(in: store) == nil, "turned off: the summary is gone")
    }

    @Test func onlyAChangeWorthSayingIsSaid() {
        let base = HealthSummary(slept: 7 * 3600, stepsToday: 1200, workouts: [], at: at(7, 0))
        var same = base
        same.stepsToday = 1900
        same.slept = 7 * 3600 + 120
        #expect(!same.differs(from: base), "a few hundred steps, two minutes' sleep")
        var more = base
        more.stepsToday = 2100
        #expect(more.differs(from: base))
        var ran = base
        ran.workouts = ["20-minute run today"]
        #expect(ran.differs(from: base) && base.differs(from: nil))
    }

    @Test func onlyTheJobsThatHearItCarryIt() {
        let store = UserDefaults.standard
        let was = (HealthSummary.isOn(), HealthSummary.load())
        defer { HealthSummary.setOn(was.0); was.1?.save() }
        HealthSummary.setOn(true)
        HealthSummary(stepsToday: 4000, at: .now).save()
        #expect(MorningIdeas.job.fullPrompt(0).contains("4,000 steps so far today"))
        #expect(EveningWrapUp.job.fullPrompt(0).contains("4,000 steps"))
        #expect(!HeadsUps.job.fullPrompt(30).contains("Apple Health") && !RoutineSuggestions.job.fullPrompt(0).contains("Apple Health"))
        _ = store
    }
}

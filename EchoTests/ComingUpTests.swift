import Foundation
import Testing
@testable import Echo

/// Coming Up (2.4): the next day of what the agents and this device will do, from the server's jobs
/// and Leave-By Alerts; what Skip does for each; the skip mark in a job's name.
struct ComingUpTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func job(_ id: String, _ name: String, _ schedule: String = "0 * * * *", in minutes: Double?, enabled: Bool = true,
                     state: String? = nil, times: Int? = nil, completed: Int = 0, profile: String? = nil) throws -> CronJob {
        var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "schedule": .string(schedule), "enabled": .bool(enabled)]
        if let minutes { fields["next_run_at"] = .number(now.addingTimeInterval(minutes * 60).timeIntervalSince1970) }
        if let state { fields["state"] = .string(state) }
        if let times { fields["repeat"] = .object(["times": .number(Double(times)), "completed": .number(Double(completed))]) }
        if let profile { fields["profile"] = .string(profile) }
        return try #require(CronJob(.object(fields)))
    }

    @Test func theNextDaySoonestFirstThenWhatIsPaused() throws {
        let jobs = [
            try job("a", "[redde-watch:k1] The kettle's price", "*/15 * * * *", in: 10),
            try job("b", "[redde-notify] Heads-up: Dentist", "once at 2026-01-15 14:15", in: 90, times: 1),
            try job("c", "[redde-followup:p1] Call the plumber", "once", in: 60 * 20),
            try job("d", "[redde] Morning ideas", "30 7 * * *", in: 60 * 12),
            try job("e", "[redde-goal:10k] Run a 10K", "0 9 * * 1", in: 60 * 30),   // after the day: left out
            try job("f", "[redde-watch:s1] School", "*/30 * * * *", in: 5, enabled: false),
            try job("g", "Backups", "0 3 * * *", in: 60 * 5, state: "completed"),
            try job("h", "[bot:ops] Disk check", "0 */4 * * *", in: 30, profile: "ops"),
        ]
        let items = ComingUp.plan(jobs: jobs, leave: [:], now: now)
        #expect(items.map(\.title) == ["The kettle's price", "Disk check", "Dentist", "Morning ideas", "Call the plumber", "School"])
        #expect(items.map(\.kind) == [.watch, .routine, .headsUp, .daily, .followUp, .watch])
        #expect(items.last?.paused == true)
        // A frequent watch is one row, with how often it looks.
        #expect(items[0].cadence == String(localized: "Every 15 minutes"))
        #expect(items[1].profile == "ops" && items[1].cadence == String(localized: "Every 4 hours"))
        #expect(items[2].cadence == nil, "a heads-up runs once")
    }

    @Test func dailyNamesAreTheJobsOwn() {
        #expect(ComingUp.dailyNames == [MorningIdeas.name, HeadsUps.name, RoutineSuggestions.name, EveningWrapUp.name, WeekAhead.name])
    }

    @Test func leaveByAlertsComeInWithTheirWay() throws {
        let start = now.addingTimeInterval(3 * 3600)
        let leave = LeaveTime.leave(for: start, travel: 25 * 60, mode: .driving)
        let set = LeaveBy.Worked(title: "Lunch", start: start, place: "1 Main St", mode: .driving, fromLatitude: 0, fromLongitude: 0,
                                 toLatitude: 0, toLongitude: 0, travel: 25 * 60, at: now, alertAt: leave)
        var gone = set
        gone.alertAt = now.addingTimeInterval(-60)
        var notSet = set
        notSet.alertAt = nil
        let items = ComingUp.plan(jobs: [], leave: ["a": set, "b": gone, "c": notSet, "d": notSet], skippedLeave: ["d"], now: now)
        #expect(items.map(\.alertID) == ["a", "d"], "gone off, or never set and not skipped: nothing to come")
        #expect(items.allSatisfy { $0.kind == .leaveBy && $0.at == leave && $0.detail != nil })
        #expect(items[1].skipped && !items[0].skipped)
    }

    @Test func whatSkipDoes() throws {
        let watch = try job("a", "[redde-watch:k1] Kettle", "*/15 * * * *", in: 10)
        let followUp = try job("b", "[redde-followup:p1] Plumber", "once", in: 60)
        let soon = try job("c", "[redde-notify] Weather", "0 7 * * *", in: 1)
        let paused = try job("d", "[redde-notify] Wear", "0 7 * * *", in: 60, enabled: false)
        let lastRun = try job("e", "[redde-watch:t-pkg-abc] Parcel", "0 */4 * * *", in: 60, times: 84, completed: 83)
        let items = ComingUp.plan(jobs: [watch, followUp, soon, paused, lastRun], leave: [:], now: now)
        func way(_ id: String) -> ComingUp.SkipWay { ComingUp.skipWay(items.first { $0.job?.id == id }!, now: now) }
        #expect(way("a") == .mark)
        #expect(way("b") == .cancel)
        #expect(way("c") == .pauseInstead, "less than two minutes away")
        #expect(way("d") == .none)
        #expect(way("e") == .cancel, "its last run is a one-off")
    }

    @Test func theSkipMarkRoundTripsAndIsNeverShown() throws {
        let run = now.addingTimeInterval(600)
        let marked = ComingUp.marked("[redde-watch:k1] Kettle", skipping: run)
        #expect(marked == "[redde-watch:k1] Kettle [redde-skip:1800000600]")
        #expect(ComingUp.marked(marked, skipping: run) == marked, "marked once")
        let job = try job("a", marked, "*/15 * * * *", in: 10)
        #expect(job.name == "[redde-watch:k1] Kettle" && job.skipping == run)
        #expect(Watches.title(of: job) == "Kettle" && AgentActivity.describe(job.name).title == "Kettle")
        let item = try #require(ComingUp.plan(jobs: [job], leave: [:], now: now).first)
        #expect(item.skipping && ComingUp.skipWay(item, now: now) == .none)
        // Not a mark: left as it is.
        #expect(ComingUp.unmarked("Price [redde-skip:soon]").skipping == nil)
        #expect(ComingUp.unmarked("Plain").name == "Plain")
    }

    @Test func aMarkNothingTookUpIsTakenOff() throws {
        let job = try job("a", ComingUp.marked("Kettle", skipping: now.addingTimeInterval(600)), in: 10)
        #expect(!ComingUp.markUnheard(job, asked: now, now: now.addingTimeInterval(30)))
        #expect(ComingUp.markUnheard(job, asked: now, now: now.addingTimeInterval(130)), "the plugin looks every 30 s")
        #expect(ComingUp.markUnheard(job, asked: nil, now: now.addingTimeInterval(601)), "its run came and went")
        #expect(ComingUp.pluginSkipped("Skipped the 9:00 AM run of Kettle."))
        #expect(!ComingUp.pluginSkipped("Usage: /redde-push pair | devices | …"))
    }

    @Test func cadenceInWords() {
        #expect(ComingUp.cadence("*/30 * * * *") == String(localized: "Every 30 minutes"))
        #expect(ComingUp.cadence("0 * * * *") == String(localized: "Every hour"))
        #expect(ComingUp.cadence("0 8 * * *") == String(localized: "Every day"))
        #expect(ComingUp.cadence("every 2h") == String(localized: "Every \(2) hours"))
        #expect(ComingUp.cadence("once at 9") == nil)
    }
}

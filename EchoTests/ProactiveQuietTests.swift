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

    /// At most N a day (2026-11-22): the first N counted, the rest quiet, a new day counted again.
    @Test func theDailyLimitQuietsTheRest() {
        let defaults = UserDefaults(suiteName: "quiet-\(UUID().uuidString)")!
        var quiet = QuietHours()
        #expect(!quiet.spent(at: .now, in: defaults), "no limit")
        quiet.perDay = 2
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!quiet.spent(at: morning, in: defaults))
        #expect(!quiet.spent(at: morning.addingTimeInterval(60), in: defaults))
        #expect(quiet.spent(at: morning.addingTimeInterval(120), in: defaults))
        #expect(!quiet.spent(at: morning.addingTimeInterval(86_400), in: defaults), "the next day")
    }

    /// When You've Gone Quiet (plugin 1.36): hourly, its wait in the prompt's mark and read back.
    @Test func theQuietJobRunsHourlyWithItsWaitInItsMark() throws {
        let prompt = GoneQuiet.job.fullPrompt(48)
        #expect(prompt.hasPrefix("[redde-quiet:48h] "))
        #expect(prompt.contains("[SILENT]"))
        let job = try #require(CronJob(.object(["id": .string("q1"), "name": .string(GoneQuiet.name), "schedule": .string("7 * * * *"),
                                                 "prompt": .string(prompt), "enabled": .bool(true)])))
        #expect(GoneQuiet.job.option(in: job) == 48)
        #expect(GoneQuiet.job.hourly && DailyJobsView.jobs.contains { $0.name == GoneQuiet.name })
    }

    /// Things to Keep in Mind (plugin 1.36): each fact said to the plugin base64url, the list read back.
    @Test func keptFactsTravelBase64URL() throws {
        let line = KeptFacts.line("add", "Driving into France, I need 3-day car insurance")
        #expect(line.hasPrefix("facts add ") && !line.dropFirst(10).contains(" "))
        let list = PushSeal.base64URL(Data(#"["Pickles needs his jab every March"]"#.utf8))
        #expect(KeptFacts.parse("redde-push facts \(list)\n") == ["Pickles needs his jab every March"])
        #expect(KeptFacts.parse("redde-push facts: this command is for the Redde app.") == nil)
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

    /// Notification levels (2026-11-27): each kind in its group, and the plugin's marks (1.57) over the kind's.
    @Test func eachNoteIsInItsGroup() throws {
        let groups: [([String: Any], NoteGroup?)] = [
            (["k": "approval"], .needsYou), (["k": "call"], .needsYou), (["k": "group_wait"], .needsYou),
            (["k": "work", "w": "needs"], .needsYou), (["k": "work", "w": "done"], .finds),
            (["k": "reply"], .replies), (["k": "failed"], .replies), (["k": "group"], .groups),
            (["k": "watch"], .finds), (["k": "watch", "l": "now"], .needsYou), (["k": "mail"], .finds),
            (["k": "routine", "x": "brief"], .background), (["k": "routine", "x": "brief", "u": "2026-11-27T10:00"], .finds),
            (["k": "routine", "x": "brief", "l": "now"], .needsYou), (["k": "routine", "x": "brief", "o": "g1"], .background),
            (["k": "ideas"], .background), (["k": "ideas", "l": "look"], .finds), (["k": "ideas", "l": "now"], .needsYou),
            (["k": "widget"], nil), (["k": "clear"], nil), (["k": "something-newer"], nil)]
        for (fields, group) in groups {
            var json: [String: Any] = ["v": 1]
            json.merge(fields) { _, new in new }
            #expect(NoteGroup.of(try note(json)) == group, "\(fields)")
        }
    }

    @Test func levelsStartQuietForWhatAgentsDoAndKeepWhatNeedsYouHeard() {
        let standard = NoteLevels()
        #expect(standard.level(.needsYou) == .sound && standard.level(.replies) == .silent && standard.level(.background) == .summary)
        let picked = NoteLevels(text: NoteLevels(chosen: ["needsYou": .summary, "background": .sound]).text)
        #expect(picked.level(.needsYou) == .sound, "what needs the person is never only in a summary")
        #expect(picked.level(.background) == .sound)
        #expect(NoteLevels(text: "") == NoteLevels() && NoteLevels(text: "{nonsense") == NoteLevels())
    }

    @Test func theNextSummaryIsOutsideTheQuiet() {
        let levels = NoteLevels()   // 8:00, 12:00, 18:00
        let night = QuietHours(on: true, start: 22 * 60, end: 7 * 60)
        #expect(levels.nextSummary(after: at(7, 30), quiet: night, calendar: calendar) == at(8))
        #expect(levels.nextSummary(after: at(8), quiet: night, calendar: calendar) == at(12), "not the one going off now")
        #expect(levels.nextSummary(after: at(18, 30), quiet: night, calendar: calendar) == at(8, day: 29))
        let lateMorning = QuietHours(on: true, start: 0, end: 9 * 60)
        #expect(levels.nextSummary(after: at(6), quiet: lateMorning, calendar: calendar) == at(12), "8:00 is in the quiet")
        let allDay = QuietHours(on: true, start: 6 * 60, end: 23 * 60)
        #expect(levels.nextSummary(after: at(7), quiet: allDay, calendar: calendar) == at(23), "every time in the quiet: its end")
    }

    @Test func aSummaryTellsOnlyWhatCameSinceTheLastOne() throws {
        let defaults = UserDefaults(suiteName: "summary-\(UUID().uuidString)")!
        let brief = try note(["v": 1, "k": "routine", "x": "brief", "t": "Weather before your day"])
        #expect(HeldNote.wait(brief, until: at(8), afterQuiet: false, now: at(6, 41), in: defaults, schedule: false) == at(8))
        #expect(HeldNote.wait(try note(["v": 1, "k": "ideas", "d": "Sol"]), until: at(12), afterQuiet: false, now: at(7, 30),
                              in: defaults, schedule: false) == at(8), "the one set for sooner")
        #expect(HeldNote.all(in: defaults).count == 2)
        #expect(HeldNote.wait(try note(["v": 1, "k": "reply", "t": "Lease"]), until: at(12), afterQuiet: false, now: at(9),
                              in: defaults, schedule: false) == at(12))
        let held = HeldNote.all(in: defaults)
        #expect(held.map(\.kind) == [.reply], "the 8:00 summary told the others")
        let words = HeldNote.digest(held, afterQuiet: false)
        #expect(words.title == "Your summary" && words.body.contains("1"))
        #expect(HeldNote.digest(held).title == "While it was quiet")
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

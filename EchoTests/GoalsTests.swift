import Foundation
import Testing
@testable import Echo

/// Goals (2.4): a check-in's note is kept as its goal's latest, the plugin's list is merged over
/// what was kept, progress and the next step are read from the note, and the check-ins default
/// to weekly, every other day for a goal less than two weeks away.
@MainActor
struct GoalsTests {
    private func store() -> UserDefaults { UserDefaults(suiteName: "goals-\(UUID().uuidString)")! }

    private func note(_ json: String) throws -> PushNote { try JSONDecoder().decode(PushNote.self, from: Data(json.utf8)) }

    @Test func aCheckInIsKeptAsItsGoalsLatest() throws {
        let store = store()
        let first = try note(#"{"v":1,"k":"routine","x":"brief","p":"default","d":"Sol","t":"[redde-goal:g7] Run a 10K by March","b":"Two runs this week.\nNext: a 5 km on Saturday","i":"job1","o":"g7","q":"2/7","at":1000}"#)
        #expect(GoalReport.take(first, in: store))
        let kept = try #require(GoalReport.all(in: store)["g7"])
        #expect(kept.title == "Run a 10K by March")
        #expect((kept.done, kept.total) == (2, 7))
        #expect(kept.headline == "Two runs this week.")
        #expect(kept.next == "a 5 km on Saturday")
        #expect(kept.job == "job1")
        #expect(kept.agent == "Sol")

        let later = try note(#"{"v":1,"k":"routine","x":"brief","t":"[redde-goal:g7] Run a 10K by March","b":"Couldn't reach the calendar","o":"g7","q":"3/7","w":"failed","at":2000}"#)
        GoalReport.take(later, in: store)
        let now = try #require(GoalReport.all(in: store)["g7"])
        #expect((now.done, now.total) == (3, 7), "the latest progress")
        #expect(now.failed)
        #expect(now.agent == "Sol", "what the later note didn't say is kept")
        #expect(now.next == nil)
    }

    @Test func otherNotesAreNotGoals() throws {
        let store = store()
        #expect(!GoalReport.take(try note(#"{"v":1,"k":"routine","x":"brief","t":"Evening wrap-up","b":"A quiet day."}"#), in: store))
        #expect(!GoalReport.take(try note(#"{"v":1,"k":"watch","t":"Kettle","b":"It dropped.","i":"w1","o":"g1"}"#), in: store))
        #expect(GoalReport.all(in: store).isEmpty)
    }

    @Test func aCheckInIsNotABriefingToo() throws {
        let store = store()
        let checkIn = try note(#"{"v":1,"k":"routine","x":"brief","t":"[redde-goal:g7] Run","b":"On track.","i":"job1","o":"g7","q":"1/3"}"#)
        #expect(!AgentBriefing.take(checkIn, in: store))
        #expect(AgentBriefing.take(try note(#"{"v":1,"k":"routine","x":"brief","t":"Evening wrap-up","b":"A quiet day.","i":"job2"}"#), in: store))
    }

    @Test func progressIsReadFromItsNote() {
        #expect(GoalReport.progress("3/7")! == (3, 7))
        #expect(GoalReport.progress("3 of 7")! == (3, 7))
        #expect(GoalReport.progress(" 0/0 ")! == (0, 0))
        #expect(GoalReport.progress("9/7")! == (7, 7), "never more done than there are")
        #expect(GoalReport.progress("three") == nil)
        #expect(GoalReport.progress("-1/4") == nil)
        #expect(GoalReport.progress(nil) == nil)
    }

    @Test func aJobsNameGivesTheGoal() {
        #expect(GoalReport.id(inJobName: "[redde-goal:g7] Run a 10K") == "g7")
        #expect(GoalReport.id(inJobName: "[bot:scout] [redde-goal:sp1] Spanish") == "sp1")
        #expect(GoalReport.id(inJobName: "[redde-watch:w1] Kettle") == nil)
        #expect(GoalReport.title(ofJobName: "[bot:scout] [redde-goal:sp1] Spanish for Madrid") == "Spanish for Madrid")
    }

    @Test func thePluginsListIsMergedOverWhatWasKept() throws {
        let store = store()
        GoalReport.take(try note(#"{"v":1,"k":"routine","x":"brief","t":"[redde-goal:g7] Run","b":"Newer words.","o":"g7","q":"2/7","at":5000}"#), in: store)
        GoalReport.take(try note(#"{"v":1,"k":"routine","x":"brief","t":"[redde-goal:old] Gone","b":"x","o":"old","q":"1/2","at":4000}"#), in: store)
        let listed = try #require(Goals.parse(list: """
            redde-push goals: [{"id":"g7","title":"Run a 10K","target":"2027-03-01","schedule":"0 9 * * 1","agent":"default",
             "steps":[{"title":"Plan","card_id":"k1","done":true},{"title":"Shoes","done":false}],
             "progress":{"done":1,"total":2,"headline":"Older words.","next":"Shoes","at":1000}}]
            """))
        #expect(listed.count == 1)
        #expect(listed[0].steps?.count == 2)
        #expect(listed[0].target != nil)
        GoalReport.merge(listed, in: store)
        let all = GoalReport.all(in: store)
        #expect(all["old"] == nil, "a goal the server no longer has is let go")
        let g7 = try #require(all["g7"])
        #expect((g7.done, g7.total) == (1, 2), "the plan's progress")
        #expect(g7.headline == "Newer words.", "a check-in heard since keeps its words")
        #expect(g7.steps?.first?.cardID == "k1")
        #expect(Goals.parse(list: "usage: hermes redde-push …") == nil, "an older plugin's answer")
    }

    @Test func anEndedGoalStaysEnded() throws {
        let store = store()
        GoalReport.take(try note(#"{"v":1,"k":"routine","x":"brief","t":"[redde-goal:g7] Run","b":"x","o":"g7","q":"1/2"}"#), in: store)
        GoalReport.end("g7", in: store)
        #expect(GoalReport.all(in: store).isEmpty)
        GoalReport.take(try note(#"{"v":1,"k":"routine","x":"brief","t":"[redde-goal:g7] Run","b":"x","o":"g7","q":"2/2"}"#), in: store)
        GoalReport.merge(jobs: [(id: "g7", job: "j", title: "Run", profile: nil)], in: store)
        #expect(GoalReport.all(in: store).isEmpty, "a late check-in or a job still listed doesn't bring it back")
    }

    @Test func theJobListAloneGivesTheGoalsOverTheHermesAPI() {
        let store = store()
        GoalReport.merge(jobs: [(id: "g1", job: "j1", title: "Learn to juggle", profile: nil)], in: store)
        #expect(GoalReport.all(in: store)["g1"]?.title == "Learn to juggle")
        #expect(GoalReport.all(in: store)["g1"]?.total == 0)
        GoalReport.merge(jobs: [], in: store)
        #expect(GoalReport.all(in: store).isEmpty, "its job gone, the goal goes")
    }

    @Test func checkInsDefaultToWeeklyAndEveryOtherDayWhenSoon() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 20)))
        func inDays(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: now)! }
        #expect(Goals.Schedule.suggested(by: nil, now: now, calendar: calendar) == .weekly)
        #expect(Goals.Schedule.suggested(by: inDays(13), now: now, calendar: calendar) == .everyOtherDay)
        #expect(Goals.Schedule.suggested(by: inDays(14), now: now, calendar: calendar) == .weekly)
        #expect(Goals.Schedule.suggested(by: inDays(90), now: now, calendar: calendar) == .weekly)
        #expect(Goals.Schedule.weekly.rawValue == "0 9 * * 1")
        #expect(Goals.Schedule.everyOtherDay.rawValue == "0 9 */2 * *")
        #expect(Goals.Schedule(job: " 0 9 * * 1") == .weekly)
        #expect(Goals.Schedule(job: "every 2h") == nil)
    }

    @Test func theAskWritesTheGoalOut() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let march = try #require(calendar.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 12)))
        let ask = Goals.ask(goal: "  Run a 10K ", by: march, schedule: .weekly, calendar: calendar)
        #expect(ask.hasPrefix("New goal: Run a 10K.\nBy Monday, March 1, 2027."))
        #expect(ask.contains("redde_goal"))
        #expect(ask.contains("every Monday at 9 in the morning"))
        #expect(!Goals.ask(goal: "Learn Spanish!", by: nil, schedule: .daily).contains("By "))
    }
}

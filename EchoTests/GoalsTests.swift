import Foundation
import Testing
import UserNotifications
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

    /// The plugin's own reply (`goals.listing`): `profile`, `by` and `card`, and from 1.35 each
    /// step's owner. Until 2026-11-22 the app read `agent`, `target` and `card_id`, so a bot's goal
    /// showed as the main agent's, with no date.
    @Test func thePluginsListIsReadAsItSaysIt() throws {
        let listed = try #require(Goals.parse(list: """
            redde-push goals [{"id":"g8","profile":"scout","title":"Read 20 books","by":"2027-01-31","every":"0 9 * * 1","job":"j8",
             "steps":[{"title":"Pick the list","card":"t1","who":"agent","done":true},{"title":"Read book 1","card":null,"who":"you","done":false},
                      {"title":"Read book 2","card":null,"who":"you","done":false}],
             "progress":{"done":0,"total":3,"headline":"Started.","next":"Read book 1","at":1000}}]
            """))
        let g8 = try #require(listed.first)
        #expect(g8.profile == "scout")
        #expect(g8.target != nil)
        #expect(g8.steps?.map(\.isYours) == [false, true, true])
        #expect(g8.steps?.first?.cardID == "t1")
        #expect((g8.done, g8.total) == (1, 3), "the plan's own count, the agent's finished card in it")
        #expect(g8.nextForYou?.index == 1)
    }

    /// A goal gone quiet (plugin 1.36): asked about, then paused; Keep Going takes the quiet off here.
    @Test func aQuietGoalIsReadAndKeptGoing() throws {
        let store = store()
        let listed = try #require(Goals.parse(list: """
            [{"id":"gq","profile":"default","title":"Learn piano","quiet":17,"asked":true,"faded":true,"steps":[]},
             {"id":"gn","profile":"default","title":"Run","quiet":0,"asked":false,"faded":false}]
            """))
        #expect(listed[0].quietDays == 17 && listed[0].faded == true && listed[0].goneQuiet)
        #expect(listed[1].quietDays == nil && listed[1].faded == nil && !listed[1].goneQuiet)
        GoalReport.merge(listed, in: store)
        GoalReport.keep("gq", in: store)
        #expect(GoalReport.all(in: store)["gq"]?.goneQuiet == false)
    }

    /// Don't Suggest This: the heading said to the plugin base64url, the list read back.
    @Test func notSuggestedIdeasTravelAsTheirHeadings() throws {
        let line = IdeasBlocked.line("block", "Book the vet for Pickles 🐶")
        #expect(line.hasPrefix("ideas block ") && !line.dropFirst(12).contains(" "))
        let back = try #require(PushSeal.data(base64URL: String(line.dropFirst(12))))
        #expect(String(decoding: back, as: UTF8.self) == "Book the vet for Pickles 🐶")
        let list = PushSeal.base64URL(Data(#"["Tidy the garage","Café"]"#.utf8))
        #expect(IdeasBlocked.parse("redde-push ideas blocked \(list)\n") == ["Tidy the garage", "Café"])
        #expect(IdeasBlocked.parse("usage: redde-push …") == nil, "an older plugin")
    }

    /// A check-in's notification names its goal, for a tap to open the goal's page.
    @Test func aCheckInsNotificationNamesItsGoal() throws {
        let content = UNMutableNotificationContent()
        #expect(try note(#"{"v":1,"k":"routine","x":"brief","t":"[redde-goal:g7] Run","b":"Two runs.","o":"g7","q":"2/7","p":"scout"}"#).fill(content))
        #expect(content.userInfo[PushNote.goalKey] as? String == "g7")
        let plain = UNMutableNotificationContent()
        #expect(try note(#"{"v":1,"k":"routine","t":"What to wear","b":"A coat.","p":"scout"}"#).fill(plain))
        #expect(plain.userInfo[PushNote.goalKey] == nil)
    }

    @Test func aStepTickedHereMovesTheCountAndTheNextStep() throws {
        let store = store()
        var goal = GoalReport(id: "g9", title: "Run", agent: "", done: 0, total: 2, headline: "", at: .now, failed: false,
                              steps: [.init(title: "Run 3K", done: false, who: "you"), .init(title: "Run 5K", done: false, who: "you")])
        GoalReport.merge([goal], in: store)
        GoalReport.setStep("g9", 0, done: true, in: store)
        goal = try #require(GoalReport.all(in: store)["g9"])
        #expect((goal.done, goal.total) == (1, 2))
        #expect(goal.nextForYou?.step.title == "Run 5K")
        GoalReport.setStep("g9", 0, done: false, in: store)
        #expect(GoalReport.all(in: store)["g9"]?.done == 0, "a tick taken back")
        // An older plugin's step: a card means it was the agent's, none that it's theirs.
        #expect(GoalReport.Step(title: "x", cardID: "k", done: false).isYours == false)
        #expect(GoalReport.Step(title: "x", done: false).isYours)
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

/// The goal's page as one plan (2026-11-22, "still not sure what to do with this goal screen":
/// a ring saying 1/7 over ten cards, eight struck through, the Blocked two last with no reason).
struct GoalPlanTests {
    private func card(_ id: String, _ status: String, _ at: Double = 0) -> KanbanTask {
        KanbanTask(.object(["id": .string(id), "title": .string("Card \(id)"), "status": .string(status),
                            "tenant": .string("redde-goal-g"), "created_at": .number(at)]))!
    }

    @Test func thePlanIsTheStepsInOrderAndTheRingCountsThem() {
        let steps: [GoalReport.Step] = [
            .init(title: "Research yeast", cardID: "a", done: false, who: "agent"),
            .init(title: "Buy bottles", done: true, who: "you"),
            .init(title: "Bottle it", done: false, who: "you"),
            .init(title: "Plan bottling", cardID: "b", done: false, who: "agent"),
        ]
        let cards = [card("a", "blocked", 1), card("b", "done", 2), card("rem", "done", 3), card("log", "done", 4),
                     card("ask", "review", 5), card("todo", "ready", 6)]
        let plan = GoalPlan(steps: steps, cards: cards)
        #expect(plan.isPlan)
        #expect(plan.waiting.map(\.id) == ["step-0", "ask"], "what waits on them, the plan's and the agent's own")
        #expect(plan.open.map(\.title) == ["Bottle it"])
        #expect(plan.done.map(\.title) == ["Buy bottles", "Plan bottling"], "a card done counts its step done")
        #expect(plan.extra.map(\.id) == ["todo", "rem", "log"], "the agent's own cards, open first, apart from the plan")
        #expect(plan.count?.done == 2 && plan.count?.total == 4, "the ring counts the plan, not the cards")
        #expect(plan.waiting.first?.step == 0 && plan.open.first?.step == 2, "rows keep their place in the steps for ticking")
    }

    @Test func withNoStepsTheCardsAreTheAgentsTasksAndTheRingIsLeftToTheCheckIn() {
        let plan = GoalPlan(steps: nil, cards: [card("x", "done", 2), card("y", "blocked", 1), card("z", "running", 3)])
        #expect(!plan.isPlan)
        #expect(plan.count == nil)
        #expect(plan.waiting.map(\.id) == ["y"])
        #expect(plan.open.map(\.id) == ["z"])
        #expect(plan.done.map(\.id) == ["x"])
    }

    @Test func overTheAPIWithNoBoardTheStepsStandAsReported() {
        let plan = GoalPlan(steps: [.init(title: "Agent's", cardID: "a", done: true, who: "agent"),
                                    .init(title: "Theirs", done: false, who: "you")], cards: nil)
        #expect(plan.done.map(\.title) == ["Agent's"])
        #expect(plan.open.map(\.title) == ["Theirs"])
        #expect(plan.waiting.isEmpty && plan.extra.isEmpty)
    }
}

/// The goal page's layouts (2026-11-25, "Build them. Trail first"): the Trail's stops, the Check-in
/// Log's entries, and plugin 1.47's log, notes, question and step dates read from its list.
struct GoalLayoutsTests {
    private func card(_ id: String, _ status: String, _ at: Double = 0) -> KanbanTask {
        KanbanTask(.object(["id": .string(id), "title": .string("Card \(id)"), "status": .string(status),
                            "tenant": .string("redde-goal-g"), "created_at": .number(at)]))!
    }

    @Test func theTrailFoldsWhatsLongDoneAndStopsWhereItWaits() {
        let steps: [GoalReport.Step] = [
            .init(title: "Plan", cardID: "p", done: true, who: "agent"),
            .init(title: "Shoes", done: true, who: "you"),
            .init(title: "5 km", done: true, who: "you"),
            .init(title: "Book", done: true, who: "you"),
            .init(title: "Pace", cardID: "a", done: false, who: "agent"),
            .init(title: "Long run", done: false, who: "you"),
            .init(title: "Race", done: false, who: "you"),
        ]
        let plan = GoalPlan(steps: steps, cards: [card("p", "done", 1), card("a", "blocked", 2), card("ask", "review", 3)])
        let trail = GoalTrail(plan, shown: 2)
        #expect(trail.folded.map(\.title) == ["Plan", "Shoes"], "the oldest done steps folded into one stop")
        #expect(trail.stops.map(\.id) == ["step-2", "step-3", "ask", "step-4", "step-5", "step-6"],
                "the agent's own card that waits on them where the trail has got to")
        #expect(trail.stops.map(\.kind) == [.done, .done, .waiting, .waiting, .next, .later])
        #expect(trail.here == 2)
        #expect(trail.finish == "step-6")
        #expect(GoalTrail(plan).folded.isEmpty, "four done and three shown: nothing worth folding one away")
    }

    @Test func daysLeftCountsWholeDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let late = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 23)))
        let early = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 1)))
        #expect(GoalTrail.daysLeft(to: early, now: late, calendar: calendar) == 1)
        #expect(GoalTrail.daysLeft(to: late, now: late, calendar: calendar) == 0)
        #expect(GoalTrail.daysLeft(to: late, now: early, calendar: calendar) == -1)
    }

    @Test func theLogIsNewestFirstWithNotesAndStepsDone() {
        var goal = GoalReport(id: "g", title: "Run", agent: "Sol", profile: "default", done: 1, total: 2,
                              headline: "Two runs.", at: Date(timeIntervalSince1970: 2_000), failed: false)
        goal.details = "Tuesday 4 km, Thursday 5 km."
        goal.steps = [.init(title: "Shoes", done: true, who: "you", at: Date(timeIntervalSince1970: 1_800)),
                      .init(title: "Plan", cardID: "p", done: true, who: "agent"),
                      .init(title: "Race", done: false, who: "you")]
        goal.checkins = [.init(at: Date(timeIntervalSince1970: 1_000), done: 0, total: 2, headline: "A plan."),
                         .init(at: Date(timeIntervalSince1970: 2_000), done: 1, total: 2, headline: "Two runs.")]
        goal.notes = [.init(at: Date(timeIntervalSince1970: 1_500), text: "Hills were hard")]
        let entries = GoalLog.entries(goal)
        #expect(entries.map(\.at.timeIntervalSince1970) == [2_000, 1_800, 1_500, 1_000])
        #expect(entries.first?.kind == .checkIn(.init(at: Date(timeIntervalSince1970: 2_000), done: 1, total: 2, headline: "Two runs.",
                                                      details: "Tuesday 4 km, Thursday 5 km.")),
                "the newest check-in has its whole report, as its note brought it")
        #expect(entries[1].kind == .step(title: "Shoes", yours: true), "a step done with no date isn't in the log")

        goal.checkins = nil
        goal.notes = nil
        goal.steps = nil
        #expect(GoalLog.entries(goal).map(\.at.timeIntervalSince1970) == [2_000], "an older plugin: the last check-in alone")
    }

    @Test func thePluginsLogNotesAndQuestionAreRead() throws {
        let listed = try #require(Goals.parse(list: """
            redde-push goals [{"id":"g9","profile":"default","title":"Run a 10K","steps":[
              {"title":"Shoes","who":"you","done":true,"at":1800},{"title":"Race","who":"you","done":false}],
             "progress":{"done":1,"total":2,"headline":"Two runs.","at":2000},
             "checkins":[{"done":0,"total":2,"headline":"A plan.","next":"Shoes","at":1000},{"done":1,"total":2,"headline":"Two runs.","at":2000},
                         {"headline":"no time"}],
             "notes":[{"at":1500,"text":"Hills were hard"},{"at":2100,"text":"Sunday","q":"Saturday or Sunday?"},{"at":2200,"text":""}],
             "question":{"q":"Which pace?","choices":["6:00","5:40"],"at":2000}}]
            """))
        let g = try #require(listed.first)
        #expect(g.steps?.map(\.at) == [Date(timeIntervalSince1970: 1_800), nil])
        #expect(g.checkins?.map(\.headline) == ["A plan.", "Two runs."], "a check-in with no time is dropped")
        #expect(g.checkins?.first?.next == "Shoes")
        #expect(g.notes?.map(\.text) == ["Hills were hard", "Sunday"], "an empty note is dropped")
        #expect(g.notes?.last?.question == "Saturday or Sunday?")
        #expect(g.question == .init(text: "Which pace?", choices: ["6:00", "5:40"]))

        let one = try #require(Goals.parse(list: #"[{"id":"g1","title":"T","question":{"q":"Only one?","choices":["Yes"]}}]"#)?.first)
        #expect(one.question == nil, "a question needs two choices")
        let old = try #require(Goals.parse(list: #"[{"id":"g2","title":"T"}]"#)?.first)
        #expect(old.checkins == nil && old.notes == nil && old.question == nil, "an older plugin's list")
    }

    @Test func anAnswerEndsTheQuestionAndIsKeptInTheLog() {
        var goal = GoalReport(id: "g", title: "Run", agent: "Sol", profile: nil, done: 0, total: 0, headline: "", at: .now, failed: false)
        goal.question = .init(text: "Which pace?", choices: ["6:00", "5:40"])
        goal.told(.init(at: .now, text: "I ran 4 km"))
        #expect(goal.question != nil, "a note isn't an answer")
        goal.told(.init(at: .now, text: "6:00", question: "Which pace?"))
        #expect(goal.question == nil)
        #expect(goal.notes?.map(\.text) == ["I ran 4 km", "6:00"])
    }
}

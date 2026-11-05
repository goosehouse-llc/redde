import Foundation
import Testing
import UserNotifications
@testable import Echo

/// Briefings (Redde's plugin 1.9: a `[redde-notify]` job's answer, its note marked `x` "brief";
/// asked 2026-10-28): kept whole on the phone, newest first; a bot's own schedule isn't one.
struct AgentBriefingsTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "briefings-\(UUID().uuidString)")! }

    /// What `core.routine_note` sends, opened.
    private func note(_ title: String, _ body: String, brief: Bool = true, at: Double = Date.now.timeIntervalSince1970, job: String = "job1") throws -> PushNote {
        var json: [String: Any] = ["v": 1, "k": "routine", "at": at, "n": "dchermes", "p": "default", "d": "Sol", "t": title, "b": body]
        if brief { json["x"] = "brief"; json["i"] = job }
        return try JSONDecoder().decode(PushNote.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func aBriefingIsKeptWholeAndABotsScheduleIsNot() throws {
        let store = defaults()
        #expect(!AgentBriefing.take(try note("What to wear", "A coat.", brief: false), in: store), "a bot's schedule is in its chat")
        let long = String(repeating: "Lots happened today. ", count: 40)
        #expect(AgentBriefing.take(try note("Evening wrap-up", long, at: 1_800_000_000), now: Date(timeIntervalSince1970: 1_800_000_100), in: store))
        #expect(AgentBriefing.take(try note("Heads-up: Dentist", "Bring the card.", at: 1_800_000_050), now: Date(timeIntervalSince1970: 1_800_000_100), in: store))
        let kept = AgentBriefing.all(in: store, now: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(kept.map(\.heading) == ["Dentist", "Evening wrap-up"], "newest first; a heads-up by its event")
        #expect(kept.last?.text == long && kept.first?.isHeadsUp == true && kept.first?.agent == "Sol")
        // The same run again (a notification delivered twice) adds nothing.
        AgentBriefing.take(try note("Heads-up: Dentist", "Bring the card.", at: 1_800_000_050), in: store)
        #expect(AgentBriefing.all(in: store, now: Date(timeIntervalSince1970: 1_800_000_100)).count == 2)
        AgentBriefing.markRead(kept[0].id, in: store)
        #expect(AgentBriefing.all(in: store, now: Date(timeIntervalSince1970: 1_800_000_100)).first?.read == true)
        #expect(AgentBriefing.all(in: store, now: Date(timeIntervalSince1970: 1_800_000_000 + 8 * 86_400)).isEmpty, "a week, then gone")
    }

    /// One card a job in the deck, its newest run, with the earlier ones unread under it; Done
    /// reads them all (2026-11-05: a check every four hours stacked six cards a day).
    @Test func aJobsRunsAreOneCardInTheDeck() throws {
        let store = defaults()
        let t0 = 1_800_000_000.0
        for hour in 0..<3 { AgentBriefing.take(try note("Strata check", "Run \(hour).", at: t0 + Double(hour) * 3600, job: "strata"), now: Date(timeIntervalSince1970: t0), in: store) }
        AgentBriefing.take(try note("Evening wrap-up", "Done: the vet.", at: t0 + 600, job: "wrap"), now: Date(timeIntervalSince1970: t0), in: store)
        let now = Date(timeIntervalSince1970: t0 + 3 * 3600)
        let deck = AgentBriefing.deck(AgentBriefing.all(in: store, now: now), now: now)
        #expect(deck.map(\.briefing.text) == ["Run 2.", "Done: the vet."])
        #expect(deck.map(\.earlier) == [2, 0])
        AgentBriefing.markJobRead(deck[0].briefing.jobKey, in: store)
        #expect(AgentBriefing.deck(AgentBriefing.all(in: store, now: now), now: now).map(\.briefing.text) == ["Done: the vet."])
        #expect(AgentBriefing.all(in: store, now: now).count == 4, "read, they stay in All Briefings")
    }

    @Test func aJobKeepsItsLastFiveRuns() throws {
        let store = defaults()
        let t0 = 1_800_000_000.0
        for run in 0..<8 { AgentBriefing.take(try note("Strata check", "Run \(run).", at: t0 + Double(run) * 60, job: "strata"), now: Date(timeIntervalSince1970: t0), in: store) }
        AgentBriefing.take(try note("Evening wrap-up", "Done.", at: t0, job: "wrap"), now: Date(timeIntervalSince1970: t0), in: store)
        let kept = AgentBriefing.all(in: store, now: Date(timeIntervalSince1970: t0 + 600))
        #expect(kept.filter { $0.job == "strata" }.map(\.text) == ["Run 7.", "Run 6.", "Run 5.", "Run 4.", "Run 3."])
        #expect(kept.contains { $0.job == "wrap" }, "another job's run isn't pushed out")
    }

    /// Old ones leave the deck by themselves: a heads-up once its event is under way, the rest after a day.
    @Test func oldCardsLeaveTheDeck() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var headsUp = AgentBriefing(id: "h/1", title: "Heads-up: Dentist", agent: "Sol", text: "Bring the card.", at: t0, failed: false)
        headsUp.eventAt = t0.addingTimeInterval(3600)
        let brief = AgentBriefing(id: "b/1", title: "Morning brief", agent: "Sol", text: "Three meetings.", at: t0, failed: false)
        let week = AgentBriefing(id: "w/1", title: "Week ahead", agent: "Sol", text: "A heavy Friday.", at: t0, failed: false)
        #expect(!headsUp.isOver(at: t0.addingTimeInterval(3600 + 29 * 60)) && headsUp.isOver(at: t0.addingTimeInterval(3600 + 31 * 60)))
        #expect(!brief.isOver(at: t0.addingTimeInterval(23 * 3600)) && brief.isOver(at: t0.addingTimeInterval(25 * 3600)))
        #expect(!week.isOver(at: t0.addingTimeInterval(3 * 86_400)))
        let later = t0.addingTimeInterval(25 * 3600)
        #expect(AgentBriefing.deck([headsUp, brief, week], now: later).map(\.briefing.id) == ["w/1"])
    }

    /// Don't Show: a hidden job's runs aren't kept; Drawer Only's are, quietly.
    @Test func aHiddenJobsRunsArentKept() throws {
        let store = defaults()
        let strata = try note("Strata check", "No change.", job: "strata")
        #expect(JobNotices.jobKey(of: strata) == "default|strata")
        JobNotices.set(.hidden, for: "default|strata", title: "Strata check", in: store)
        #expect(!AgentBriefing.take(strata, in: store))
        #expect(AgentBriefing.all(in: store).isEmpty)
        #expect(JobNotices.hidden(in: store).keys.sorted() == ["default|strata"])
        JobNotices.set(.drawerOnly, for: "default|strata", title: "Strata check", in: store)
        #expect(AgentBriefing.take(strata, in: store))
        #expect(JobNotices.hidden(in: store).isEmpty && JobNotices.choice(for: "default|strata", in: store) == .drawerOnly)
        JobNotices.set(.notify, for: "default|strata", title: "", in: store)
        #expect(JobNotices.load(store).isEmpty, "the default isn't stored")
        #expect(JobNotices.muteKey("default|strata") == "j:default|strata", "as the plugin's routines.job_mute names it")
    }

    /// Today or Updates in the deck.
    @Test func theDaysOwnAreTodayAndChecksAreUpdates() {
        func briefing(_ title: String) -> AgentBriefing { AgentBriefing(id: "x/1", title: title, agent: "Sol", text: "…", at: .now, failed: false) }
        #expect(["Evening wrap-up", "Week ahead", "Heads-up: Dentist", "Daily meeting brief", "Morning check-in"].allSatisfy { briefing($0).isAboutTheDay })
        #expect(!["Strata Mac Qwen3.6 Monitor", "UniFi price check", "Backups"].contains { briefing($0).isAboutTheDay })
    }

    /// Its notification names it a briefing, so a tap opens it.
    @Test func itsNotificationOpensBriefings() throws {
        let content = UNMutableNotificationContent()
        #expect(try note("Evening wrap-up", "Done: the vet.").fill(content))
        #expect(content.userInfo[PushNote.taskKey] as? String == "brief")
        #expect(content.title == "Evening wrap-up")
    }

    /// A page's choice is kept in its job's prompt, and read back from it.
    @Test func aHeadsUpsLeadIsReadBackFromItsJob() throws {
        let daily = HeadsUps.job
        let listed: (String) throws -> CronJob = { prompt in
            try #require(CronJob(.object(["id": .string("j"), "name": .string(HeadsUps.name), "schedule": .string("30 6 * * *"),
                                          "prompt_preview": .string(String(prompt.prefix(100)))])))
        }
        let job = try listed(daily.prompt(15))
        #expect(daily.option(in: job) == 15, "read from the preview a list sends")
        #expect(daily.option(in: try listed("Something else")) == 45, "else the default: time enough to work out leaving")
        let time = try #require(DailyJob.time(of: job))
        #expect(time.hour == 6 && time.minute == 30)
        #expect(daily.prompt(45).contains("minutes 45"))
        #expect(EveningWrapUp.name.hasPrefix("[redde-notify] "), "its answer reaches the phone")
        #expect(!HeadsUps.name.hasPrefix("[redde-notify]"), "the morning's planning says nothing itself")
    }
}

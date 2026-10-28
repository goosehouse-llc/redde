import Foundation
import Testing
import UserNotifications
@testable import Echo

/// Briefings (Redde's plugin 1.9: a `[redde-notify]` job's answer, its note marked `x` "brief";
/// asked 2026-10-28): kept whole on the phone, newest first; a bot's own schedule isn't one.
struct AgentBriefingsTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "briefings-\(UUID().uuidString)")! }

    /// What `core.routine_note` sends, opened.
    private func note(_ title: String, _ body: String, brief: Bool = true, at: Double = Date.now.timeIntervalSince1970) throws -> PushNote {
        var json: [String: Any] = ["v": 1, "k": "routine", "at": at, "n": "dchermes", "p": "default", "d": "Sol", "t": title, "b": body]
        if brief { json["x"] = "brief"; json["i"] = "job1" }
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
        let job = try listed(daily.prompt(45))
        #expect(daily.option(in: job) == 45, "read from the preview a list sends")
        #expect(daily.option(in: try listed("Something else")) == 30)
        let time = try #require(DailyJob.time(of: job))
        #expect(time.hour == 6 && time.minute == 30)
        #expect(daily.prompt(45).contains("minutes 45"))
        #expect(EveningWrapUp.name.hasPrefix("[redde-notify] "), "its answer reaches the phone")
        #expect(!HeadsUps.name.hasPrefix("[redde-notify]"), "the morning's planning says nothing itself")
    }
}

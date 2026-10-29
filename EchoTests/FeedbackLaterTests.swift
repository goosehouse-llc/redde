import Foundation
import Testing
@testable import Echo

/// More Like This / Fewer Like This and Later (asked 2026-10-28, "Proactive"): what the person said
/// goes into the prompts of the jobs that make ideas, heads-ups and briefings; an idea or a
/// briefing put off leaves the list and comes back at its time.
struct FeedbackLaterTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "feedback-\(UUID().uuidString)")! }

    @Test func whatWasSaidIsKeptNewestFirstAndTheLastWordWins() {
        let store = defaults()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AgentFeedback.note(for: [.idea], in: store, now: start) == nil, "nothing said, nothing added")
        AgentFeedback.record(.idea, title: "Book the vet", agent: "Sol", liked: true, now: start, in: store)
        AgentFeedback.record(.idea, title: "Turn the heating down", agent: "Home", liked: false, now: start, in: store)
        AgentFeedback.record(.idea, title: "book the vet ", agent: "Sol", liked: false, now: start.addingTimeInterval(1), in: store)
        let kept = AgentFeedback.all(in: store, now: start)
        #expect(kept.count == 2 && kept.first?.liked == false, "the same idea again: the last word")
        let note = AgentFeedback.note(for: [.idea], in: store, now: start)
        #expect(note == "What the user said of earlier ones (let it guide what you choose; don't mention it): Ideas they wanted fewer like: \"book the vet\", \"Turn the heating down\".")
        #expect(AgentFeedback.note(for: [.briefing], in: store, now: start) == nil, "each job hears its own")
        for n in 0 ..< 12 { AgentFeedback.record(.idea, title: "Liked \(n)", agent: "Sol", liked: true, now: start.addingTimeInterval(Double(10 + n)), in: store) }
        let liked = AgentFeedback.all(in: store, now: start).filter(\.liked)
        #expect(liked.count == AgentFeedback.most && liked.first?.title == "Liked 11", "the newest few each way")
        #expect(AgentFeedback.all(in: store, now: start.addingTimeInterval(31 * 86_400)).isEmpty, "a month, then gone")
    }

    @Test func aJobsPromptCarriesItAfterItsOwnOpening() {
        let store = NeedsYou.shared
        let before = store?.data(forKey: "agentFeedback")
        defer { store?.set(before, forKey: "agentFeedback") }
        AgentFeedback.clear()
        #expect(HeadsUps.job.fullPrompt(15) == HeadsUps.prompt(minutes: 15))
        AgentFeedback.record(.headsUp, title: "Gym", agent: "Sol", liked: false)
        let prompt = HeadsUps.job.fullPrompt(15)
        #expect(prompt.hasPrefix(HeadsUps.prompt(minutes: 15)) && prompt.hasSuffix("Heads-ups they didn't need: \"Gym\"."))
        #expect(!MorningIdeas.job.fullPrompt(0).contains("Heads-ups they"), "the ideas job doesn't hear of heads-ups")
        #expect(FeedbackFold.jobs.allSatisfy { !$0.heard.isEmpty })
    }

    @Test func laterTimesMakeSense() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // A Wednesday, 10:15.
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 10, minute: 15)))
        #expect(Later.thisEvening.date(from: morning, calendar: calendar).map { calendar.component(.hour, from: $0) } == 18)
        let tomorrow = try #require(Later.tomorrowMorning.date(from: morning, calendar: calendar))
        #expect(calendar.component(.day, from: tomorrow) == 29 && calendar.component(.hour, from: tomorrow) == 8)
        let weekend = try #require(Later.thisWeekend.date(from: morning, calendar: calendar))
        #expect(calendar.component(.weekday, from: weekend) == 7 && calendar.component(.hour, from: weekend) == 9, "Saturday at 9")
        let evening = try #require(calendar.date(bySettingHour: 20, minute: 0, second: 0, of: morning))
        #expect(Later.thisEvening.date(from: evening, calendar: calendar) == nil, "not 'this evening' in the evening")
        let saturday = try #require(calendar.date(byAdding: .day, value: 3, to: morning))
        #expect(Later.thisWeekend.date(from: saturday, calendar: calendar) == nil)
    }

    @Test func anIdeaPutOffLeavesTheDeckAndComesBackFirst() throws {
        let store = defaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json: [String: Any] = ["v": 1, "k": "ideas", "at": 1_800_000_000, "p": "default", "d": "Sol", "i": "offer",
                                   "y": [["t": "Book the vet", "r": "Book the vet"], ["t": "Call the plumber", "r": "Call the plumber"]]]
        let note = try JSONDecoder().decode(PushNote.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(AgentIdea.take(note, now: now, in: store))
        let vet = try #require(AgentIdea.all(in: store, now: now).first { $0.title == "Book the vet" })
        AgentIdea.snooze(vet.id, until: now.addingTimeInterval(3600), in: store)
        #expect(AgentIdea.showing(in: store, now: now).map(\.title) == ["Call the plumber"])
        #expect(AgentIdea.nextBack(in: store, now: now) == now.addingTimeInterval(3600))
        #expect(AgentIdea.showing(in: store, now: now.addingTimeInterval(3601)).map(\.title) == ["Book the vet", "Call the plumber"], "back, on top")
        #expect(AgentIdea.nextBack(in: store, now: now.addingTimeInterval(3601)) == nil)
        // Put off past the three days an idea is kept: kept until it is back, and three days after.
        AgentIdea.snooze(vet.id, until: now.addingTimeInterval(4 * 86_400), in: store)
        #expect(AgentIdea.showing(in: store, now: now.addingTimeInterval(4 * 86_400 + 60)).first?.title == "Book the vet")
    }

    @Test func aBriefingPutOffComesBackUnread() throws {
        let store = defaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json: [String: Any] = ["v": 1, "k": "routine", "at": 1_800_000_000, "d": "Sol", "t": "Week ahead", "b": "Busy.", "x": "brief", "i": "w"]
        #expect(AgentBriefing.take(try JSONDecoder().decode(PushNote.self, from: JSONSerialization.data(withJSONObject: json)), now: now, in: store))
        var week = try #require(AgentBriefing.all(in: store, now: now).first)
        #expect(week.feedback?.topic == .briefing && week.feedback?.title == "Week ahead")
        AgentBriefing.markRead(week.id, in: store)
        AgentBriefing.snooze(week.id, until: now.addingTimeInterval(600), in: store)
        week = try #require(AgentBriefing.all(in: store, now: now).first)
        #expect(!week.showing(at: now) && week.showing(at: now.addingTimeInterval(601)) && !week.read)
        #expect(week.shownAt == now.addingTimeInterval(600))
    }
}

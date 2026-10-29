import Foundation
import UserNotifications

/// Puts what the person said of ideas, heads-ups and briefings (`AgentFeedback`), and their day's
/// health if they share it (`HealthSummary`), into the prompts of the jobs that make them, on
/// whichever connection has scheduled jobs. A little after the last
/// word, so a few in a row make one change; again when Redde comes forward if that one didn't take.
@MainActor
enum FeedbackFold {
    /// The jobs that hear it, each with what it hears.
    static var jobs: [DailyJob] { [MorningIdeas.job, RoutineSuggestions.job, HeadsUps.job, EveningWrapUp.job, WeekAhead.job] }
    private static let owedKey = "feedbackOwed"
    /// Bumped when Redde words those jobs anew (2026-10-29: ideas written out when the tool can't be
    /// called, the week ahead in a shape drawn as a calendar), so the jobs already on Hermes are said
    /// again once, the next time Redde comes forward.
    static let wording = 2
    private static let wordingKey = "dailyJobsWording"
    private static var pending: Task<Void, Never>?

    static func said(_ topic: AgentFeedback.Topic, title: String, agent: String, liked: Bool) {
        AgentFeedback.record(topic, title: title, agent: agent, liked: liked)
        UserDefaults.standard.set(true, forKey: owedKey)
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await fold()
        }
    }

    /// Redde came forward: a change that didn't take, tried again.
    static func cameForward() {
        if UserDefaults.standard.integer(forKey: wordingKey) < wording { UserDefaults.standard.set(true, forKey: owedKey) }
        guard UserDefaults.standard.bool(forKey: owedKey), pending == nil else { return }
        pending = Task { await fold() }
    }

    /// Each of those jobs that is on, its prompt said again with what the person said.
    static func fold() async {
        defer { pending = nil }
        guard let backend = CronBackend.current(), let listed = try? await backend.list() else { return }
        var failed = false
        for daily in jobs where !daily.heard.isEmpty || daily.health {
            guard let job = listed.first(where: { $0.name == daily.name }) else { continue }
            let time = DailyJob.time(of: job) ?? (daily.hour, daily.minute)
            do {
                try await daily.set(at: time.hour, time.minute, option: daily.option(in: job), replacing: job)
            } catch {
                failed = true
            }
        }
        if !failed {
            UserDefaults.standard.set(false, forKey: owedKey)
            UserDefaults.standard.set(wording, forKey: wordingKey)
        }
    }
}

/// An idea or a briefing put off ("Later"): a quiet notification when it comes back, so the person
/// knows to look; gone if it is dealt with first.
enum LaterReminder {
    static let prefix = "redde.later."

    static func idea(_ idea: AgentIdea, at when: Date) {
        let content = UNMutableNotificationContent()
        content.title = idea.agent.isEmpty ? String(localized: "An idea, back") : String(localized: "\(idea.agent)'s idea, back")
        content.body = idea.title
        add(content, id: idea.id, at: when)
    }

    static func briefing(_ briefing: AgentBriefing, at when: Date) {
        let content = UNMutableNotificationContent()
        content.title = briefing.heading
        content.body = String(PlainText.display(briefing.text).prefix(180))
        content.userInfo = [PushNote.taskKey: "brief"]
        add(content, id: briefing.id, at: when)
    }

    static func cancel(_ id: String, center: UNUserNotificationCenter = .current()) {
        center.removePendingNotificationRequests(withIdentifiers: [prefix + id])
    }

    private static func add(_ content: UNMutableNotificationContent, id: String, at when: Date,
                            center: UNUserNotificationCenter = .current()) {
        content.threadIdentifier = "redde.later"
        content.interruptionLevel = .passive
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
        center.add(UNNotificationRequest(identifier: prefix + id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }
}

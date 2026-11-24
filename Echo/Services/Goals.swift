import Foundation
import Observation
import SwiftUI

/// Goals (2.4, asked 2026-11-02 after Meta's Muse): the person names a goal, in any chat or in the
/// New Goal sheet, and an agent makes a plan of it (cards on the Hermes Kanban board, waiting in
/// Triage until the person approves them) and checks in on a schedule. Redde's plugin 1.15
/// (`goals.py`, its `redde_goal` tool) keeps the goal; this side shows it: a progress card atop
/// the chat list from what the check-ins said (`GoalReport`, in the app group, so the list never
/// asks the server), and the goal's page, which does. Never "goal" alone as a command or a tool's
/// name: Hermes has a `/goal` of its own.
enum Goals {
    /// A goal's check-in, by how often. 9:00 in the server's time, as Redde's other daily jobs.
    enum Schedule: String, CaseIterable, Identifiable, Sendable {
        case daily = "0 9 * * *"
        case everyOtherDay = "0 9 */2 * *"
        case twiceAWeek = "0 9 * * 1,4"
        case weekly = "0 9 * * 1"
        var id: String { rawValue }

        var label: String {
            switch self {
            case .daily: String(localized: "Every morning", comment: "How often a goal's agent checks in")
            case .everyOtherDay: String(localized: "Every other day", comment: "How often a goal's agent checks in")
            case .twiceAWeek: String(localized: "Mondays and Thursdays", comment: "How often a goal's agent checks in")
            case .weekly: String(localized: "Every Monday", comment: "How often a goal's agent checks in")
            }
        }

        /// How it is put to the agent, in English as the rest of the ask.
        var spoken: String {
            switch self {
            case .daily: "every morning at 9"
            case .everyOtherDay: "every other day at 9 in the morning"
            case .twiceAWeek: "on Mondays and Thursdays at 9 in the morning"
            case .weekly: "every Monday at 9 in the morning"
            }
        }

        /// His pick (2026-11-02): weekly on Monday mornings; every other day for a goal less than
        /// two weeks away.
        static func suggested(by target: Date?, now: Date = .now, calendar: Calendar = .current) -> Schedule {
            guard let target else { return .weekly }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target)).day ?? .max
            return days < 14 ? .everyOtherDay : .weekly
        }

        /// The choice a job's schedule is, if it is one of these.
        init?(job schedule: String) {
            let trimmed = schedule.trimmingCharacters(in: .whitespaces)
            guard let found = Self.allCases.first(where: { $0.rawValue == trimmed }) else { return nil }
            self = found
        }
    }

    /// The Kanban tenant a goal's plan cards are made under (`goals.py`).
    static func tenant(_ id: String) -> String { "redde-goal-" + id }

    /// What is sent to set a goal up, from the New Goal sheet: the person's words, written out so
    /// the plugin's note (and any agent without it) knows what to do with them.
    static func ask(goal: String, by target: Date?, schedule: Schedule, calendar: Calendar = .current) -> String {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let ending = goal.last.map { ".!?".contains($0) } == true ? goal : goal + "."
        var lines = ["New goal: \(ending)"]
        if let target {
            let style = Date.FormatStyle(locale: Locale(identifier: "en_US"), calendar: calendar).weekday(.wide).month(.wide).day().year()
            lines.append("By \(target.formatted(style)).")
        }
        lines.append("Set it up as a goal with redde_goal: make a plan of steps, saying which are mine to do and which are yours, "
                     + "and check in with me \(schedule.spoken) on how it's going. Show me the plan first.")
        return lines.joined(separator: "\n")
    }

    /// The Dashboard's `/redde-push goals list`: its JSON, one goal each. Nil for anything else (a
    /// plugin older than 1.15 answers with its usage).
    static func parse(list output: String) -> [GoalReport]? {
        guard let start = output.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(output[start...].utf8)) else { return nil }
        let goals = json.array ?? json["goals"]?.array ?? []
        return goals.compactMap { g -> GoalReport? in
            guard let id = g["id"]?.string, !id.isEmpty else { return nil }
            let progress = g["progress"]
            // (The plugin says `card`, `profile` and `by`; this read `card_id`, `agent` and `target`
            // until 2026-11-22, so a bot's goal showed as the main agent's and with no date.)
            let steps = (g["steps"]?.array ?? []).compactMap { s -> GoalReport.Step? in
                guard let title = s["title"]?.string, !title.isEmpty else { return nil }
                return GoalReport.Step(title: title, cardID: (s["card"] ?? s["card_id"])?.string?.nilIfEmpty, done: s["done"]?.bool ?? false,
                                       who: s["who"]?.string)
            }
            // The plan's own count where there is one (the person's ticks and the board's cards, plugin
            // 1.35), else what the last check-in said.
            let done = steps.isEmpty ? progress?["done"]?.int ?? 0 : steps.filter(\.done).count
            let total = steps.isEmpty ? progress?["total"]?.int ?? 0 : steps.count
            let agent = (g["profile"] ?? g["agent"])?.string ?? ""
            // The main agent's name is the app's (`GoalCard`); a bot's as the roster has it.
            let name = agent.isEmpty || agent == "default" ? "" : BotRoutines.botName(agent) ?? agent
            return GoalReport(id: id, title: g["title"]?.string ?? "", agent: name,
                              profile: agent.isEmpty ? nil : agent, done: min(done, total), total: total,
                              headline: progress?["headline"]?.string ?? "", next: progress?["next"]?.string?.nilIfEmpty,
                              details: progress?["details"]?.string?.nilIfEmpty,
                              at: CronJob.date(progress?["at"]) ?? .distantPast, failed: false, job: g["job"]?.string,
                              target: date(g["by"] ?? g["target"]), steps: steps.isEmpty ? nil : steps,
                              quietDays: g["quiet"]?.int.flatMap { $0 > 0 ? $0 : nil }, faded: g["faded"]?.bool == true ? true : nil)
        }
    }

    /// A target as the plugin keeps it: a day ("2027-03-01"), or a time.
    static func date(_ v: JSONValue?) -> Date? {
        if let day = v?.string, day.count == 10 {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: day)
        }
        return CronJob.date(v)
    }

    /// Goals' check-in jobs in a job list: the goal, the job, the goal's words, whose store.
    static func jobs(in list: [CronJob]) -> [(id: String, job: String, title: String, profile: String?)] {
        list.compactMap { job in
            guard let id = GoalReport.id(inJobName: job.name) else { return nil }
            return (id, job.id, GoalReport.title(ofJobName: job.name), job.profile)
        }
    }

    /// The server's goals, as well as this connection can say: on the Dashboard the plugin's list
    /// (plan and progress), over the Hermes API the check-in jobs alone. Kept in the app group for
    /// the chat list. The jobs come back for the goal's page.
    @MainActor
    @discardableResult
    static func refresh() async -> [CronJob] {
        #if DEBUG
        if demo { return demoJobs }
        #endif
        let backend = CronBackend.current()
        let jobs = (try? await backend?.list()) ?? []
        var listed = false
        if HermesServeClient.shared.hasCredentials, Settings.shared.serveBaseURL != nil,
           let output = try? await PushService.command(over: .shared)("goals list"), let goals = parse(list: output) {
            GoalReport.merge(goals)
            listed = true
        }
        if !listed, backend != nil { GoalReport.merge(jobs: Goals.jobs(in: jobs)) }
        GoalsInbox.shared.reload()
        return jobs
    }

    /// The person ticked one of their steps (or took the tick back): shown at once, then said to
    /// the plugin (1.35: `goals step <profile> <goal> <n> done|undo`), over either connection. Nil
    /// when it was said; else why not, the tick taken back here.
    @MainActor
    static func tick(_ goal: GoalReport, step index: Int, done: Bool) async -> String? {
        GoalsInbox.shared.setStep(goal.id, index, done: done)
        #if DEBUG
        if demo { return nil }
        #endif
        let line = "goals step \(goal.profile ?? "default") \(goal.id) \(index + 1) \(done ? "done" : "undo")"
        let reply = try? await PushService.command(over: .shared)(line)
        if reply?.hasPrefix("redde-push goals step ") == true { return nil }
        GoalsInbox.shared.setStep(goal.id, index, done: !done)
        return reply == nil
            ? String(localized: "Couldn't reach your Hermes. Try again in a moment.", comment: "A goal's step couldn't be ticked: the server didn't answer")
            : String(localized: "Ticking steps off takes the Redde plugin 1.35: update it in Settings › Redde Plugin.", comment: "A goal's step couldn't be ticked: the plugin is too old")
    }

    /// Keep Going on a goal that went quiet (plugin 1.36: `goals keep <profile> <goal>`): its quiet
    /// starts again and paused check-ins run again. Nil when it was said; else why not.
    @MainActor
    static func keep(_ goal: GoalReport) async -> String? {
        #if DEBUG
        if demo { GoalsInbox.shared.kept(goal.id); return nil }
        #endif
        let reply = try? await PushService.command(over: .shared)("goals keep \(goal.profile ?? "default") \(goal.id)")
        if reply?.hasPrefix("redde-push goals kept ") == true {
            GoalReport.keep(goal.id)
            GoalsInbox.shared.reload()
            return nil
        }
        return reply == nil
            ? String(localized: "Couldn't reach your Hermes. Try again in a moment.", comment: "A goal's step couldn't be ticked: the server didn't answer")
            : String(localized: "Keeping a quiet goal going takes the Redde plugin 1.36: update it in Settings › Redde Plugin.", comment: "Keep Going on a quiet goal didn't work: the plugin is too old")
    }

    /// The goal's check-in job in a list.
    static func job(of goal: GoalReport, in jobs: [CronJob]) -> CronJob? {
        jobs.first { $0.id == goal.job } ?? jobs.first { GoalReport.id(inJobName: $0.name) == goal.id }
    }

    #if DEBUG
    /// `-echo.demoGoals`: two made-up goals, for screenshots.
    static var demo: Bool { DevHooks.has("-echo.demoGoals") }

    static let demoGoals: [GoalReport] = [
        GoalReport(id: "g10k", title: "Run a 10K by March", agent: "Sol", profile: "default", done: 3, total: 7,
                   headline: "Three runs this week, the long one at 6 km.", next: "Book the Riverside 10K before early entry closes Friday",
                   details: """
                   Your pace is coming down on the easy runs, and Thursday's hills felt **easier** than last week's.

                   | Run | Distance | Pace |
                   |---|---|---|
                   | Tuesday | 4 km | 6:12 /km |
                   | Thursday | 4.5 km, hills | 6:30 /km |
                   | Sunday | 6 km | 6:05 /km |

                   - Rest day tomorrow; your calves were tight on Sunday.
                   - Early entry for the Riverside 10K is $35 until Friday, $45 after.
                   """,
                   at: .now.addingTimeInterval(-3_600 * 5), failed: false, job: "jg10k",
                   target: Calendar.current.date(byAdding: .day, value: 118, to: .now),
                   steps: [.init(title: "Pick a 12-week plan", cardID: "k1", done: true, who: "agent"),
                           .init(title: "Get fitted for running shoes", done: true, who: "you"),
                           .init(title: "First 5 km without stopping", done: true, who: "you"),
                           .init(title: "Find the Riverside 10K's early entry", cardID: "k4", done: false, who: "agent"),
                           .init(title: "Long run at 8 km", done: false, who: "you"),
                           .init(title: "Taper week", done: false, who: "you"),
                           .init(title: "Race day", done: false, who: "you")]),
        GoalReport(id: "gspanish", title: "Order dinner in Spanish in Madrid", agent: "Scout", profile: "scout", done: 1, total: 5,
                   headline: "Day 12 of the app streak; the menu words are next.", next: "Twenty minutes on food words tonight",
                   at: .now.addingTimeInterval(-86_400 * 2), failed: false, job: "jgspanish",
                   target: Calendar.current.date(byAdding: .day, value: 11, to: .now)),
    ]

    static var demoJobs: [CronJob] {
        [CronJob(.object(["id": .string("jg10k"), "name": .string("[redde-goal:g10k] Run a 10K by March"),
                          "schedule": .string(Schedule.weekly.rawValue), "prompt": .string("Check in on the goal."), "enabled": .bool(true),
                          "next_run_at": .number(Date.now.addingTimeInterval(86_400 * 3).timeIntervalSince1970)])),
         CronJob(.object(["id": .string("jgspanish"), "name": .string("[redde-goal:gspanish] Order dinner in Spanish in Madrid"),
                          "schedule": .string(Schedule.everyOtherDay.rawValue), "prompt": .string("Check in on the goal."), "enabled": .bool(true),
                          "profile": .string("scout")]))].compactMap(\.self)
    }
    #endif
}

/// The goals on this device, for the chat list: read from the app group only (never the
/// network), again when Redde comes to the front and when a check-in arrives with it open.
@MainActor
@Observable
final class GoalsInbox {
    static let shared = GoalsInbox()
    private(set) var goals: [GoalReport] = []
    /// A goal to show, from a tapped check-in: the chat list opens its page.
    var opening: String?

    /// The chat list's: at most two, the newest check-ins first.
    var onList: [GoalReport] { Array(goals.prefix(2)) }

    init() { reload() }

    func reload() {
        #if DEBUG
        if Goals.demo {
            if goals.isEmpty { goals = Goals.demoGoals }
            return
        }
        #endif
        let now = GoalReport.showing()
        if now != goals {
            goals = now
            WidgetWriter.reload(WidgetKind.goals)
        }
    }

    /// A step ticked here: on the card and Today at once.
    func setStep(_ id: String, _ index: Int, done: Bool) {
        #if DEBUG
        if Goals.demo {
            if let i = goals.firstIndex(where: { $0.id == id }) { goals[i].setStep(index, done: done) }
            return
        }
        #endif
        GoalReport.setStep(id, index, done: done)
        reload()
    }

    #if DEBUG
    /// Kept going in the demo: the quiet gone from it.
    func kept(_ id: String) {
        if let i = goals.firstIndex(where: { $0.id == id }) { goals[i].quietDays = nil; goals[i].faded = nil }
    }
    #endif

    /// Ended here: off the list at once.
    func end(_ id: String) {
        GoalReport.end(id)
        #if DEBUG
        if Goals.demo { goals.removeAll { $0.id == id }; return }
        #endif
        reload()
    }
}

/// A goal to set up, from the New Goal sheet: its agent's chat, with the ask sent
/// (`ContentView.handleGoalChat`).
struct GoalChatRequest: Equatable {
    /// The agent's profile ("default", the main one).
    var profile: String
    var message: String
    var issuedAt: Date
}

/// A goal's page read as one plan (2026-11-22, his "still not sure what to do with this goal
/// screen": a ring saying 1/7 over ten cards, eight struck through, the two Blocked ones at the
/// bottom with Unblock and no reason). The plan is the goal's own steps, in their order, and the
/// ring counts those; what waits on the person comes first, whichever card it is; finished steps
/// and the cards the agent made for itself (a reminder, a reading logged) fold away.
///
/// With no steps from the plugin (an older one, or a goal set up before steps were kept) the
/// agent's cards are listed as its tasks, and the ring stays the check-in's own count: a card done
/// says the agent finished its part, not that the goal moved.
nonisolated struct GoalPlan: Equatable {
    nonisolated struct Row: Equatable, Identifiable {
        var id: String
        var title: String
        /// Where it is in the goal's steps (for ticking off), nil for a card outside them.
        var step: Int?
        var yours: Bool
        var done: Bool
        var card: KanbanTask?
    }

    /// Cards that can't go on without the person: Blocked, Review, Triage.
    var waiting: [Row] = []
    /// The plan's steps still to do, in its order (or, with no plan, the agent's open cards).
    var open: [Row] = []
    var done: [Row] = []
    /// The agent's own cards for the goal that aren't steps of the plan and don't wait on anyone.
    var extra: [Row] = []
    /// Whether these are the plan's steps (and the ring counts them) or only the agent's cards.
    var isPlan = false

    static let waits: Set<String> = ["blocked", "review", "triage"]

    init(steps: [GoalReport.Step]?, cards: [KanbanTask]?) {
        let cards = cards ?? []
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let steps, !steps.isEmpty else {
            for card in cards.sorted(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }) {
                let row = Row(id: card.id, title: card.title, yours: false, done: card.status == "done", card: card)
                if Self.waits.contains(card.status) { waiting.append(row) } else if row.done { done.append(row) } else { open.append(row) }
            }
            return
        }
        isPlan = true
        var linked = Set<String>()
        for (index, step) in steps.enumerated() {
            let card = step.isYours ? nil : step.cardID.flatMap { byID[$0] }
            if let id = step.cardID { linked.insert(id) }
            let row = Row(id: "step-\(index)", title: step.title, step: index, yours: step.isYours,
                          done: card.map { $0.status == "done" } ?? step.done, card: card)
            if let card, Self.waits.contains(card.status) { waiting.append(row) } else if row.done { done.append(row) } else { open.append(row) }
        }
        let others = cards.filter { !linked.contains($0.id) }
            .sorted { ($0.status == "done" ? 1 : 0, $0.createdAt ?? .distantPast) < ($1.status == "done" ? 1 : 0, $1.createdAt ?? .distantPast) }
        for card in others {
            let row = Row(id: card.id, title: card.title, yours: false, done: card.status == "done", card: card)
            if Self.waits.contains(card.status) { waiting.append(row) } else { extra.append(row) }
        }
    }

    /// The plan's steps done, of all of them; nil when there's no plan to count.
    var count: (done: Int, total: Int)? {
        guard isPlan else { return nil }
        let steps = (waiting + open + done).filter { $0.step != nil }
        return (steps.filter(\.done).count, steps.count)
    }
}

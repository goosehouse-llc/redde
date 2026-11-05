import Foundation
import Testing
@testable import Echo

/// Usage and spend (2.4): each connection's answer added up honestly: costs of different kinds
/// never summed into one figure, sessions counted on the day they started, models and bots
/// broken out, and money written as money.
@MainActor
struct UsageTests {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// Mon 2 November 2026, 15:00 in New York.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 15))! }

    private func at(_ day: Int, _ hour: Int = 12, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func session(_ id: String, day: Int, month: Int = 11, model: String = "m", input: Int = 1_000, output: Int = 100,
                         estimated: Double? = nil, actual: Double? = nil, status: String? = nil) -> SessionFacts {
        var facts = SessionFacts(id: id)
        facts.model = model
        facts.startedAt = at(day, month: month)
        facts.lastActive = at(day, 13, month: month)
        facts.inputTokens = input
        facts.outputTokens = output
        facts.estimatedCost = estimated
        facts.actualCost = actual
        facts.costStatus = status
        return facts
    }

    // MARK: - Ranges

    @Test func eachRangeStartsWhereItSays() {
        #expect(UsageRange.today.start(now: now, calendar: calendar) == at(2, 0))
        #expect(UsageRange.week.start(now: now, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 10, day: 27))!)
        #expect(UsageRange.month.start(now: now, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 10, day: 4))!)
        #expect(UsageRange.thisMonth.start(now: now, calendar: calendar) == at(1, 0))
        #expect(UsageRange.today.days(now: now, calendar: calendar) == 1)
        #expect(UsageRange.week.days(now: now, calendar: calendar) == 7)
        #expect(UsageRange.month.days(now: now, calendar: calendar) == 30)
        #expect(UsageRange.thisMonth.days(now: now, calendar: calendar) == 2, "the 1st and the 2nd")
    }

    // MARK: - The Dashboard's analytics

    @Test func theDashboardsAnalyticsAreRead() throws {
        let analytics = UsageReport.Analytics.parse(try json("""
        {"daily": [{"day": "2026-11-01", "input_tokens": 1000, "output_tokens": 200, "cache_read_tokens": 700, "reasoning_tokens": 10,
                    "estimated_cost": 0.5, "actual_cost": 0, "sessions": 3, "api_calls": 9}],
         "by_model": [{"model": "claude-sonnet-5-5", "input_tokens": 900, "output_tokens": 150, "estimated_cost": 0.5, "sessions": 2, "api_calls": 7},
                      {"model": "qwen36-kapitsa", "input_tokens": 100, "output_tokens": 50, "estimated_cost": 0, "sessions": 1, "api_calls": 2},
                      {"model": null, "input_tokens": 5}],
         "totals": {"total_input": 1000}, "period_days": 2}
        """))
        #expect(analytics.days.count == 1)
        #expect(analytics.days[0].tokens == UsageTokens(input: 1000, output: 200, cacheRead: 700, reasoning: 10))
        #expect(analytics.days[0].estimated == 0.5 && analytics.days[0].sessions == 3 && analytics.days[0].calls == 9)
        #expect(analytics.models.map(\.model) == ["claude-sonnet-5-5", "qwen36-kapitsa"], "a row with no model is left out")
    }

    @Test func theDashboardAddsUpEveryBotForTheRangeOnly() {
        typealias Day = UsageReport.Analytics.Day
        let sol = UsageReport.Analytics(
            days: [Day(day: "2026-10-31", tokens: UsageTokens(input: 5_000, output: 500), estimated: 9, sessions: 4, calls: 8),   // before this month
                   Day(day: "2026-11-01", tokens: UsageTokens(input: 1_000, output: 100), estimated: 0.40, actual: 0.30, sessions: 2, calls: 3),
                   Day(day: "2026-11-02", tokens: UsageTokens(input: 2_000, output: 200), estimated: 0.60, sessions: 1, calls: 2)],
            models: [UsageModelRow(model: "claude-sonnet-5-5", tokens: UsageTokens(input: 3_000, output: 300), sessions: 3, calls: 5, cost: 1.0)])
        let home = UsageReport.Analytics(
            days: [Day(day: "2026-11-02", tokens: UsageTokens(input: 4_000, output: 400), estimated: 0, sessions: 5, calls: 6)],
            models: [UsageModelRow(model: "qwen36-splash", tokens: UsageTokens(input: 4_000, output: 400), sessions: 5, calls: 6, cost: 0),
                     UsageModelRow(model: "claude-sonnet-5-5", tokens: UsageTokens(input: 10, output: 1), sessions: 1, calls: 1, cost: 0.01)])
        let report = UsageReport.dashboard(range: .thisMonth,
                                           profiles: [(name: "default", title: "Sol", analytics: sol), (name: "ops", title: "Home", analytics: home),
                                                      (name: "claude", title: "Coder", analytics: nil)],
                                           sessions: [], capped: false, now: now, calendar: calendar)
        #expect(report.tokens == UsageTokens(input: 7_000, output: 700), "October's day is left out")
        #expect(report.sessions == 8 && report.modelCalls == 11)
        #expect(abs(report.spend.estimated - 1.0) < 0.000_1)
        #expect(abs(report.spend.reported - 0.30) < 0.000_1, "kept beside the estimate, not added to it")
        #expect(report.spend.noCostModels == ["qwen36-splash"])
        #expect(report.days.map(\.tokens) == [1_100, 6_600], "the 1st and the 2nd, every bot")
        #expect(report.profiles.map(\.title) == ["Sol", "Home"], "costliest first; a bot that couldn't be read isn't a row")
        #expect(report.unreadProfiles == ["Coder"])
        let sonnet = report.models.first { $0.model == "claude-sonnet-5-5" }
        #expect(sonnet?.sessions == 4 && sonnet?.tokens.input == 3_010, "the same model in two bots is one row")
        #expect(report.models.first?.model == "claude-sonnet-5-5", "what cost most first")
    }

    // MARK: - The Hermes API's sessions

    @Test func theAPIsSessionsAreAddedUpByTheDayTheyStarted() {
        var late = session("late", day: 1, model: "claude-sonnet-5-5", estimated: 0.20)
        late.lastActive = at(2, 14)   // started on the 1st, still going on the 2nd
        let sessions = [
            session("old", day: 20, month: 10, estimated: 5),
            late,
            session("billed", day: 2, model: "openrouter/x", estimated: 0.10, actual: 0.12),
            session("local", day: 2, model: "qwen36-kapitsa", input: 50_000, output: 2_000),
        ]
        let report = UsageReport.api(range: .thisMonth, sessions: sessions, capped: false, now: now, calendar: calendar)
        #expect(report.sessions == 3, "October's session is out of range")
        #expect(report.days.map(\.date) == [at(1, 0), at(2, 0)])
        #expect(report.days.first?.tokens == 1_100, "a session counts wholly on the day it started")
        #expect(abs(report.spend.estimated - 0.30) < 0.000_1)
        #expect(abs(report.spend.reported - 0.12) < 0.000_1)
        #expect(report.spend.noCostModels == ["qwen36-kapitsa"], "tokens with no cost are named, not $0")
        #expect(report.profiles.isEmpty, "the Hermes API names no profiles")
        #expect(report.top.map(\.id) == ["late", "billed", "local"], "dearest first, then the busiest of those with no cost")
    }

    @Test func mixedCostsAreNeverOneActualFigure() {
        let sessions = [session("a", day: 2, estimated: 1.0, status: "estimated"),
                        session("b", day: 2, estimated: 0.5, actual: 0.6, status: "actual"),
                        session("c", day: 2, status: "included"),
                        session("d", day: 2, status: "unknown")]
        let report = UsageReport.api(range: .today, sessions: sessions, capped: false, now: now, calendar: calendar)
        #expect(abs(report.spend.estimated - 1.5) < 0.000_1, "the running cost of every session")
        #expect(abs(report.spend.reported - 0.6) < 0.000_1, "only what a provider reconciled")
        #expect(SessionCost(sessions[1]) == .actual(0.6))
        #expect(SessionCost(sessions[2]) == .included)
        #expect(SessionCost(sessions[3]) == .unpriced)
    }

    @Test func aProvidersPerCallCostIsActualNotAnEstimate() {
        // Hermes keeps a provider-reported per-call cost in the estimate column, marked "actual".
        let facts = session("r", day: 2, estimated: 0.42, status: "actual")
        #expect(SessionCost(facts) == .actual(0.42))
    }

    @Test func everyDayOfTheRangeIsThereEmptyOnesToo() {
        let report = UsageReport.api(range: .week, sessions: [session("x", day: 30, month: 10, estimated: 1)], capped: false, now: now, calendar: calendar)
        #expect(report.days.count == 7)
        #expect(report.days.map(\.cost).reduce(0, +) == 1)
        #expect(report.days.filter { $0.cost == 0 }.count == 6)
    }

    // MARK: - Money

    @Test func moneyReadsLikeMoney() {
        let us = Locale(identifier: "en_US")
        #expect(UsageMoney.text(0.84, locale: us) == "$0.84")
        #expect(UsageMoney.text(0.5, locale: us) == "$0.50")
        #expect(UsageMoney.text(1_234.5, locale: us) == "$1,234.50")
        #expect(UsageMoney.text(0, locale: us) == "$0.00")
        #expect(UsageMoney.text(0.004, locale: us).hasPrefix("under "), "too small for cents")
        #expect(UsageMoney.text(0.004, locale: us).hasSuffix("$0.01"))
        let german = UsageMoney.text(1_234.5, locale: Locale(identifier: "de_DE"))
        #expect(german.contains("1.234,50"), "grouped and written the person's way: \(german)")
    }

    @Test func sessionDetailsShowsTwoDecimals() {
        #expect(!SessionDetailsView.costText(.estimated(0.84)).contains("0.840"))
    }

    // MARK: - Top conversations

    @Test func topConversationsStayInTheRangeAndUsedTokens() {
        let sessions = [session("empty", day: 2, input: 0, output: 0),
                        session("old", day: 1, month: 10, estimated: 9),
                        session("cheap", day: 2, estimated: 0.01),
                        session("dear", day: 2, estimated: 2)]
        let top = UsageReport.top(sessions, from: UsageRange.today.start(now: now, calendar: calendar))
        #expect(top.map(\.id) == ["dear", "cheap"])
    }
}

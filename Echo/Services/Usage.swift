import Foundation

/// Usage and spend across every conversation (his pick 2026-11-02, after Nous's Hermes Mobile):
/// what the agents used and what it cost, by day, bot, model and conversation, read when the page
/// opens. The Dashboard has Hermes's own analytics (`GET /api/analytics/usage`, every session of a
/// profile: bots', cron's and summarised ones too, helper models folded into the models); the
/// Hermes API has only its list of sessions (`GET /api/sessions`, the main profile, no bots'
/// hidden chats). Both count a session on the day it started, as Hermes does.
///
/// Money is never summed across kinds: Hermes's running cost (list prices, or what a provider
/// reported per call) is one number; what providers reconciled afterwards is shown beside it as
/// part of the same spend, not added to it; and tokens with no cost recorded (a local model, a
/// free one, a subscription, an unpriced one) are named, never counted as $0.
nonisolated enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, thisMonth

    var id: String { rawValue }

    /// The first day counted, at its start.
    func start(now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return switch self {
        case .today: today
        case .week: calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .thisMonth: calendar.dateInterval(of: .month, for: now)?.start ?? today
        }
    }

    /// The days counted, today included: what the Dashboard's analytics is asked for. Its
    /// window is that many 24 hours back from now, so it always reaches the first day's start.
    func days(now: Date = .now, calendar: Calendar = .current) -> Int {
        let first = start(now: now, calendar: calendar)
        let span = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: now)).day ?? 0
        return max(1, span + 1)
    }
}

nonisolated struct UsageTokens: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var reasoning = 0
    var total: Int { input + output }

    static func + (a: UsageTokens, b: UsageTokens) -> UsageTokens {
        UsageTokens(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                    reasoning: a.reasoning + b.reasoning)
    }
}

/// What it cost, kept apart by kind.
nonisolated struct UsageSpend: Equatable, Sendable {
    /// Hermes's running cost: the model's list price, or what the provider reported per call.
    var estimated = 0.0
    /// What providers reconciled afterwards, for the sessions they did: part of the same spend.
    var reported = 0.0
    /// Models that used tokens with no cost recorded, busiest first.
    var noCostModels: [String] = []

    var isEmpty: Bool { estimated == 0 && reported == 0 && noCostModels.isEmpty }
}

nonisolated struct UsageDay: Identifiable, Equatable, Sendable {
    var date: Date
    var tokens: Int
    var cost: Double
    var id: Date { date }
}

nonisolated struct UsageModelRow: Identifiable, Equatable, Sendable {
    var model: String
    var tokens = UsageTokens()
    var sessions = 0
    var calls = 0
    var cost = 0.0
    var id: String { model }
    /// Used tokens, and nothing was charged or priced for them.
    var noCost: Bool { cost <= 0 && tokens.total > 0 }
}

nonisolated struct UsageProfileRow: Identifiable, Equatable, Sendable {
    var profile: String
    var title: String
    var tokens = UsageTokens()
    var sessions = 0
    var cost = 0.0
    var id: String { profile }
}

nonisolated struct UsageReport: Equatable, Sendable {
    nonisolated enum Origin: Equatable, Sendable { case dashboard, api }

    var range: UsageRange
    var origin: Origin
    var tokens = UsageTokens()
    var sessions = 0
    var modelCalls = 0
    var spend = UsageSpend()
    /// Every day of the range, oldest first, empty ones included.
    var days: [UsageDay] = []
    var models: [UsageModelRow] = []
    var profiles: [UsageProfileRow] = []
    /// The conversations that cost most (or used most, where nothing was priced).
    var top: [SessionFacts] = []
    /// Stopped reading sessions at the cap, so older ones in the range are left out.
    var capped = false
    /// Profiles whose usage couldn't be read.
    var unreadProfiles: [String] = []

    /// How many top conversations the page lists.
    static let topCount = 8

    // MARK: The Dashboard: Hermes's analytics

    /// One profile's `GET /api/analytics/usage`: its days (by the server's local date) and models.
    nonisolated struct Analytics: Equatable, Sendable {
        nonisolated struct Day: Equatable, Sendable {
            var day: String
            var tokens = UsageTokens()
            var estimated = 0.0
            var actual = 0.0
            var sessions = 0
            var calls = 0
        }

        var days: [Day] = []
        var models: [UsageModelRow] = []

        static func parse(_ json: JSONValue) -> Analytics {
            func whole(_ row: JSONValue, _ key: String) -> Int { row[key]?.number.map { Int($0) } ?? 0 }
            func money(_ row: JSONValue, _ key: String) -> Double { row[key]?.number ?? 0 }
            func tokens(_ row: JSONValue) -> UsageTokens {
                UsageTokens(input: whole(row, "input_tokens"), output: whole(row, "output_tokens"),
                            cacheRead: whole(row, "cache_read_tokens"), reasoning: whole(row, "reasoning_tokens"))
            }
            var analytics = Analytics()
            analytics.days = (json["daily"]?.array ?? []).compactMap { row in
                guard let day = row["day"]?.string else { return nil }
                return Day(day: day, tokens: tokens(row), estimated: money(row, "estimated_cost"), actual: money(row, "actual_cost"),
                           sessions: whole(row, "sessions"), calls: whole(row, "api_calls"))
            }
            analytics.models = (json["by_model"]?.array ?? []).compactMap { row in
                guard let model = row["model"]?.string?.nilIfEmpty else { return nil }
                return UsageModelRow(model: model, tokens: tokens(row), sessions: whole(row, "sessions"), calls: whole(row, "api_calls"),
                                     cost: money(row, "estimated_cost"))
            }
            return analytics
        }
    }

    /// The report from each profile's analytics and the recent sessions of every profile.
    /// `profiles`: name, title, and what its analytics said (nil: couldn't be read).
    static func dashboard(range: UsageRange, profiles: [(name: String, title: String, analytics: Analytics?)], sessions: [SessionFacts],
                          capped: Bool, now: Date = .now, calendar: Calendar = .current) -> UsageReport {
        var report = UsageReport(range: range, origin: .dashboard, capped: capped)
        let first = range.start(now: now, calendar: calendar)
        var byDay: [Date: (tokens: Int, cost: Double)] = [:]
        var models: [String: UsageModelRow] = [:]
        for profile in profiles {
            guard let analytics = profile.analytics else {
                report.unreadProfiles.append(profile.title)
                continue
            }
            var row = UsageProfileRow(profile: profile.name, title: profile.title)
            for day in analytics.days {
                guard let date = Self.date(day.day, calendar: calendar), date >= first else { continue }
                row.tokens = row.tokens + day.tokens
                row.sessions += day.sessions
                row.cost += day.estimated
                report.modelCalls += day.calls
                report.spend.reported += day.actual
                var bucket = byDay[date] ?? (0, 0)
                bucket.tokens += day.tokens.total
                bucket.cost += day.estimated
                byDay[date] = bucket
            }
            report.tokens = report.tokens + row.tokens
            report.sessions += row.sessions
            report.spend.estimated += row.cost
            if row.sessions > 0 || row.tokens.total > 0 { report.profiles.append(row) }
            for model in analytics.models {
                var merged = models[model.model] ?? UsageModelRow(model: model.model)
                merged.tokens = merged.tokens + model.tokens
                merged.sessions += model.sessions
                merged.calls += model.calls
                merged.cost += model.cost
                models[model.model] = merged
            }
        }
        report.finish(models: Array(models.values), byDay: byDay, first: first, now: now, calendar: calendar)
        report.top = Self.top(sessions, from: first)
        return report
    }

    // MARK: The Hermes API: its sessions

    /// The report from the sessions the Hermes API listed (summarised ones included).
    static func api(range: UsageRange, sessions: [SessionFacts], capped: Bool, now: Date = .now, calendar: Calendar = .current) -> UsageReport {
        var report = UsageReport(range: range, origin: .api, capped: capped)
        let first = range.start(now: now, calendar: calendar)
        var byDay: [Date: (tokens: Int, cost: Double)] = [:]
        var models: [String: UsageModelRow] = [:]
        var profiles: [String: UsageProfileRow] = [:]
        let counted = sessions.filter { ($0.startedAt ?? .distantPast) >= first }
        for session in counted {
            let tokens = UsageTokens(input: session.inputTokens ?? 0, output: session.outputTokens ?? 0,
                                     cacheRead: session.cacheReadTokens ?? 0, reasoning: session.reasoningTokens ?? 0)
            let cost = session.estimatedCost ?? 0
            report.tokens = report.tokens + tokens
            report.sessions += 1
            report.modelCalls += session.apiCallCount ?? 0
            report.spend.estimated += cost
            report.spend.reported += session.actualCost ?? 0
            if let started = session.startedAt {
                let day = calendar.startOfDay(for: started)
                var bucket = byDay[day] ?? (0, 0)
                bucket.tokens += tokens.total
                bucket.cost += cost
                byDay[day] = bucket
            }
            let name = session.model?.nilIfEmpty ?? String(localized: "Unknown model", comment: "Usage: a session that names no model")
            var model = models[name] ?? UsageModelRow(model: name)
            model.tokens = model.tokens + tokens
            model.sessions += 1
            model.calls += session.apiCallCount ?? 0
            // A provider's reconciled cost counts for a model Hermes had no list price for.
            model.cost += max(cost, session.actualCost ?? 0)
            models[name] = model
            if let profile = session.profile {
                var row = profiles[profile] ?? UsageProfileRow(profile: profile, title: profile)
                row.tokens = row.tokens + tokens
                row.sessions += 1
                row.cost += cost
                profiles[profile] = row
            }
        }
        report.profiles = profiles.count > 1 ? Array(profiles.values) : []
        report.finish(models: Array(models.values), byDay: byDay, first: first, now: now, calendar: calendar)
        report.top = Self.top(counted, from: first)
        return report
    }

    // MARK: Pieces

    /// Sorts what was gathered and fills the range's empty days.
    private mutating func finish(models: [UsageModelRow], byDay: [Date: (tokens: Int, cost: Double)], first: Date, now: Date, calendar: Calendar) {
        self.models = models.filter { $0.tokens.total > 0 || $0.cost > 0 }
            .sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.tokens.total > $1.tokens.total }
        spend.noCostModels = self.models.filter(\.noCost).sorted { $0.tokens.total > $1.tokens.total }.map(\.model)
        profiles.sort { $0.cost != $1.cost ? $0.cost > $1.cost : $0.tokens.total > $1.tokens.total }
        var days: [UsageDay] = []
        var day = first
        let last = calendar.startOfDay(for: now)
        while day <= last {
            let bucket = byDay[day] ?? (0, 0)
            days.append(UsageDay(date: day, tokens: bucket.tokens, cost: bucket.cost))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        self.days = days
    }

    /// The conversations that cost most in the range, then those that used most.
    static func top(_ sessions: [SessionFacts], from first: Date) -> [SessionFacts] {
        let inRange = sessions.filter { ($0.startedAt ?? .distantPast) >= first && (($0.inputTokens ?? 0) + ($0.outputTokens ?? 0)) > 0 }
        func cost(_ s: SessionFacts) -> Double { SessionCost(s).amount ?? 0 }
        func tokens(_ s: SessionFacts) -> Int { (s.inputTokens ?? 0) + (s.outputTokens ?? 0) }
        return Array(inRange.sorted { cost($0) != cost($1) ? cost($0) > cost($1) : tokens($0) > tokens($1) }.prefix(topCount))
    }

    /// "2026-11-02", the server's way of naming a day, as that day's start here.
    static func date(_ day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Money as people read it: dollars and cents in the person's way of writing them, and a cost too
/// small to show in cents as "under $0.01" (Hermes reports US dollars).
nonisolated enum UsageMoney {
    static func text(_ usd: Double, locale: Locale = .current) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: locale).precision(.fractionLength(2))
        if usd > 0, usd < 0.005 {
            return String(localized: "under \(0.01.formatted(style))", comment: "A cost smaller than one cent")
        }
        return usd.formatted(style)
    }
}

/// Where the page reads usage from, and the reading itself: once when it opens or the range
/// changes, again on pull to refresh, kept a few minutes per server and range. Nothing runs while
/// the page is closed.
@MainActor @Observable
final class UsageModel {
    enum Source {
        case dashboard(HermesServeClient)
        /// The Hermes API; `profile`, an API bot's (its own address and key), nil for the app's.
        case api(HermesSessionsAPI, profile: String?)

        var origin: UsageReport.Origin {
            if case .dashboard = self { .dashboard } else { .api }
        }

        /// The connection Settings has: the Dashboard where its login is there (all profiles), else
        /// the Hermes API.
        static func current(dashboard: Bool) -> Source? {
            if dashboard { return .dashboard(.shared) }
            guard let endpoint = Settings.shared.gatewayEndpoint(profile: nil) else { return nil }
            return .api(HermesSessionsAPI(baseURL: endpoint.url, apiKey: endpoint.key, headers: Settings.shared.apiHeaders), profile: nil)
        }

        init?(_ details: SessionDetailsSource?) {
            switch details {
            case .dashboard(let client, _): self = .dashboard(client)
            case .api(let api): self = .api(api, profile: nil)
            case nil: return nil
            }
        }

        init(dashboard client: HermesServeClient) { self = .dashboard(client) }
        init(api: HermesSessionsAPI, profile: String?) { self = .api(api, profile: profile) }
    }

    private(set) var report: UsageReport?
    private(set) var loading = false
    private(set) var problem: String?
    let source: Source?
    /// Made-up figures for screenshots (`-echo.demoUsage`), worked out again for each range.
    var demo = false

    /// Sessions read at most, a page at a time, newest first.
    nonisolated static let sessionCap = 2_000
    nonisolated static let pageSize = 200
    /// The Dashboard's list of every profile's sessions fans out over each profile's database:
    /// fewer pages of it.
    nonisolated static let dashboardPages = 3
    private static let keep: TimeInterval = 5 * 60
    private static var cache: [String: (at: Date, report: UsageReport)] = [:]

    init(source: Source?, report: UsageReport? = nil) {
        self.source = source
        self.report = report
    }

    func load(_ range: UsageRange, force: Bool = false) async {
        #if DEBUG
        if demo {
            report = UsageReport.demo(range)
            return
        }
        #endif
        guard let source else { return }
        let key = Self.key(source, range)
        if !force, let kept = Self.cache[key], Date.now.timeIntervalSince(kept.at) < Self.keep {
            report = kept.report
            return
        }
        if report?.range != range { report = nil }
        loading = true
        problem = nil
        defer { loading = false }
        do {
            let read = switch source {
            case .dashboard(let client): try await Self.dashboard(client, range)
            case .api(let api, _): try await Self.api(api, range)
            }
            Self.cache[key] = (.now, read)
            report = read
        } catch {
            problem = error.localizedDescription
        }
    }

    private static func key(_ source: Source, _ range: UsageRange) -> String {
        let server = Settings.shared.activeServerID.uuidString
        return switch source {
        case .dashboard: "\(server)|dashboard|\(range.rawValue)"
        case .api(_, let profile): "\(server)|api|\(profile ?? "")|\(range.rawValue)"
        }
    }

    // MARK: Reading

    private static func dashboard(_ client: HermesServeClient, _ range: UsageRange) async throws -> UsageReport {
        let listed = (try? await client.profiles()) ?? []
        let profiles: [(name: String, title: String)] = listed.isEmpty
            ? [("default", Settings.shared.headerTitle)]
            : listed.prefix(12).map { ($0.name, $0.title) }
        let days = range.days()
        // Each profile's analytics at once, a few at a time; one that can't be read is named.
        var analytics: [String: UsageReport.Analytics] = [:]
        var firstError: Error?
        await withTaskGroup(of: (String, Result<UsageReport.Analytics, Error>).self) { group in
            var waiting = profiles.makeIterator()
            func next() {
                guard let profile = waiting.next() else { return }
                let name = profile.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile.name
                group.addTask {
                    do {
                        let data = try await client.restData("api/analytics/usage?days=\(days)&profile=\(name)")
                        return (profile.name, .success(try await Self.parseAnalytics(data)))
                    } catch {
                        return (profile.name, .failure(error))
                    }
                }
            }
            for _ in 0 ..< 4 { next() }
            for await (name, result) in group {
                switch result {
                case .success(let read): analytics[name] = read
                case .failure(let error): firstError = firstError ?? error
                }
                next()
            }
        }
        if analytics.isEmpty, let firstError { throw firstError }
        let (sessions, capped) = await dashboardSessions(client, from: range.start())
        let read = profiles.map { (name: $0.name, title: $0.title, analytics: analytics[$0.name]) }
        return await build { UsageReport.dashboard(range: range, profiles: read, sessions: sessions, capped: capped) }
    }

    /// Every profile's recent sessions, for the top conversations: a few pages, newest first,
    /// stopping at the first page wholly before the range.
    private static func dashboardSessions(_ client: HermesServeClient, from first: Date) async -> ([SessionFacts], Bool) {
        var found: [SessionFacts] = []
        for page in 0 ..< dashboardPages {
            let path = "api/profiles/sessions?profile=all&order=recent&archived=include&limit=\(pageSize)&offset=\(page * pageSize)"
            guard let data = try? await client.restData(path) else { break }
            let rows = await parseSessions(data)
            found += rows
            if rows.count < pageSize || rows.allSatisfy({ ($0.lastActive ?? $0.startedAt ?? .distantPast) < first }) {
                return (found, false)
            }
        }
        return (found, true)
    }

    private static func api(_ api: HermesSessionsAPI, _ range: UsageRange) async throws -> UsageReport {
        let first = range.start()
        var found: [SessionFacts] = []
        var capped = false
        var offset = 0
        while true {
            let page = try await api.requestJSON("GET", "api/sessions", query: [
                .init(name: "limit", value: String(pageSize)), .init(name: "offset", value: String(offset)),
                .init(name: "include_children", value: "true"),
            ])
            let rows = await parseRows(page["data"] ?? page["sessions"] ?? .array([]))
            found += rows
            offset += pageSize
            // Newest active first: a page wholly before the range ends the reading.
            let more = page["has_more"]?.bool ?? (rows.count >= pageSize)
            if !more || rows.isEmpty || rows.allSatisfy({ ($0.lastActive ?? $0.startedAt ?? .distantPast) < first }) { break }
            if found.count >= sessionCap {
                capped = true
                break
            }
        }
        let sessions = found, stopped = capped
        return await build { UsageReport.api(range: range, sessions: sessions, capped: stopped) }
    }

    // Off the main actor: parsing hundreds of rows and adding them up.

    @concurrent private static func parseAnalytics(_ data: Data) async throws -> UsageReport.Analytics {
        UsageReport.Analytics.parse(try JSONValue.parse(data))
    }

    @concurrent private static func parseSessions(_ data: Data) async -> [SessionFacts] {
        guard let json = try? JSONValue.parse(data) else { return [] }
        return (json["sessions"]?.array ?? json["data"]?.array ?? []).compactMap(SessionFacts.parse)
    }

    @concurrent private static func parseRows(_ rows: JSONValue) async -> [SessionFacts] {
        (rows.array ?? []).compactMap(SessionFacts.parse)
    }

    @concurrent private static func build(_ make: @Sendable () -> UsageReport) async -> UsageReport { make() }
}

#if DEBUG
extension UsageModel {
    /// `-echo.demoUsage`: a month on the Dashboard with three bots, for screenshots.
    static var demo: UsageModel {
        let model = UsageModel(source: nil, report: UsageReport.demo(.week))
        model.demo = true
        return model
    }
}

extension UsageReport {
    static func demo(_ range: UsageRange, now: Date = .now, calendar: Calendar = .current) -> UsageReport {
        let today = calendar.startOfDay(for: now)
        func day(_ back: Int) -> String {
            let date = calendar.date(byAdding: .day, value: -back, to: today) ?? today
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        func days(_ costs: [Double], tokens: [Int]) -> [Analytics.Day] {
            zip(costs, tokens).enumerated().map { back, pair in
                Analytics.Day(day: day(back), tokens: UsageTokens(input: pair.1 * 9 / 10, output: pair.1 / 10, cacheRead: pair.1 * 7 / 10, reasoning: pair.1 / 40),
                              estimated: pair.0, actual: 0, sessions: max(1, pair.1 / 90_000), calls: pair.1 / 22_000)
            }
        }
        let sol = Analytics(days: days([0.41, 0.88, 0.12, 0.64, 0.30, 1.12, 0.22, 0.09, 0.47, 0.31],
                                        tokens: [520_000, 980_000, 210_000, 760_000, 400_000, 1_310_000, 330_000, 150_000, 610_000, 380_000]),
                            models: [UsageModelRow(model: "claude-sonnet-5-5", tokens: UsageTokens(input: 3_900_000, output: 260_000), sessions: 31, calls: 410, cost: 4.21),
                                     UsageModelRow(model: "qwen36-kapitsa", tokens: UsageTokens(input: 6_200_000, output: 420_000), sessions: 48, calls: 690, cost: 0)])
        let home = Analytics(days: days([0, 0, 0, 0, 0, 0, 0], tokens: [180_000, 240_000, 90_000, 310_000, 120_000, 200_000, 160_000]),
                             models: [UsageModelRow(model: "qwen36-splash", tokens: UsageTokens(input: 1_200_000, output: 100_000), sessions: 22, calls: 140, cost: 0)])
        let coder = Analytics(days: days([0.0, 0.62, 0.0, 0.0, 1.48, 0.0, 0.0], tokens: [0, 410_000, 0, 0, 890_000, 0, 0]),
                              models: [UsageModelRow(model: "claude-opus-5-5", tokens: UsageTokens(input: 1_180_000, output: 120_000), sessions: 4, calls: 61, cost: 2.10)])
        var top = SessionFacts(id: "20261029_141002_c0de01")
        top.title = "Upgrade Basic Memory to 1.0"
        top.profile = "claude"
        top.model = "claude-opus-5-5"
        top.startedAt = calendar.date(byAdding: .day, value: -4, to: now)
        top.inputTokens = 840_000
        top.outputTokens = 52_000
        top.estimatedCost = 1.31
        top.costStatus = "estimated"
        var second = SessionFacts(id: "20261102_081544_9f3c2a")
        second.title = "Move the blog to the new site"
        second.profile = "default"
        second.model = "claude-sonnet-5-5"
        second.startedAt = calendar.date(byAdding: .hour, value: -5, to: now)
        second.inputTokens = 1_284_310
        second.outputTokens = 38_902
        second.estimatedCost = 0.84
        second.costStatus = "estimated"
        var third = SessionFacts(id: "20261101_190233_ab12cd")
        third.title = "Turn off the porch light at 11"
        third.profile = "ops"
        third.model = "qwen36-splash"
        third.startedAt = calendar.date(byAdding: .day, value: -1, to: now)
        third.inputTokens = 96_000
        third.outputTokens = 4_100
        third.costStatus = "unknown"
        return .dashboard(range: range, profiles: [(name: "default", title: "Sol", analytics: sol), (name: "claude", title: "Coder", analytics: coder),
                                                   (name: "ops", title: "Home", analytics: home)],
                          sessions: [top, second, third], capped: false, now: now, calendar: calendar)
    }
}
#endif

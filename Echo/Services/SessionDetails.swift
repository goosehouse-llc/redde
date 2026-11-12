import Foundation

/// A conversation's session as its server keeps it, for the chat's Session Details (his ask
/// 2026-11-02): read once when the page opens, from `GET api/sessions/{id}` on either
/// connection. The Dashboard's answer is the database row (billing, cost status, folder, branch,
/// the model's settings); the Hermes API's is a safe subset (no billing, no folder, no model
/// settings). Everything is optional: an older Hermes leaves fields out.
nonisolated struct SessionFacts: Equatable, Sendable {
    var id: String
    var title: String?
    var source: String?
    var profile: String?
    var model: String?
    /// Who bills it (the Dashboard's `billing_provider`): the provider the session ran on.
    var provider: String?
    var reasoningEffort: String?
    var startedAt: Date?
    var endedAt: Date?
    var lastActive: Date?
    var endReason: String?
    var parentID: String?
    /// The session was branched (Hermes's /branch, Redde's fork) from its parent, not continued
    /// from it when that one filled up.
    var branched = false
    var folder: String?
    var branch: String?
    var messageCount: Int?
    var toolCallCount: Int?
    var apiCallCount: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var reasoningTokens: Int?
    var estimatedCost: Double?
    var actualCost: Double?
    /// "actual", "estimated", "included" or "unknown" (the Dashboard's); nil on the Hermes API.
    var costStatus: String?

    /// The session out of either connection's answer: the Dashboard's row as it is, the Hermes
    /// API's inside `session`. Nil without an id.
    static func parse(_ json: JSONValue) -> SessionFacts? {
        let row = json["session"]?.object.map(JSONValue.object) ?? json
        guard let id = row["id"]?.string, !id.isEmpty else { return nil }
        func text(_ key: String) -> String? { row[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        func whole(_ key: String) -> Int? { row[key]?.number.map { Int($0) } ?? row[key]?.string.flatMap(Int.init) }
        func money(_ key: String) -> Double? { row[key]?.number }
        func date(_ key: String) -> Date? { row[key]?.number.map { Date(timeIntervalSince1970: $0) } }
        // The model's settings come as JSON in a string (SQLite keeps them so) or as an object.
        let config: JSONValue? = row["model_config"].flatMap { value in
            if let raw = value.string { return try? JSONValue.parse(Data(raw.utf8)) }
            return value.object != nil ? value : nil
        }
        let effort = config?["reasoning_config"]?["effort"]?.string ?? config?["reasoning_effort"]?.string
        var facts = SessionFacts(id: id)
        facts.title = text("title")
        facts.source = text("source")
        facts.profile = text("profile") ?? text("profile_name")
        facts.model = text("model")
        facts.provider = text("billing_provider")
        facts.reasoningEffort = effort?.nilIfEmpty
        facts.startedAt = date("started_at")
        facts.endedAt = date("ended_at")
        facts.lastActive = date("last_active") ?? date("last_activity_at")
        facts.endReason = text("end_reason")
        facts.parentID = text("parent_session_id")
        facts.branched = config?["_branched_from"].map { !$0.isNull } ?? false
        facts.folder = text("cwd")
        facts.branch = text("git_branch")
        facts.messageCount = whole("message_count")
        facts.toolCallCount = whole("tool_call_count")
        facts.apiCallCount = whole("api_call_count")
        facts.inputTokens = whole("input_tokens")
        facts.outputTokens = whole("output_tokens")
        facts.cacheReadTokens = whole("cache_read_tokens")
        facts.cacheWriteTokens = whole("cache_write_tokens")
        facts.reasoningTokens = whole("reasoning_tokens")
        facts.estimatedCost = money("estimated_cost_usd")
        facts.actualCost = money("actual_cost_usd")
        facts.costStatus = text("cost_status")
        return facts
    }

    /// Ended because it filled up and went on in a new session (Hermes's compression).
    var wasCompressed: Bool { endReason == "compression" }
}

/// What a session cost, as honestly as the server says it: never "$0" for a cost nobody knows.
nonisolated enum SessionCost: Equatable, Sendable {
    /// What the provider billed.
    case actual(Double)
    /// Hermes's estimate from the model's list price.
    case estimated(Double)
    /// Part of a subscription: no charge per call.
    case included
    /// Hermes says nothing was charged, without saying why (the Hermes API leaves the status out).
    case noCharge
    /// Hermes has no price for this model.
    case unpriced
    /// The server didn't say.
    case notReported

    init(_ facts: SessionFacts?) {
        guard let facts else { self = .notReported; return }
        switch facts.costStatus {
        case "included":
            self = .included
            return
        case "unknown":
            // An actual bill can still have come in for a model without a list price.
            if let actual = facts.actualCost, actual > 0 { self = .actual(actual) } else { self = .unpriced }
            return
        default:
            break
        }
        if let actual = facts.actualCost, actual > 0 { self = .actual(actual); return }
        // Hermes keeps a provider's per-call cost in the estimate column, marked "actual".
        if let estimate = facts.estimatedCost, estimate > 0 { self = facts.costStatus == "actual" ? .actual(estimate) : .estimated(estimate); return }
        // A zero is a cost only when Hermes priced it: an included model or a free one both say 0.
        if facts.actualCost != nil || facts.estimatedCost != nil {
            self = .noCharge
            return
        }
        self = facts.costStatus == nil ? .notReported : .unpriced
    }

    /// The amount to show, when there is one.
    var amount: Double? {
        switch self {
        case .actual(let usd), .estimated(let usd): usd
        default: nil
        }
    }
}

/// How this conversation's session came to be: the sessions before it, newest first, as far as
/// the page looked (`SessionDetailsModel.lineage`).
nonisolated struct SessionLineage: Equatable, Sendable {
    /// Times it filled up and went on in a new session, counted back from this one.
    var compressions = 0
    /// Branched from another conversation (the first link back is a branch, not a compression).
    var branchedFrom: String?
    /// The oldest session reached: where the conversation started.
    var rootID: String?
    /// Stopped looking before the start (`SessionDetailsModel.lineageLimit`).
    var more = false

    /// The chain from the parents a page fetched, nearest first: each parent that ended in a
    /// compression counts; the first that didn't (or a branch) ends it.
    static func from(start: SessionFacts, parents: [SessionFacts], limitReached: Bool) -> SessionLineage {
        var lineage = SessionLineage()
        guard start.parentID != nil else { return lineage }
        if start.branched {
            lineage.branchedFrom = parents.first?.title ?? start.parentID
            lineage.rootID = start.parentID
            return lineage
        }
        for parent in parents {
            guard parent.wasCompressed else { break }
            lineage.compressions += 1
            lineage.rootID = parent.id
        }
        lineage.more = limitReached && (parents.last?.wasCompressed ?? false)
        return lineage
    }
}

/// What this device saw of the conversation: its messages, the tools its replies called, and the
/// replies it timed itself (`TurnMetrics`, only for replies streamed here, not loaded ones).
nonisolated struct SessionActivity: Equatable, Sendable {
    struct Tool: Equatable, Sendable, Identifiable {
        var name: String
        var count: Int
        var failed: Int
        var id: String { name }
    }

    var messages = 0
    var yourMessages = 0
    var replies = 0
    var tools: [Tool] = []
    var toolCalls: Int { tools.reduce(0) { $0 + $1.count } }
    var toolFailures: Int { tools.reduce(0) { $0 + $1.failed } }
    /// Replies timed on this device, their total time and average speed.
    var timedReplies = 0
    var replyTime: TimeInterval = 0
    var tokensPerSecond: Double?

    static func from(_ messages: [Message]) -> SessionActivity {
        var activity = SessionActivity()
        var counts: [String: (count: Int, failed: Int)] = [:]
        var rates: [Double] = []
        for message in messages {
            activity.messages += 1
            switch message.role {
            case .user:
                // Another bot's message, a process report or an aside isn't one of the person's.
                if message.delivered == nil, !message.isSteer { activity.yourMessages += 1 }
            case .assistant:
                activity.replies += 1
            }
            for tool in message.tools where !tool.name.isEmpty {
                var tally = counts[tool.name] ?? (0, 0)
                tally.count += 1
                if tool.status == .failed { tally.failed += 1 }
                counts[tool.name] = tally
            }
            if let metrics = message.metrics, let done = metrics.completedAt {
                activity.timedReplies += 1
                activity.replyTime += max(0, done.timeIntervalSince(metrics.sentAt))
                if let rate = metrics.tokensPerSecond { rates.append(rate) }
            }
        }
        activity.tools = counts.map { Tool(name: $0.key, count: $0.value.count, failed: $0.value.failed) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        if !rates.isEmpty { activity.tokensPerSecond = rates.reduce(0, +) / Double(rates.count) }
        return activity
    }
}

/// Where the session details come from: the conversation's own connection.
@MainActor
enum SessionDetailsSource {
    case dashboard(HermesServeClient, profile: String?)
    case api(HermesSessionsAPI)

    func facts(_ id: String) async throws -> SessionFacts? {
        do {
            switch self {
            case .dashboard(let client, let profile):
                return SessionFacts.parse(try await client.sessionDetail(stored: id, profile: profile))
            case .api(let api):
                return SessionFacts.parse(try await api.requestJSON("GET", "api/sessions/\(id)"))
            }
        } catch TransportError.http(404, _) {
            return nil
        }
    }

    var isDashboard: Bool { if case .dashboard = self { true } else { false } }
}

/// The page's model: the conversation's session read once when it opens (and again on pull to
/// refresh), then the sessions before it, a few at most. Nothing runs while the page is closed.
@MainActor @Observable
final class SessionDetailsModel {
    private(set) var facts: SessionFacts?
    private(set) var lineage = SessionLineage()
    private(set) var loading = false
    private(set) var problem: String?
    /// The connection said nothing about this session (gone, or never kept on the server).
    private(set) var missing = false

    /// How many sessions back the page follows a conversation that kept filling up.
    nonisolated static let lineageLimit = 12

    init(facts: SessionFacts? = nil, lineage: SessionLineage = SessionLineage()) {
        self.facts = facts
        self.lineage = lineage
    }

    func load(id: String?, from source: SessionDetailsSource?) async {
        guard let id, let source else { return }
        loading = true
        problem = nil
        defer { loading = false }
        do {
            guard let found = try await source.facts(id) else {
                missing = true
                facts = nil
                return
            }
            missing = false
            facts = found
            lineage = await Self.lineage(of: found, from: source)
        } catch {
            problem = error.localizedDescription
        }
    }

    private static func lineage(of start: SessionFacts, from source: SessionDetailsSource) async -> SessionLineage {
        var parents: [SessionFacts] = []
        var next = start.parentID
        // A branch needs its parent's name only; a compression, every parent that filled up.
        while let id = next, parents.count < (start.branched ? 1 : lineageLimit) {
            guard let parent = try? await source.facts(id) else { break }
            parents.append(parent)
            guard parent.wasCompressed else { break }
            next = parent.parentID
        }
        return SessionLineage.from(start: start, parents: parents, limitReached: parents.count >= lineageLimit)
    }
}

#if DEBUG
extension SessionDetailsModel {
    /// A long-running conversation on the Dashboard, for previews.
    static var demo: SessionDetailsModel {
        let now = Date.now
        var facts = SessionFacts(id: "20261102_081544_9f3c2a")
        facts.title = "Move the blog to the new site"
        facts.source = "desktop"
        facts.profile = "default"
        facts.model = "qwen36-kapitsa"
        facts.provider = "custom:paloma"
        facts.reasoningEffort = "medium"
        facts.startedAt = now.addingTimeInterval(-3 * 3600 - 1260)
        facts.lastActive = now.addingTimeInterval(-240)
        facts.parentID = "20261101_214002_1b7e44"
        facts.folder = "~/Projects/blog"
        facts.branch = "migrate-hugo"
        facts.messageCount = 64
        facts.toolCallCount = 41
        facts.apiCallCount = 57
        facts.inputTokens = 1_284_310
        facts.outputTokens = 38_902
        facts.cacheReadTokens = 1_102_550
        facts.reasoningTokens = 9_418
        facts.estimatedCost = 0.84
        facts.costStatus = "estimated"
        return SessionDetailsModel(facts: facts, lineage: SessionLineage(compressions: 2, rootID: "20261101_090112_aa01ff"))
    }

    static var demoActivity: SessionActivity {
        SessionActivity(messages: 64, yourMessages: 19, replies: 23,
                        tools: [.init(name: "terminal", count: 17, failed: 2), .init(name: "read_file", count: 11, failed: 0),
                                .init(name: "web_search", count: 6, failed: 0), .init(name: "patch", count: 5, failed: 1),
                                .init(name: "redde_show", count: 2, failed: 0)],
                        timedReplies: 21, replyTime: 1_046, tokensPerSecond: 61.4)
    }
}
#endif

import Foundation

nonisolated struct Message: Identifiable, Equatable, Sendable, Codable {
    enum Role: String, Sendable, Codable { case user, assistant }

    let id: UUID
    let role: Role
    var text: String
    var createdAt: Date
    /// Set once a reply finishes streaming.
    var metrics: TurnMetrics?
    var error: String?
    /// The model's reasoning, when the backend streams it.
    var reasoning: String = ""
    /// When the reasoning started arriving and when it stopped (the first text, or the end of
    /// the turn), for "Thought for 6 s".
    var reasoningStartedAt: Date?
    var reasoningEndedAt: Date?
    var tools: [ToolActivity] = []
    /// The agent's own task list as this reply left it, when the reply changed it (`TodoList`).
    var todos: [TodoItem]?
    /// The cards this reply shows (a map, places, the weather), asked for with `redde_show`.
    var cards: [ReplyCard]?
    /// Delegated child agents spawned during this reply.
    var subagents: [SubagentActivity] = []
    var attachments: [Attachment] = []
    /// A nudge sent into a running turn rather than a new question.
    var isSteer: Bool = false
    /// Filed as the person's, but not theirs: another bot's message, a bot's reply, or a
    /// background process reporting back (`BotMessages`).
    var delivered: Delivered?

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, createdAt, metrics, error, reasoning, reasoningStartedAt, reasoningEndedAt, tools, todos, subagents, attachments, isSteer
        case delivered, cards
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        metrics = try c.decodeIfPresent(TurnMetrics.self, forKey: .metrics)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        reasoningStartedAt = try c.decodeIfPresent(Date.self, forKey: .reasoningStartedAt)
        reasoningEndedAt = try c.decodeIfPresent(Date.self, forKey: .reasoningEndedAt)
        tools = try c.decodeIfPresent([ToolActivity].self, forKey: .tools) ?? []
        todos = try c.decodeIfPresent([TodoItem].self, forKey: .todos)
        subagents = try c.decodeIfPresent([SubagentActivity].self, forKey: .subagents) ?? []
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        isSteer = try c.decodeIfPresent(Bool.self, forKey: .isSteer) ?? false
        delivered = try c.decodeIfPresent(Delivered.self, forKey: .delivered)
        cards = try c.decodeIfPresent([ReplyCard].self, forKey: .cards)
    }
}

/// A message the person didn't write, though Hermes files it as theirs (a user row): another
/// bot's, delivered into this bot's chat (Bot Mode's `message_agent`); a bot's reply to one this
/// bot sent, which comes back as a background process finishing; another background process
/// reporting back; or what one of the bot's schedules came up with (`BotRoutines`), which the
/// bot then answers. Read out of transcripts by `BotMessages`.
nonisolated struct Delivered: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case message, reply, process, routine }
    var kind: Kind
    /// The bot it is from: its profile, and what it called itself.
    var profile: String?
    var name: String?
    /// A process notice's one line (`display_text`), or the schedule's name.
    var title: String?
}

/// How much of the model's context window a conversation fills, in tokens.
nonisolated struct ContextUsage: Equatable, Sendable {
    var used: Int
    var window: Int
}

/// Wall-clock timings for one turn, measured on the phone. The whole point of M0/M1 is to know
/// where the latency budget goes, so these are first-class.
nonisolated struct TurnMetrics: Equatable, Sendable, Codable {
    var sentAt: Date
    var firstTokenAt: Date?
    var completedAt: Date?
    var characters: Int = 0
    var usage: TokenUsage?
    /// Model context window in tokens, for the percentage. Detected from llama.cpp when possible.
    var contextWindow: Int?

    /// Context occupancy after this turn. Only when the backend states it (hermes serve) or the
    /// numbers are unambiguous (fast lane: one call's prompt tokens against the detected window).
    var context: ContextUsage? {
        guard let usage, let used = usage.contextUsed, let max = usage.contextMax ?? contextWindow, max > 0 else { return nil }
        return ContextUsage(used: used, window: max)
    }

    var contextPercent: Double? { context.map { Double($0.used) / Double($0.window) * 100 } }

    /// Average decode speed; see `TokenUsage.decodeRate` for the windowing rules.
    var tokensPerSecond: Double? {
        TokenUsage.decodeRate(output: usage?.output, firstTokenAt: firstTokenAt, doneAt: completedAt, sentAt: sentAt)
    }

    /// "1.2M", "54k", "8.2k", "900": a token count in a few characters.
    static func compact(_ n: Int) -> String {
        func scaled(_ value: Double, digits: Int) -> String {
            value.formatted(.number.precision(.fractionLength(digits)).grouping(.never))
        }
        if n >= 1_000_000 {
            return String(localized: "\(scaled(Double(n) / 1_000_000, digits: 1))M", comment: "A token count in millions, as 1.2M")
        }
        if n >= 10_000 {
            return String(localized: "\(scaled(Double(n) / 1000, digits: 0))k", comment: "A token count in thousands, as 54k or 8.2k")
        }
        if n >= 1000 {
            return String(localized: "\(scaled(Double(n) / 1000, digits: 1))k", comment: "A token count in thousands, as 54k or 8.2k")
        }
        return n.formatted()
    }

    var timeToFirstToken: TimeInterval? { firstTokenAt.map { $0.timeIntervalSince(sentAt) } }
    var total: TimeInterval? { completedAt.map { $0.timeIntervalSince(sentAt) } }

    var summary: String {
        var parts: [String] = []
        if let ttft = timeToFirstToken {
            parts.append(String(localized: "TTFT \(Self.seconds(ttft))", comment: "A reply's timings: the time to its first token, as TTFT 0.52s"))
        }
        if let total {
            parts.append(String(localized: "total \(Self.seconds(total))", comment: "A reply's timings: how long the whole reply took, as total 3.40s"))
        }
        if let pct = contextPercent {
            let share = (pct / 100).formatted(.percent.precision(.fractionLength(1)))
            parts.append(String(localized: "ctx \(share)", comment: "A reply's timings: how full the model's context is, as ctx 12.3%"))
        } else if let usage {
            // Hermes API server: only session totals are known. Say so rather than fake a percentage.
            parts.append(String(localized: "session \(Self.compact(usage.total)) tok", comment: "A reply's timings: tokens used in the whole session, as session 12.3k tok"))
        }
        if let tps = tokensPerSecond {
            let rate = tps.formatted(.number.precision(.fractionLength(0)))
            parts.append(String(localized: "\(rate) tok/s", comment: "A reply's timings: tokens a second"))
        }
        if characters > 0 { parts.append(String(localized: "\(characters) chars", comment: "A reply's timings: how many characters the reply has")) }
        return parts.joined(separator: " · ")
    }

    /// "0.52s": seconds to two places.
    private static func seconds(_ interval: TimeInterval) -> String {
        Duration.seconds(interval).formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 2)))
    }
}

extension TokenUsage {
    /// Average decode speed: reply tokens (reasoning included) over the time from the first
    /// token of any kind to the last. Falls back to the whole request window when the stream
    /// arrived in one burst, so a batched delivery can't fake a huge rate.
    nonisolated static func decodeRate(output: Int?, firstTokenAt: Date?, doneAt: Date?, sentAt: Date?) -> Double? {
        guard let output, output > 1, let doneAt else { return nil }
        var window = firstTokenAt.map { doneAt.timeIntervalSince($0) } ?? 0
        if window < 0.5 { window = sentAt.map { doneAt.timeIntervalSince($0) } ?? 0 }
        guard window > 0.2 else { return nil }
        return Double(output) / window
    }
}

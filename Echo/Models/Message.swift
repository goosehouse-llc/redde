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
    var tools: [ToolActivity] = []
    /// Delegated child agents spawned during this reply.
    var subagents: [SubagentActivity] = []
    var attachments: [Attachment] = []
    /// A nudge sent into a running turn rather than a new question.
    var isSteer: Bool = false

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, createdAt, metrics, error, reasoning, tools, subagents, attachments, isSteer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        metrics = try c.decodeIfPresent(TurnMetrics.self, forKey: .metrics)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        tools = try c.decodeIfPresent([ToolActivity].self, forKey: .tools) ?? []
        subagents = try c.decodeIfPresent([SubagentActivity].self, forKey: .subagents) ?? []
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        isSteer = try c.decodeIfPresent(Bool.self, forKey: .isSteer) ?? false
    }
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
    var contextPercent: Double? {
        guard let usage, let used = usage.contextUsed, let max = usage.contextMax ?? contextWindow, max > 0 else { return nil }
        return Double(used) / Double(max) * 100
    }

    /// Average decode speed; see `TokenUsage.decodeRate` for the windowing rules.
    var tokensPerSecond: Double? {
        TokenUsage.decodeRate(output: usage?.output, firstTokenAt: firstTokenAt, doneAt: completedAt, sentAt: sentAt)
    }

    static func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 10_000 ? String(format: "%.0fk", Double(n) / 1000) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : String(n)
    }

    var timeToFirstToken: TimeInterval? { firstTokenAt.map { $0.timeIntervalSince(sentAt) } }
    var total: TimeInterval? { completedAt.map { $0.timeIntervalSince(sentAt) } }

    var summary: String {
        var parts: [String] = []
        if let ttft = timeToFirstToken { parts.append(String(format: "TTFT %.2fs", ttft)) }
        if let total { parts.append(String(format: "total %.2fs", total)) }
        if let pct = contextPercent {
            parts.append(String(format: "ctx %.1f%%", pct))
        } else if let usage {
            // Hermes API server: only session totals are known. Say so rather than fake a percentage.
            parts.append("session \(Self.compact(usage.total)) tok")
        }
        if let tps = tokensPerSecond { parts.append(String(format: "%.0f tok/s", tps)) }
        if characters > 0 { parts.append("\(characters) chars") }
        return parts.joined(separator: " · ")
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

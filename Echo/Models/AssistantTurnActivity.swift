import Foundation

/// How consecutive assistant messages are presented as one visual turn in the transcript.
/// Messages stay separate in the conversation; this is display metadata only.
nonisolated struct AssistantTurnActivity: Equatable, Sendable {
    struct Segment: Identifiable, Equatable, Sendable {
        let messageID: UUID
        let reasoning: String
        let reasoningStartedAt: Date?
        let reasoningEndedAt: Date?
        let tools: [ToolActivity]

        var id: UUID { messageID }
    }

    struct Placement: Equatable, Sendable {
        let showsSpeaker: Bool
        let isContinuation: Bool
        let isFinal: Bool
        let isLiveTurn: Bool
        /// Present only on the row that owns the turn-level disclosure.
        let activity: AssistantTurnActivity?
        /// More than one assistant message belongs to this visual turn, so their own folds hide.
        let isGrouped: Bool
    }

    let segments: [Segment]

    var toolCount: Int { segments.reduce(0) { $0 + $1.tools.count } }
    var thoughtCount: Int { segments.count { !$0.reasoning.isEmpty } }

    // The same words as a single reply's steps fold ("Used …", "Working · …").
    var completedLabel: String { String(localized: "Used \(summary)") }
    var workingLabel: String { String(localized: "Working · \(summary)") }

    private var summary: String {
        var parts: [String] = []
        if toolCount > 0 { parts.append(String(localized: "\(toolCount) tools")) }
        if thoughtCount > 0 {
            parts.append(String(localized: "\(thoughtCount) thoughts",
                                comment: "Turn activity summary: how many times the agent reasoned in one turn"))
        }
        return parts.joined(separator: " · ")
    }

    /// Consecutive assistant messages are one visual turn. The first owns the speaker line; the
    /// last answer (or the newest row while work is still under way) owns one activity disclosure.
    static func layout(_ messages: some Collection<Message>, liveMessageID: UUID? = nil) -> [UUID: Placement] {
        let messages = Array(messages)
        var result: [UUID: Placement] = [:]
        var index = messages.startIndex
        while index < messages.endIndex {
            guard messages[index].role == .assistant else { index += 1; continue }
            let start = index
            index += 1
            // A turn started without a visible user row (for example, a page button talking back)
            // follows a completed reply directly. Its finished metrics are the boundary we still
            // have locally even though there is no user bubble between the two assistant rows.
            while index < messages.endIndex, messages[index].role == .assistant,
                  !messages[index].beginsAssistantTurn,
                  messages[index - 1].metrics?.completedAt == nil, messages[index - 1].error == nil {
                index += 1
            }
            let run = Array(messages[start..<index])
            let grouped = run.count > 1
            let activity = grouped ? AssistantTurnActivity(messages: run) : nil
            let liveOwner = liveMessageID.flatMap { id in run.contains(where: { $0.id == id }) ? id : nil }
            let owner = liveOwner
                ?? run.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.id
                ?? run.last?.id
            for (offset, message) in run.enumerated() {
                result[message.id] = Placement(
                    showsSpeaker: offset == 0,
                    isContinuation: offset > 0,
                    isFinal: message.id == owner,
                    isLiveTurn: liveOwner != nil,
                    activity: message.id == owner ? activity : nil,
                    isGrouped: grouped
                )
            }
        }
        return result
    }

    private init?(messages: [Message]) {
        segments = messages.compactMap { message in
            guard !message.reasoning.isEmpty || !message.tools.isEmpty else { return nil }
            return Segment(messageID: message.id, reasoning: message.reasoning,
                           reasoningStartedAt: message.reasoningStartedAt,
                           reasoningEndedAt: message.reasoningEndedAt, tools: message.tools)
        }
        if segments.isEmpty { return nil }
    }
}

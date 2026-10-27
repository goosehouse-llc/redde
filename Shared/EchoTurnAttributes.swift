import ActivityKit
import Foundation

/// Live Activity payload for one turn. Shared by the app (which drives it) and the widget
/// extension (which draws it).
nonisolated struct EchoTurnAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case thinking, tool, replying, done, failed }
        var phase: Phase
        /// Tool name while `.tool`; reply preview while `.replying` / `.done`; error text if `.failed`.
        var detail: String
        var startedAt: Date
        /// A command waiting for a yes or no. While set the activity shows it, with Approve and
        /// Deny, whatever the phase underneath. Optional, so a state an older build wrote decodes.
        var approval: Approval?
        /// How far the agent has got down its task list, once it has touched the list in this
        /// turn. Optional, like the approval, so an older state decodes.
        var progress: Progress?

        struct Progress: Codable, Hashable {
            var done: Int
            var total: Int
            /// The task being worked on, when the list marks one.
            var current: String?
        }

        struct Approval: Codable, Hashable {
            var id: String
            var command: String
            /// What the two buttons answer with, as the request named its choices.
            var approve: String
            var deny: String
        }
    }

    /// The question, trimmed for the banner.
    var question: String
    /// Who is answering: the bot's name in its chat, else the main agent's, as Redde names it
    /// ("Sol is thinking"). Optional, so an activity an older build started decodes, as "Redde".
    var agent: String? = nil
}

extension EchoTurnAttributes {
    /// How long an activity may go without an update before the system calls it stale. The app
    /// refreshes it well inside this while a reply is running, so one that has gone stale has
    /// stopped hearing from the app: it crashed, was closed, or was suspended mid-reply. Two
    /// minutes is as soon as the system acts: asked for 75 seconds, it marked the activity stale
    /// 120 seconds after its last update (measured in the simulator).
    static let staleAfter: TimeInterval = 120
    static let refreshEvery: TimeInterval = 45
}

extension EchoTurnAttributes.ContentState {
    /// Still being worked on, as far as this state says.
    var isLive: Bool { phase != .done && phase != .failed }

    /// The command to show with its buttons. Not on a stale activity: the app that would carry
    /// the answer has stopped, so a yes there would go nowhere.
    func pendingApproval(stale: Bool) -> Approval? { stale || !isLive ? nil : approval }

    /// The words and symbol for the banner and the Dynamic Island. `stale` is the system's word
    /// that updates stopped coming: a reply that was live then is shown as interrupted, not as
    /// still thinking with the clock running.
    /// `agent`: who is answering (`EchoTurnAttributes.agent`); "Redde" when not said.
    func title(stale: Bool, agent: String? = nil) -> String {
        if stale, isLive { return "Reply interrupted" }
        if pendingApproval(stale: stale) != nil { return "Needs your approval" }
        let name = agent.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "Redde"
        switch phase {
        case .thinking: return "\(name) is thinking"
        case .tool: return "Using \(detail)"
        case .replying: return "\(name) is replying"
        case .done: return "\(name) replied"
        case .failed: return "\(name) couldn't reply"
        }
    }

    /// The task list's progress, to show. Not beside a command waiting for an answer: that takes
    /// the activity over until it is settled.
    func tasks(stale: Bool) -> Progress? { pendingApproval(stale: stale) == nil ? progress : nil }

    /// The task in hand, while the agent is at it: the line that says more than a tool's name.
    func step(stale: Bool) -> String? {
        guard isLive, !stale, phase == .thinking || phase == .tool else { return nil }
        return tasks(stale: stale)?.current
    }

    func compact(stale: Bool) -> String {
        if stale, isLive { return "stopped" }
        if pendingApproval(stale: stale) != nil { return "approve?" }
        // Through a long job the count is the thing to glance at.
        if isLive, let progress { return progress.short }
        switch phase {
        case .thinking: return "thinking"
        case .tool: return detail
        case .replying: return "replying"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    func symbol(stale: Bool) -> String {
        if stale, isLive { return "pause.circle.fill" }
        if pendingApproval(stale: stale) != nil { return "hand.raised.fill" }
        switch phase {
        case .thinking: return "brain"
        case .tool: return "gearshape.2"
        case .replying: return "waveform"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// The line under the title: what the reply was doing, or what to do about one that stopped.
    func detailLine(stale: Bool, question: String) -> String {
        if stale, isLive { return "Open Redde to see where it got to." }
        if let approval = pendingApproval(stale: stale) { return approval.command }
        if let step = step(stale: stale) { return step }
        return phase == .thinking ? question : detail
    }
}

extension EchoTurnAttributes.ContentState.Progress {
    var fraction: Double { total > 0 ? min(max(Double(done) / Double(total), 0), 1) : 0 }
    /// "3/6", for the Dynamic Island's few points.
    var short: String { "\(done)/\(total)" }
    /// "3 of 6 done".
    var summary: String { done >= total ? "All \(total) done" : "\(done) of \(total) done" }
}

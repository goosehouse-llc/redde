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
    func title(stale: Bool) -> String {
        if stale, isLive { return "Reply interrupted" }
        if pendingApproval(stale: stale) != nil { return "Needs your approval" }
        switch phase {
        case .thinking: return "Redde is thinking"
        case .tool: return "Using \(detail)"
        case .replying: return "Redde is replying"
        case .done: return "Redde replied"
        case .failed: return "Redde couldn't reply"
        }
    }

    func compact(stale: Bool) -> String {
        if stale, isLive { return "stopped" }
        if pendingApproval(stale: stale) != nil { return "approve?" }
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
        return phase == .thinking ? question : detail
    }
}

import Foundation
import Testing
@testable import Echo

/// What the Live Activity says: while a reply runs, and once the app has stopped updating it.
struct TurnActivityStateTests {
    private func state(_ phase: EchoTurnAttributes.ContentState.Phase, _ detail: String = "") -> EchoTurnAttributes.ContentState {
        .init(phase: phase, detail: detail, startedAt: .now)
    }

    @Test func aRunningReplySaysWhatItIsDoing() {
        #expect(state(.thinking).title(stale: false) == "Redde is thinking")
        #expect(state(.tool, "terminal").title(stale: false) == "Using terminal")
        #expect(state(.tool, "terminal").compact(stale: false) == "terminal")
        #expect(state(.replying, "The cabinets").detailLine(stale: false, question: "When?") == "The cabinets")
        #expect(state(.thinking).detailLine(stale: false, question: "When?") == "When?")
    }

    /// The app crashed, was closed or was suspended mid-reply: nothing ended the activity, so the
    /// system's "stale" is all there is to go on, and a reply that was running must stop looking busy.
    @Test func aReplyThatStoppedHearingFromTheAppShowsAsInterrupted() {
        for phase in [EchoTurnAttributes.ContentState.Phase.thinking, .tool, .replying] {
            let stopped = state(phase, "terminal")
            #expect(stopped.isLive)
            #expect(stopped.title(stale: true) == "Reply interrupted")
            #expect(stopped.compact(stale: true) == "stopped")
            #expect(stopped.symbol(stale: true) == "pause.circle.fill")
            #expect(stopped.detailLine(stale: true, question: "When?") == "Open Redde to see where it got to.")
        }
    }

    /// A reply that finished, or failed and said so, is what it is however old the banner gets.
    @Test func aFinishedReplyDoesntTurnIntoAnInterruption() {
        #expect(!state(.done).isLive)
        #expect(state(.done, "All set.").title(stale: true) == "Redde replied")
        #expect(state(.done, "All set.").detailLine(stale: true, question: "When?") == "All set.")
        #expect(state(.failed, "No connection").title(stale: true) == "Redde couldn't reply")
        #expect(state(.failed).symbol(stale: true) == "exclamationmark.triangle.fill")
    }

    /// The app refreshes a live activity more than twice within the time it takes to go stale,
    /// so one missed refresh doesn't make a running reply look interrupted.
    @Test func theHeartbeatOutpacesTheStaleDate() {
        #expect(EchoTurnAttributes.refreshEvery * 2 < EchoTurnAttributes.staleAfter)
    }
}

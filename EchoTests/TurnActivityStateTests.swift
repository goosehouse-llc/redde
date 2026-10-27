import Foundation
import Testing
@testable import Echo

/// What the Live Activity says: while a reply runs, and once the app has stopped updating it.
struct TurnActivityStateTests {
    private func state(_ phase: EchoTurnAttributes.ContentState.Phase, _ detail: String = "") -> EchoTurnAttributes.ContentState {
        .init(phase: phase, detail: detail, startedAt: .now)
    }

    /// The Lock Screen named Redde beside iOS's own card naming Sol (2026-10-26): it says who answers.
    @Test func itNamesTheAgentAnswering() throws {
        #expect(state(.thinking).title(stale: false, agent: "Sol") == "Sol is thinking")
        #expect(state(.replying).title(stale: false, agent: "Home") == "Home is replying")
        #expect(state(.done).title(stale: false, agent: "Home") == "Home replied")
        #expect(state(.failed).title(stale: false, agent: "Sol") == "Sol couldn't reply")
        #expect(state(.thinking).title(stale: false, agent: "  ") == "Redde is thinking", "no name: Redde")
        // An activity an older build started has no agent, and still reads.
        let old = try JSONDecoder().decode(EchoTurnAttributes.self, from: Data(#"{"question":"Is the tree on?"}"#.utf8))
        #expect(old.agent == nil && old.question == "Is the tree on?")
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

    // MARK: A command waiting for a yes or no

    private func waiting(_ phase: EchoTurnAttributes.ContentState.Phase = .tool) -> EchoTurnAttributes.ContentState {
        var state = state(phase, "terminal")
        state.approval = .init(id: "req1", command: "rm -rf build", approve: "once", deny: "deny")
        return state
    }

    @Test func aCommandWaitingForAnAnswerTakesOverTheActivity() {
        let state = waiting()
        #expect(state.pendingApproval(stale: false)?.id == "req1")
        #expect(state.title(stale: false) == "Needs your approval")
        #expect(state.compact(stale: false) == "approve?")
        #expect(state.symbol(stale: false) == "hand.raised.fill")
        #expect(state.detailLine(stale: false, question: "Clean up?") == "rm -rf build")
    }

    /// The buttons run in the app. Once it has stopped updating the activity there is nobody to
    /// take the answer, so a stale activity shows the interruption and no buttons.
    @Test func aStaleActivityOffersNoButtons() {
        let state = waiting()
        #expect(state.pendingApproval(stale: true) == nil)
        #expect(state.title(stale: true) == "Reply interrupted")
        #expect(waiting(.done).pendingApproval(stale: false) == nil, "a finished reply has nothing left to approve")
    }

    /// An activity started by an earlier build has no approval in its state.
    @Test func aStateWithoutAnApprovalStillDecodes() throws {
        let old = #"{"phase":"tool","detail":"terminal","startedAt":0}"#
        let state = try JSONDecoder().decode(EchoTurnAttributes.ContentState.self, from: Data(old.utf8))
        #expect(state.approval == nil)
        #expect(state.title(stale: false) == "Using terminal")
    }

    @Test func buttonsNeedBothAYesAndANo() {
        #expect(ApprovalRequest(id: "a", command: "x", description: nil, choices: ["once", "session", "always", "deny"]).yesNo?.approve == "once")
        #expect(ApprovalRequest(id: "a", command: "x", description: nil, choices: ["session", "deny"]).yesNo?.approve == "session")
        #expect(ApprovalRequest(id: "a", command: "x", description: nil, choices: ["once"]).yesNo == nil)
        #expect(ApprovalRequest(id: "a", command: "x", description: nil, choices: ["deny"]).yesNo == nil)
    }

    /// The app refreshes a live activity more than twice within the time it takes to go stale,
    /// so one missed refresh doesn't make a running reply look interrupted.
    @Test func theHeartbeatOutpacesTheStaleDate() {
        #expect(EchoTurnAttributes.refreshEvery * 2 < EchoTurnAttributes.staleAfter)
    }

    // MARK: The agent's task list

    private func item(_ id: String, _ content: String, _ status: TodoItem.Status, parent: String? = nil) -> TodoItem {
        TodoItem(id: id, content: content, status: status, parent: parent)
    }

    @Test func theListBecomesACountAndTheTaskInHand() throws {
        let list = [item("1", "Export the posts", .completed), item("2", "Import the posts", .inProgress),
                    item("3", "Check every link", .pending), item("4", "Tell the mailing list", .cancelled)]
        let progress = try #require(TodoList.progress(list))
        #expect(progress.done == 1 && progress.total == 3, "a cancelled task is neither done nor left to do")
        #expect(progress.current == "Import the posts")
        #expect(progress.summary == "1 of 3 done" && progress.short == "1/3")
        #expect(abs(progress.fraction - 1.0 / 3) < 0.001)

        let finished = try #require(TodoList.progress(list.map { item($0.id, $0.content, $0.status == .cancelled ? .cancelled : .completed) }))
        #expect(finished.summary == "All 3 done" && finished.fraction == 1 && finished.current == nil)
        // Of a task and its subtask both in hand, the subtask is the one being done.
        let nested = [item("1", "Move the blog", .inProgress), item("2", "Redirect the old addresses", .inProgress, parent: "1"), item("3", "Switch over", .pending)]
        #expect(TodoList.progress(nested)?.current == "Redirect the old addresses")
        // One task is not a list to follow, and neither is none.
        #expect(TodoList.progress([item("1", "Export the posts", .inProgress)]) == nil)
        #expect(TodoList.progress([]) == nil)
        #expect(TodoList.progress([item("1", String(repeating: "long ", count: 60), .inProgress), item("2", "b", .pending)])?.current?.count == 90)
    }

    private func working(_ phase: EchoTurnAttributes.ContentState.Phase = .tool, done: Int = 3) -> EchoTurnAttributes.ContentState {
        var state = state(phase, phase == .tool ? "terminal" : phase == .replying ? "The blog is" : "")
        state.progress = .init(done: done, total: 6, current: "Redirect the old addresses")
        return state
    }

    @Test func aLongJobShowsHowFarItHasGot() {
        let state = working()
        #expect(state.title(stale: false) == "Using terminal", "what it is doing stays the headline")
        #expect(state.compact(stale: false) == "3/6", "the count is what the island shows at rest")
        #expect(state.step(stale: false) == "Redirect the old addresses")
        #expect(state.detailLine(stale: false, question: "Move the blog") == "Redirect the old addresses")
        #expect(working(.thinking).detailLine(stale: false, question: "Move the blog") == "Redirect the old addresses")
        // While the reply is being written, its words are the line; the count stays.
        let replying = working(.replying)
        #expect(replying.step(stale: false) == nil && replying.detailLine(stale: false, question: "Move the blog") == "The blog is")
        #expect(replying.compact(stale: false) == "3/6" && replying.tasks(stale: false)?.summary == "3 of 6 done")
    }

    @Test func aCommandWaitingForAnAnswerComesBeforeTheList() {
        var state = working()
        state.approval = .init(id: "req1", command: "rm -rf build", approve: "once", deny: "deny")
        #expect(state.tasks(stale: false) == nil && state.step(stale: false) == nil)
        #expect(state.compact(stale: false) == "approve?")
        #expect(state.detailLine(stale: false, question: "Move the blog") == "rm -rf build")
    }

    /// Where it got to is still worth reading on a reply that stopped, and on one that finished.
    @Test func theCountStaysOnAReplyThatStoppedOrFinished() {
        let stopped = working()
        #expect(stopped.compact(stale: true) == "stopped" && stopped.step(stale: true) == nil)
        #expect(stopped.tasks(stale: true)?.summary == "3 of 6 done")
        #expect(stopped.detailLine(stale: true, question: "Move the blog") == "Open Redde to see where it got to.")
        var done = working(.done, done: 6)
        done.detail = "The blog is on the new site."
        #expect(done.compact(stale: false) == "done" && done.tasks(stale: false)?.summary == "All 6 done")
        #expect(done.detailLine(stale: false, question: "Move the blog") == "The blog is on the new site.")
    }

    /// A state written before there was a list on it still reads.
    @Test func anOlderStateDecodes() throws {
        let old = #"{"phase":"tool","detail":"terminal","startedAt":781000000}"#
        let state = try JSONDecoder().decode(EchoTurnAttributes.ContentState.self, from: Data(old.utf8))
        #expect(state.progress == nil && state.compact(stale: false) == "terminal")
    }
}

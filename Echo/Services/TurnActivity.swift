#if os(iOS)
import ActivityKit
import Foundation
import os

/// Drives the Live Activity for the turn in flight. Updates are throttled so a fast token
/// stream doesn't hammer ActivityKit; the final state lingers so a glance later still shows it.
///
/// An activity outlives the app: if the app crashes, is closed or is suspended mid-reply, nothing
/// is left to end it, and it would sit in the Dynamic Island looking busy for hours. So every
/// update carries a stale date a little way off and a heartbeat keeps pushing it out while the
/// reply runs; once the app stops, the system marks the activity stale and it shows as
/// interrupted. The next launch clears whatever an earlier run left behind.
@MainActor
final class TurnActivity {
    static let shared = TurnActivity()
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "activity")
    private var activity: Activity<EchoTurnAttributes>?
    private var pending: EchoTurnAttributes.ContentState?
    private var flushTask: Task<Void, Never>?
    private var lastFlush = Date.distantPast
    private var preview = ""
    /// The state last sent, for the heartbeat to send again with a later stale date.
    private var lastState: EchoTurnAttributes.ContentState?
    private var heartbeat: Task<Void, Never>?
    /// The command waiting for an answer, carried on every update until it is settled.
    private var approval: EchoTurnAttributes.ContentState.Approval?
    /// How far the agent is down its task list, carried on every update once it has said.
    private var progress: EchoTurnAttributes.ContentState.Progress?
    /// The turn whose activity is being asked for (off the main actor: the first request of a
    /// launch held a send's frame ~45 ms on the simulator). What happens meanwhile waits in
    /// `pending`; a turn over before its activity arrives ends it with its last word, if it had one.
    private var requesting: UUID?
    private var endedWhileRequesting: [UUID: EchoTurnAttributes.ContentState?] = [:]
    private var turnStartedAt: Date?

    /// Ends activities this object isn't driving: left by a run of the app that crashed or was
    /// closed mid-reply. Called at launch, when nothing can be in flight, and before each turn.
    func clearStrays() {
        for stray in Activity<EchoTurnAttributes>.activities where stray.id != activity?.id {
            nonisolated(unsafe) let stray = stray   // see `flush`
            Task { await stray.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// `agent`: who is answering, for "Sol is thinking" (`EchoTurnAttributes.agent`).
    func start(question: String, agent: String? = nil) {
        end(final: nil)
        clearStrays()
        guard Settings.shared.showLiveActivity else { return }
        preview = ""
        let attributes = EchoTurnAttributes(question: String(question.prefix(120)), agent: agent.map { String($0.prefix(40)) })
        let state = EchoTurnAttributes.ContentState(phase: .thinking, detail: "", startedAt: .now)
        let turn = UUID()
        (requesting, turnStartedAt, lastState) = (turn, state.startedAt, state)
        let content = content(state)
        Task {
            let made = await Self.request(attributes, content, log: log)
            let final = endedWhileRequesting.removeValue(forKey: turn)
            guard requesting == turn else {
                // Over already, or another turn began: it goes with its last word, if any.
                if let made { Self.end(made.activity, final: final ?? nil) }
                return
            }
            requesting = nil
            guard let made else { (lastState, pending) = (nil, nil); return }
            activity = made.activity
            startHeartbeat()
            if let pending { flush(pending) }
        }
    }

    /// `Activity` isn't Sendable (see `flush`): handed back from the request in this.
    private nonisolated struct Made: @unchecked Sendable { let activity: Activity<EchoTurnAttributes> }

    @concurrent private static func request(_ attributes: EchoTurnAttributes, _ content: ActivityContent<EchoTurnAttributes.ContentState>,
                                            log: Logger) async -> Made? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        do {
            return Made(activity: try Activity.request(attributes: attributes, content: content, pushType: nil))
        } catch {
            log.info("live activity unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    func tool(_ name: String) { push(.tool, name) }

    /// A command is waiting for a yes or no: the activity shows it with Approve and Deny
    /// (`ApproveRequestIntent`, `DenyRequestIntent`). Only when the request offers both.
    func needsApproval(_ request: ApprovalRequest) {
        guard isOn, let choices = request.yesNo else { return }
        approval = .init(id: request.id, command: String(request.command.prefix(160)),
                         approve: choices.approve, deny: choices.deny)
        refresh()
    }

    /// Answered, expired or cancelled: back to what the turn is doing.
    func approvalSettled() {
        guard approval != nil else { return }
        approval = nil
        refresh()
    }

    /// The agent's task list has changed in this turn: "3 of 6" and the task in hand go on the
    /// activity. (A list left from an earlier turn that this one hasn't touched is not shown: a
    /// quick question about something else would wear another job's count.)
    func tasks(_ items: [TodoItem]) {
        let now = TodoList.progress(items)
        guard isOn, now != progress else { return }
        progress = now
        refresh()
    }

    /// The latest state again, at once, with the approval and the task list as they now stand.
    private func refresh() {
        guard var state = pending ?? lastState else { return }
        state.approval = approval
        state.progress = progress
        flush(state)
    }

    func replyDelta(_ delta: String) {
        // The banner shows 160 characters; past that the preview is fixed, so stop growing it.
        guard preview.count < 160 else { return }
        preview += delta
        push(.replying, String(preview.prefix(160)))
    }

    func finish(reply: String) {
        end(final: .init(phase: .done, detail: String(reply.prefix(200)), startedAt: startedAt, progress: progress))
    }

    func fail(_ message: String) {
        end(final: .init(phase: .failed, detail: String(message.prefix(160)), startedAt: startedAt, progress: progress))
    }

    /// The turn goes on, but not here: the activity goes without a last word.
    func leave() { end(final: nil) }

    // MARK: - Internals

    /// A turn has an activity, or one is being asked for.
    private var isOn: Bool { activity != nil || requesting != nil }

    private var startedAt: Date { turnStartedAt ?? .now }

    /// A live state, good until a little after the next heartbeat is due.
    private func content(_ state: EchoTurnAttributes.ContentState) -> ActivityContent<EchoTurnAttributes.ContentState> {
        .init(state: state, staleDate: .now.addingTimeInterval(EchoTurnAttributes.staleAfter))
    }

    /// Sends the current state again every so often, so a long quiet stretch (a slow tool, a
    /// model thinking) doesn't go stale while the app is alive and listening.
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(EchoTurnAttributes.refreshEvery))
                guard let self, !Task.isCancelled, activity != nil, let lastState else { return }
                if Date.now.timeIntervalSince(lastFlush) >= EchoTurnAttributes.refreshEvery - 1 { flush(pending ?? lastState) }
            }
        }
    }

    private func push(_ phase: EchoTurnAttributes.ContentState.Phase, _ detail: String) {
        guard isOn else { return }
        var state = EchoTurnAttributes.ContentState(phase: phase, detail: detail, startedAt: startedAt)
        state.approval = approval
        state.progress = progress
        if activity == nil {
            pending = state   // sent when the activity arrives
        } else if Date.now.timeIntervalSince(lastFlush) > 1 {
            flush(state)
        } else {
            // One pending flush at a time: it picks up whatever is newest when it fires,
            // instead of a cancel-and-recreate per token.
            pending = state
            guard flushTask == nil else { return }
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                flushTask = nil
                guard !Task.isCancelled, let pending else { return }
                flush(pending)
            }
        }
    }

    /// Updates chained one after another so they land in order. `Activity` isn't Sendable in
    /// the iOS 27 SDK, yet its update and end run off the main actor; ActivityKit serializes
    /// them itself, so handing the object over is safe (`nonisolated(unsafe)` below).
    private var updateChain: Task<Void, Never>?

    private func flush(_ state: EchoTurnAttributes.ContentState) {
        guard let current = activity else {
            if requesting != nil { pending = state }
            return
        }
        nonisolated(unsafe) let activity = current
        pending = nil
        lastFlush = .now
        lastState = state
        let content = content(state)
        let previous = updateChain
        updateChain = Task {
            await previous?.value
            await activity.update(content)
        }
    }

    private func end(final: EchoTurnAttributes.ContentState?) {
        if let requesting { endedWhileRequesting[requesting] = .some(final) }
        requesting = nil
        turnStartedAt = nil
        flushTask?.cancel()
        flushTask = nil
        heartbeat?.cancel()
        heartbeat = nil
        lastState = nil
        pending = nil
        approval = nil
        progress = nil
        guard let current = activity else { return }
        self.activity = nil
        Self.end(current, final: final, after: updateChain)
    }

    /// The last word stays two minutes; without one the activity goes at once.
    private static func end(_ current: Activity<EchoTurnAttributes>, final: EchoTurnAttributes.ContentState?, after previous: Task<Void, Never>? = nil) {
        nonisolated(unsafe) let activity = current
        Task {
            await previous?.value
            if let final {
                await activity.end(.init(state: final, staleDate: nil), dismissalPolicy: .after(.now + 2 * 60))
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
#else
import Foundation

/// The Mac has no Live Activities: a reply shows in its window. The iPhone's calls, which do
/// nothing, so the conversation's code is the same on both.
@MainActor
final class TurnActivity {
    static let shared = TurnActivity()

    func clearStrays() {}
    func start(question: String, agent: String? = nil) {}
    func tool(_ name: String) {}
    func needsApproval(_ request: ApprovalRequest) {}
    func approvalSettled() {}
    func tasks(_ items: [TodoItem]) {}
    func replyDelta(_ delta: String) {}
    func finish(reply: String) {}
    func fail(_ message: String) {}
    func leave() {}
}
#endif

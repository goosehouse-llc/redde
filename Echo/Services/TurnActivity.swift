import ActivityKit
import Foundation
import os

/// Drives the Live Activity for the turn in flight. Updates are throttled so a fast token
/// stream doesn't hammer ActivityKit; the final state lingers so a glance later still shows it.
@MainActor
final class TurnActivity {
    static let shared = TurnActivity()
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "activity")
    private var activity: Activity<EchoTurnAttributes>?
    private var pending: EchoTurnAttributes.ContentState?
    private var flushTask: Task<Void, Never>?
    private var lastFlush = Date.distantPast
    private var preview = ""

    private var enabled: Bool {
        Settings.shared.showLiveActivity && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(question: String) {
        end(final: nil)
        // A crash mid-turn leaves the old banner on the Lock Screen for hours; clear strays first.
        for stray in Activity<EchoTurnAttributes>.activities {
            nonisolated(unsafe) let stray = stray   // see `flush`
            Task { await stray.end(nil, dismissalPolicy: .immediate) }
        }
        guard enabled else { return }
        preview = ""
        let attributes = EchoTurnAttributes(question: String(question.prefix(120)))
        let state = EchoTurnAttributes.ContentState(phase: .thinking, detail: "", startedAt: .now)
        do {
            activity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil), pushType: nil)
        } catch {
            log.info("live activity unavailable: \(error.localizedDescription)")
        }
    }

    func tool(_ name: String) { push(.tool, name) }

    func replyDelta(_ delta: String) {
        // The banner shows 160 characters; past that the preview is fixed, so stop growing it.
        guard preview.count < 160 else { return }
        preview += delta
        push(.replying, String(preview.prefix(160)))
    }

    func finish(reply: String) {
        end(final: .init(phase: .done, detail: String(reply.prefix(200)), startedAt: startedAt))
    }

    func fail(_ message: String) {
        end(final: .init(phase: .failed, detail: String(message.prefix(160)), startedAt: startedAt))
    }

    // MARK: - Internals

    private var startedAt: Date { activity?.content.state.startedAt ?? .now }

    private func push(_ phase: EchoTurnAttributes.ContentState.Phase, _ detail: String) {
        guard let activity else { return }
        let state = EchoTurnAttributes.ContentState(phase: phase, detail: detail, startedAt: activity.content.state.startedAt)
        if Date.now.timeIntervalSince(lastFlush) > 1 {
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
        guard let current = activity else { return }
        nonisolated(unsafe) let activity = current
        pending = nil
        lastFlush = .now
        let previous = updateChain
        updateChain = Task {
            await previous?.value
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    private func end(final: EchoTurnAttributes.ContentState?) {
        flushTask?.cancel()
        flushTask = nil
        pending = nil
        guard let current = activity else { return }
        nonisolated(unsafe) let activity = current
        self.activity = nil
        let previous = updateChain
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

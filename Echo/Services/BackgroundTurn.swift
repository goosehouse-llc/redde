import BackgroundTasks
import UIKit
import os

/// Keeps the process alive after backgrounding while a turn is streaming, so the reply can
/// finish and a notification can be posted.
///
/// Two mechanisms run side by side. A UIKit background task buys about 30 seconds, as it always
/// has. On top of it, a turn the person starts in the app is submitted as an iOS 26
/// continued-processing task: work iOS lets run on after the phone locks or the app is left, with
/// network access, under a system activity that shows progress and a stop button. Without it a
/// reply that outlasted auto-lock died half a minute later.
///
/// iOS may refuse the task (system load, a turn started from the background by Siri or a
/// notification button, a Mac, the simulator) or end it early; the 30 seconds are the fallback.
@MainActor
final class BackgroundTurn {
    static let shared = BackgroundTurn()
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "background")

    private var task: UIBackgroundTaskIdentifier = .invalid
    /// iOS ran out the window during this turn: the app was suspended and its connection dropped.
    private(set) var expired = false

    /// Matches `BGTaskSchedulerPermittedIdentifiers` in Info.plist (`com.goosehouse.echo.turn.*`).
    nonisolated static let identifierPrefix = "com.goosehouse.echo.turn."
    /// The request submitted for this turn; `continued` is set once iOS starts it.
    private var continuedID: String?
    private var continued: BGContinuedProcessingTask?
    private var ticker: Task<Void, Never>?
    private var startedAt = Date.now

    /// iOS started this turn's continued-processing task.
    var isContinuing: Bool { continued != nil }
    /// Why the last request wasn't taken, if it wasn't.
    private(set) var refusal: String?

    func begin(question: String = "") {
        if task == .invalid {
            expired = false
            task = UIApplication.shared.beginBackgroundTask(withName: "redde.turn") { [weak self] in
                // With a continued task running, the turn goes on; otherwise this was the window.
                if self?.continued == nil { self?.expired = true }
                self?.endShortTask()
            }
        }
        submitContinuedTask(question: question)
    }

    /// The turn is over. `success` only colours the system activity's last state.
    func end(success: Bool = true) {
        endShortTask()
        ticker?.cancel()
        ticker = nil
        if let continued {
            continued.progress.completedUnitCount = continued.progress.totalUnitCount
            continued.setTaskCompleted(success: success)
        } else if let continuedID {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedID)   // submitted, never started
        }
        continued = nil
        continuedID = nil
    }

    private func endShortTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }

    // MARK: - Continued processing

    private func submitContinuedTask(question: String) {
        // Only for a turn started in front of the person: iOS ties the request to the foreground
        // app. (Inactive is still in front: a Face ID sheet or a system alert is up.) An iOS app
        // on a Mac has no such scheduler.
        guard continuedID == nil, !ProcessInfo.processInfo.isiOSAppOnMac,
              UIApplication.shared.applicationState != .background else { return }
        let id = Self.identifierPrefix + UUID().uuidString
        refusal = nil
        guard Self.register(id) else {
            refusal = "registration refused"
            log.info("continued task: registration refused")
            return
        }
        let subtitle = question.split(whereSeparator: \.isNewline).joined(separator: " ")
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "\(Settings.shared.headerTitle) is working",
                                                       subtitle: subtitle.isEmpty ? "Replying" : String(subtitle.prefix(80)))
        // Fail rather than queue: a reply that starts late in the background is no use, and the
        // 30-second task is already running.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            continuedID = id
            startedAt = .now
        } catch {
            refusal = "\(error)"
            log.info("continued task not accepted: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The launch and expiration handlers are called off the main actor's executor by the
    /// scheduler; closures written in main-actor code would trap there, so both are formed here.
    nonisolated private static func register(_ id: String) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            task.expirationHandler = {
                Task { @MainActor in BackgroundTurn.shared.continuedTaskExpired(id) }
            }
            // Called on the main queue (see `using:`), so this is the main actor's own thread;
            // the task object isn't Sendable and the compiler can't see that it never leaves it.
            nonisolated(unsafe) let started = task
            MainActor.assumeIsolated { BackgroundTurn.shared.continuedTaskStarted(started, id: id) }
        }
    }

    private func continuedTaskStarted(_ started: BGContinuedProcessingTask, id: String) {
        guard id == continuedID else {
            started.setTaskCompleted(success: true)   // the turn ended before iOS got to it
            return
        }
        continued = started
        started.progress.totalUnitCount = Self.progressTotal
        started.progress.completedUnitCount = Self.progress(after: Date.now.timeIntervalSince(startedAt))
        // iOS expires a task that looks stalled, and a reply has no known length: the bar creeps
        // toward the end and never arrives until the turn does.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let continued = self.continued, !Task.isCancelled else { return }
                continued.progress.completedUnitCount = Self.progress(after: Date.now.timeIntervalSince(self.startedAt))
            }
        }
    }

    /// iOS took the time back, or the person pressed stop on the system activity; the two can't
    /// be told apart. The turn is not cancelled: on a Hermes connection the agent keeps working
    /// on the server and the reply is picked up on return, and stopping it for a system reason
    /// would throw that work away. Stop in the app still stops it.
    private func continuedTaskExpired(_ id: String) {
        guard id == continuedID, let continued else { return }
        log.info("continued task expired")
        ticker?.cancel()
        ticker = nil
        self.continued = nil
        continuedID = nil
        if task == .invalid { expired = true }
        continued.setTaskCompleted(success: false)
    }

    nonisolated static let progressTotal: Int64 = 1_000_000

    /// A third of the way after a minute, 71% after five, 94% after half an hour: always moving.
    nonisolated static func progress(after elapsed: TimeInterval) -> Int64 {
        let t = max(0, elapsed)
        return min(progressTotal - 1, Int64(Double(progressTotal) * t / (t + 120)))
    }
}


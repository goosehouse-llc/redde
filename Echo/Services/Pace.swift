import Foundation
import Observation

/// How often Redde asks the host for news while it is open (the battery review, 2026-11-11):
/// often while something is under way, now and then while nothing is, and less often again in
/// Low Power Mode. Each request wakes the phone's radio for some ten seconds, so a few seconds
/// between them kept it awake the whole time the iPad's sidebar or the Mac's window was open.
@MainActor @Observable
final class Pace {
    static let shared = Pace()

    /// Low Power Mode, as last heard.
    private(set) var saving = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Redde on screen: in front on the iPhone and iPad, its window visible on the Mac (not hidden,
    /// minimised, covered or with the display asleep). Set by the app (`EchoApp`, `ReddeMacApp`).
    /// The chat list asks only while it is; the open chat goes by `Conversation.appIsActive`.
    var onScreen = true

    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Pace.shared.saving = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
    }

    /// The wait before the next look: `busy` while something is under way, `idle` otherwise,
    /// each three times as long in Low Power Mode.
    func wait(busy: Bool, _ busyWait: Duration, idle idleWait: Duration) -> Duration {
        Self.wait(busy: busy, busyWait, idle: idleWait, saving: saving)
    }

    nonisolated static func wait(busy: Bool, _ busyWait: Duration, idle idleWait: Duration, saving: Bool) -> Duration {
        let base = busy ? busyWait : idleWait
        return saving ? base * 3 : base
    }
}

import Foundation
#if os(macOS)
import AppKit
import CoreGraphics
#endif

/// Notifications where you are (asked 2026-11-05, from the Muse / Grok Bot list): every paired
/// device used to get every note, so at the Mac the iPhone buzzed beside it. Now a device in use
/// tells the paired Hermes so (`/redde-push here <devices> <until>`, plugin 1.19.0), again every
/// minute while it is, and that it isn't as it is left; while one is, the plugin sends its notes
/// there alone (`Store.where_you_are`). With none in use, every device hears, as before.
///
/// - iPhone and iPad: in use while Redde is on screen.
/// - Mac: in use while Redde is running and someone is at the Mac: input within the last five
///   minutes, the screen awake and unlocked. Redde needn't be in front: working in another app at
///   the Mac is being at the Mac.
///
/// Said over the Dashboard, the only way to the plugin's commands; a Hermes API connection without
/// its login says nothing, and every device hears. A device that stops saying so (closed, asleep,
/// out of reach) is forgotten within three minutes (`lasts`).
@MainActor
final class WhereYouAre {
    static let shared = WhereYouAre()

    /// How long each saying holds, and how often it is said again while in use.
    static let lasts: TimeInterval = 180
    static let every: Duration = .seconds(60)
    #if os(macOS)
    /// No input for this long and the person has left the Mac.
    static let idleAfter: TimeInterval = 300
    #endif

    private var loop: Task<Void, Never>?
    /// What was last said to the plugin: in use or not (nil: nothing yet).
    private(set) var saidHere: Bool?
    /// The app is on screen (iPhone, iPad) or running (Mac).
    private var appInFront = false
    #if os(macOS)
    /// The Mac's screen is locked or asleep, or another user has it.
    private var macAway = false
    private var observers: [NSObjectProtocol] = []
    #endif

    /// Redde came on screen, or the Mac app started.
    func cameForward() {
        appInFront = true
        start()
    }

    /// Redde went to the background (iPhone, iPad). On the Mac the app being behind another
    /// changes nothing.
    func wentBack() {
        #if os(iOS)
        appInFront = false
        loop?.cancel()
        loop = nil
        tell(false)
        #endif
    }

    /// The setting changed, or a pairing was made: say where things stand now.
    func settingChanged() {
        saidHere = nil
        if Settings.shared.notifyWhereYouAre, appInFront { start() } else { loop?.cancel(); loop = nil; tell(false) }
    }

    /// Whether this device counts as in use now.
    var inUse: Bool {
        guard appInFront, Settings.shared.notifyWhereYouAre else { return false }
        #if os(macOS)
        return !macAway && Self.idleSeconds() < Self.idleAfter
        #else
        return true
        #endif
    }

    private func start() {
        #if os(macOS)
        watchTheMac()
        #endif
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tell(self?.inUse ?? false, again: true)
                try? await Task.sleep(for: Self.every)
            }
        }
    }

    /// Says it to the plugin: in use (for another `lasts`), or no longer. `again`: in use is said
    /// each time (it runs out); no longer only once.
    private func tell(_ here: Bool, again: Bool = false) {
        guard here || saidHere != false else { return }
        if here, saidHere == true, !again { return }
        saidHere = here
        let server = Settings.shared.connectionKey
        Task {
            let said = await PushService.shared.sayHere(until: here ? .now.addingTimeInterval(Self.lasts) : nil, server: server)
            // Not said (no Dashboard, no plugin, no pairing): said again on the next round.
            if !said, self.saidHere == here { self.saidHere = nil }
        }
    }

    #if os(macOS)
    /// Seconds since the last key press, click or move of the mouse, anywhere on the Mac.
    static func idleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// The screen locking or sleeping, the Mac sleeping, another user switched to: away at once,
    /// not at the next round. Back when it wakes or unlocks, and the next input says so.
    private func watchTheMac() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func away(_ gone: Bool) -> (Notification) -> Void {
            { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.macAway = gone
                    self.tell(self.inUse, again: true)
                }
            }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main, using: away(true)))
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main, using: away(false)))
        }
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: away(true)))
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: away(false)))
    }
    #endif
}

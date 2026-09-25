import AVFAudio
import Foundation
import MediaPlayer

/// Headset and Lock Screen buttons for the voice screen. While it's open, Redde is the Now Playing
/// app, so an AirPods press (and the Lock Screen / CarPlay play-pause) arrives here as a remote
/// command, and the AirPods mute gesture during listening arrives as an input-mute change. Both do
/// what tapping the mic does.
///
/// Handlers are formed in this nonisolated type and hop to the main actor themselves: the system
/// may call them off the main thread, and a main-actor closure called there traps.
nonisolated final class HeadsetControls: @unchecked Sendable {
    static let shared = HeadsetControls()

    private let lock = NSLock()
    private var targets: [(MPRemoteCommand, Any)] = []
    private var muteObserver: NSObjectProtocol?

    /// Starts routing headset presses to `primary`. Calling again replaces the handler.
    func enable(primary: @escaping @MainActor @Sendable () -> Void) {
        disable()
        let center = MPRemoteCommandCenter.shared()
        let fire: @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { primary() } }
            return .success
        }
        var added: [(MPRemoteCommand, Any)] = []
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            command.isEnabled = true
            added.append((command, command.addTarget(handler: fire)))
        }
        // The AirPods mute gesture while the mic is open: treat it as a press, then unmute so the
        // next listen isn't silently zeroed.
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: nil
        ) { note in
            guard (note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue == true else { return }
            try? AVAudioApplication.shared.setInputMuted(false)
            DispatchQueue.main.async { MainActor.assumeIsolated { primary() } }
        }
        lock.lock(); targets = added; muteObserver = observer; lock.unlock()
    }

    func disable() {
        lock.lock()
        let old = targets, observer = muteObserver
        targets = []; muteObserver = nil
        lock.unlock()
        for (command, target) in old { command.removeTarget(target) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// What the Lock Screen and Control Center show while the voice screen is open.
    func setNowPlaying(status: String, active: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Redde",
            MPMediaItemPropertyArtist: status,
        ]
        MPNowPlayingInfoCenter.default().playbackState = active ? .playing : .paused
    }
}

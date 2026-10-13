import AVFoundation
import Foundation

/// The sound voice mode makes while the agent works and nothing is being said: a soft double
/// pulse, round and round, so that silence isn't taken for a failure by someone who can't look
/// at the screen. `VoiceSession` decides when; this plays it.
@MainActor
protocol ThinkingSounding: AnyObject {
    func start()
    func stop()
}

/// Plays the bundled loop (`scripts/thinking-sound.py` makes it) through the app's audio
/// session, like the listening tones: on the voice session it follows the reply to the car, the
/// headphones or the speaker, and ignores the ring/silent switch.
@MainActor
final class ThinkingSoundPlayer: ThinkingSounding {
    static let shared = ThinkingSoundPlayer()

    private let player: AVAudioPlayer?
    private(set) var isPlaying = false
    private var winding: Task<Void, Never>?
    private var sample: Task<Void, Never>?
    /// How long the sound takes to go when it is stopped: gone before the reply's first word is
    /// out, and not cut off with a click.
    private static let fade = 0.12

    private init() {
        player = Bundle.main.url(forResource: "thinking", withExtension: "wav").flatMap { try? AVAudioPlayer(contentsOf: $0) }
        player?.numberOfLoops = -1
        player?.prepareToPlay()
    }

    func start() {
        // A sample being played in Settings is no longer that: it plays on, as the real thing.
        sample?.cancel()
        sample = nil
        play()
    }

    private func play() {
        guard let player, !isPlaying else { return }
        winding?.cancel()
        isPlaying = true
        player.currentTime = 0
        player.volume = 1
        player.play()
    }

    func stop() {
        guard let player, isPlaying else { return }
        isPlaying = false
        player.setVolume(0, fadeDuration: Self.fade)
        winding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fade + 0.03))
            guard let self, !Task.isCancelled, !isPlaying else { return }
            player.pause()
        }
    }

    /// Plays it twice through, for Settings: what the choice there will sound like. Outside a
    /// voice session it has to bring up an audio session of its own, and lets go of it after.
    func preview(audio: any VoiceAudioControlling = AudioSessionController.shared) {
        guard let player, !isPlaying, VoiceSession.current?.phase ?? .idle == .idle else { return }
        sample?.cancel()
        sample = Task { [weak self] in
            guard (try? audio.activateForPlayback()) != nil else { return }
            self?.play()
            try? await Task.sleep(for: .seconds(player.duration * 2))
            guard let self, !Task.isCancelled else { return }
            stop()
            try? await Task.sleep(for: .seconds(Self.fade + 0.05))
            // A conversation may have started meanwhile: then the session is its to keep.
            if !Task.isCancelled, VoiceSession.current?.phase ?? .idle == .idle { audio.deactivate() }
        }
    }
}

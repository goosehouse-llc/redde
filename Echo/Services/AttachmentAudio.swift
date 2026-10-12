import AVFoundation
import Foundation
import Observation
import os

/// Plays a sound that came with a message, in the conversation: a spoken reply from the agent's
/// speech tool, a recording it found, a voice memo that was attached. One at a time across the
/// app; starting another stops the first. What the phone can't decode is not played, and the
/// attachment is shown as a file instead (`AudioBubble`).
@Observable
final class AttachmentAudio: NSObject, AVAudioPlayerDelegate {
    static let shared = AttachmentAudio()

    /// The attachment being played, or paused part-way through.
    private(set) var current: UUID?
    private(set) var isPlaying = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let log = Logger(subsystem: "com.goosehouse.echo", category: "audio")

    /// Where the attachment's playback stands, in seconds; nothing unless it is the current one.
    func position(of id: UUID) -> TimeInterval {
        current == id ? player?.currentTime ?? 0 : 0
    }

    /// Play, or pause, or carry on. Another attachment's playback ends.
    func toggle(_ attachment: Attachment) {
        if current == attachment.id, let player {
            if player.isPlaying { player.pause(); isPlaying = false; release() } else { start(player) }
            return
        }
        stop()
        guard let made = Self.player(for: attachment) else { return }
        made.delegate = self
        player = made
        current = attachment.id
        start(made)
    }

    /// Moves to `time`, making this the current attachment if it isn't (paused there).
    func seek(_ attachment: Attachment, to time: TimeInterval) {
        if current != attachment.id {
            stop()
            guard let made = Self.player(for: attachment) else { return }
            made.delegate = self
            player = made
            current = attachment.id
        }
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
    }

    func stop() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        current = nil
        isPlaying = false
        release()
    }

    private func start(_ player: AVAudioPlayer) {
        // Like a reply read aloud: through the speaker or what is connected, whatever the ring
        // switch says. It was asked for.
        try? AudioSessionController.shared.activateForPlayback()
        isPlaying = player.play()
        if !isPlaying { log.error("an audio attachment would not play") }
    }

    /// Gives other apps their audio back, unless voice mode has the session.
    private func release() {
        guard VoiceSession.current?.mightBeBusy != true else { return }
        AudioSessionController.shared.deactivate()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }

    // MARK: - Reading a file

    /// How long the attachment plays, or nil when this phone can't play it at all.
    nonisolated static func duration(of attachment: Attachment) -> TimeInterval? {
        guard let player = player(for: attachment), player.duration > 0 else { return nil }
        return player.duration
    }

    /// A player for the attachment's bytes, read from a file named for its kind: the decoder
    /// goes by the name as much as by the contents.
    private nonisolated static func player(for attachment: Attachment) -> AVAudioPlayer? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "audio")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kind = (attachment.filename as NSString).pathExtension.lowercased()
        let url = folder.appending(path: "\(attachment.id.uuidString).\(kind.isEmpty ? "mp3" : kind)")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? attachment.data.write(to: url)) != nil else { return nil }
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        return player
    }
}

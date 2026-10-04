import AVFoundation
import MediaPlayer
import os

/// Reads a reply aloud: with the phone's Kokoro server when it has one (one request per reply,
/// a WAV file played back), else the system voice. Through paired headphones or the watch's
/// speaker.
///
/// On headphones the reply keeps playing after the wrist goes down: the app declares the `audio`
/// background mode (`WKBackgroundModes` in Info.plist) and plays under the long-form audio
/// policy, the only one watchOS keeps alive for an app that left the screen. That policy plays
/// to Bluetooth alone, so it is used only when headphones are connected; the speaker plays under
/// the default policy, which lasts while the app is on screen. The session is released when the
/// reply ends so other audio can resume.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let log = Logger(subsystem: "com.goosehouse.echo.watch", category: "speaker")
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var fetch: Task<Void, Never>?
    var onFinished: (() -> Void)?

    struct Kokoro {
        var url: URL
        var voice: String
        var speed: Double
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        // The volume control's output sheet (and a call, an alarm) interrupts the session; the
        // reply picks up where it stopped once that ends.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            guard type == .ended else { return }
            MainActor.assumeIsolated { self?.resume() }
        }
    }

    private func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        if let player, !player.isPlaying {
            player.play()
        } else if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        }
    }

    func speak(_ text: String, language: String, title: String, kokoro: Kokoro?) {
        stop(releasing: false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: "Redde"]
        fetch = Task { [weak self] in
            async let audio = Self.audio(for: text, kokoro: kokoro)
            await Self.activate()
            guard let self, !Task.isCancelled else { return }
            if let data = await audio, let player = try? AVAudioPlayer(data: data) {
                player.delegate = self
                self.player = player
                player.play()
            } else {
                if kokoro != nil { log.error("kokoro unavailable, using the system voice") }
                synthesize(text, language: language)
            }
        }
    }

    /// Headphones connected: the long-form policy, activated the asynchronous way it requires.
    /// Otherwise the speaker. Asking long-form for the speaker would put up the pairing sheet
    /// on every reply and, dismissed, leave the session with no route at all.
    nonisolated private static func activate() async {
        let session = AVAudioSession.sharedInstance()
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        let onHeadphones = session.currentRoute.outputs.contains { bluetooth.contains($0.portType) }
        if onHeadphones, (try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])) != nil {
            let activated = await withCheckedContinuation { continuation in
                session.activate(options: []) { activated, _ in continuation.resume(returning: activated) }
            }
            if activated { return }
        }
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .default, options: [])
        try? session.setActive(true)
    }

    private func synthesize(_ text: String, language: String) {
        let utterance = AVSpeechUtterance(string: text)
        if !language.isEmpty, let voice = AVSpeechSynthesisVoice(language: language) { utterance.voice = voice }
        synthesizer.speak(utterance)
    }

    nonisolated private static func audio(for text: String, kokoro: Kokoro?) async -> Data? {
        guard let kokoro else { return nil }
        return try? await kokoroAudio(text, kokoro)
    }

    /// One whole reply as WAV. The phone streams PCM sentence by sentence; a watch reply is short.
    nonisolated private static func kokoroAudio(_ text: String, _ kokoro: Kokoro) async throws -> Data {
        struct Body: Encodable {
            var model = "kokoro"; var input: String; var voice: String; var speed: Double
            var response_format = "wav"; var stream = false
        }
        var request = URLRequest(url: kokoro.url.appending(path: "v1/audio/speech"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(input: text, voice: kokoro.voice, speed: kokoro.speed))
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func stop() {
        stop(releasing: true)
    }

    private func stop(releasing: Bool) {
        fetch?.cancel()
        fetch = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        if releasing { release() }
    }

    private func release() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onFinished?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.release() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.release() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.release() }
    }
}

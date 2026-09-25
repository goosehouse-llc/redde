import Foundation

// Seams for VoiceSession's hardware dependencies, so the orchestration — phases, barge-in,
// stop phrase, hands-free relisten, offline hold, error paths — is testable with fakes.
// Production types conform one-to-one; VoiceSession never learns which it got.

/// The microphone/STT side (SpeechRecognizer in production).
@MainActor
protocol VoiceRecognizing: AnyObject {
    var transcript: String { get }
    var level: Float { get }
    /// A faster, less smoothed level for animation; defaults to `level`.
    var meterLevel: Float { get }
    /// Starts listening; `onEnd` fires with the final utterance when speech ends on its own.
    func start(onEnd: @escaping (String) -> Void) async throws
    /// Ends the utterance now and returns what was heard.
    func stop() async -> String
    func cancel()
}
extension SpeechRecognizer: VoiceRecognizing {}

extension VoiceRecognizing {
    var meterLevel: Float { level }
}

/// The TTS side (SpeechOutput in production).
@MainActor
protocol VoiceSpeaking: AnyObject {
    var onFirstSpeech: (() -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    func beginReply()
    func append(_ delta: String)
    func endReply()
    func stop()
    func releaseAudio()
    /// How loud the reply is right now, 0…1, for animation; defaults to 0.
    var meterLevel: Float { get }
    /// Hold the reply where it is, and carry on from there. Default: no-op.
    func pause()
    func resume()
}
extension SpeechOutput: VoiceSpeaking {}

extension VoiceSpeaking {
    var meterLevel: Float { 0 }
    func pause() {}
    func resume() {}
}

/// The audio-session side (AudioSessionController in production).
@MainActor
protocol VoiceAudioControlling: AnyObject {
    var onInterruption: (() -> Void)? { get set }
    var onInterruptionEnded: ((Bool) -> Void)? { get set }
    var onOutputDeviceLost: (() -> Void)? { get set }
    func activateForVoice() throws
    /// Speaking only, no microphone (Replay, Read aloud). Default: the voice configuration.
    func activateForPlayback() throws
    func deactivate()
    func refreshRoute()
}
extension AudioSessionController: VoiceAudioControlling {}

extension VoiceAudioControlling {
    func activateForPlayback() throws { try activateForVoice() }
}

import AVFoundation
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

    // Talking over a reply: the microphone open behind it, hearing levels and no words.
    /// Opens the microphone without transcribing; `onEnd` is for once it is listening.
    func startHeld(onEnd: @escaping (String) -> Void) async throws
    /// While held: `heard` is called once when the level says someone has started talking.
    func watchForVoice(_ detector: BargeInDetector?, heard: (() -> Void)?)
    /// Held → transcribing, with the second of audio from before the call if `withHeldAudio`.
    /// `endsOnSilence`: a pause ends the utterance, as with `start`; without it nothing does.
    func beginTranscribing(withHeldAudio: Bool, endsOnSilence: Bool)
    /// Transcribing with no end → an utterance that a pause ends.
    func endOnSilence()
    /// Transcribing → held again, what was heard forgotten: it wasn't words, or not the one waited for.
    func holdAgain()
}
extension SpeechRecognizer: VoiceRecognizing {}

extension VoiceRecognizing {
    var meterLevel: Float { level }
}

/// The TTS side (SpeechOutput in production).
@MainActor
protocol VoiceSpeaking: AnyObject {
    var onFirstSpeech: (() -> Void)? { get set }
    /// Whose words the next reply is (a bot's profile), for its voice of its own (`BotVoices`).
    var speaker: String? { get set }
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
    /// The first sentence of what will be read next, as `speaker`'s, fetched now (`whole`: the
    /// text is all there is of it); nil lets it go. Default: no-op.
    func prefetch(_ text: String?, whole: Bool, speaker: String?)
}
extension SpeechOutput: VoiceSpeaking {}

extension VoiceSpeaking {
    var meterLevel: Float { 0 }
    func pause() {}
    func resume() {}
    func prefetch(_ text: String?, whole: Bool, speaker: String?) {}
}

/// The head-movement side (HeadGestures in production): a nod or a shake, from AirPods.
@MainActor
protocol HeadGestureSensing: AnyObject {
    /// Movement is arriving: headphones that sense it are in, and iOS lets Redde read it.
    var isSensing: Bool { get }
    /// Reads movement until `stop()`; `heard` is called for each nod or shake made meanwhile.
    func start(heard: @escaping (HeadGesture) -> Void)
    func stop()
}
extension HeadGestures: HeadGestureSensing {}

/// The camera side (VoiceCamera in production): what the person is showing while they ask.
@MainActor
protocol VoiceLooking: AnyObject {
    /// Whether there is a camera to open at all.
    var isAvailable: Bool { get }
    /// Opens the camera, asking iOS for it the first time. False when it can't be had.
    func open() async -> Bool
    func close()
    /// What the camera sees right now, as a picture to send; nil when it has shown nothing lately.
    func still() -> Attachment?
    /// The live picture for the voice screen; nil for a stand-in, which has none.
    var viewfinder: AVCaptureSession? { get }
}
extension VoiceCamera: VoiceLooking {}

/// What a reply plays through, as far as talking over it goes: the phone's own speaker (or
/// earpiece) needs the echo cancelled, a headset doesn't, and a car is left alone.
nonisolated enum VoiceRoute: Sendable { case speaker, headphones, car }

/// The audio-session side (AudioSessionController in production).
@MainActor
protocol VoiceAudioControlling: AnyObject {
    var route: VoiceRoute { get }
    var onInterruption: (() -> Void)? { get set }
    var onInterruptionEnded: ((Bool) -> Void)? { get set }
    var onOutputDeviceLost: (() -> Void)? { get set }
    func activateForVoice() throws
    /// Speaking only, no microphone (Replay, Read aloud). Default: the voice configuration.
    func activateForPlayback() throws
    func deactivate()
    func refreshRoute()
    /// On while a reply is spoken: the proximity sensor may then move it to the earpiece.
    func setEarRouting(_ on: Bool)
    /// On while Redde thinks or speaks (no microphone): the session leaves voice-chat mode, so the
    /// volume buttons set the volume the reply plays at.
    func setReplying(_ on: Bool)
}
extension AudioSessionController: VoiceAudioControlling {}

extension VoiceAudioControlling {
    var route: VoiceRoute { .speaker }
    func activateForPlayback() throws { try activateForVoice() }
    func setEarRouting(_ on: Bool) {}
    func setReplying(_ on: Bool) {}
}

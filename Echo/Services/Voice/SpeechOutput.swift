import AVFoundation
import Foundation
import Observation
import os

/// On-device text-to-speech via AVSpeechSynthesizer. Text is fed incrementally as the model
/// streams; we speak sentence by sentence so the first words start before the reply finishes.
// Explicit: NSObject subclasses don't pick up the module's MainActor default.
@MainActor
@Observable
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    /// Fires the first time audio actually starts for a reply. Used for the latency budget.
    var onFirstSpeech: (() -> Void)?
    var onFinished: (() -> Void)?

    private let log = Logger(subsystem: "com.goosehouse.echo", category: "tts")
    private let synthesizer = AVSpeechSynthesizer()
    /// The built-in voice can't be metered, so each word it starts is a pulse: when, and how
    /// strong (longer words hit harder). Written from the synthesizer's callback thread.
    private nonisolated let wordPulse = OSAllocatedUnfairLock(initialState: (at: Date.distantPast, strength: Float(0)))
    private let kokoro = KokoroPlayer()
    private var chunker = SentenceChunker()
    private var queued = 0
    private var announcedStart = false
    /// Bumped by beginReply()/stop(). Synthesizer callbacks carry the epoch of the utterance they
    /// belong to; a callback from an older epoch (a late didCancel after a barge-in) is ignored so
    /// it can't fire onFinished into the next turn.
    private var epoch = 0
    private var utteranceEpochs: [ObjectIdentifier: Int] = [:]
    private var streamEnded = false
    /// Decided per reply so a Settings change takes effect on the next turn, not mid-sentence.
    private var usingKokoro = false
    private var kokoroDrained = false
    /// Whether this reply has handed Kokoro a sentence; until then it can still switch to the
    /// built-in voice for a language Kokoro can't speak.
    private var sentToKokoro = false
    /// The reply's language once it's clear ("es"), and what's been heard of it until then.
    private var detectedLanguage: String?
    private var heard = ""
    /// The Kokoro server's voices, for reading a reply in another language.
    private var kokoroVoiceIDs: (server: URL, ids: [String])?

    override init() {
        super.init()
        synthesizer.delegate = self
        // Mixing with the session we already configured; don't let the synthesizer flip categories.
        synthesizer.usesApplicationAudioSession = true
        kokoro.onFirstAudio = { [weak self] in
            guard let self, !announcedStart else { return }
            announcedStart = true
            onFirstSpeech?()
        }
        kokoro.onDrained = { [weak self] in
            guard let self, usingKokoro else { return }
            kokoroDrained = true
            // Fallback utterances may still be queued on the synthesizer.
            if queued == 0 { isSpeaking = false; onFinished?() }
        }
        kokoro.onFailure = { [weak self] text in
            guard let self else { return }
            log.warning("Kokoro failed; speaking on-device instead")
            // Both voices share the session: Kokoro's playback loop waits here until the
            // built-in voice has finished the sentence, or it would talk over the next one.
            await speakLocallyAndWait(text)
        }
    }

    /// Utterances a caller is waiting on, resolved by the synthesizer's finish/cancel callbacks.
    private var utteranceWaiters: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

    private func speakLocallyAndWait(_ spoken: String) async {
        let utterance = speakLocally(spoken)
        await withCheckedContinuation { utteranceWaiters[ObjectIdentifier(utterance)] = $0 }
    }

    /// Resolved once per language: speechVoices() enumerates every installed voice asset and
    /// sat on the first-audio latency path for each sentence.
    private var cachedVoices: [String: AVSpeechSynthesisVoice?] = [:]

    /// The language Redde listens in ("en-US"); replies are read in it unless they're clearly
    /// in another.
    private var listeningLanguage: String {
        let chosen = Settings.shared.speechLanguage
        return chosen.isEmpty ? AVSpeechSynthesisVoice.currentLanguageCode() : chosen
    }

    /// The best installed voice for a base language ("es"), in the listening dialect when it's
    /// the listening language, else the iPhone's region's. Nil leaves it to the synthesizer.
    func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let listening = listeningLanguage
        let key = "\(language)|\(listening)"
        if let cached = cachedVoices[key] { return cached }
        let preferred = SpokenLanguage.base(listening) == language
            ? listening : "\(language)-\(Locale.current.region?.identifier ?? "")"
        let installed = AVSpeechSynthesisVoice.speechVoices().map {
            SpokenLanguage.AppleVoice(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue,
                                      novelty: $0.voiceTraits.contains(.isNoveltyVoice))
        }
        var chosen: AVSpeechSynthesisVoice?
        if let pick = SpokenLanguage.appleVoice(for: language, preferred: preferred, among: installed) {
            chosen = pick.identifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? AVSpeechSynthesisVoice(language: pick.language)
        } else if language != SpokenLanguage.base(listening) {
            chosen = voice(for: SpokenLanguage.base(listening))   // nothing speaks it; read it as before
        }
        cachedVoices[key] = chosen
        return chosen
    }

    /// The reply's base language so far: what it's clearly written in, or the listening language.
    private func replyLanguage(adding spoken: String) -> String {
        let fallback = SpokenLanguage.base(listeningLanguage)
        guard Settings.shared.matchReplyLanguage else { return fallback }
        if let detectedLanguage { return detectedLanguage }
        heard += heard.isEmpty ? spoken : " " + spoken
        detectedLanguage = SpokenLanguage.detect(heard, hint: fallback)
        return detectedLanguage ?? fallback
    }

    /// The Kokoro voice for `language`, or nil when the server has none for it.
    private func kokoroVoice(for language: String) -> String? {
        let current = Settings.shared.kokoroVoice
        // Your pick reads your language, and anything whose language can't be told from its name.
        if language == SpokenLanguage.base(listeningLanguage) || SpokenLanguage.kokoroLanguage(of: current) == nil {
            return current
        }
        return SpokenLanguage.kokoroVoice(for: language, current: current, available: kokoroVoiceIDs?.ids ?? [])
    }

    private func loadKokoroVoices(_ server: URL) {
        guard kokoroVoiceIDs?.server != server else { return }
        Task {
            if let ids = try? await KokoroPlayer.voiceIDs(baseURL: server) { kokoroVoiceIDs = (server, ids) }
        }
    }

    // MARK: - Streaming input

    func beginReply() {
        stop()
        epoch += 1
        chunker = SentenceChunker()
        queued = 0
        announcedStart = false
        streamEnded = false
        kokoroDrained = false
        sentToKokoro = false
        detectedLanguage = nil
        heard = ""
        usingKokoro = Settings.shared.useKokoro && Settings.shared.kokoroBaseURL != nil
        if usingKokoro, let server = Settings.shared.kokoroBaseURL {
            kokoro.begin(baseURL: server)
            if Settings.shared.matchReplyLanguage { loadKokoroVoices(server) }
        }
    }

    func append(_ delta: String) {
        chunker.append(delta).forEach(enqueue)
    }

    func endReply() {
        guard !streamEnded else { return }   // idempotent: callers may not know whether .done arrived
        streamEnded = true
        if let tail = chunker.flush() { enqueue(tail) }
        if usingKokoro {
            kokoro.finish() // onDrained → onFinished
        } else if queued == 0 {
            onFinished?()
        }
    }

    func stop() {
        epoch += 1
        utteranceEpochs.removeAll()
        let waiters = utteranceWaiters.values
        utteranceWaiters.removeAll()
        waiters.forEach { $0.resume() }
        synthesizer.stopSpeaking(at: .immediate)
        kokoro.stop()
        chunker = SentenceChunker()
        queued = 0
        isSpeaking = false
    }

    /// Holds the reply mid-word (built-in voice) or mid-buffer (Kokoro); `resume` carries on.
    func pause() {
        if usingKokoro { kokoro.pause() } else { synthesizer.pauseSpeaking(at: .word) }
    }

    func resume() {
        if usingKokoro { kokoro.resume() } else { synthesizer.continueSpeaking() }
    }

    /// Stops the streaming player's audio engine without touching reply state, so the audio
    /// session can actually deactivate once a reply has finished playing.
    func releaseAudio() { kokoro.release() }

    private func enqueue(_ text: String) {
        let spoken = PlainText.spoken(text)
        guard !spoken.isEmpty else { return }
        let language = replyLanguage(adding: spoken)
        if usingKokoro, let base = Settings.shared.kokoroBaseURL {
            let voice = kokoroVoice(for: language)
            if voice != nil || sentToKokoro {
                isSpeaking = true
                sentToKokoro = true
                kokoro.enqueue(spoken, baseURL: base, voice: voice ?? Settings.shared.kokoroVoice,
                               speed: Settings.shared.voiceSpeed)
                return
            }
            // Kokoro has no voice for this language: the built-in one reads the whole reply.
            usingKokoro = false
            kokoro.stop()
        }
        speakLocally(spoken)
    }

    @discardableResult
    private func speakLocally(_ spoken: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = voice(for: detectedLanguage ?? SpokenLanguage.base(listeningLanguage))
        utteranceEpochs[ObjectIdentifier(utterance)] = epoch
        utterance.prefersAssistiveTechnologySettings = false
        // The same speed slider as Kokoro, scaled around the system default rate.
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate,
                                 AVSpeechUtteranceDefaultSpeechRate * Float(Settings.shared.voiceSpeed)))
        utterance.postUtteranceDelay = 0.02
        queued += 1
        isSpeaking = true
        synthesizer.speak(utterance)
        return utterance
    }

    /// How loud the reply is right now, 0…1, for voice mode's waveform: Kokoro's real output
    /// level, or the built-in voice's word pulses fading over ~180 ms.
    var meterLevel: Float {
        guard isSpeaking else { return 0 }
        if usingKokoro { return kokoro.meterLevel }
        let pulse = wordPulse.withLock { $0 }
        let age = Float(Date.now.timeIntervalSince(pulse.at))
        return pulse.strength * exp(-age / 0.18)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let strength = 0.6 + 0.4 * min(1, Float(characterRange.length) / 7)
        wordPulse.withLock { $0 = (.now, strength) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !announcedStart {
                announcedStart = true
                onFirstSpeech?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in utteranceEnded(key) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in utteranceEnded(key) }
    }

    private func utteranceEnded(_ key: ObjectIdentifier) {
        utteranceWaiters.removeValue(forKey: key)?.resume()
        // A callback for an utterance from a previous reply (or one cancelled by stop()) is stale.
        guard utteranceEpochs.removeValue(forKey: key) == epoch else { return }
        queued = max(queued - 1, 0)
        if queued == 0 {
            if usingKokoro {
                if kokoroDrained { isSpeaking = false; onFinished?() }
            } else {
                isSpeaking = false
                if streamEnded { onFinished?() }
            }
        }
    }
}

/// Turns a token stream into speakable sentences as early as possible. Pure, so it's testable.
nonisolated struct SentenceChunker: Sendable {
    private var pending = ""
    /// Break a long clause at a comma once it's clearly a phrase, so TTS doesn't wait forever.
    var longClauseThreshold = 240
    /// Sentence end (optionally followed by a closing quote/bracket) then whitespace, or a newline.
    /// Compiled once: `range(of:options:)` would build the regex again for every streamed token.
    /// `Regex` isn't marked Sendable but is immutable once built, so sharing it is safe.
    nonisolated(unsafe) private static let sentenceEnd = /([.!?]["')\]]?\s+|\n+)/

    /// Feed a delta; returns any sentences that are now complete.
    mutating func append(_ delta: String) -> [String] {
        pending += delta
        var out: [String] = []
        while let match = pending.firstMatch(of: Self.sentenceEnd) {
            let sentence = String(pending[..<match.range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(..<match.range.upperBound)
            if !sentence.isEmpty { out.append(sentence) }
        }
        if pending.utf8.count > longClauseThreshold, let comma = pending.lastIndex(of: ",") {
            let phrase = String(pending[...comma]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...comma)
            if !phrase.isEmpty { out.append(phrase) }
        }
        return out
    }

    /// Whatever is left at end of stream.
    mutating func flush() -> String? {
        let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return tail.isEmpty ? nil : tail
    }
}

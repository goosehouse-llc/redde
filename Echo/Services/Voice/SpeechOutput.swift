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
    /// Plays Kokoro's sentences, or Hermes's.
    private let player = KokoroPlayer()
    private var chunker = SentenceChunker()
    private var queued = 0
    private var announcedStart = false
    /// Bumped by beginReply()/stop(). Synthesizer callbacks carry the epoch of the utterance they
    /// belong to; a callback from an older epoch (a late didCancel after a barge-in) is ignored so
    /// it can't fire onFinished into the next turn.
    private var epoch = 0
    private var utteranceEpochs: [ObjectIdentifier: Int] = [:]
    private var streamEnded = false
    /// Held by `pause`. The built-in voice can only be held in the middle of a sentence, so one
    /// that arrives while nothing is being said (before the reply's first word, or in a gap of
    /// it) waits in `held` for `resume`. The player (Kokoro, Hermes) holds what arrives itself.
    private var paused = false
    private var held: [String] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Decided per reply so a Settings change takes effect on the next turn, not mid-sentence:
    /// whether the player speaks it (Kokoro, or Hermes when `hermesServer` is set).
    private var usingPlayer = false
    /// The Dashboard whose Hermes reads this reply out.
    private var hermesServer: URL?
    private var playerDrained = false
    /// Whether this reply has handed Kokoro a sentence; until then it can still switch to the
    /// built-in voice for a language Kokoro can't speak.
    private var sentToKokoro = false
    /// The reply's language once it's clear ("es"), and what's been heard of it until then.
    private var detectedLanguage: String?
    private var heard = ""
    /// The Kokoro server's voices, for reading a reply in another language.
    private var kokoroVoiceIDs: (server: URL, ids: [String], at: Date)?
    /// ElevenLabs: the key this reply is read with (nil, not ElevenLabs), the sentence said
    /// before the next (for how it follows on), and the account's voices, for bots' own.
    private var elevenLabsKey: String?
    private var lastSaid: String?
    private var elevenLabsVoiceIDs: (ids: [String], at: Date)?
    private var elevenLabsVoicesLoading = false
    private var kokoroVoicesLoading = false
    private var voicesObserver: NSObjectProtocol?

    override init() {
        super.init()
        // A voice downloaded in the iPhone's Settings while Redde runs is used from the next reply.
        voicesObserver = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cachedVoices = [:]; self?.installedVoices = nil }
        }
        // Ready before the first reply, so it isn't read by the wrong voice while the list loads.
        // Settings' and every bot's own, so a bot's first reply isn't read by the wrong voice either.
        let readers = Set([Settings.shared.replyVoice] + Settings.shared.botVoicesHere.values.compactMap(\.reader))
        if readers.contains(.kokoro), let server = Settings.shared.kokoroBaseURL { loadKokoroVoices(server) }
        if readers.contains(.elevenLabs) { loadElevenLabsVoices() }
        synthesizer.delegate = self
        // Mixing with the session we already configured; don't let the synthesizer flip categories.
        #if os(iOS)
        synthesizer.usesApplicationAudioSession = true
        #endif
        player.onFirstAudio = { [weak self] in
            guard let self, !announcedStart else { return }
            announcedStart = true
            onFirstSpeech?()
        }
        player.onDrained = { [weak self] in
            guard let self, usingPlayer else { return }
            playerDrained = true
            // Fallback utterances may still be queued on the synthesizer.
            if queued == 0 { isSpeaking = false; onFinished?() }
        }
        player.onFailure = { [weak self] text in
            guard let self else { return }
            log.warning("the server's voice failed; speaking on-device instead")
            // Both voices share the session: the player's playback loop waits here until the
            // built-in voice has finished the sentence, or it would talk over the next one.
            await speakLocallyAndWait(text)
        }
    }

    /// Utterances a caller is waiting on, resolved by the synthesizer's finish/cancel callbacks.
    private var utteranceWaiters: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

    private func speakLocallyAndWait(_ spoken: String) async {
        // A sentence the player failed on while the reply is held is not said into the hold.
        let begun = epoch
        while paused { await withCheckedContinuation { resumeWaiters.append($0) } }
        guard begun == epoch else { return }   // stopped meanwhile
        let utterance = speakLocally(spoken)
        await withCheckedContinuation { utteranceWaiters[ObjectIdentifier(utterance)] = $0 }
    }

    /// Whose words the next reply is: a bot's profile, read in that bot's voice (`BotVoices`); nil
    /// or "default", Redde's own. Set before `beginReply`.
    var speaker: String?
    /// A voice to read in whatever `speaker` says (Settings' preview of a bot's voice).
    var voiceOverride: BotVoice?

    /// The Kokoro voice the reply under way starts from: the bot's, or the one Settings picks.
    private var replyKokoroVoice: String {
        if let id = voiceOverride?.kokoro { return id }
        guard voiceOverride == nil else { return Settings.shared.kokoroVoice }
        return kokoroVoice(of: speaker)
    }

    /// The Kokoro voice `speaker`'s words are read in (`BotVoices`), Redde's own for nil.
    /// How fast `speaker` reads: a bot's own speed, else Redde's (`BotVoices.speed`).
    private func speed(of speaker: String?) -> Double {
        BotVoices.speed(for: speaker, picked: Settings.shared.botVoicesHere, main: Settings.shared.voiceSpeed)
    }

    /// Which voice reads what `speaker` says: a preview's, the bot's own reading voice, else
    /// Settings' (`Settings.readingVoice`).
    private func reader(of speaker: String?) -> Settings.ReplyVoice {
        voiceOverride?.reader ?? Settings.shared.readingVoice(for: speaker)
    }

    /// The ElevenLabs voice Redde reads in: the one picked, else the account's first.
    private var mainElevenLabsVoice: String? {
        Settings.shared.elevenLabsVoice.nilIfEmpty ?? elevenLabsVoiceIDs?.ids.first
    }

    /// The ElevenLabs voice `speaker`'s words are read in (`BotVoices`): Redde's own for nil, or
    /// the one a preview names.
    private func elevenLabsVoice(of speaker: String?) -> String? {
        if let id = voiceOverride?.elevenLabs { return id }
        guard voiceOverride == nil, let main = mainElevenLabsVoice else { return mainElevenLabsVoice }
        return BotVoices.elevenLabs(for: speaker, picked: Settings.shared.botVoicesHere, main: main,
                                    available: elevenLabsVoiceIDs?.ids ?? [], names: botNames) ?? main
    }

    private func loadElevenLabsVoices() {
        if let loaded = elevenLabsVoiceIDs, Date.now.timeIntervalSince(loaded.at) < 600 { return }
        guard !elevenLabsVoicesLoading, let key = ElevenLabsSpeech.key else { return }
        elevenLabsVoicesLoading = true
        Task {
            defer { elevenLabsVoicesLoading = false }
            if let voices = try? await ElevenLabsVoice.all(key: key) { elevenLabsVoiceIDs = (voices.map(\.id), .now) }
        }
    }

    private func kokoroVoice(of speaker: String?) -> String {
        BotVoices.kokoro(for: speaker, picked: Settings.shared.botVoicesHere, main: Settings.shared.kokoroVoice,
                         available: kokoroVoiceIDs?.ids ?? [], names: botNames) ?? Settings.shared.kokoroVoice
    }

    /// The first sentence of what will be read next, in `speaker`'s voice: asked of Kokoro now,
    /// while something else is read (a group chat's next bot), so it starts the moment its turn
    /// comes instead of after the server has made it. Only a sentence the reading will cut the
    /// same way: a whole one, or all of `text` when `whole`. In a language other than Redde's it
    /// gets another voice then, and is simply asked for again. nil lets it go.
    func prefetch(_ text: String?, whole: Bool, speaker: String?) {
        guard let text else { player.dropPrefetch(); return }
        var chunker = SentenceChunker()
        guard let first = chunker.append(text).first ?? (whole ? chunker.flush() : nil) else { return }
        let spoken = PlainText.spoken(first)
        guard !spoken.isEmpty else { return }
        if reader(of: speaker) == .elevenLabs, let key = ElevenLabsSpeech.key, let voice = elevenLabsVoice(of: speaker) {
            player.prefetchElevenLabs(spoken, voice: voice, speed: speed(of: speaker), key: key)
            return
        }
        guard reader(of: speaker) == .kokoro, let base = Settings.shared.kokoroBaseURL else { return }
        player.prefetch(spoken, baseURL: base, voice: kokoroVoice(of: speaker), speed: speed(of: speaker))
    }

    /// The bot's own built-in voice for `language`, when it has one there: looked up once a reply
    /// (the installed voices are slow to list, and each sentence waits on it).
    private func botVoice(for language: String) -> AVSpeechSynthesisVoice? {
        if let id = voiceOverride?.onDevice { return AVSpeechSynthesisVoice(identifier: id) }
        guard voiceOverride == nil, let speaker, speaker != "default" else { return nil }
        let key = "\(speaker)|\(language)"
        if let cached = botVoiceCache[key] { return cached }
        let found = lookUpBotVoice(speaker, language)
        botVoiceCache[key] = found
        return found
    }
    private var botVoiceCache: [String: AVSpeechSynthesisVoice?] = [:]

    private func lookUpBotVoice(_ speaker: String, _ language: String) -> AVSpeechSynthesisVoice? {
        let installed = installedVoices ?? AVSpeechSynthesisVoice.speechVoices().map {
            SpokenLanguage.AppleVoice(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue,
                                      novelty: $0.voiceTraits.contains(.isNoveltyVoice))
        }
        installedVoices = installed
        return BotVoices.onDevice(for: speaker, picked: Settings.shared.botVoicesHere, language: language,
                                  main: voice(for: language)?.identifier, installed: installed, names: botNames)
            .flatMap(AVSpeechSynthesisVoice.init(identifier:))
    }

    /// The bots on the server, for no two alike.
    private var botNames: [String] { BotDirectory.shared.bots(for: Settings.shared.connectionKey).map(\.name) }

    /// Resolved once per language: speechVoices() enumerates every installed voice asset and
    /// sat on the first-audio latency path for each sentence.
    private var cachedVoices: [String: AVSpeechSynthesisVoice?] = [:]
    /// The installed voices a bot's is picked from, kept until iOS's change: the pick itself is
    /// made again for each reply (a voice picked since is the one), the slow listing wasn't needed.
    private var installedVoices: [SpokenLanguage.AppleVoice]?

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
            ?? (heard.count > SpokenLanguage.detectionLimit ? fallback : nil)   // long and still unclear: stop
        return detectedLanguage ?? fallback
    }

    /// The Kokoro voice for `language`, or nil when the server has none for it.
    private func kokoroVoice(for language: String) -> String? {
        let current = replyKokoroVoice
        // Your pick until the reply's language is clear (and always with "Listening language",
        // which never detects), or when its name doesn't say what it speaks. After that, a voice
        // for that language: yours if it is one, so listening in Spanish with an English voice
        // still gets a Spanish one.
        if detectedLanguage == nil || SpokenLanguage.kokoroLanguage(of: current) == nil { return current }
        return SpokenLanguage.kokoroVoice(for: language, current: current, available: kokoroVoiceIDs?.ids ?? [])
    }

    /// Fetched once per server, again after ten minutes (voices added on the server).
    private func loadKokoroVoices(_ server: URL) {
        if let loaded = kokoroVoiceIDs, loaded.server == server, Date.now.timeIntervalSince(loaded.at) < 600 { return }
        guard !kokoroVoicesLoading else { return }
        kokoroVoicesLoading = true
        Task {
            defer { kokoroVoicesLoading = false }
            if let ids = try? await KokoroPlayer.voiceIDs(baseURL: server) { kokoroVoiceIDs = (server, ids, .now) }
        }
    }

    // MARK: - Streaming input

    func beginReply() {
        stop()
        madeUpTurn = false
        epoch += 1
        chunker = SentenceChunker()
        queued = 0
        announcedStart = false
        streamEnded = false
        playerDrained = false
        sentToKokoro = false
        detectedLanguage = nil
        heard = ""
        hermesServer = nil
        elevenLabsKey = nil
        lastSaid = nil
        botVoiceCache = [:]   // a voice picked since is the one
        switch reader(of: speaker) {
        case .kokoro:
            usingPlayer = Settings.shared.kokoroBaseURL != nil
            if let server = Settings.shared.kokoroBaseURL {
                player.begin(baseURL: server)
                // The server's voices: for the reply's language, and for a bot's voice of its own.
                loadKokoroVoices(server)
            }
        case .hermes:
            // Without a Dashboard to speak through, the built-in voice reads it.
            hermesServer = HermesSpeech.isAvailable ? Settings.shared.serveBaseURL : nil
            usingPlayer = hermesServer != nil
            if usingPlayer { player.begin() }
        case .elevenLabs:
            // Without a key, or before a voice is known, the built-in voice reads it.
            loadElevenLabsVoices()
            elevenLabsKey = mainElevenLabsVoice == nil ? nil : ElevenLabsSpeech.key
            usingPlayer = elevenLabsKey != nil
            if usingPlayer { player.begin() }
        case .onDevice:
            usingPlayer = false
        }
    }

    func append(_ delta: String) {
        chunker.append(delta).forEach(enqueue)
    }

    func endReply() {
        guard !streamEnded else { return }   // idempotent: callers may not know whether .done arrived
        streamEnded = true
        if let tail = chunker.flush() { enqueue(tail) }
        if usingPlayer {
            player.finish() // onDrained → onFinished
        } else if queued == 0, held.isEmpty {
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
        player.stop()
        chunker = SentenceChunker()
        queued = 0
        isSpeaking = false
        paused = false
        held = []
        letResumeWaitersGo()
    }

    /// Holds the reply mid-word (built-in voice) or mid-buffer (the player); `resume` carries on.
    /// Before the reply's first word it holds the whole of it: what is appended waits.
    func pause() {
        paused = true
        if usingPlayer { player.pause() } else { synthesizer.pauseSpeaking(at: .word) }
    }

    func resume() {
        paused = false
        if usingPlayer { player.resume() } else { synthesizer.continueSpeaking() }
        let waiting = held
        held = []
        waiting.forEach { speakLocally($0) }
        letResumeWaitersGo()
    }

    private func letResumeWaitersGo() {
        let waiters = resumeWaiters
        resumeWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Stops the streaming player's audio engine without touching reply state, so the audio
    /// session can actually deactivate once a reply has finished playing.
    func releaseAudio() { player.release() }

    /// The reply went on to write a message as if from the person (`BotMessages.inventedTurn`):
    /// nothing more of it is read.
    private var madeUpTurn = false

    private func enqueue(_ text: String) {
        guard !madeUpTurn else { return }
        var text = text
        if let frame = text.range(of: "[out-of-band", options: .caseInsensitive) {
            madeUpTurn = true
            text = String(text[..<frame.lowerBound])
        }
        let spoken = PlainText.spoken(text)
        guard !spoken.isEmpty else { return }
        let language = replyLanguage(adding: spoken)
        // ElevenLabs' voices speak every language: the speaker's, whatever the reply's.
        if let key = elevenLabsKey, let voice = elevenLabsVoice(of: speaker) {
            isSpeaking = true
            player.enqueueElevenLabs(spoken, voice: voice, speed: speed(of: speaker), previous: lastSaid, key: key)
            lastSaid = spoken
            return
        }
        // Hermes's voice is the one it is set up with, whatever the reply's language.
        if let server = hermesServer {
            isSpeaking = true
            player.enqueueHermes(spoken, client: .shared, server: server)
            return
        }
        if usingPlayer, let base = Settings.shared.kokoroBaseURL {
            let voice = kokoroVoice(for: language)
            if voice != nil || sentToKokoro {
                isSpeaking = true
                sentToKokoro = true
                player.enqueue(spoken, baseURL: base, voice: voice ?? replyKokoroVoice,
                               speed: speed(of: speaker))
                return
            }
            // Kokoro has no voice for this language: the built-in one reads the whole reply.
            usingPlayer = false
            player.stop()
        }
        if paused { held.append(spoken); return }
        speakLocally(spoken)
    }

    @discardableResult
    private func speakLocally(_ spoken: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: spoken)
        let language = detectedLanguage ?? SpokenLanguage.base(listeningLanguage)
        utterance.voice = botVoice(for: language) ?? voice(for: language)
        utteranceEpochs[ObjectIdentifier(utterance)] = epoch
        utterance.prefersAssistiveTechnologySettings = false
        // The same speed slider as Kokoro, scaled around the system default rate.
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate,
                                 AVSpeechUtteranceDefaultSpeechRate * Float(speed(of: speaker))))
        utterance.postUtteranceDelay = 0.02
        queued += 1
        isSpeaking = true
        synthesizer.speak(utterance)
        return utterance
    }

    /// How loud the reply is right now, 0…1, for voice mode's waveform: the player's real output
    /// level (Kokoro, Hermes), or the built-in voice's word pulses fading over ~180 ms.
    var meterLevel: Float {
        guard isSpeaking else { return 0 }
        if usingPlayer { return player.meterLevel }
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
            if usingPlayer {
                if playerDrained { isSpeaking = false; onFinished?() }
            } else {
                isSpeaking = false
                if streamEnded, held.isEmpty { onFinished?() }
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

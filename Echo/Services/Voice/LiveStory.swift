import Foundation

/// A story the agent writes for the person to hear, read in a live call as it is written
/// (`LiveVoice`), while the call's voice is held: the voice services that take an answer only
/// whole would have kept the person waiting for all of it (2026-10-27).
@MainActor
protocol StoryReading: AnyObject {
    /// More of it, as the agent writes it.
    func append(_ text: String)
    /// The agent is done: returns once what was written has been heard. What couldn't be read
    /// (the voice service refused), for the call's voice to say instead; nil when all of it was.
    func finish() async -> String?
    /// It stops where it is, unheard from here (the call ends, the person moved on).
    func stop()
}

/// In an ElevenLabs call: a sentence at a time, by ElevenLabs' text to speech on the same key, in
/// the call's own voice, into the call's own player (`LiveCalling.playStory`). So it sounds as the
/// call does: as loud (the call levels what it plays), from the same speaker, its echo cancelled.
/// Read by Redde's reply player instead, it came out quieter than the voice: a call's voice
/// processing turns down whatever else plays (Marta, 2026-10-27).
@MainActor
final class LiveStoryReader: StoryReading {
    private weak var call: (any LiveCalling)?
    private let voice: String, key: String, speed: Double, host: String
    private var chunker = SentenceChunker()
    /// Sentences not yet asked for, and the one before the next of them (ElevenLabs reads it for
    /// how the next follows on, and doesn't say it).
    private var waiting: [String] = []
    private var previous: String?
    private var ended = false, stopped = false
    private var wake: CheckedContinuation<Void, Never>?
    private var reading: Task<Void, Never>?
    /// What wasn't read, once ElevenLabs wouldn't.
    private var unread: [String] = []
    /// Asked for ahead of the one playing: one, as ElevenLabs takes only so many requests at once
    /// and the call holds one of them; a sentence is made much faster than it is heard.
    private static let ahead = 1
    /// How much is let wait in the call's player (its queue holds a minute).
    private static let mostQueued = 8.0

    /// nil without a key or a voice to read in.
    convenience init?(call: any LiveCalling, profile: String?) {
        let settings = Settings.shared
        guard let key = ElevenLabsSpeech.key,
              let voice = settings.liveVoice(for: profile, engine: .elevenLabs).nilIfEmpty ?? settings.elevenLabsVoice.nilIfEmpty
        else { return nil }
        self.init(call: call, voice: voice, key: key,
                  speed: BotVoices.speed(for: profile, picked: settings.botVoicesHere, main: settings.voiceSpeed))
    }

    /// `host`: ElevenLabs', or a stand-in's (the tests').
    init(call: any LiveCalling, voice: String, key: String, speed: Double, host: String = ElevenLabsDialect.host) {
        self.call = call
        self.key = key
        self.voice = voice
        self.speed = speed
        self.host = host
        reading = Task { await read() }
    }

    func append(_ text: String) {
        guard !ended, !stopped else { return }
        take(chunker.append(text))
    }

    func finish() async -> String? {
        if !ended, let tail = chunker.flush() { take([tail]) }
        ended = true
        letGo()
        await reading?.value
        // Heard to its end: the call's player has played what it was given.
        var waited = 0
        while !stopped, let call, call.queuedSeconds > 0, waited < 600 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        return unread.isEmpty ? nil : unread.joined(separator: " ")
    }

    func stop() {
        stopped = true
        reading?.cancel()
        letGo()
        call?.setVoiceHeld(true)   // what is queued of it goes at once
    }

    private func take(_ sentences: [String]) {
        let spoken = sentences.map(PlainText.spoken).filter { !$0.isEmpty }
        guard !spoken.isEmpty else { return }
        waiting += spoken
        letGo()
    }

    private func letGo() {
        wake?.resume()
        wake = nil
    }

    private func ask(_ text: String) -> (text: String, sound: AsyncThrowingStream<Data, Error>) {
        defer { previous = text }
        return (text, ElevenLabsSpeech.pcm(text, voice: voice, speed: speed, previous: previous, key: key, host: host))
    }

    /// Sentence after sentence into the call, in order, the next asked for while one plays.
    private func read() async {
        var asked: [(text: String, sound: AsyncThrowingStream<Data, Error>)] = []
        while !stopped {
            while asked.count <= Self.ahead, !waiting.isEmpty { asked.append(ask(waiting.removeFirst())) }
            guard !asked.isEmpty else {
                if ended { return }
                await withCheckedContinuation { wake = $0 }
                continue
            }
            let sentence = asked.removeFirst()
            if await !play(sentence) {
                guard !stopped else { return }
                unread = [sentence.text] + asked.map(\.text) + waiting
                waiting = []
                return
            }
        }
    }

    /// One sentence played; false when ElevenLabs wouldn't make it. Busy (its limit on requests
    /// at once) is waited out a few times, and anything else asked once more, before giving up.
    private func play(_ sentence: (text: String, sound: AsyncThrowingStream<Data, Error>)) async -> Bool {
        var sound = sentence.sound, tries = 0
        while true {
            var played = false
            do {
                for try await piece in sound {
                    guard !stopped else { return true }
                    while !stopped, let call, call.queuedSeconds > Self.mostQueued {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    call?.playStory(piece)
                    played = true
                }
                return true
            } catch {
                // Cut off part-way: what was heard isn't said again.
                if played || stopped { return true }
                tries += 1
                let busy = KokoroPlayer.isBusy(error)
                guard busy ? tries <= 3 : tries == 1 && KokoroPlayer.worthAskingAgain(error) else { return false }
                try? await Task.sleep(for: .milliseconds(busy ? 1_000 * tries : 300))
                sound = ElevenLabsSpeech.pcm(sentence.text, voice: voice, speed: speed, previous: nil, key: key, host: host)
            }
        }
    }
}

/// With any other voice service: Redde's reply player, in the agent's reading voice.
@MainActor
final class SpokenStory: StoryReading {
    private let reader = SpeechOutput()

    init(profile: String?) {
        reader.speaker = profile
        reader.beginReply()
    }

    func append(_ text: String) { reader.append(text) }

    func finish() async -> String? {
        // Heard to its end: the reader says so (set before the last of it goes in, which can say
        // so at once), or two seconds with nothing playing; a stop ends the wait too.
        final class Flag { var on = false }
        let finished = Flag()
        reader.onFinished = { finished.on = true }
        reader.endReply()
        var quiet = 0
        while !finished.on, !stopped, quiet < 8 {
            try? await Task.sleep(for: .milliseconds(250))
            quiet = reader.isSpeaking ? 0 : quiet + 1
        }
        reader.onFinished = nil
        return nil
    }

    private var stopped = false

    func stop() {
        stopped = true
        reader.stop()
    }
}

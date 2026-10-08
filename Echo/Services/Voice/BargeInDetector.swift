import Foundation

/// Notices that someone has started talking while Redde is speaking, from the microphone's level
/// alone. It is fed every buffer the mic delivers while a reply plays, and answers once: now.
///
/// Level, not words, on purpose. The recogniser must not listen while Redde's voice is in the
/// air: twice it was given that audio (echo-cancelled, then with Redde's own words filtered out)
/// and both times it wrote down something and interrupted the reply by itself. What the level
/// says is only "something is being said"; the reply is then held and the recogniser listens to
/// a quiet room to find out whether it was words (`VoiceSession`).
///
/// The numbers come from an iPhone 15 Pro Max (2026-10-07). On its speaker, at half to full
/// volume, with the system's echo cancellation on, the microphone is all but silent while a reply
/// plays, around -95 dBFS, because the same processing gates out what it takes for echo. A voice
/// at arm's length comes through at -14 to -21 dBFS for a few tenths of a second per word. What
/// leaks of the reply is the first half second of every reply, at -20 to -30 dBFS, while the
/// canceller learns the room again, and after that only bursts shorter than a tenth of a second,
/// below -30. On AirPods nothing gates the microphone: it hears the room, there at -52 to -68
/// dBFS, none of the reply, and the wearer at -26 to -36. So: loud enough for where the
/// microphone is, for long enough, and not in a reply's first moments.
nonisolated struct BargeInDetector: Sendable, Equatable {
    /// The level a voice has to reach, in dBFS, whatever the room: the floor under `margin`.
    var minimum: Float
    /// How far above the room's own noise a voice has to be. Matters where nothing gates the
    /// microphone (a headset), so a loud room isn't taken for a voice.
    var margin: Float = 14
    /// How long it has to stay that loud, in seconds, dips between syllables forgiven.
    var hold = 0.16
    /// After a reply's sound starts or resumes, how long nothing counts: the echo canceller is
    /// learning the room again, and for about half a second the reply leaks as loud as a voice.
    var settle = 1.2

    /// The microphone after the phone's echo cancellation: the speaker, the earpiece.
    static let echoCancelled = BargeInDetector(minimum: -28)
    /// A headset's microphone, which hears the room at its real level and none of the reply.
    static let headset = BargeInDetector(minimum: -38)

    private var loudFor = 0.0
    private var waiting = 0.0
    /// The room's noise, in dBFS: it snaps down to anything quieter and creeps up slowly.
    private var floor: Float = 0

    init(minimum: Float) {
        self.minimum = minimum
        waiting = settle
    }

    /// Start over, as a reply starts or resumes.
    mutating func rearm() {
        loudFor = 0
        waiting = settle
    }

    /// One buffer's level and length. True once a voice has been loud for long enough; the
    /// caller stops feeding it then, until `rearm()`.
    mutating func feed(decibels: Float, seconds: Double) -> Bool {
        floor = min(decibels, floor + Float(seconds) * 3)   // up by 3 dB a second at most
        if waiting > 0 {
            waiting -= seconds
            return false
        }
        if decibels > max(minimum, floor + margin) {
            loudFor += seconds
        } else {
            // A dip between syllables takes back only as much as it lasts.
            loudFor = max(0, loudFor - seconds)
        }
        return loudFor >= hold
    }
}

/// "Stop", for a reply that only that word stops (Settings → Voice → Interrupt with).
nonisolated enum StopWord {
    /// Said before "stop", these mean the opposite.
    private static let negations: Set<String> = ["don't", "dont", "not", "never", "won't", "wont", "can't", "cant", "cannot", "doesn't", "didn't"]

    /// True when `text` has "stop" in it as a word of its own, and not as "don't stop". One of
    /// the person's own stop phrases (`own`) counts the same, said as a run of words anywhere in
    /// what was heard; one written without spaces (Chinese, Japanese) counts wherever it stands.
    static func heard(in text: String, own: [String] = []) -> Bool {
        let words = Self.words(text)
        let phrases = [["stop"]] + StopPhrase.own(own).map(Self.words).filter { !$0.isEmpty }
        for phrase in phrases {
            guard words.count >= phrase.count else { continue }
            for i in 0 ... words.count - phrase.count where Array(words[i ..< i + phrase.count]) == phrase {
                if !(i > 0 && negations.contains(words[i - 1])) { return true }
            }
        }
        let run = words.joined()
        return StopPhrase.own(own).contains { phrase in
            !phrase.contains(" ") && phrase.unicodeScalars.contains { $0.value >= 0x2E80 } && run.contains(phrase)
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
}

/// The small sounds a listener makes without meaning to take the floor ("mm-hm", "okay", "right").
/// Said over a reply they are no reason to stop it.
nonisolated enum Backchannel {
    private static let words: Set<String> = [
        "mm", "mhm", "mhmm", "mmhm", "mmhmm", "hmm", "hm", "uh", "um", "huh", "ah", "oh", "ooh", "aha", "uhhuh", "yeah", "yep", "yup", "yes",
        "ok", "okay", "right", "sure", "wow", "cool", "nice", "great", "good", "true", "exactly", "indeed", "really", "interesting",
        "i", "see", "got", "it", "gotcha", "alright", "all", "fine", "thanks", "thank", "you",
    ]

    /// True when `text` is nothing but such sounds: "Mm-hm.", "Okay, right", "I see". Words only
    /// count as a whole: "okay, stop" is not one, and neither is a long run of them.
    static func isOnly(_ text: String) -> Bool {
        let said = text.lowercased().replacingOccurrences(of: "-", with: "")
            .split { !$0.isLetter }.map(String.init)
        guard !said.isEmpty, said.count <= 3 else { return false }
        return said.allSatisfy(words.contains)
    }
}

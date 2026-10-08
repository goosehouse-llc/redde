import Testing
@testable import Echo

/// The level watch that notices someone talking over a reply. The recorded cases are from an
/// iPhone 15 Pro Max on its speaker at half volume, echo cancellation on, 2026-10-07: the loudest
/// the microphone got in each tenth of a second (coarser than the buffers the detector is fed in
/// the app, which are a hundredth of a second each, so these are the outline of each case).
struct BargeInDetectorTests {
    /// Feeds one level per tenth of a second; the index at which the detector says "a voice", if it does.
    private func firstVoice(in levels: [Float], with detector: BargeInDetector = .echoCancelled) -> Int? {
        var detector = detector
        return levels.firstIndex { detector.feed(decibels: $0, seconds: 0.1) }
    }

    /// Nobody talking while a reply plays: silence but for the canceller's start and a few leaks.
    private static let quiet: [Float] = [
        -64, -66, -67, -79, -25, -41, -74, -60, -80, -105, -127, -140, -118, -118, -99, -99, -49, -98, -102, -108, -110, -100, -109,
        -101, -93, -96, -93, -93, -95, -100, -93, -96, -96, -100, -97, -94, -95, -96, -100, -98, -106, -100, -94, -94, -96, -97, -103,
        -94, -96, -95, -92, -93, -95, -103, -94, -94, -94, -100, -98, -100, -96, -97, -98, -94, -103, -101, -97, -92, -95, -97, -97,
        -97, -96, -94, -100, -100, -99, -97, -95, -101, -97, -96, -94, -83, -104, -107, -99, -97, -101, -97, -96, -92, -96, -100, -98,
        -98, -99, -113, -93, -87, -103, -102, -34, -55, -66, -31, -35, -57, -44, -31, -53, -48, -51, -56, -56, -62, -63, -62, -66, -85,
        -41, -102, -105, -42, -95, -48, -52, -49, -92, -59, -40, -104, -104, -108, -106, -103, -100, -66, -60, -60, -61, -61, -61, -52,
    ]
    private static let quietAgain: [Float] = [
        -42, -42, -53, -82, -60, -109, -109, -102, -97, -97, -100, -112, -96, -88, -94, -140, -137, -106, -119, -127, -116, -97, -99,
        -85, -92, -37, -25, -41, -58, -58, -61, -63, -54, -63, -45, -82, -106, -104, -98, -103, -107, -41, -45, -62, -62, -43, -35,
        -54, -53, -58, -63, -70, -110, -105, -94, -96, -96, -97, -91, -101, -98,
    ]
    /// The volume buttons being pressed while a reply plays: clicks and handling, no voice.
    private static let buttons: [Float] = [
        -96, -95, -94, -97, -97, -92, -39, -39, -48, -62, -53, -55, -51, -49, -45, -61, -61, -62, -62, -52, -62, -48, -43, -41, -54,
        -44, -49, -46, -59, -54, -46, -47, -45, -49, -46, -46, -44, -47, -51, -51, -53, -60,
    ]
    /// "Wait, stop", said five times over a reply, from five seconds of nobody talking.
    private static let talkedOver: [Float] = [
        -97, -97, -98, -97, -102, -103, -98, -100, -99, -102, -88, -97, -97, -98, -96, -95, -96, -96, -97, -96, -102, -97, -98, -98,
        -97, -98, -98, -96, -97, -97, -99, -101, -98, -103, -98, -92, -107, -120, -99, -98, -97, -95, -95, -95, -95, -102, -99, -104,
        -100, -100, -103, -97, -96, -97, -17, -14, -19, -42, -64, -32, -17, -20, -31, -73, -76, -68, -69, -59, -70, -74, -69, -18, -19,
        -28, -52, -69, -49, -46, -19, -21, -38, -70, -72, -77, -80, -79, -68, -55, -25, -16, -20, -38, -66, -74, -38, -20, -17, -21,
        -51, -59, -73, -60, -66, -70, -69, -69, -69, -60, -62, -22, -17, -27, -48, -39, -26, -17, -25, -48, -60, -69, -71, -69, -67,
    ]

    @Test func aReplyNobodyTalksOverIsLeftAlone() {
        #expect(firstVoice(in: Self.quiet) == nil)
        #expect(firstVoice(in: Self.quietAgain) == nil)
        #expect(firstVoice(in: Self.buttons) == nil)
    }

    @Test func aVoiceOverTheReplyIsHeardWithinItsFirstWord() throws {
        let heard = try #require(firstVoice(in: Self.talkedOver))
        let spoken = try #require(Self.talkedOver.firstIndex { $0 > -30 })
        #expect(heard - spoken <= 2, "more than two tenths of a second after the voice began")
        // Every "wait, stop" is caught, not only the first: one detector hearing the whole
        // recording, set going again after each (as a reply that carried on would).
        var detector = BargeInDetector.echoCancelled
        detector.settle = 0.3
        var caught = 0
        for level in Self.talkedOver where detector.feed(decibels: level, seconds: 0.1) {
            caught += 1
            detector.rearm()
        }
        #expect(caught >= 5)
    }

    /// The start of seven replies in a row, nobody talking: the canceller learning the room again.
    private static let replyStarts: [[Float]] = [
        [-107, -107, -103, -69, -60, -61, -61, -59, -54, -23, -21, -27, -47, -61, -50, -54, -52, -39, -54, -59, -62, -63, -68, -100, -95],
        [-59, -101, -107, -96, -55, -44, -44, -24, -22, -29, -29, -61, -42, -44, -44, -37, -30, -48, -60, -58, -108, -103, -104, -99, -45],
        [-60, -99, -105, -101, -60, -44, -44, -45, -43, -23, -20, -26, -30, -36, -84, -48, -44, -34, -30, -44, -63, -48, -48, -34, -44],
        [-77, -107, -104, -84, -61, -61, -35, -36, -30, -41, -34, -73, -50, -120, -108, -37, -58, -55, -53, -96, -95, -94, -96, -104, -98],
        [-65, -102, -106, -102, -65, -62, -63, -57, -25, -30, -35, -47, -75, -81, -108, -49, -52, -110, -113, -109, -107, -91, -104, -103, -98],
        [-61, -103, -107, -102, -52, -47, -52, -39, -35, -28, -44, -94, -96, -109, -99, -89, -107, -101, -100, -100, -97, -94, -97, -96, -95],
        [-59, -100, -108, -104, -64, -60, -50, -43, -31, -43, -38, -66, -108, -120, -88, -85, -108, -107, -105, -104, -99, -94, -97, -97, -95],
    ]

    @Test func aReplysFirstMomentsDontCount() {
        // In these the reply's sound started about four tenths of a second in, which is when the
        // app sets the detector going. As loud as a voice, for three tenths of a second, and not one.
        for start in Self.replyStarts {
            #expect(firstVoice(in: Array(start.dropFirst(4))) == nil, "a reply's own first words were taken for a voice: \(start)")
        }
        // The same loudness later in a reply is a voice.
        #expect(firstVoice(in: Array(repeating: -95, count: 20) + Array(repeating: -20, count: 5)) != nil)
    }

    @Test func stopIsAWordOfItsOwnAndNotDontStop() {
        for said in ["Stop", "stop.", "Okay, stop", "Redde, stop please", "no no STOP", "and then I said stop"] {
            #expect(StopWord.heard(in: said), "\(said) would not stop a reply")
        }
        for said in ["", "Don't stop", "don’t stop now", "do not stop", "never stop", "the bus stopped", "nonstop", "a stopwatch",
                     "we were talking about the top of the hill"] {
            #expect(!StopWord.heard(in: said), "\(said) would stop a reply")
        }
    }

    @Test func aPhraseOfThePersonsOwnStopsAReplyLikeTheWord() {
        let own = ["Das reicht", "basta così", "終わり"]
        for said in ["Das reicht", "okay, das reicht jetzt", "und dann … Das reicht!", "Basta cosi, grazie", "stop", "はい、終わりです"] {
            #expect(StopWord.heard(in: said, own: own), "\(said) would not stop a reply")
        }
        for said in ["das Geld reicht", "reicht das", "not das reicht", "basta", "così così", "das ist reichlich", ""] {
            #expect(!StopWord.heard(in: said, own: own), "\(said) would stop a reply")
        }
        // Without them in the list they are only talk.
        #expect(!StopWord.heard(in: "das reicht"))
    }

    @Test func aListenersNoisesAreNotWords() {
        for noise in ["Mm-hm.", "Okay", "okay, right", "I see.", "Yeah yeah", "Uh-huh", "Got it", "Wow, cool"] {
            #expect(Backchannel.isOnly(noise), "\(noise) would stop a reply")
        }
        for words in ["Okay, stop", "Wait a second", "No", "What's your name?", "Right, and the other one", "Okay okay okay okay", "Stop", ""] {
            #expect(!Backchannel.isOnly(words), "\(words) would be ignored")
        }
    }

    @Test func oneLoudInstantIsNotAVoice() {
        var levels: [Float] = Array(repeating: -95, count: 20)
        levels += [-20]
        levels += Array(repeating: -95, count: 20)
        #expect(firstVoice(in: levels) == nil)
    }

    /// Fed as the app feeds it, a hundredth of a second at a time: syllables with dips between them.
    @Test func dipsBetweenSyllablesAreForgiven() {
        var detector = BargeInDetector.echoCancelled
        var fired = false
        func feed(_ level: Float, hundredths: Int) {
            for _ in 0 ..< hundredths where !fired { fired = detector.feed(decibels: level, seconds: 0.01) }
        }
        feed(-95, hundredths: 150)   // well into the reply
        feed(-18, hundredths: 12); feed(-60, hundredths: 3); feed(-20, hundredths: 6)
        #expect(!fired, "a dip takes back as much as it lasts: 150 ms of voice so far")
        feed(-20, hundredths: 6)   // "wai-t": 240 ms of voice around a 30 ms dip
        #expect(fired)
    }

    @Test func aLoudRoomRaisesTheBarOnAHeadset() {
        // A headset's microphone hears the room: here a steady -40 dBFS, above the fixed minimum.
        var levels: [Float] = Array(repeating: -40, count: 30)
        #expect(firstVoice(in: levels, with: .headset) == nil, "the room's own noise was taken for a voice")
        levels += [-22, -20, -21]
        #expect(firstVoice(in: levels, with: .headset) != nil)
        // In a quiet room a soft voice is enough.
        #expect(firstVoice(in: Array(repeating: -70, count: 30) + [-34, -33, -34], with: .headset) != nil)
    }

    @Test func rearmingStartsTheCountAgain() {
        var detector = BargeInDetector.echoCancelled
        for _ in 0 ..< 20 { _ = detector.feed(decibels: -95, seconds: 0.1) }
        let half = detector.feed(decibels: -20, seconds: 0.1)
        #expect(!half)
        detector.rearm()   // the reply resumed
        let first = detector.feed(decibels: -20, seconds: 0.1), second = detector.feed(decibels: -20, seconds: 0.1)
        #expect(!first && !second, "the first moments after resuming count for nothing")
    }
}

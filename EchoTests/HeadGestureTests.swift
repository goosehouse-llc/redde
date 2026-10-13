import Foundation
import Testing
@testable import Echo

/// Settings → Voice → Nod or shake to answer: a nod approves and a shake denies, with AirPods
/// that sense movement. The detector is run on drawn movement, and the conversation on a stand-in
/// for the AirPods; neither has seen a real head.
@MainActor
struct HeadGestureTests {
    // MARK: Telling a nod from a shake from the rest

    private typealias Angles = (pitch: Double, yaw: Double, roll: Double)

    private func degrees(_ value: Double) -> Double { value * .pi / 180 }

    /// A head sampled as AirPods sample it, 25 times a second, at angles in degrees.
    private func samples(seconds: Double, every step: Double = 0.04, _ angles: (Double) -> Angles) -> [HeadGestureDetector.Sample] {
        stride(from: 0, to: seconds, by: step).map { t in
            let a = angles(t)
            // (Yaw comes from the AirPods between -π and π.)
            let yaw = degrees(a.yaw)
            return .init(time: 100 + t, pitch: degrees(a.pitch), yaw: atan2(sin(yaw), cos(yaw)), roll: degrees(a.roll))
        }
    }

    /// Back and forth `times` over, `size` degrees each way, after half a second of holding still.
    private func swinging(_ size: Double, times: Double, perSecond: Double = 1.8) -> (Double) -> Double {
        { t in t < 0.5 || t > 0.5 + times / perSecond ? 0 : -size * sin(2 * .pi * perSecond * (t - 0.5)) }
    }

    /// Down `size` degrees and back to where it was, `times` over: how a head nods.
    private func dipping(_ size: Double, times: Double, perSecond: Double = 1.8) -> (Double) -> Double {
        { t in t < 0.5 || t > 0.5 + times / perSecond ? 0 : -size * (0.5 - 0.5 * cos(2 * .pi * perSecond * (t - 0.5))) }
    }

    private func gestures(_ samples: [HeadGestureDetector.Sample]) -> [HeadGesture] {
        var detector = HeadGestureDetector()
        return samples.compactMap { detector.feed($0) }
    }

    @Test func aNodAndAShakeAreToldApart() {
        let nod = swinging(8, times: 2)
        #expect(gestures(samples(seconds: 3) { (nod($0), 0, 0) }) == [.nod])
        let shake = swinging(15, times: 2, perSecond: 2)
        #expect(gestures(samples(seconds: 3) { (0, shake($0), 0) }) == [.shake])
        // Down and back, twice, the way a head nods: it doesn't swing past where it started.
        let dips = dipping(10, times: 2)
        #expect(gestures(samples(seconds: 3) { (dips($0), 0, 0) }) == [.nod])
        // Up first is a nod as well.
        #expect(gestures(samples(seconds: 3) { (-nod($0), 0, 0) }) == [.nod])
        // A real head doesn't move in one direction only.
        #expect(gestures(samples(seconds: 3) { (nod($0), nod($0) * 0.2, nod($0) * 0.12) }) == [.nod])
    }

    @Test func aNodHasToBeMeant() {
        // Once down and up.
        let once = swinging(8, times: 1)
        #expect(gestures(samples(seconds: 3) { (once($0), 0, 0) }).isEmpty)
        let dip = dipping(15, times: 1)
        #expect(gestures(samples(seconds: 3) { (dip($0), 0, 0) }).isEmpty)
        // Twice, but hardly: the small nod of someone listening.
        let small = dipping(4, times: 2)
        #expect(gestures(samples(seconds: 3) { (small($0), 0, 0) }).isEmpty)
        // A look down at the phone, and back up two seconds later.
        let look: (Double) -> Double = { t in -30 * min(1, max(0, (t - 0.5) / 0.4)) + 30 * min(1, max(0, (t - 2.9) / 0.4)) }
        #expect(gestures(samples(seconds: 5) { (look($0), 0, 0) }).isEmpty)
        // The bob of a head on a walk: quick, and small.
        let walk = swinging(2, times: 12, perSecond: 2)
        #expect(gestures(samples(seconds: 8) { (walk($0), 0, 0) }).isEmpty)
        // Slowly down and up, three times: stretching, not nodding.
        let slow = swinging(12, times: 3, perSecond: 0.4)
        #expect(gestures(samples(seconds: 9) { (slow($0), 0, 0) }).isEmpty)
        // Two single nods with a pause between them.
        let twice: (Double) -> Double = { t in once(t) + once(t - 2) }
        #expect(gestures(samples(seconds: 5) { (twice($0), 0, 0) }).isEmpty)
    }

    @Test func aHeadDoingSomethingElseIsNeither() {
        let nod = swinging(10, times: 2)
        // On a slant: as much sideways as up and down.
        #expect(gestures(samples(seconds: 3) { (nod($0), nod($0), 0) }).isEmpty)
        // Ear to shoulder and back, the chin following.
        #expect(gestures(samples(seconds: 3) { (nod($0) * 0.8, 0, nod($0) * 1.5) }).isEmpty)
        // Going round: a nod and a shake a quarter of a turn apart.
        let round = swinging(10, times: 2.25)
        #expect(gestures(samples(seconds: 3) { t in (round(t), round(t + 0.25 / 1.8), 0) }).isEmpty)
    }

    @Test func aShakeFacingBackwardsIsStillAShake() {
        // Yaw runs out at 180° and starts again at -180°: a head pointing there crosses it.
        let shake = swinging(15, times: 2, perSecond: 2)
        #expect(gestures(samples(seconds: 3) { (0, 178 + shake($0), 0) }) == [.shake])
    }

    @Test func aGapInWhatTheAirPodsSendStartsOver() {
        let nod = swinging(8, times: 2)
        let all = samples(seconds: 3) { (nod($0), 0, 0) }
        // The same nod with its middle missing is two halves, and neither is a nod.
        #expect(gestures(all.filter { !(100.9 ... 101.3).contains($0.time) }).isEmpty)
    }

    // MARK: What a nod answers

    private let command = ApprovalRequest(id: "a1", command: "rm -rf ~/builds/2025-*", description: "Clear out the old builds",
                                          choices: ["once", "session", "always", "deny"])

    private func question(_ text: String, _ choices: [String]) -> Interrupt {
        .clarify(ClarifyRequest(id: "c1", questions: [ClarifyQuestion(id: "", question: text, choices: choices, multiSelect: false)], isBatch: false))
    }

    @Test func aNodIsYesAndAShakeIsNo() throws {
        let approval = try #require(SpokenRequest(.approval(command)))
        #expect(approval.answer(nod: true) == .approval("once"))
        #expect(approval.answer(nod: false) == .approval("deny"))
        #expect(approval.nodHint == "Nod or say “approve”. Shake your head or say “deny”.")
        // A question whose two choices are a yes and a no, whichever way round.
        let yesNo = try #require(SpokenRequest(question("Shall I carry on?", ["No", "Yes"])))
        #expect(yesNo.answer(nod: true) == .clarify(questionID: "", answer: "Yes"))
        #expect(yesNo.answer(nod: false) == .clarify(questionID: "", answer: "No"))
        // Any other question has nothing a head can say.
        for choices in [["Staging", "Production"], ["Yes", "No", "Later"], ["Yes", "Yeah"], []] {
            let other = try #require(SpokenRequest(question("Which?", choices)))
            #expect(!other.takesNod && other.answer(nod: true) == nil && other.answer(nod: false) == nil)
        }
    }

    // MARK: In a conversation

    /// Stands in for the AirPods: says it is sensing as soon as it is started.
    @MainActor final class FakeHead: HeadGestureSensing {
        private(set) var isSensing = false
        private(set) var starts = 0
        private var heard: ((HeadGesture) -> Void)?
        var isWatched: Bool { heard != nil }
        func start(heard: @escaping (HeadGesture) -> Void) { starts += 1; self.heard = heard; isSensing = true }
        func stop() { heard = nil; isSensing = false }
        func move(_ gesture: HeadGesture) { heard?(gesture) }
    }

    private typealias Harness = SpokenRequestTests.Harness
    private let waitUntil = SpokenRequestTests.waitUntil

    private func waiting(_ interrupt: Interrupt) -> SpokenRequestTests.GatedTransport {
        .init([.textDelta("Let me clear those out. "), .interrupt(interrupt, runtimeSession: "r1")])
    }

    @Test func aNodApprovesOnceTheRequestHasBeenReadOut() async throws {
        let h = Harness(waiting(.approval(command)), nod: true, route: .headphones)
        try await h.ask()
        #expect(h.head.isWatched, "the AirPods are read from when the request starts being read out")
        // A nod along to what is being said answers nothing.
        h.head.move(.nod)
        #expect(h.answers.given.isEmpty && h.session.asking != nil && h.session.phase == .speaking)

        h.speaker.finishSpeaking()
        try await waitUntil("the mic for the answer", 3) { h.recognizer.starts == 2 }
        #expect(h.session.headAnswers, "the voice screen says a nod will do")
        let cancelsBefore = h.recognizer.cancels
        h.head.move(.nod)
        #expect(h.answers.given == [.approval("once")])
        #expect(h.session.asking == nil && h.session.phase == .speaking)
        #expect(h.said.contains("Approved."))
        #expect(h.recognizer.cancels > cancelsBefore, "the mic was shut: nothing it heard is the answer")
        #expect(!h.head.isWatched, "and the AirPods are let be")
        #expect(h.conversation.isStreaming, "the turn carries on")
        // What the head does after that is nobody's business.
        h.head.move(.shake)
        #expect(h.answers.given == [.approval("once")])
        h.session.cancel()
    }

    @Test func aShakeDenies() async throws {
        let h = Harness(waiting(.approval(command)), nod: true, route: .headphones)
        try await h.ask()
        h.speaker.finishSpeaking()
        try await waitUntil("the mic for the answer", 3) { h.recognizer.starts == 2 }
        h.head.move(.shake)
        #expect(h.answers.given == [.approval("deny")])
        #expect(h.said.contains("Denied."))
        h.session.cancel()
    }

    /// Saying it still works, and whichever comes first is the answer.
    @Test func theVoiceAnswersAsBeforeAndTheHeadIsLetBe() async throws {
        let h = Harness(waiting(.approval(command)), nod: true, route: .headphones)
        try await h.ask()
        h.speaker.finishSpeaking()
        try await waitUntil("the mic for the answer", 3) { h.recognizer.starts == 2 }
        h.recognizer.deliver("Deny.")
        try await waitUntil("the answer", 3) { !h.answers.given.isEmpty }
        #expect(h.answers.given == [.approval("deny")])
        #expect(!h.head.isWatched)
        h.head.move(.nod)
        #expect(h.answers.given == [.approval("deny")], "a nod after the answer changes nothing")
        h.session.cancel()
    }

    @Test func theHeadIsNotReadUnlessAskedForAndOnHeadphones() async throws {
        // The switch is off.
        var h = Harness(waiting(.approval(command)), nod: false, route: .headphones)
        try await h.ask()
        #expect(h.head.starts == 0 && !h.session.headAnswers)
        h.session.cancel()
        // The reply plays through the phone's speaker: whatever AirPods are about are not on a head.
        h = Harness(waiting(.approval(command)), nod: true, route: .speaker)
        try await h.ask()
        #expect(h.head.starts == 0)
        h.session.cancel()
        // The request is one a head can't answer.
        h = Harness(waiting(question("Which environment?", ["Staging", "Production"])), nod: true, route: .headphones)
        try await h.ask("Deploy the site")
        #expect(h.session.asking != nil && h.head.starts == 0)
        h.session.cancel()
        // Answering aloud is off altogether: nothing is asked, so nothing is nodded at.
        h = Harness(waiting(.approval(command)), aloud: false, nod: true, route: .headphones)
        try await h.ask()
        #expect(h.head.starts == 0)
        h.session.cancel()
    }

    @Test func aYesOrNoQuestionTakesANod() async throws {
        let h = Harness(waiting(question("Shall I carry on?", ["Yes", "No"])), nod: true, route: .headphones)
        try await h.ask("Tidy up the folder")
        h.speaker.finishSpeaking()
        try await waitUntil("the mic for the answer", 3) { h.recognizer.starts == 2 }
        h.head.move(.nod)
        #expect(h.answers.given == [.clarify(questionID: "", answer: "Yes")])
        #expect(h.said.contains("Okay, Yes."))
        h.session.cancel()
    }

    /// However the asking ends, the AirPods stop being read with it.
    @Test func theHeadIsReadOnlyWhileARequestWaits() async throws {
        // Left for the screen.
        var h = Harness(waiting(.approval(command)), nod: true, route: .headphones)
        try await h.ask()
        h.speaker.finishSpeaking()
        try await waitUntil("the mic for the answer", 3) { h.recognizer.starts == 2 }
        h.session.mute()
        #expect(h.session.asking == nil && !h.head.isWatched)
        h.head.move(.nod)
        #expect(h.answers.given.isEmpty)
        h.session.cancel()
        // The conversation ended.
        h = Harness(waiting(.approval(command)), nod: true, route: .headphones)
        try await h.ask()
        #expect(h.head.isWatched)
        h.session.cancel()
        #expect(!h.head.isWatched)
    }
}

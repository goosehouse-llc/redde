import Foundation
import Testing
@testable import Echo

/// Settings → Voice → Answer requests by voice: a command that waits for approval, or a question
/// from the agent, read out in voice mode and answered by voice.
@MainActor
struct SpokenRequestTests {
    private let command = ApprovalRequest(id: "a1", command: "rm -rf ~/builds/2025-*", description: "Clear out the old builds",
                                          choices: ["once", "session", "always", "deny"])

    private func question(_ text: String, _ choices: [String] = [], multi: Bool = false, id: String = "", batch: Bool = false) -> Interrupt {
        .clarify(ClarifyRequest(id: "c1", questions: [ClarifyQuestion(id: id, question: text, choices: choices, multiSelect: multi)], isBatch: batch))
    }

    // MARK: What is asked, and what counts as an answer

    @Test func aCommandIsReadOutWithWhatItIsForAndHowToAnswer() throws {
        let request = try #require(SpokenRequest(.approval(command)))
        #expect(request.prompt == "Approval needed. Clear out the old builds. rm -rf ~/builds/2025-*. Say approve, or deny.")
        #expect(request.hint == "Say “approve” or “deny”.")
        // A long command is not read out to its end, and never across lines.
        let long = ApprovalRequest(id: "a2", command: "python3 - <<'EOF'\n" + String(repeating: "print('x')\n", count: 60), description: nil, choices: ["once", "deny"])
        let spoken = try #require(SpokenRequest(.approval(long))).prompt
        #expect(spoken.count < 220 && spoken.hasSuffix("and more. Say approve, or deny.") && !spoken.contains("\n"))
    }

    @Test func approveAndDenyAreWholeAnswersFromAShortList() throws {
        let request = try #require(SpokenRequest(.approval(command)))
        for yes in ["Approve.", "approve it", "Yes", "yeah", "Go ahead.", "Okay, approve it please", "Yes, approve.", "Do it", "Hermes, allow it"] {
            #expect(request.answer(yes) == .approval("once"), "\(yes) approves")
        }
        for no in ["Deny.", "no", "Nope", "Don't do it.", "cancel", "No, deny it", "never mind", "Stop."] {
            #expect(request.answer(no) == .approval("deny"), "\(no) denies")
        }
        // Not an answer: asked about again, never taken for a yes.
        for other in ["", "sure why not", "okay", "what does that do", "yes but only the first one", "I don't know", "approve the budget meeting for Tuesday",
                      "the kids said yes to pizza"] {
            #expect(request.answer(other) == nil, "\(other) is no answer")
        }
        #expect(request.confirmation(of: .approval("once")) == "Approved.")
        #expect(request.confirmation(of: .approval("deny")) == "Denied.")
    }

    @Test func whatHasToBeTypedOrHasSeveralPartsStaysForTheScreen() {
        #expect(SpokenRequest(.sudo(id: "s1")) == nil)
        #expect(SpokenRequest(.secret(SecretRequest(id: "k1", prompt: "The key", envVar: "API_KEY"))) == nil)
        // An approval that can't simply be denied.
        #expect(SpokenRequest(.approval(ApprovalRequest(id: "a3", command: "ls", description: nil, choices: ["once", "always"]))) == nil)
        #expect(SpokenRequest(question("Which ones?", ["A", "B"], multi: true)) == nil)
        let two = ClarifyRequest(id: "c2", questions: [ClarifyQuestion(id: "q1", question: "One?", choices: [], multiSelect: false),
                                                       ClarifyQuestion(id: "q2", question: "Two?", choices: [], multiSelect: false)], isBatch: true)
        #expect(SpokenRequest(.clarify(two)) == nil)
    }

    @Test func aQuestionWithChoicesTakesANumberOrTheChoiceItself() throws {
        let request = try #require(SpokenRequest(question("Which environment should I deploy to?", ["Staging", "Production", "Both of them"])))
        #expect(request.prompt == "Which environment should I deploy to? One: Staging. Two: Production. Three: Both of them. Say the number, or the answer.")
        for (said, choice) in [("Two.", "Production"), ("number one", "Staging"), ("the third one", "Both of them"), ("option 2", "Production"),
                               ("Staging", "Staging"), ("both of them, please", "Both of them"), ("First", "Staging")] {
            #expect(request.answer(said) == .clarify(questionID: "", answer: choice), "\(said) picks \(choice)")
        }
        for other in ["four", "the fast one", "", "yes"] { #expect(request.answer(other) == nil, "\(other) picks nothing") }
        #expect(request.reminder == "Say one, two or three.")
        #expect(request.confirmation(of: .clarify(questionID: "", answer: "Production")) == "Okay, Production.")
    }

    @Test func aQuestionWithoutChoicesTakesWhatIsSaid() throws {
        let request = try #require(SpokenRequest(question("What should the branch be called?", id: "q7", batch: true)))
        #expect(request.prompt == "What should the branch be called?")
        // Under the question's own id when the host asked in its batched form.
        #expect(request.answer(" Fix the login page. ") == .clarify(questionID: "q7", answer: "Fix the login page."))
        #expect(request.answer("") == nil)
    }

    // MARK: In a conversation

    /// Yields its first events, then waits to be opened before the rest: a turn that stands
    /// still on a request, as a real one does.
    final class GatedTransport: HermesTransport, @unchecked Sendable {
        private let before: [TurnEvent], after: [TurnEvent]
        private let gate = AsyncStream<Void>.makeStream()
        init(_ before: [TurnEvent], then after: [TurnEvent] = []) { self.before = before; self.after = after }
        func open() { gate.continuation.yield() }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            let before = before, after = after, opened = gate.stream
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for e in before { try await Task.sleep(for: .milliseconds(20)); continuation.yield(e) }
                    for await _ in opened { break }
                    for e in after { try await Task.sleep(for: .milliseconds(20)); continuation.yield(e) }
                    try await Task.sleep(for: .seconds(30))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    @MainActor final class Answers {
        private(set) var given: [SpokenRequest.Answer] = []
        func record(_ answer: SpokenRequest.Answer) { given.append(answer) }
    }

    struct Harness {
        let session: VoiceSession
        let conversation: Conversation
        let recognizer = VoiceSessionTests.FakeRecognizer()
        let speaker = VoiceSessionTests.FakeSpeaker()
        let audio = VoiceSessionTests.FakeAudio()
        let head = HeadGestureTests.FakeHead()
        let answers = Answers()
        var said: String { speaker.spoken.joined() }

        init(_ transport: any HermesTransport, aloud: Bool = true, nod: Bool = false, route: VoiceRoute = .speaker) {
            audio.route = route
            let settings = Settings(defaults: UserDefaults(suiteName: "spoken-\(UUID().uuidString)")!)
            settings.transport = .chatCompletions
            settings.fastLaneURL = "http://example.invalid:11500"
            settings.fastLaneModel = "test"
            let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "spoken-\(UUID().uuidString)"))
            conversation = Conversation(settings: settings, store: store, transportOverride: transport)
            let answers = answers
            session = VoiceSession(conversation: conversation, recognizer: recognizer, output: speaker, audio: audio, head: head,
                                   requestPermissions: { true }, earcon: { _ in }, keepAwake: { _ in }, talkOver: { .off },
                                   interruption: { .speech }, stopPhrases: { [] }, answersAloud: { aloud }, answersByNod: { nod },
                                   respond: { answers.record($0) })
        }

        /// Says a question and waits until the agent's request has been dealt with one way or the other.
        func ask(_ text: String = "Clear out the old builds") async throws {
            session.beginListening()
            try await SpokenRequestTests.waitUntil("the mic") { recognizer.starts == 1 }
            recognizer.deliver(text)
            try await SpokenRequestTests.waitUntil("the request") { session.asking != nil || session.activeTool == "waiting for you" }
        }
    }

    static func waitUntil(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waiting(_ interrupt: Interrupt, then after: [TurnEvent] = []) -> GatedTransport {
        GatedTransport([.textDelta("Let me clear those out. "), .interrupt(interrupt, runtimeSession: "r1")], then: after)
    }

    @Test func untilTurnedOnARequestWaitsForTheScreenAsItAlwaysDid() async throws {
        let h = Harness(waiting(.approval(command)), aloud: false)
        try await h.ask()
        #expect(h.session.asking == nil)
        #expect(h.session.activeTool == "waiting for you")
        #expect(!h.said.contains("Approval needed"))
        #expect(h.recognizer.starts == 1, "the mic stays shut")
        h.session.cancel()
    }

    @Test func aCommandIsReadOutAndApprovedByVoice() async throws {
        let h = Harness(waiting(.approval(command)))
        try await h.ask()
        #expect(h.said.contains("Let me clear those out.") && h.said.contains("Approval needed. Clear out the old builds."))
        #expect(h.session.phase == .speaking && h.session.activeTool == nil)
        #expect(h.recognizer.starts == 1, "not listening while it is read out")

        h.speaker.finishSpeaking()
        try await Self.waitUntil("the mic for the answer") { h.recognizer.starts == 2 }
        #expect(h.session.phase == .listening)
        h.recognizer.deliver("Approve.")
        try await Self.waitUntil("the answer") { !h.answers.given.isEmpty }
        #expect(h.answers.given == [.approval("once")])
        #expect(h.session.asking == nil)
        #expect(h.said.contains("Approved."))
        #expect(h.conversation.isStreaming, "the turn carries on")
        h.session.cancel()
    }

    @Test func denyIsHeardToo() async throws {
        let h = Harness(waiting(.approval(command)))
        try await h.ask()
        h.speaker.finishSpeaking()
        try await Self.waitUntil("the mic for the answer") { h.recognizer.starts == 2 }
        h.recognizer.deliver("No, deny it.")
        try await Self.waitUntil("the answer") { !h.answers.given.isEmpty }
        #expect(h.answers.given == [.approval("deny")])
        #expect(h.said.contains("Denied."))
        h.session.cancel()
    }

    /// Nothing is approved because it sounded a bit like yes: one reminder, then the screen.
    @Test func whatIsNotAnAnswerIsAskedOnceMoreThenLeftForTheScreen() async throws {
        let h = Harness(waiting(.approval(command)))
        try await h.ask()
        h.speaker.finishSpeaking()
        try await Self.waitUntil("the mic for the answer") { h.recognizer.starts == 2 }
        h.recognizer.deliver("Sure, why not.")
        try await Self.waitUntil("the reminder") { h.said.hasSuffix("Say approve, or deny.") && h.session.phase == .speaking }
        #expect(h.session.asking != nil)

        h.speaker.finishSpeaking()
        try await Self.waitUntil("the mic again") { h.recognizer.starts == 3 }
        h.recognizer.deliver("What does it do?")
        try await Self.waitUntil("the hand-over") { h.session.asking == nil }
        #expect(h.said.hasSuffix("It's waiting for you on your iPhone."))
        #expect(h.session.activeTool == "waiting for you", "the car's card says Needs your phone")
        #expect(h.answers.given.isEmpty)

        h.speaker.finishSpeaking()
        #expect(h.session.phase == .thinking, "the turn is still the agent's: no going idle, no listening for a new question")
        #expect(h.conversation.isStreaming)
        h.session.cancel()
    }

    @Test func silenceIsNoAnswer() async throws {
        let h = Harness(waiting(.approval(command)))
        h.session.answerWindow = .milliseconds(120)
        try await h.ask()
        h.speaker.finishSpeaking()
        try await Self.waitUntil("the mic for the answer") { h.recognizer.starts == 2 }
        try await Self.waitUntil("the reminder") { h.said.hasSuffix("Say approve, or deny.") }
        #expect(h.answers.given.isEmpty)
        h.session.cancel()
    }

    @Test func aQuestionIsAnsweredByItsNumber() async throws {
        let h = Harness(waiting(question("Which environment should I deploy to?", ["Staging", "Production"])))
        try await h.ask("Deploy the site")
        #expect(h.said.contains("Which environment should I deploy to? One: Staging. Two: Production. Say the number, or the answer."))
        h.speaker.finishSpeaking()
        try await Self.waitUntil("the mic for the answer") { h.recognizer.starts == 2 }
        h.recognizer.deliver("Two.")
        try await Self.waitUntil("the answer") { !h.answers.given.isEmpty }
        #expect(h.answers.given == [.clarify(questionID: "", answer: "Production")])
        #expect(h.said.contains("Okay, Production."))
        h.session.cancel()
    }

    @Test func aPasswordIsNeverAskedForAloud() async throws {
        let h = Harness(waiting(.sudo(id: "s1")))
        try await h.ask("Install the update")
        #expect(h.session.asking == nil && h.session.activeTool == "waiting for you")
        #expect(h.recognizer.starts == 1)
        h.session.cancel()
    }

    /// A tap while a reply is spoken barges in and ends the turn. While a request is read out
    /// it must not: it means "I'll answer now".
    @Test func aTapWhileItIsReadOutHearsTheAnswerWithoutEndingTheTurn() async throws {
        let h = Harness(waiting(.approval(command)))
        try await h.ask()
        h.session.primaryAction()
        try await Self.waitUntil("the mic for the answer") { h.recognizer.starts == 2 }
        #expect(h.session.phase == .listening && h.session.asking != nil)
        #expect(h.conversation.isStreaming, "the turn was not cancelled")
        h.recognizer.deliver("yes")
        try await Self.waitUntil("the answer") { !h.answers.given.isEmpty }
        #expect(h.answers.given == [.approval("once")])
        h.session.cancel()
    }

    /// The car's Mute, pressed instead of an answer: the request waits on the phone.
    @Test func mutingInsteadOfAnsweringLeavesItForTheScreen() async throws {
        let h = Harness(waiting(.approval(command)))
        try await h.ask()
        h.speaker.finishSpeaking()
        try await Self.waitUntil("the mic for the answer") { h.recognizer.starts == 2 }
        h.session.mute()
        #expect(h.session.asking == nil && h.session.activeTool == "waiting for you")
        #expect(h.session.phase == .thinking && !h.session.isMuted)
        #expect(h.conversation.isStreaming && h.answers.given.isEmpty)
        h.session.cancel()
    }

    /// Settled some other way while the mic waits (here the host's own time limit): the asking
    /// stops, the mic shuts and the reply carries on.
    @Test func aRequestSettledElsewhereStopsTheAsking() async throws {
        let transport = waiting(.approval(command), then: [.interruptExpired(id: "a1"), .textDelta("That timed out, so I left them."), .done])
        let h = Harness(transport)
        try await h.ask()
        h.speaker.finishSpeaking()
        try await Self.waitUntil("the mic for the answer") { h.recognizer.starts == 2 }
        let cancelsBefore = h.recognizer.cancels
        transport.open()
        try await Self.waitUntil("the asking to stop") { h.session.asking == nil }
        try await Self.waitUntil("the rest of the reply") { h.said.contains("That timed out") }
        #expect(h.recognizer.cancels > cancelsBefore, "the mic was shut")
        #expect(h.answers.given.isEmpty)
        #expect(h.session.phase == .speaking)
        h.session.cancel()
    }
}

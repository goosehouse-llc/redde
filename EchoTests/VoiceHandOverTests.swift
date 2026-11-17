import Foundation
import Testing
@testable import Echo

/// Between voice mode and typing, the reply goes on (asked 2026-10-28: "when I ask a question
/// verbally it starts but then I click the keyboard… the message stops. can we make it fluid").
@MainActor
struct VoiceHandOverTests {
    /// A reply that says its first words, then waits to be let go on.
    final class HeldTransport: HermesTransport, @unchecked Sendable {
        private let gate = AsyncStream<Void>.makeStream()
        func open() { gate.continuation.yield() }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            let opened = gate.stream
            return AsyncThrowingStream { continuation in
                let task = Task {
                    try await Task.sleep(for: .milliseconds(20))
                    continuation.yield(.textDelta("Pack a fleece, "))
                    for await _ in opened { break }
                    continuation.yield(.textDelta("it gets cold at night."))
                    continuation.yield(.done)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func switchingToTypingKeepsTheReplyComing() async throws {
        let transport = HeldTransport()
        let h = VoiceSessionTests.Harness(transport: transport)
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("What should I pack for the cabin?")
        try await waitUntil("the reply begins") { h.speaker.spoken.joined().contains("fleece") }
        h.session.handOverToTyping()
        #expect(h.session.phase == .idle && h.conversation.isStreaming, "voice stops; the reply doesn't")
        h.session.cancel()   // the voice screen going away cancels again
        transport.open()
        try await waitUntil("the reply finishes on screen") { !h.conversation.isStreaming }
        #expect(h.conversation.messages.last?.text == "Pack a fleece, it gets cold at night.")
        #expect(!h.speaker.spoken.joined().contains("cold"), "read on the screen, not aloud")
    }

    @Test func openingVoiceModeMidReplyReadsItInsteadOfStoppingIt() async throws {
        let transport = HeldTransport()
        let h = VoiceSessionTests.Harness(transport: transport)
        _ = h.conversation.send("What should I pack for the cabin?")   // typed
        try await waitUntil("the reply begins") { h.conversation.messages.last?.text.contains("fleece") == true }
        h.session.joinReply()
        #expect(h.session.phase == .speaking && h.conversation.isStreaming, "joined, not barged in on")
        try await waitUntil("what's there is read") { h.speaker.spoken.joined().contains("fleece") }
        transport.open()
        try await waitUntil("and the rest as it comes") { h.speaker.spoken.joined().contains("cold at night") }
        try await waitUntil("the reply finishes") { !h.conversation.isStreaming }
        #expect(h.conversation.messages.last?.text == "Pack a fleece, it gets cold at night.")
        #expect(h.speaker.spoken.joined() == "Pack a fleece, it gets cold at night.", "each word once")
    }

    /// 2.7: the agents the agent asked by @name answered, and it goes on by itself. Hands-free,
    /// with the mic open behind the reply before and nothing said, that is read too, then the
    /// mic opens again.
    @Test func theAgentGoingOnAfterTheAgentsItAskedIsReadInVoiceMode() async throws {
        let transport = HeldTransport()
        let h = VoiceSessionTests.Harness(transport: transport)
        h.session.continuous = true
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.conversation.startTurn(Message(role: .user, text: "[Redde: the agents you asked answered]"), unseen: true)
        let reply = try #require(h.conversation.messages.last?.id)
        h.session.joinFollowOn(reply: reply)
        try await waitUntil("what's there is read") { h.speaker.spoken.joined().contains("fleece") }
        #expect(h.recognizer.cancels >= 1, "the mic set aside for it")
        transport.open()
        try await waitUntil("and the rest") { h.speaker.spoken.joined().contains("cold at night") }
        try await waitUntil("the reading ended") { h.speaker.ends >= 1 }
        h.speaker.finishSpeaking()
        try await waitUntil("listening again") { h.recognizer.starts == 2 }
        #expect(h.conversation.messages.map(\.role) == [.assistant], "no message of the person's shown")
    }

    @Test func theAgentGoingOnIsNotReadOverThePerson() async throws {
        let transport = HeldTransport()
        let h = VoiceSessionTests.Harness(transport: transport)
        h.session.continuous = true
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.hear("Wait, also")
        h.conversation.startTurn(Message(role: .user, text: "[Redde: the agents you asked answered]"), unseen: true)
        h.session.joinFollowOn(reply: try #require(h.conversation.messages.last?.id))
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.session.phase == .listening && h.speaker.spoken.isEmpty && h.recognizer.cancels == 0)
        transport.open()
    }

    @Test func withNoReplyComingVoiceModeListens() async throws {
        let h = VoiceSessionTests.Harness(transport: HeldTransport())
        h.session.joinReply()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.session.phase == .listening)
    }
}

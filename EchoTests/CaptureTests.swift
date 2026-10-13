import Foundation
import Testing
@testable import Echo

/// Quick capture: a note taken in passing is kept, handed to the server when it can be reached,
/// and never answered aloud. The turn that files it with a real Hermes is not run here.
@MainActor
struct CaptureTests {
    // MARK: Keeping notes and handing them over

    /// Stands in for the server: takes what it is handed, or refuses, or holds on to it for a while.
    @MainActor final class Post {
        private(set) var batches: [[String]] = []
        var down = false
        var holding = false
        private var held: [CheckedContinuation<Void, Never>] = []

        func deliver(_ notes: [CaptureInbox.Note]) async throws {
            if holding { await withCheckedContinuation { held.append($0) } }
            if down { throw URLError(.notConnectedToInternet) }
            batches.append(notes.map(\.text))
        }

        func letGo() { holding = false; held.forEach { $0.resume() }; held = [] }
    }

    struct Harness {
        let defaults = UserDefaults(suiteName: "capture-\(UUID().uuidString)")!
        let settings: Settings
        let post = Post()
        let inbox: CaptureInbox

        init() {
            settings = Settings(defaults: defaults)
            let post = post
            inbox = CaptureInbox(defaults: defaults, settings: settings, deliver: { try await post.deliver($0) })
            inbox.retryDelays = [600]   // nothing is tried again behind a test's back
        }

        /// The inbox as the next launch finds it.
        func relaunched() -> CaptureInbox {
            let post = post
            return CaptureInbox(defaults: defaults, settings: settings, deliver: { try await post.deliver($0) })
        }
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aNoteIsKeptAndHandedOverAtOnce() async throws {
        let h = Harness()
        #expect(h.inbox.add("  The plumber comes Thursday at ten.  "))
        #expect(h.inbox.waiting.map(\.text) == ["The plumber comes Thursday at ten."], "kept the moment it is taken")
        try await waitUntil("the note to go") { h.inbox.waiting.isEmpty }
        #expect(h.post.batches == [["The plumber comes Thursday at ten."]])
        // Nothing in it, nothing taken.
        #expect(!h.inbox.add("   ") && h.inbox.waiting.isEmpty)
    }

    @Test func aNoteThatCannotBeSentWaitsAndGoesLater() async throws {
        let h = Harness()
        h.post.down = true
        h.inbox.add("Renew the car registration")
        try await waitUntil("the first try") { !h.inbox.isFiling && h.inbox.waiting.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.inbox.waiting.count == 1 && h.post.batches.isEmpty)
        // It is still there when the app is opened again.
        #expect(h.relaunched().waiting.map(\.text) == ["Renew the car registration"])

        // A second one while the server is away, and then the server is back: both go, as one.
        h.inbox.add("Call the school on Monday")
        try await Task.sleep(for: .milliseconds(50))
        h.post.down = false
        await h.inbox.file()
        #expect(h.inbox.waiting.isEmpty)
        #expect(h.post.batches == [["Renew the car registration", "Call the school on Monday"]])
        #expect(h.relaunched().waiting.isEmpty)
    }

    @Test func itIsTriedAgainByItself() async throws {
        let h = Harness()
        h.inbox.retryDelays = [0.05]
        h.post.down = true
        h.inbox.add("Renew the car registration")
        try await waitUntil("the first try") { !h.inbox.isFiling }
        h.post.down = false
        try await waitUntil("the next try") { h.inbox.waiting.isEmpty }
        #expect(h.post.batches == [["Renew the car registration"]])
    }

    @Test func aNoteTakenWhileAnotherIsOnItsWayGoesNext() async throws {
        let h = Harness()
        h.post.holding = true
        h.inbox.add("One")
        try await waitUntil("the first on its way") { h.inbox.isFiling }
        h.inbox.add("Two")
        #expect(h.inbox.waiting.count == 2)
        h.post.letGo()
        try await waitUntil("both to go") { h.inbox.waiting.isEmpty }
        #expect(h.post.batches == [["One"], ["Two"]], "the second is not sent with the first, nor twice")
    }

    /// A note taken for Work is not handed to the default profile because that is what is in
    /// use an hour later.
    @Test func aNoteWaitsForTheProfileItWasTakenFor() async throws {
        let h = Harness()
        h.post.down = true
        h.settings.hermesProfile = "work"
        h.inbox.add("Send the invoice")
        try await waitUntil("the first try") { !h.inbox.isFiling }
        h.post.down = false

        h.settings.hermesProfile = ""
        #expect(h.inbox.ready.isEmpty)
        await h.inbox.file()
        #expect(h.post.batches.isEmpty && h.inbox.waiting.count == 1)

        h.settings.hermesProfile = "work"
        await h.inbox.file()
        #expect(h.post.batches == [["Send the invoice"]] && h.inbox.waiting.isEmpty)
    }

    @Test func aNoteCanBeThrownAway() async throws {
        let h = Harness()
        h.post.down = true
        h.inbox.add("Buy the wrong thing")
        try await waitUntil("the first try") { !h.inbox.isFiling }
        let note = try #require(h.inbox.waiting.first)
        h.inbox.remove(note.id)
        #expect(h.inbox.waiting.isEmpty && h.relaunched().waiting.isEmpty)
    }

    // MARK: What the agent is sent

    @Test func theAgentIsToldWhatTheNotesAreAndThatNobodyIsWaiting() {
        let server = UUID()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let when = at.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.wide).month(.wide).day().hour().minute())
            .replacingOccurrences(of: "\u{202F}", with: " ")
        let one = CaptureFiler.message(for: [.init(text: "The plumber comes Thursday at ten.", at: at, server: server)])
        #expect(one.hasPrefix("A note I took in passing, with Redde's quick capture. File it where it belongs"))
        #expect(one.contains("I'm not waiting for an answer") && one.contains("don't ask me anything back"))
        #expect(one.hasSuffix("\n\n\(when): The plumber comes Thursday at ten."))
        #expect(when.contains("January") && when.contains("2027") == false, "the day and the time, said as a person would")

        let two = CaptureFiler.message(for: [.init(text: "One", at: at, server: server), .init(text: "Two", at: at.addingTimeInterval(600), server: server)])
        #expect(two.hasPrefix("Notes I took in passing, with Redde's quick capture. File each where it belongs"))
        #expect(two.contains("\n\n- \(when): One\n- "))
        #expect(two.hasSuffix(": Two"))
    }

    // MARK: Without an agent

    /// The OpenAI-compatible connection has nobody to file a note: it is kept, in a conversation
    /// of the phone's own.
    @Test func withoutAnAgentNotesAreKeptInAConversationOfTheirOwn() async throws {
        let h = Harness()
        h.settings.transport = .chatCompletions
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID().uuidString)"))
        let server = h.settings.activeServerID
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try await CaptureFiler.deliver([.init(text: "One", at: at, server: server)], settings: h.settings, store: store, defaults: h.defaults)
        try await CaptureFiler.deliver([.init(text: "Two", at: at.addingTimeInterval(60), server: server),
                                        .init(text: "Three", at: at.addingTimeInterval(120), server: server)],
                                       settings: h.settings, store: store, defaults: h.defaults)
        #expect(store.sorted.map(\.title) == ["Notes"], "one conversation, not one a note")
        let kept = try #require(store.sorted.first)
        let record = try #require(store.record(id: kept.id))
        #expect(record.messages.map(\.text) == ["One", "Two", "Three"])
        #expect(record.messages.allSatisfy { $0.role == .user })
        #expect(record.messages.first?.createdAt == at, "each under the time it was taken")
    }

    // MARK: Taking a note by voice

    @Test func aNoteByVoiceIsKeptAndNotSentToTheConversation() async throws {
        let h = CarPlayTests.Harness()
        h.session.continuous = true
        h.session.beginListening(capturing: true)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.session.isCapturing)
        h.recognizer.deliver("The plumber comes Thursday at ten.")
        try await waitUntil("noted") { h.session.phase == .speaking }
        #expect(h.taken.notes == ["The plumber comes Thursday at ten."])
        #expect(h.speaker.spoken == ["Noted."])
        #expect(!h.session.isCapturing)
        #expect(h.conversation.messages.isEmpty && !h.conversation.isStreaming)
        h.speaker.finishSpeaking()
        #expect(h.session.phase == .idle)
        #expect(h.recognizer.starts == 1, "the mic doesn't reopen after a note, hands-free or not")

        // What is said next is a question like any other.
        h.session.beginListening()
        try await waitUntil("listening again") { h.recognizer.starts == 2 }
        #expect(!h.session.isCapturing)
        h.recognizer.deliver("What's the weather in Lisbon?")
        try await waitUntil("the question to go") { h.conversation.messages.first?.text == "What's the weather in Lisbon?" }
        #expect(h.taken.notes.count == 1)
        h.session.cancel()
    }

    @Test func neverMindOrSilenceTakesNoNote() async throws {
        let h = CarPlayTests.Harness()
        h.session.beginListening(capturing: true)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("Never mind.")
        try await waitUntil("okay") { h.session.phase == .speaking }
        #expect(h.speaker.spoken == ["Okay."] && h.taken.notes.isEmpty && !h.session.isCapturing)
        h.speaker.finishSpeaking()

        h.session.beginListening(capturing: true)
        try await waitUntil("listening") { h.recognizer.starts == 2 }
        h.recognizer.deliver("")
        try await waitUntil("idle") { h.session.phase == .idle }
        #expect(h.taken.notes.isEmpty && !h.session.isCapturing)
    }

    /// A reply being typed out on the phone has nothing to do with a note: it carries on. And a
    /// note is not taken over a reply being spoken, which taking it would end.
    @Test func aNoteLeavesARunningReplyAlone() async throws {
        let h = CarPlayTests.Harness()
        let gated = SpokenRequestTests.GatedTransport([.textDelta("Working on it. ")], then: [.textDelta("Done."), .done])
        let conversation = Conversation(settings: h.settings, store: h.store, transportOverride: gated)
        let session = VoiceSession(conversation: conversation, recognizer: h.recognizer, output: h.speaker, audio: h.audio,
                                   requestPermissions: { true }, earcon: { _ in }, keepAwake: { _ in }, talkOver: { .off },
                                   interruption: { .speech }, takeNote: { h.taken.add($0) })
        let typed = conversation.send("Tidy up the downloads folder")
        Task { for await _ in typed {} }
        try await waitUntil("the reply to start") { conversation.isStreaming && conversation.messages.last?.text.isEmpty == false }

        session.beginListening(capturing: true)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(conversation.isStreaming, "the typed reply was not cancelled for a note")
        h.recognizer.deliver("Buy more boxes")
        try await waitUntil("noted") { session.phase == .speaking }
        #expect(h.taken.notes == ["Buy more boxes"] && conversation.isStreaming)

        // While "Noted." is being said, another note has to wait its turn.
        session.beginListening(capturing: true)
        #expect(session.phase == .speaking && h.recognizer.starts == 1)
        h.speaker.finishSpeaking()
        gated.open()
        try await waitUntil("the rest of the reply") { conversation.messages.last?.text == "Working on it. Done." }
        conversation.cancel()
    }
}

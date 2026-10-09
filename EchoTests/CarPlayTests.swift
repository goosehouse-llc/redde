import CarPlay
import Foundation
import Testing
@testable import Echo

/// The car screen without a car: the rows, the Recent Chats list and the voice card are built
/// and pressed directly, against a fake microphone and a scripted transport. What the car draws
/// with them is CarPlay's business and isn't covered here.
@MainActor
struct CarPlayTests {
    // MARK: Harness

    struct Harness {
        let delegate = CarPlaySceneDelegate()
        let settings: Settings
        let store: ConversationStore
        let conversation: Conversation
        let session: VoiceSession
        let recognizer = VoiceSessionTests.FakeRecognizer()
        let speaker = VoiceSessionTests.FakeSpeaker()
        let audio = VoiceSessionTests.FakeAudio()

        init() {
            settings = Settings(defaults: UserDefaults(suiteName: "carplay-\(UUID().uuidString)")!)
            settings.transport = .chatCompletions
            settings.fastLaneURL = "http://example.invalid:11500"
            settings.fastLaneModel = "test"
            store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "carplay-\(UUID().uuidString)"))
            conversation = Conversation(settings: settings, store: store,
                                        transportOverride: ConversationLifecycleTests.ScriptedTransport([.textDelta("Hello."), .done]))
            session = VoiceSession(conversation: conversation, recognizer: recognizer, output: speaker, audio: audio,
                                   requestPermissions: { true }, earcon: { _ in }, keepAwake: { _ in }, talkOver: { .off }, interruption: { .speech })
            delegate.sessionOverride = session
            delegate.conversationOverride = conversation
            delegate.settings = settings
            delegate.store = store
        }

        /// One typed turn, start to finish, so the conversation is worth keeping.
        func ask(_ question: String) async {
            for await _ in conversation.send(question) {}
            while conversation.isStreaming { try? await Task.sleep(for: .milliseconds(5)) }
        }

        func row(_ title: String) -> CPListItem? {
            delegate.menuSections().flatMap(\.items).compactMap { $0 as? CPListItem }.first { $0.text == title }
        }
    }

    /// Presses a row the way the car does, and waits for it to say it's done (the row's spinner).
    private func press(_ row: CPListItem?) async throws {
        let row = try #require(row)
        let handler = try #require(row.handler)
        await withCheckedContinuation { done in handler(row) { done.resume() } }
    }

    private func waitUntil(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func session(_ id: String, title: String? = nil, preview: String? = nil, lastActive: Double, pinned: Bool? = nil) -> HermesSessionsAPI.SessionSummary {
        var s = HermesSessionsAPI.SessionSummary(id: id)
        s.title = title; s.preview = preview; s.last_active = lastActive; s.pinned = pinned
        return s
    }

    // MARK: Which chats, in what order

    @Test func serverSessionsListPinnedFirstThenNewest() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = CarPlayChats.rows(sessions: [
            session("old", title: "Older", lastActive: now.timeIntervalSince1970 - 7200),
            session("new", title: "Newer", lastActive: now.timeIntervalSince1970 - 60),
            session("pin", title: "Kept", lastActive: now.timeIntervalSince1970 - 86_400 * 30, pinned: true),
        ], currentSessionID: "new", limit: 12, now: now)
        #expect(rows.map(\.title) == ["Kept", "Newer", "Older"])
        #expect(rows.map(\.isCurrent) == [false, true, false])
        #expect(rows[0].detail.hasPrefix("Pinned · "))
        #expect(rows[1].detail == CarPlayChats.currentDetail)
    }

    @Test func aSessionNobodyNamedNeverShowsWhatWasSaid() {
        let rows = CarPlayChats.rows(sessions: [session("a", preview: "Your door code is 4417.", lastActive: 100)],
                                     currentSessionID: nil, limit: 12)
        #expect(rows.map(\.title) == [CarPlayChats.untitled])
        #expect(!rows[0].detail.contains("4417"))
    }

    @Test func theListIsCutToWhatTheCarShows() {
        let sessions = (0 ..< 30).map { session("s\($0)", title: "Chat \($0)", lastActive: Double($0)) }
        let rows = CarPlayChats.rows(sessions: sessions, currentSessionID: nil, limit: 12)
        #expect(rows.count == 12)
        #expect(rows.first?.title == "Chat 29")
    }

    // MARK: The rows

    @Test func theMenuIsFourRowsAndSaysWhichConversationIsOpen() async throws {
        let h = Harness()
        let rows = h.delegate.menuSections().map { $0.items.compactMap { ($0 as? CPListItem)?.text } }
        #expect(rows == [["Ask Redde", "Talk with Redde"], ["New Chat", "Recent Chats"]])
        #expect(h.row("Recent Chats")?.detailText == "Carry on an earlier conversation")
        await h.ask("Plan the lake trip")
        #expect(h.row("Recent Chats")?.detailText == "Now in “Plan the lake trip”")
    }

    @Test func askAndTalkListenInTheirOwnModes() async throws {
        let h = Harness()
        try await press(h.row("Talk with Redde"))
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.session.continuous)
        h.delegate.pressed(.end)
        try await press(h.row("Ask Redde"))
        try await waitUntil("listening again") { h.recognizer.starts == 2 }
        #expect(!h.session.continuous)
    }

    @Test(arguments: [false, true]) func newChatStartsFreshAndListens(handsFreeByDefault: Bool) async throws {
        let h = Harness()
        h.settings.handsFreeByDefault = handsFreeByDefault
        await h.ask("Plan the lake trip")
        let before = h.conversation.id
        try await press(h.row("New Chat"))
        #expect(h.conversation.id != before)
        #expect(!h.conversation.hasMessages)
        #expect(h.store.sorted.map(\.id) == [before], "the one that was open stays in the list")
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.session.phase == .listening)
        #expect(h.session.continuous == handsFreeByDefault)
    }

    // MARK: Recent chats

    @Test func pickingAChatOpensItAndListens() async throws {
        let h = Harness()
        await h.ask("Plan the lake trip")
        let lake = h.conversation.id
        h.conversation.reset()
        await h.ask("What's for dinner")
        let rows = try await h.delegate.chatRows()
        #expect(rows.map(\.text) == ["What's for dinner", "Plan the lake trip"])
        #expect(rows.first?.detailText == CarPlayChats.currentDetail)

        try await press(rows.last)
        #expect(h.conversation.id == lake)
        #expect(h.conversation.messages.first?.text == "Plan the lake trip")
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.session.phase == .listening)
    }

    @Test func pickingTheOpenChatJustListens() async throws {
        let h = Harness()
        await h.ask("Plan the lake trip")
        let open = h.conversation.id
        try await press(try await h.delegate.chatRows().first)
        #expect(h.conversation.id == open)
        #expect(h.conversation.messages.count == 2)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
    }

    // MARK: The voice card

    @Test func theCardStaysWithinFiveStatesAndEachHasAWayOut() {
        let states = Harness().delegate.voiceTemplate().voiceControlStates
        #expect(states.map(\.identifier) == ["listening", "thinking", "speaking", "muted", "phone"])
        #expect(states.count <= 5, "a voice-control template drops any state past its fifth")
        if #available(iOS 26.4, *) {
            #expect(states.map { $0.actionButtons.compactMap(\.title) } ==
                [["Mute", "End"], ["End"], ["End"], ["Unmute", "End"], ["End"]])
            #expect(states.allSatisfy { $0.actionButtons.count <= CPVoiceControlState.maximumActionButtonCount })
        }
    }

    @Test func everyStateKeepsItsPictureForAsLongAsItLasts() {
        // The card treats a state's image as an animation and takes away one that doesn't repeat
        // once its single cycle is over: on 2026-10-07 every state was set to play once, and the
        // car showed "Listening…" and "Thinking…" with nothing above the words.
        let states = Harness().delegate.voiceTemplate().voiceControlStates
        for state in states {
            #expect(state.repeats, "\(state.identifier) would lose its picture after a moment")
            let image = state.image
            #expect(image != nil, "\(state.identifier) has no picture")
            // CarPlay takes at most 150 by 150 points.
            #expect((image?.size.width ?? 999) <= 150 && (image?.size.height ?? 999) <= 150, "\(state.identifier)'s picture is larger than the card takes")
        }
        #expect(CarPlayArtwork.voiceImageSide == 150)
    }

    @Test func muteShutsTheMicAndKeepsTheConversation() async throws {
        let h = Harness()
        try await press(h.row("Talk with Redde"))
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.delegate.pressed(.mute)
        #expect(h.session.phase == .idle)
        #expect(h.session.isMuted)
        #expect(h.session.continuous, "hands-free is still on for when the mic comes back")
        #expect(h.recognizer.cancels == 1)
        h.recognizer.deliver("something said in the car")
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.conversation.messages.isEmpty, "nothing heard while muted is sent")

        h.delegate.pressed(.unmute)
        try await waitUntil("listening again") { h.recognizer.starts == 2 }
        #expect(h.session.phase == .listening)
        #expect(!h.session.isMuted)
    }

    @Test func endStopsEverythingIncludingHandsFree() async throws {
        let h = Harness()
        try await press(h.row("Talk with Redde"))
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.delegate.pressed(.mute)
        h.delegate.pressed(.end)
        #expect(h.session.phase == .idle)
        #expect(!h.session.isMuted)
        #expect(!h.session.continuous)
    }

    @Test func theCardFollowsTheVoiceSession() {
        typealias D = CarPlaySceneDelegate
        #expect(D.card(phase: .listening, waitingOnPhone: false, muted: false) == .showing(.listening))
        #expect(D.card(phase: .thinking, waitingOnPhone: false, muted: false) == .showing(.thinking))
        #expect(D.card(phase: .thinking, waitingOnPhone: true, muted: false) == .showing(.phone))
        #expect(D.card(phase: .speaking, waitingOnPhone: false, muted: false) == .showing(.speaking))
        #expect(D.card(phase: .idle, waitingOnPhone: false, muted: true) == .showing(.muted))
        #expect(D.card(phase: .idle, waitingOnPhone: false, muted: false) == .closed)
        #expect(D.card(phase: .error("no route"), waitingOnPhone: false, muted: false) == .failed)
    }
}

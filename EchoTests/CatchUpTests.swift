import Foundation
import Testing
@testable import Echo

/// The car's "Catch me up": which chats count as news, what is said about them, and the voice
/// session saying something that isn't a reply. The card itself is in `CarPlayTests`.
@MainActor
struct CatchUpTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC

    private func chat(_ title: String, _ key: String, minutesAgo: Double?, current: Bool = false) -> CarPlayChat {
        CarPlayChat(title: title, detail: "", isCurrent: current, source: .session(.init(id: key)),
                    lastActive: minutesAgo.map { now.addingTimeInterval(-$0 * 60) })
    }

    private func message(_ role: Message.Role, _ text: String, minutesAgo: Double) -> Message {
        Message(role: role, text: text, createdAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    // MARK: What counts as news

    @Test func aChatIsNewsWhenItMovedAfterItWasLastSeenOrTold() {
        let chats = [chat("Old", "a", minutesAgo: 30 * 60), chat("Yesterday evening", "b", minutesAgo: 14 * 60),
                     chat("Just now", "c", minutesAgo: 5), chat("No time", "d", minutesAgo: nil)]
        // Before any catch-up: the last day, newest first.
        var marks = CatchUp.Marks()
        #expect(CatchUp.moved(chats, marks: marks, now: now).map(\.title) == ["Just now", "Yesterday evening"])
        // After one, an hour ago: only what moved since.
        marks.told = now.addingTimeInterval(-3600)
        #expect(CatchUp.moved(chats, marks: marks, now: now).map(\.title) == ["Just now"])
        // And not that either once it has been seen.
        marks.saw("c", at: now.addingTimeInterval(-60))
        #expect(CatchUp.moved(chats, marks: marks, now: now).isEmpty)
        // It moves again after it was seen: news again.
        #expect(CatchUp.moved([chat("Just now", "c", minutesAgo: 0.5)], marks: marks, now: now).count == 1)
    }

    @Test func marksOlderThanTheLastCatchUpAreDropped() throws {
        var marks = CatchUp.Marks()
        marks.saw("a", at: now.addingTimeInterval(-7200))
        marks.told = now.addingTimeInterval(-3600)
        marks.saw("b", at: now)
        #expect(marks.seen.keys.sorted() == ["b"], "a mark from before the catch-up says nothing it doesn't")
        // They are kept as they are written.
        let back = try JSONDecoder().decode(CatchUp.Marks.self, from: JSONEncoder().encode(marks))
        #expect(back == marks)
    }

    // MARK: What is said about a chat

    @Test func aChatsNewsIsTheStartOfItsLatestReply() throws {
        let marks = CatchUp.Marks(told: now.addingTimeInterval(-3600))
        let deploy = chat("Deploy script", "a", minutesAgo: 20)
        let item = try #require(CatchUp.item(for: deploy, messages: [
            message(.user, "Run the deploy", minutesAgo: 25),
            message(.assistant, "The deploy **finished** and all checks passed.\n\n```\nok 14/14\n```", minutesAgo: 20),
        ], marks: marks, now: now))
        #expect(item == .init(title: "Deploy script", when: now.addingTimeInterval(-1200), said: .reply("The deploy finished and all checks passed. code block omitted")))

        // The last word is the person's: the agent is still at it.
        #expect(CatchUp.item(for: deploy, messages: [message(.user, "Run the deploy", minutesAgo: 20)], marks: marks, now: now)?.said == .working)
        // The open chat, mid-reply.
        #expect(CatchUp.item(for: deploy, messages: [message(.assistant, "Starting", minutesAgo: 1)], working: true, marks: marks, now: now)?.said == .working)
        // A reply that only ran tools has nothing to read; the one before it does.
        #expect(CatchUp.item(for: deploy, messages: [message(.assistant, "Uploading now.", minutesAgo: 22), message(.assistant, "", minutesAgo: 20)],
                             marks: marks, now: now)?.said == .reply("Uploading now."))
        #expect(CatchUp.item(for: deploy, messages: [message(.assistant, "", minutesAgo: 20)], marks: marks, now: now)?.said == .nothing)
        // The list says it moved, and nothing in it is newer than the last catch-up: not news.
        #expect(CatchUp.item(for: deploy, messages: [message(.assistant, "Done.", minutesAgo: 90)], marks: marks, now: now) == nil)
        #expect(CatchUp.item(for: deploy, messages: [], marks: marks, now: now) == nil)
    }

    @Test func theStartOfAReplyIsWholeSentencesAndNotTooMany() {
        #expect(CatchUp.gist("  Done.\n\nAll **three** files are in `~/builds`.  ") == "Done. All three files are in ~/builds.")
        let long = "The backup ran at two. " + String(repeating: "It copied the photos and then it checked every one of them against the copy. ", count: 6)
        let gist = CatchUp.gist(long)
        #expect(gist.hasPrefix("The backup ran at two. It copied the photos"))
        #expect(gist.count <= 220 && gist.hasSuffix("against the copy."), "cut at the end of a sentence")
        // One sentence longer than all of that is cut between words.
        let endless = String(repeating: "and then another thing ", count: 30)
        let cut = CatchUp.gist(endless)
        #expect(cut.count <= 232 && cut.hasSuffix("thing, and more.") || cut.hasSuffix("another, and more.") || cut.hasSuffix("then, and more.") || cut.hasSuffix("and, and more."))
        #expect(CatchUp.gist("") == "")
    }

    // MARK: What is said

    @Test func theCatchUpNamesEachChatAndWhenItMoved() {
        let items: [CatchUp.Item] = [
            .init(title: "Deploy script", when: now.addingTimeInterval(-20 * 60), said: .reply("The deploy finished and all checks passed.")),
            .init(title: "Backups.", when: now.addingTimeInterval(-3 * 3600), said: .working),
            .init(title: CarPlayChats.untitled, when: now.addingTimeInterval(-26 * 3600), said: .nothing),
        ]
        #expect(CatchUp.script(items, told: nil, now: now) == """
        3 chats have something new.

        Deploy script, 20 minutes ago. The deploy finished and all checks passed.

        Backups, 3 hours ago. No reply yet.

        An untitled chat, yesterday.
        """)
        #expect(CatchUp.script(Array(items.prefix(1)), told: nil, now: now).hasPrefix("One chat has something new.\n\nDeploy script, 20 minutes ago."))
        // More than are read out: counted, and said so.
        #expect(CatchUp.script(Array(items.prefix(2)), more: 4, told: nil, now: now).hasPrefix("6 chats have something new. Here are the latest 2.\n\n"))
    }

    @Test func nothingNewIsSaidWithSinceWhen() {
        #expect(CatchUp.script([], told: nil, now: now) == "You're all caught up. Nothing new in the last day.")
        let today = Calendar.current.startOfDay(for: now).addingTimeInterval(8 * 3600 + 10 * 60)
        let later = today.addingTimeInterval(3 * 3600)
        #expect(CatchUp.script([], told: today, now: later) == "You're all caught up. Nothing new since 8:10 AM.")
        #expect(CatchUp.script([], told: today, now: later.addingTimeInterval(24 * 3600)) == "You're all caught up. Nothing new since yesterday at 8:10 AM.")
    }

    @Test func aRequestWaitingOnThePhoneComesFirst() {
        #expect(CatchUp.script([], told: nil, waiting: "Backups", now: now)
            == "Backups is waiting for your answer on your iPhone.\n\nOtherwise nothing new in the last day.")
        let item = CatchUp.Item(title: "Deploy script", when: now.addingTimeInterval(-90), said: .reply("Done."))
        #expect(CatchUp.script([item], told: nil, waiting: "Backups", now: now)
            == "Backups is waiting for your answer on your iPhone.\n\nOne chat has something new.\n\nDeploy script, 1 minute ago. Done.")
    }

    // MARK: Saying something that isn't a reply

    /// Holds what is to be said until the test lets it go.
    @MainActor final class Held {
        private var waiting: CheckedContinuation<String, Never>?
        private(set) var asked = 0
        func words() async -> String {
            asked += 1
            return await withCheckedContinuation { waiting = $0 }
        }
        func release(_ text: String) { waiting?.resume(returning: text); waiting = nil }
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aBriefingThinksThenSpeaksAndListensToNothing() async throws {
        let h = CarPlayTests.Harness()
        let held = Held()
        var heard = 0
        h.session.brief({ await held.words() }, heard: { heard += 1 })
        #expect(h.session.phase == .thinking)
        try await waitUntil("the words to be asked for") { held.asked == 1 }
        #expect(h.speaker.spoken.isEmpty)
        held.release("Two chats have something new.")
        try await waitUntil("speaking") { h.session.phase == .speaking }
        #expect(h.speaker.spoken == ["Two chats have something new."])
        #expect(heard == 0)
        h.speaker.finishSpeaking()
        #expect(h.session.phase == .idle && heard == 1)
        #expect(h.recognizer.starts == 0 && !h.conversation.isStreaming, "not a turn: nothing was sent, nothing is listened to")
    }

    @Test func aBriefingEndedWhileItThinksSaysNothing() async throws {
        let h = CarPlayTests.Harness()
        let held = Held()
        var heard = 0
        h.session.brief({ await held.words() }, heard: { heard += 1 })
        try await waitUntil("the words to be asked for") { held.asked == 1 }
        h.session.cancel()
        #expect(h.session.phase == .idle)
        held.release("Two chats have something new.")
        try await Task.sleep(for: .milliseconds(60))
        #expect(h.speaker.spoken.isEmpty && h.session.phase == .idle && heard == 0)
    }

    @Test func aBriefingCutShortWasNotHeard() async throws {
        let h = CarPlayTests.Harness()
        var heard = 0
        h.session.brief({ "Two chats have something new." }, heard: { heard += 1 })
        try await waitUntil("speaking") { h.session.phase == .speaking }
        h.session.primaryAction()   // a tap on the mic: now it listens
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.speaker.finishSpeaking()
        #expect(heard == 0)
        h.session.cancel()
    }

    @Test func aBriefingWaitsItsTurn() async throws {
        let h = CarPlayTests.Harness()
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.session.brief({ "Two chats have something new." })
        try await Task.sleep(for: .milliseconds(60))
        #expect(h.session.phase == .listening && h.speaker.spoken.isEmpty, "the mic is open: nothing is said over it")
        h.session.cancel()
    }
}

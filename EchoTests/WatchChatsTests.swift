import Foundation
import Testing
@testable import Echo

/// The Apple Watch's list of the server's conversations and where one stands when it is opened:
/// the reading of what the Hermes API returns. (The watch target has no tests of its own; this
/// file's subject is compiled into the phone's app too.)
struct WatchChatsTests {
    private func sessions(_ text: String) throws -> [HermesSessionsAPI.SessionSummary] {
        try JSONDecoder().decode([HermesSessionsAPI.SessionSummary].self, from: Data(text.utf8))
    }

    private func rows(_ text: String) throws -> [HermesSessionsAPI.StoredMessage] {
        try JSONDecoder().decode([HermesSessionsAPI.StoredMessage].self, from: Data(text.utf8))
    }

    @Test func theListIsTheNewestConversationsThatHaveSomethingInThem() throws {
        let list = WatchChat.list(try sessions(#"""
        [{"id": "a", "title": "Weekend hike", "message_count": 4, "started_at": 100, "last_active": 500},
         {"id": "b", "title": "", "preview": "What is on my calendar tomorrow and the day after that, in order of time please", "message_count": 2, "last_active": 900},
         {"id": "c", "title": "Never used", "message_count": 0, "last_active": 950},
         {"id": "d", "title": "  ", "preview": "", "message_count": 2, "started_at": 300},
         {"id": "e", "title": "Old one", "last_active": 10}]
        """#))
        #expect(list.map(\.id) == ["b", "a", "d", "e"], "newest first; one nobody said anything in is left out")
        #expect(list[0].title == "What is on my calendar tomorrow and the day after that, in o", "untitled: how it began, cut to fit a wrist")
        #expect(list[1].title == "Weekend hike" && list[1].lastActive == Date(timeIntervalSince1970: 500))
        #expect(list[2].title == "Untitled chat" && list[2].lastActive == Date(timeIntervalSince1970: 300), "when it started, where nothing says when it was last used")
        #expect(list[3].title == "Old one")

        let many = (0 ..< 50).map { #"{"id": "s\#($0)", "title": "Chat \#($0)", "message_count": 2, "last_active": \#($0)}"# }.joined(separator: ",")
        let capped = WatchChat.list(try sessions("[\(many)]"))
        #expect(capped.count == WatchChat.most && capped.first?.id == "s49")
    }

    @Test func anOpenedConversationShowsItsLastQuestionAndAnswer() throws {
        let last = WatchChat.lastExchange(try rows(#"""
        [{"role": "user", "content": "Plan the weekend hike"},
         {"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "function": {"name": "terminal", "arguments": "{}"}}]},
         {"role": "tool", "content": "ok", "tool_name": "terminal"},
         {"role": "assistant", "content": "Sunrise at Bear Peak works."},
         {"role": "system", "content": "ignored"},
         {"role": "user", "content": "  And what should I pack?  "},
         {"role": "assistant", "content": "", "tool_calls": [{"id": "c2", "function": {"name": "memory", "arguments": "{}"}}]},
         {"role": "assistant", "content": "Layers, water and a headlamp."},
         {"role": "assistant", "content": "A note Hermes keeps to itself.", "display_kind": "hidden"}]
        """#))
        #expect(last.question == "And what should I pack?")
        #expect(last.reply == "Layers, water and a headlamp.", "the words, not the tool rows or what Hermes hides")

        // Asked and not answered yet: the question, and nothing after it.
        let waiting = WatchChat.lastExchange(try rows(#"[{"role": "user", "content": "One"}, {"role": "assistant", "content": "First."}, {"role": "user", "content": "Two"}]"#))
        #expect(waiting.question == "Two" && waiting.reply.isEmpty)
        // Nothing to show.
        let none = WatchChat.lastExchange([])
        #expect(none.question.isEmpty && none.reply.isEmpty)
        // A reply-language note the phone added to a message isn't part of what was asked.
        let row = try JSONSerialization.data(withJSONObject: [["role": "user", "content": "Hallo" + ReplyLanguage.note("de")]])
        let noted = WatchChat.lastExchange(try JSONDecoder().decode([HermesSessionsAPI.StoredMessage].self, from: row))
        #expect(noted.question == "Hallo")
    }

    @Test func aRowSaysHowLongAgo() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(WatchChat(id: "a", title: "A", lastActive: now.addingTimeInterval(-20)).when(now: now) == "just now")
        #expect(WatchChat(id: "a", title: "A", lastActive: now.addingTimeInterval(-7200)).when(now: now)?.contains("2") == true)
        #expect(WatchChat(id: "a", title: "A").when(now: now) == nil)
    }
}

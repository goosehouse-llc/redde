import Foundation
import Testing
@testable import Echo

/// Reactions to a reply: the note the agent is told, hidden when read back, and kept on a reread.
struct ReactionsTests {
    @Test func theNoteSaysWhatAndToWhichReplyAndIsHiddenOnTheWayBack() throws {
        let note = try #require(ReactionNote.note([("👍", "Booked the 9:40 to Lisbon.\nSeat 12A."), ("👎", "Here is a poem")]))
        #expect(note.contains("👍 (liked it) to your reply that began \"Booked the 9:40 to Lisbon. Seat 12A.\""))
        #expect(note.contains("👎 (didn't like it)"))
        #expect(ReactionNote.note([]) == nil)
        let sent = "Thanks, and the hotel?" + note + "\n\n(Reply in English.)"
        #expect(ReplyLanguage.stripNote(sent) == "Thanks, and the hotel?", "anywhere among the others")
    }

    @Test func aLongReplyIsQuotedByItsStart() {
        let quoted = Reactions.opening(of: String(repeating: "word ", count: 50))
        #expect(quoted.count <= 80 && quoted.hasSuffix("…"))
    }

    @Test func reactionsGoBackOnTheirRepliesWhenTheChatIsReadAgain() {
        var reacted = Message(role: .assistant, text: "Booked the 9:40.")
        reacted.reaction = "❤️"
        reacted.reactionSaid = true
        let here = [Message(role: .user, text: "Book it"), reacted]
        let host = [Message(role: .user, text: "Book it"), Message(role: .assistant, text: "Booked the 9:40.")]
        let merged = Conversation.keepingAsides(of: here, in: host)
        #expect(merged.count == 2 && merged[1].reaction == "❤️" && merged[1].reactionSaid)
    }
}

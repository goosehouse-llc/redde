import Foundation
import Testing
@testable import Echo

/// A group chat's voice reads each bot's reply as it is written, once, in the order they began,
/// and never a bot that passes (`GroupReplies`).
struct GroupRepliesTests {
    private func message(_ seq: Int, _ member: String, _ text: String) -> GroupEvent {
        GroupEvent(seq: seq, kind: "message.member", actorKind: "member", actorID: member,
                   payload: .object(["text": .string(text)]), createdAt: .now)
    }

    private func draft(_ id: String, _ member: String?, _ text: String, after: Int, finished: Bool = false) -> GroupDraft {
        GroupDraft(id: id, memberID: member, text: text, finishedAt: finished ? .now : nil, after: after)
    }

    @Test func aReplyIsReadAsItIsWrittenAndNotAgainWhenItLands() throws {
        var replies = GroupReplies(since: 10)
        replies.update(events: [], drafts: [draft("s1", "scout", "Falls Loop is open", after: 11)])
        let next = replies.next()
        let reading = try #require(next)
        #expect(reading.memberID == "scout" && reading.text == "Falls Loop is open" && !reading.whole)
        replies.update(events: [], drafts: [draft("s1", "scout", "Falls Loop is open. Bring layers.", after: 11)])
        #expect(replies.reading?.text == "Falls Loop is open. Bring layers.")
        // The room has it: whole, with the room's words.
        replies.update(events: [message(12, "scout", "Falls Loop is open. Bring layers!")], drafts: [])
        #expect(replies.reading?.whole == true && replies.reading?.seq == 12)
        #expect(replies.reading?.text == "Falls Loop is open. Bring layers!")
        replies.finishReading()
        replies.update(events: [message(12, "scout", "Falls Loop is open. Bring layers!")], drafts: [])
        #expect(replies.next() == nil, "read once")
    }

    @Test func aDraftFinishedBeforeItsMessageIsReadOnce() {
        var replies = GroupReplies(since: 0)
        replies.update(events: [], drafts: [draft("s1", "writer", "Saturday at eight.", after: 3, finished: true)])
        #expect(replies.next()?.whole == true)
        replies.finishReading()
        // Its message comes once it has been heard.
        replies.update(events: [message(4, "writer", "Saturday at eight.")], drafts: [])
        #expect(replies.next() == nil)
    }

    @Test func aReplyNeverSeenBeingWrittenIsReadWhenItLands() {
        var replies = GroupReplies(since: 5)
        replies.update(events: [message(4, "scout", "Before voice began."), message(6, "scout", "Three trails.")], drafts: [])
        let next = replies.next()
        #expect(next?.text == "Three trails." && next?.whole == true, "only what follows the voice's start")
        replies.finishReading()
        #expect(replies.next() == nil)
    }

    @Test func aDraftAndItsMessageSeenTogetherAreOneReply() {
        var replies = GroupReplies(since: 0)
        replies.update(events: [message(8, "scout", "Three trails.")], drafts: [draft("s1", "scout", "Three trails.", after: 7, finished: true)])
        #expect(replies.next()?.seq == 8)
        replies.finishReading()
        #expect(replies.next() == nil)
    }

    @Test func aBotThatPassesIsNeverRead() {
        var replies = GroupReplies(since: 0)
        for text in ["", "P", "pa", "Pass", "(pass", "(pass)", "Pass."] {
            replies.update(events: [], drafts: [draft("s1", "fixit", text, after: 1)])
            #expect(replies.next() == nil, "\"\(text)\" might be a pass")
        }
        replies.update(events: [], drafts: [draft("s1", "fixit", "Pass.", after: 1, finished: true)])
        #expect(replies.next() == nil)
        // Words that only begin like it are read.
        replies.update(events: [], drafts: [draft("s2", "scout", "Passing the mill, turn left.", after: 1)])
        #expect(replies.next()?.memberID == "scout")
        #expect(!GroupReplies.mayBePass("Passing"))
    }

    @Test func repliesAreReadInTheOrderTheyBegan() {
        var replies = GroupReplies(since: 0)
        replies.update(events: [], drafts: [draft("b", "writer", "Second to start.", after: 5)])
        replies.update(events: [message(4, "scout", "First to start.")], drafts: [draft("b", "writer", "Second to start.", after: 5)])
        #expect(replies.next()?.memberID == "scout")
        replies.finishReading()
        #expect(replies.next()?.memberID == "writer")
    }

    /// The order a reply was found in breaks a tie between two begun at the same point.
    @Test func twoBegunTogetherKeepTheOrderTheyWereFound() {
        var replies = GroupReplies(since: 0)
        replies.update(events: [], drafts: [draft("a", "scout", "Scout here.", after: 5), draft("b", "writer", "Quill here.", after: 5)])
        #expect(replies.next()?.memberID == "scout")
        replies.finishReading()
        #expect(replies.next()?.memberID == "writer")
    }

    @Test func aReplyStoppedBeforeItsEndIsCutWhereItGot() {
        var replies = GroupReplies(since: 0)
        replies.update(events: [], drafts: [draft("a", "scout", "Falls Loop is", after: 1), draft("b", "writer", "Saturday", after: 1)])
        #expect(replies.next()?.memberID == "scout")
        // The room stops: both drafts go with no message.
        replies.update(events: [], drafts: [])
        #expect(replies.reading?.isAbandoned == true, "the one being read ends where it got")
        replies.finishReading()
        #expect(replies.next() == nil, "one not begun isn't read")
    }

    @Test func whatWasLetGoIsNotReadWhenItLands() {
        var replies = GroupReplies(since: 0)
        replies.update(events: [], drafts: [draft("a", "scout", "Falls Loop is open", after: 1), draft("b", "writer", "Saturday works", after: 1)])
        _ = replies.next()
        // The person spoke (or Stop): all of it is let go.
        replies.dropAll()
        replies.update(events: [message(2, "scout", "Falls Loop is open."), message(3, "writer", "Saturday works.")], drafts: [])
        #expect(replies.next() == nil)
        // What is written after that is read.
        replies.update(events: [], drafts: [draft("c", "scout", "And the bridge is fixed.", after: 4)])
        #expect(replies.next()?.memberID == "scout")
    }

    @Test func aDraftWaitsUntilItsBotIsKnown() {
        var replies = GroupReplies(since: 0)
        replies.update(events: [], drafts: [draft("a", nil, "Falls Loop is open.", after: 1)])
        #expect(replies.next() == nil, "no face or voice for it yet")
        replies.update(events: [], drafts: [draft("a", "scout", "Falls Loop is open.", after: 1)])
        #expect(replies.next()?.memberID == "scout")
    }
}

import Foundation
import Testing
@testable import Echo

/// How much of a conversation the transcript lays out: sized by what it holds.
struct TranscriptPageTests {
    private func thread(_ turns: Int, replyLength: Int) -> [Message] {
        (0 ..< turns).flatMap { _ in
            [Message(role: .user, text: "A question."), Message(role: .assistant, text: String(repeating: "x", count: replyLength))]
        }
    }

    @Test func aChatOfShortRepliesShowsManyMessages() {
        // 600-character replies: about 1,100 a turn with the rows themselves, so a 30,000 budget holds ~27 turns.
        let count = TranscriptPage.count(thread(100, replyLength: 600), budget: 30_000)
        #expect(count > 40 && count <= TranscriptPage.maximumMessages)
    }

    @Test func longRepliesShrinkThePageToWhatFits() {
        // 10,000-character replies: two fit, with their questions; the third would go over.
        #expect(TranscriptPage.count(thread(32, replyLength: 10_000), budget: 30_000) == 4)
        #expect(TranscriptPage.count(thread(32, replyLength: 10_000), budget: 60_000) == 10)
    }

    /// The budget may run out on a reply; its question is shown with it all the same.
    @Test func aPageDoesNotOpenOnAReplyWithoutItsQuestion() {
        // 9,500-character replies: the third fits, its question would not.
        let messages = thread(32, replyLength: 9_500)
        let count = TranscriptPage.count(messages, budget: 30_000)
        #expect(count == 6)
        #expect(messages[messages.count - count].role == .user)
    }

    @Test func theLastExchangesShowHoweverLongTheyAre() {
        #expect(TranscriptPage.count(thread(10, replyLength: 200_000), budget: 30_000) == TranscriptPage.minimumMessages)
        #expect(TranscriptPage.count(thread(1, replyLength: 200_000), budget: 30_000) == 2)   // all there is
        #expect(TranscriptPage.count([Message](), budget: 30_000) == 0)
    }

    @Test func aPageNeverHoldsMoreThanTheMostMessages() {
        #expect(TranscriptPage.count(thread(200, replyLength: 5), budget: .max) == TranscriptPage.maximumMessages)
    }

    @Test func thingsThatTakeRoomWithoutTextCount() {
        var withPictures = Message(role: .user, text: "Look.")
        withPictures.attachments = (0 ..< 4).map { _ in Attachment(kind: .image, filename: "a.jpg", mimeType: "image/jpeg", data: Data()) }
        #expect(TranscriptPage.weight(of: withPictures) > TranscriptPage.weight(of: Message(role: .user, text: "Look.")) + 5_000)
        // Thinking is folded away: it doesn't count.
        var thoughtful = Message(role: .assistant, text: "Yes.")
        thoughtful.reasoning = String(repeating: "x", count: 50_000)
        #expect(TranscriptPage.weight(of: thoughtful) == TranscriptPage.weight(of: Message(role: .assistant, text: "Yes.")))
    }

    /// "Show earlier messages" takes the page before: sized the same way, from where the page starts.
    @Test func theEarlierPageIsSizedTheSameWay() {
        let messages = thread(32, replyLength: 10_000)
        let shown = TranscriptPage.count(messages, budget: 30_000)
        #expect(TranscriptPage.count(messages.dropLast(shown), budget: 30_000) == 4)
        #expect(TranscriptPage.count(messages.dropLast(messages.count), budget: 30_000) == 0)
    }
}

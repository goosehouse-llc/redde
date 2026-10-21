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

    // MARK: - The window

    /// The bug this guards against: with the page kept as a length from the end, a message added
    /// at the end pushed the oldest rows off the top until the page was resized, and the
    /// transcript tore them down and built them again on every send.
    @Test func addingAMessageLeavesTheRowsAboveInPlace() {
        var messages = thread(2, replyLength: 200)
        var window = TranscriptPage.Window()
        window.settle(messages, budget: 30_000)
        #expect(window.hiddenCount(in: messages, budget: 30_000) == 0)
        // Sent: the question and the reply's empty row are there before the page is settled again.
        messages += [Message(role: .user, text: "And then?"), Message(role: .assistant, text: "")]
        #expect(window.hiddenCount(in: messages, budget: 30_000) == 0, "the first rows must still be on the page")
        window.settle(messages, budget: 30_000)
        #expect(window.hiddenCount(in: messages, budget: 30_000) == 0)
    }

    @Test func aFullPageSlidesOnlyWhenItIsSettled() {
        // 10,000-character replies: two exchanges fit.
        var messages = thread(6, replyLength: 10_000)
        var window = TranscriptPage.Window()
        window.settle(messages, budget: 30_000)
        #expect(window.hiddenCount(in: messages, budget: 30_000) == 8)
        messages += thread(1, replyLength: 10_000)
        #expect(window.hiddenCount(in: messages, budget: 30_000) == 8, "nothing moves until the page is settled")
        window.settle(messages, budget: 30_000)
        #expect(window.hiddenCount(in: messages, budget: 30_000) == 10)
    }

    @Test func earlierMessagesTheReaderLoadedStayUntilTheySendAgain() {
        var messages = thread(6, replyLength: 10_000)
        var window = TranscriptPage.Window()
        window.settle(messages, budget: 30_000)
        #expect(window.earlierCount(in: messages, budget: 30_000) == 4)
        window.showEarlier(messages, budget: 30_000)
        #expect(window.hiddenCount(in: messages, budget: 30_000) == 4)
        // A reply arrives while they read: the page keeps what they loaded.
        messages += thread(1, replyLength: 10_000)
        window.settle(messages, budget: 30_000)
        #expect(window.hiddenCount(in: messages, budget: 30_000) == 4)
        // They send: back to the newest page.
        window.settle(messages, release: true, budget: 30_000)
        #expect(window.hiddenCount(in: messages, budget: 30_000) == 10)
    }

    @Test func aSearchBringsItsMatchOntoThePage() {
        let messages = thread(6, replyLength: 10_000)
        var window = TranscriptPage.Window()
        window.settle(messages, budget: 30_000)
        window.reveal(5, in: messages, budget: 30_000)
        #expect(window.hiddenCount(in: messages, budget: 30_000) == 3)
        // One already on the page changes nothing.
        window.reveal(10, in: messages, budget: 30_000)
        #expect(window.hiddenCount(in: messages, budget: 30_000) == 3)
    }

    /// Messages can go as well as come (a reply regenerated, a message edited and resent).
    @Test func theWindowNeverStartsPastTheEnd() {
        let messages = thread(6, replyLength: 10_000)
        var window = TranscriptPage.Window()
        window.settle(messages, budget: 30_000)
        #expect(window.hiddenCount(in: Array(messages.prefix(4)), budget: 30_000) == 4)
        #expect(window.earlierCount(in: Array(messages.prefix(2)), budget: 30_000) >= 1)
    }

    /// The bug this guards against: a page settled for a short chat kept its count (nothing before
    /// the page) for the long one opened after it, which laid the whole of it out for the pass
    /// before the page was settled: two seconds frozen for 48 long replies, to show five.
    @Test func anotherConversationIsPagedAfresh() {
        var window = TranscriptPage.Window()
        window.settle(thread(1, replyLength: 200), budget: 30_000)
        #expect(window.hiddenCount(in: thread(24, replyLength: 10_000), budget: 30_000) == 44)
    }

    /// A conversation from the server opens empty and its history comes after.
    @Test func historyArrivingAfterAnEmptyOpenIsPagedAfresh() {
        var window = TranscriptPage.Window()
        window.settle([], budget: 30_000)
        #expect(window.hiddenCount(in: thread(24, replyLength: 10_000), budget: 30_000) == 44)
    }

    @Test func earlierMessagesLoadedInOneConversationAreLetGoForAnother() {
        let first = thread(6, replyLength: 10_000)
        var window = TranscriptPage.Window()
        window.settle(first, budget: 30_000)
        window.showEarlier(first, budget: 30_000)
        let other = thread(6, replyLength: 10_000)
        #expect(window.hiddenCount(in: other, budget: 30_000) == 8)
        window.settle(other, budget: 30_000)
        #expect(window.hiddenCount(in: other, budget: 30_000) == 8)
    }

    @Test func nothingEarlierMeansNothingToShow() {
        let messages = thread(2, replyLength: 100)
        var window = TranscriptPage.Window()
        window.settle(messages, budget: 30_000)
        #expect(window.earlierCount(in: messages, budget: 30_000) == 0)
    }
}

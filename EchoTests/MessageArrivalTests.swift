import Foundation
import Testing
@testable import Echo

/// Which messages arrive with a move: only one just sent, and the reply's row while it waits.
struct MessageArrivalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(_ role: Message.Role, _ text: String, secondsAgo: TimeInterval) -> Message {
        var message = Message(role: role, text: text)
        message.createdAt = now.addingTimeInterval(-secondsAgo)
        return message
    }

    @Test func aMessageJustSentRises() {
        #expect(MessageArrival.kind(for: message(.user, "Hello", secondsAgo: 0.05), isLive: false, now: now) == .sent)
    }

    /// A conversation that is opened, or history that loads, is simply there.
    @Test func olderMessagesDontMove() {
        #expect(MessageArrival.kind(for: message(.user, "Hello", secondsAgo: 5), isLive: false, now: now) == .none)
        #expect(MessageArrival.kind(for: message(.assistant, "Hi.", secondsAgo: 5), isLive: false, now: now) == .none)
        #expect(MessageArrival.kind(for: message(.user, "Hello", secondsAgo: MessageArrival.freshness + 0.1), isLive: false, now: now) == .none)
    }

    @Test func theReplysRowWaitsABeatOnlyWhileItIsEmpty() {
        let waiting = message(.assistant, "", secondsAgo: 0.05)
        #expect(MessageArrival.kind(for: waiting, isLive: true, now: now) == .waitingReply)
        // Words have come, or thinking, or a tool: it is a reply now, and stays put.
        #expect(MessageArrival.kind(for: message(.assistant, "The", secondsAgo: 0.05), isLive: true, now: now) == .none)
        var thinking = waiting
        thinking.reasoning = "weighing"
        #expect(MessageArrival.kind(for: thinking, isLive: true, now: now) == .none)
        // Not the live reply (a row from the demo, a reply that failed at once).
        #expect(MessageArrival.kind(for: waiting, isLive: false, now: now) == .none)
    }
}

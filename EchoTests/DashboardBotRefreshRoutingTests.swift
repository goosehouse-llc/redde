import Foundation
import Testing
@testable import Echo

struct DashboardBotRefreshRoutingTests {
    @Test func onlyAnAlreadyOpenDashboardBotUsesBoundedRefresh() {
        let bot = BotRef(profile: "default", name: "Hermes")
        #expect(Conversation.usesBoundedDashboardBotRefresh(connection: .hermesServe, bot: bot))
        #expect(!Conversation.usesBoundedDashboardBotRefresh(connection: .hermesServe, bot: nil))
        #expect(!Conversation.usesBoundedDashboardBotRefresh(connection: .hermesSessions, bot: bot))
        #expect(!Conversation.usesBoundedDashboardBotRefresh(connection: .acp, bot: bot))
    }

    @Test func overlappingNewestPagePreservesOlderRowsAndReplacesTheSuffix() {
        let old = (1 ... 5).map(message)
        let page = (4 ... 7).map(message)

        let merged = Conversation.mergingRefreshedPage(page, into: old)

        #expect(merged?.map(\.text) == (1 ... 7).map(String.init))
    }

    @Test func disjointNewestPageLeavesTheLocalTranscriptUntouched() {
        let old = (1 ... 3).map(message)
        let page = (7 ... 9).map(message)

        #expect(Conversation.mergingRefreshedPage(page, into: old) == nil)
    }

    @Test func overlapDoesNotDuplicateRowsOrKeepAStaleSuffix() {
        let old = (1 ... 6).map(message)
        let page = (4 ... 5).map(message) + [message(7)]

        let merged = Conversation.mergingRefreshedPage(page, into: old)

        #expect(merged?.map(\.text) == ["1", "2", "3", "4", "5", "7"])
    }

    @Test func ambiguousOverlapFailsSafe() {
        let repeated = message(2)
        let old = [message(1), repeated, message(3), repeated]

        #expect(Conversation.mergingRefreshedPage([repeated, message(4)], into: old) == nil)
    }

    private func message(_ value: Int) -> Message {
        Message(role: value.isMultiple(of: 2) ? .assistant : .user,
                text: String(value), createdAt: Date(timeIntervalSince1970: TimeInterval(value)))
    }
}

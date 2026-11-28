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
}

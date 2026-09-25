import Foundation
import Testing
import UserNotifications
@testable import Echo

/// Notifier against a fake notification center: banner construction, suppression rules,
/// category registration, and routing banner actions back onto the pending interrupt.
@MainActor
struct NotifierTests {
    final class FakeCenter: NotificationCentering {
        var delegate: UNUserNotificationCenterDelegate?
        private(set) var categories: Set<UNNotificationCategory> = []
        private(set) var added: [UNNotificationRequest] = []
        private(set) var clearedDelivered = 0
        var authorizationGranted = true

        func setNotificationCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories }
        func add(_ request: UNNotificationRequest, withCompletionHandler handler: (@Sendable ((any Error)?) -> Void)?) {
            added.append(request)
            handler?(nil)
        }
        func removeAllDeliveredNotifications() { clearedDelivered += 1 }
        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { authorizationGranted }

        /// What the dedupe sweep sees in Notification Center.
        var deliveredList: [Notifier.DeliveredBanner] = []
        private(set) var removedIDs: [String] = []
        func delivered() async -> [Notifier.DeliveredBanner] { deliveredList }
        func removeDelivered(ids: [String]) {
            removedIDs += ids
            deliveredList.removeAll { ids.contains($0.id) }
        }
    }

    struct Harness {
        let notifier: Notifier
        let center = FakeCenter()
        let settings: Settings

        init(enabled: Bool = true, appActive: Bool = false) {
            let suite = UserDefaults(suiteName: "notifier-\(UUID().uuidString)")!
            settings = Settings(defaults: suite)
            settings.notifyInBackground = enabled
            notifier = Notifier(center: center, settings: settings, isAppActive: { appActive })
        }
    }

    // MARK: Approval banners

    @Test func approvalBannerCarriesActionsAndRouting() {
        let h = Harness()
        h.notifier.notifyApproval(ApprovalRequest(id: "req1", command: "rm -rf /tmp/x",
                                                  description: "Dangerous", choices: ["once", "session", "deny"]))
        let request = try! #require(h.center.added.first)
        #expect(request.identifier == "redde.interrupt.req1")
        #expect(request.content.categoryIdentifier == "redde.approval")
        #expect(request.content.body.contains("rm -rf /tmp/x") && request.content.body.contains("Dangerous"))
        #expect(request.content.userInfo["approve"] as? String == "once")
        #expect(request.content.userInfo["deny"] as? String == "deny")
    }

    @Test func approvalWithoutADenyChoiceGetsNoActionCategory() {
        let h = Harness()
        h.notifier.notifyApproval(ApprovalRequest(id: "r", command: "x", description: nil, choices: ["once"]))
        #expect(h.center.added.first?.content.categoryIdentifier == "")
    }

    @Test func twoApprovalsInOneTurnBothShow() {
        let h = Harness()
        h.notifier.notifyApproval(ApprovalRequest(id: "a", command: "x", description: nil, choices: ["once", "deny"]))
        h.notifier.notifyApproval(ApprovalRequest(id: "b", command: "y", description: nil, choices: ["once", "deny"]))
        #expect(Set(h.center.added.map(\.identifier)).count == 2, "distinct ids so neither replaces the other")
    }

    // MARK: Clarify banners

    @Test func clarifyWithFewChoicesRegistersAdHocButtons() {
        let h = Harness()
        h.notifier.install(conversation: Conversation(settings: h.settings,
                                                      store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "n-\(UUID().uuidString)"))))
        let q = ClarifyQuestion(id: "q1", question: "Which day?", choices: ["Mon", "Tue"], multiSelect: false)
        h.notifier.notifyClarify(ClarifyRequest(id: "c1", questions: [q], isBatch: false))
        let request = try! #require(h.center.added.first)
        #expect(request.content.categoryIdentifier == "redde.clarify.choice.c1")
        let category = h.center.categories.first { $0.identifier == "redde.clarify.choice.c1" }
        #expect(category?.actions.map(\.title) == ["Mon", "Tue"])
        #expect(request.content.userInfo["questionID"] as? String == "q1")
    }

    @Test func clarifyWithManyChoicesFallsBackToTextInput() {
        let h = Harness()
        let q = ClarifyQuestion(id: "q1", question: "Pick one",
                                choices: ["a", "b", "c", "d", "e"], multiSelect: false)
        h.notifier.notifyClarify(ClarifyRequest(id: "c2", questions: [q], isBatch: false))
        #expect(h.center.added.first?.content.categoryIdentifier == "redde.clarify.text")
    }

    @Test func batchClarifyJustOpensTheApp() {
        let h = Harness()
        let qs = [ClarifyQuestion(id: "a", question: "A?", choices: [], multiSelect: false),
                  ClarifyQuestion(id: "b", question: "B?", choices: [], multiSelect: false)]
        h.notifier.notifyClarify(ClarifyRequest(id: "c3", questions: qs, isBatch: true))
        let request = try! #require(h.center.added.first)
        #expect(request.content.title.contains("2 questions"))
        #expect(request.content.categoryIdentifier == "")
    }

    // MARK: Suppression rules

    @Test func suppressedWhenDisabledForegroundOrEmpty() {
        let disabled = Harness(enabled: false)
        disabled.notifier.notify(.replied, title: "t", body: "b")
        #expect(disabled.center.added.isEmpty)

        let foreground = Harness(appActive: true)
        foreground.notifier.notify(.replied, title: "t", body: "b")
        #expect(foreground.center.added.isEmpty, "in front, the UI already shows it")

        let empty = Harness()
        empty.notifier.notify(.replied, title: "t", body: "")
        #expect(empty.center.added.isEmpty)
    }

    // MARK: Relay-duplicate sweep

    /// When a background stream survives, the local banner and the push relay's remote banner
    /// describe the same event; the sweep keeps the local one and removes the relay push.
    @Test func localBannerSweepsARecentRelayPush() async throws {
        let h = Harness()
        h.center.deliveredList = [
            .init(id: "apns-1", isRelayPush: true, date: .now.addingTimeInterval(-2)),
            .init(id: "apns-old", isRelayPush: true, date: .now.addingTimeInterval(-300)),
            .init(id: "redde.failed", isRelayPush: false, date: .now.addingTimeInterval(-2)),
        ]
        h.notifier.notify(.replied, title: "t", body: "the reply")
        let deadline = Date().addingTimeInterval(2)
        while !h.center.removedIDs.contains("apns-1") {
            if Date() > deadline { Issue.record("sweep never removed the relay push"); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(h.center.removedIDs == ["apns-1"], "only the relay push from this event's window goes")
        #expect(h.center.deliveredList.map(\.id).sorted() == ["apns-old", "redde.failed"])
    }

    @Test func suppressedBannerRunsNoSweep() async throws {
        let h = Harness(appActive: true)
        h.center.deliveredList = [.init(id: "apns-1", isRelayPush: true, date: .now)]
        h.notifier.notify(.replied, title: "t", body: "b")
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.center.removedIDs.isEmpty, "no local banner posted, so the remote one is the only banner and must stay")
    }

    @Test func bodyTruncatesAndAirPodsSettingRaisesInterruptionLevel() {
        let h = Harness()
        h.settings.announceOnAirPods = true
        h.notifier.notify(.replied, title: "t", body: String(repeating: "x", count: 300))
        let request = try! #require(h.center.added.first)
        #expect(request.content.body.count == 200)
        #expect(request.content.interruptionLevel == .timeSensitive)
    }

    // MARK: Routing banner actions

    /// A conversation whose transport raises an approval and then hangs, so the interrupt
    /// stays pending while the banner action arrives.
    private func pendingApprovalConversation() async throws -> (Conversation, String) {
        let suite = UserDefaults(suiteName: "notifier-conv-\(UUID().uuidString)")!
        let settings = Settings(defaults: suite)
        settings.transport = .chatCompletions
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        let approval = ApprovalRequest(id: "req9", command: "restart", description: nil, choices: ["once", "deny"])
        let transport = ConversationLifecycleTests.ScriptedTransport(
            [.interrupt(.approval(approval), runtimeSession: "run1")], hang: true)
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "n-\(UUID().uuidString)"))
        let conversation = Conversation(settings: settings, store: store, transportOverride: transport)
        conversation.send("do it")
        let deadline = Date().addingTimeInterval(3)
        while conversation.pendingInterrupt == nil {
            if Date() > deadline { Issue.record("interrupt never arrived"); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return (conversation, "req9")
    }

    @Test func approveActionAnswersThePendingInterrupt() async throws {
        let h = Harness()
        let (conversation, id) = try await pendingApprovalConversation()
        h.notifier.install(conversation: conversation)
        h.notifier.route(action: "redde.approve", requestID: id, questionID: nil,
                         approve: "once", deny: "deny", userText: nil)
        #expect(conversation.pendingInterrupt == nil, "the approval was answered and cleared")
    }

    @Test func staleApprovalActionIsIgnored() async throws {
        let h = Harness()
        let (conversation, _) = try await pendingApprovalConversation()
        h.notifier.install(conversation: conversation)
        h.notifier.route(action: "redde.approve", requestID: "some-old-request", questionID: nil,
                         approve: "once", deny: "deny", userText: nil)
        #expect(conversation.pendingInterrupt != nil, "a banner for a different request must not answer this one")
    }

    @Test func plainTapRoutesNowhere() async throws {
        let h = Harness()
        let (conversation, _) = try await pendingApprovalConversation()
        h.notifier.install(conversation: conversation)
        h.notifier.route(action: UNNotificationDefaultActionIdentifier, requestID: nil, questionID: nil,
                         approve: nil, deny: nil, userText: nil)
        #expect(conversation.pendingInterrupt != nil)
    }
}

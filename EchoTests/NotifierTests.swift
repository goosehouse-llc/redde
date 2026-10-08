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

    @Test func withTheSoundOffEveryNotificationIsSilentAndStillShown() {
        let h = Harness()
        h.notifier.notify(.replied, title: "t", body: "Done.")
        #expect(h.center.added.last?.content.sound != nil, "a sound unless it is turned off")
        #expect(h.notifier.presentation(pushKind: "reply", sessionID: "another").contains(.sound))

        h.settings.notificationSound = false
        h.notifier.notify(.replied, title: "t", body: "Done.")
        h.notifier.notifyApproval(ApprovalRequest(id: "req1", command: "rm -rf /tmp/x", description: nil, choices: ["once", "deny"]))
        #expect(h.center.added.count == 3)
        #expect(h.center.added.dropFirst().allSatisfy { $0.content.sound == nil })
        // One a paired Hermes sent, arriving while Redde is in front: shown, without the sound.
        #expect(h.notifier.presentation(pushKind: "reply", sessionID: "another") == [.banner, .list])
        // On until it is turned off, and it stays as set.
        let suite = UserDefaults(suiteName: "sound-\(UUID().uuidString)")!
        #expect(Settings(defaults: suite).notificationSound)
        Settings(defaults: suite).notificationSound = false
        #expect(!Settings(defaults: suite).notificationSound)
    }

    // MARK: Routing banner actions

    /// A conversation whose transport raises an approval and then hangs, so the interrupt
    /// stays pending while the banner action arrives.
    private func pendingApprovalConversation(session: String? = nil) async throws -> (Conversation, String) {
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
        if let session { conversation.replaceForDemo(serverSessionID: session, messages: []) }
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

    // MARK: Replying from a finished reply's banner

    private func idleConversation() -> Conversation {
        let settings = Settings(defaults: UserDefaults(suiteName: "notifier-conv-\(UUID().uuidString)")!)
        settings.transport = .chatCompletions
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "n-\(UUID().uuidString)"))
        return Conversation(settings: settings, store: store,
                            transportOverride: ConversationLifecycleTests.ScriptedTransport([.textDelta("Done."), .done]))
    }

    @Test func aFinishedReplysBannerNamesItsConversationAndOffersAReply() {
        let h = Harness()
        h.notifier.registerCategories()
        h.notifier.notify(.replied, title: "Redde replied", body: "All set.",
                          category: Notifier.repliedCategory, userInfo: [Notifier.conversationKey: "abc"])
        let request = try! #require(h.center.added.first)
        #expect(request.content.categoryIdentifier == "redde.replied")
        #expect(request.content.userInfo["conversation"] as? String == "abc")
        #expect(request.identifier == "redde.replied", "still one reply banner at a time")
        let action = h.center.categories.first { $0.identifier == "redde.replied" }?.actions.first
        #expect(action is UNTextInputNotificationAction)
        #expect(action?.options.contains(.authenticationRequired) == false)
    }

    /// With the app's own lock on, a reply from the Lock Screen would be a way round it.
    @Test func replyingFromTheBannerNeedsAnUnlockWhenTheAppIsLocked() {
        let h = Harness()
        h.settings.requireBiometrics = true
        h.notifier.registerCategories()
        let action = h.center.categories.first { $0.identifier == "redde.replied" }?.actions.first
        #expect(action?.options.contains(.authenticationRequired) == true)
    }

    @Test func aReplyTypedOnTheBannerIsTheNextMessage() {
        let h = Harness()
        let conversation = idleConversation()
        h.notifier.install(conversation: conversation)
        h.notifier.route(action: "redde.followup", requestID: nil, questionID: nil, approve: nil, deny: nil,
                         userText: "And tomorrow?", conversationID: conversation.id.uuidString)
        #expect(conversation.messages.contains { $0.role == .user && $0.text == "And tomorrow?" })
    }

    /// The banner's conversation was deleted since: the reply doesn't land in whichever is open.
    @Test func aReplyForAConversationThatIsGoneIsNotSentIntoAnother() {
        let h = Harness()
        let conversation = idleConversation()
        h.notifier.install(conversation: conversation)
        h.notifier.route(action: "redde.followup", requestID: nil, questionID: nil, approve: nil, deny: nil,
                         userText: "And tomorrow?", conversationID: UUID().uuidString)
        #expect(conversation.messages.isEmpty)
    }

    /// The Live Activity's Approve button answers through the same door as the banner's.
    @Test func theLiveActivitysAnswerSettlesThePendingApproval() async throws {
        let h = Harness()
        let (conversation, id) = try await pendingApprovalConversation()
        h.notifier.install(conversation: conversation)
        h.notifier.answerApproval(requestID: "some-old-request", choice: "once")
        #expect(conversation.pendingInterrupt != nil)
        h.notifier.answerApproval(requestID: id, choice: "deny")
        #expect(conversation.pendingInterrupt == nil)
    }

    @Test func plainTapRoutesNowhere() async throws {
        let h = Harness()
        let (conversation, _) = try await pendingApprovalConversation()
        h.notifier.install(conversation: conversation)
        h.notifier.route(action: UNNotificationDefaultActionIdentifier, requestID: nil, questionID: nil,
                         approve: nil, deny: nil, userText: nil)
        #expect(conversation.pendingInterrupt != nil)
    }

    // MARK: Notifications a paired Hermes sent

    @Test func aPushedReplyCanBeAnsweredOnlyOnceThePhoneIsUnlocked() {
        let h = Harness()
        h.notifier.registerCategories()
        let pushed = try! #require(h.center.categories.first { $0.identifier == PushNote.repliedCategory })
        #expect(pushed.actions.map(\.title) == ["Reply"])
        #expect(pushed.actions[0].options.contains(.authenticationRequired),
                "the app is started for it and can't read its passwords while the phone is locked")
        let local = try! #require(h.center.categories.first { $0.identifier == Notifier.repliedCategory })
        #expect(!local.actions[0].options.contains(.authenticationRequired))
    }

    @Test func tappingAPushedNotificationAsksForItsConversation() {
        let h = Harness()
        _ = LaunchRouter.shared.consumeSession()
        h.notifier.route(action: UNNotificationDefaultActionIdentifier, requestID: nil, questionID: nil,
                         approve: nil, deny: nil, userText: nil, sessionID: "20261006_101500_ab12cd")
        #expect(LaunchRouter.shared.consumeSession() == "20261006_101500_ab12cd")
        // A tap on one of the app's own banners just opens the app.
        h.notifier.route(action: UNNotificationDefaultActionIdentifier, requestID: nil, questionID: nil,
                         approve: nil, deny: nil, userText: nil)
        #expect(LaunchRouter.shared.consumeSession() == nil)
    }

    @Test func aPushArrivingInFrontShowsUnlessItsConversationIsOnScreen() {
        let h = Harness(appActive: true)
        let conversation = Conversation(settings: h.settings,
                                        store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "n-\(UUID().uuidString)")))
        conversation.replaceForDemo(serverSessionID: "open-session", messages: [])
        h.notifier.attach(conversation: conversation)
        #expect(h.notifier.presentation(pushKind: "reply", sessionID: "open-session") == [])
        #expect(h.notifier.presentation(pushKind: "approval", sessionID: "open-session") == [])
        #expect(h.notifier.presentation(pushKind: "reply", sessionID: "another").contains(.banner))
        #expect(h.notifier.presentation(pushKind: "paired", sessionID: nil).contains(.banner))
        #expect(h.notifier.presentation(pushKind: "test", sessionID: nil).contains(.banner))
        #expect(h.notifier.presentation(pushKind: nil, sessionID: nil) == [], "not from a paired Hermes: as before")
    }

    // MARK: Approve and Deny on a pushed approval

    @Test func aPushedApprovalIsAnsweredOnlyOnceThePhoneIsUnlocked() {
        let h = Harness()
        h.notifier.registerCategories()
        let pushed = try! #require(h.center.categories.first { $0.identifier == PushNote.approvalCategory })
        #expect(pushed.actions.map(\.title) == ["Approve", "Deny"])
        #expect(pushed.actions.allSatisfy { $0.options.contains(.authenticationRequired) },
                "the app may be started for either, and can't sign in while the phone is locked")
        #expect(pushed.actions[1].options.contains(.destructive))
    }

    /// What the notifier asked the Dashboard, in place of the Dashboard.
    final class Answers {
        var asked: [String] = []
        var outcome: Result<HermesServeClient.WaitingApproval, Error> = .success(.answered)
    }

    private func answering(_ h: Harness, _ answers: Answers) {
        h.notifier.answerWaiting = { session, digest, approve in
            answers.asked.append("\(session) \(digest) \(approve ? "approve" : "deny")")
            return try answers.outcome.get()
        }
    }

    @Test func approveOnAPushedApprovalAnswersThatSessionAndThatCommand() async {
        let h = Harness()
        let answers = Answers()
        answering(h, answers)
        let approve = h.notifier.route(action: "redde.approve", requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                                       sessionID: "20261007_1", approvalDigest: "17f69ae2697b61fd")
        await approve?.value
        let deny = h.notifier.route(action: "redde.deny", requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                                    sessionID: "20261007_2", approvalDigest: "d20c97f7d0825f2f")
        await deny?.value
        #expect(answers.asked == ["20261007_1 17f69ae2697b61fd approve", "20261007_2 d20c97f7d0825f2f deny"])
        #expect(h.center.added.isEmpty, "answered: nothing more to say")
        #expect(approve != nil, "the app is kept running until the answer is given")
    }

    @Test func anAnswerThatCouldNotBeGivenSaysSo() async throws {
        for (outcome, words) in [(Result<HermesServeClient.WaitingApproval, Error>.success(.nothingWaiting), "no longer waiting"),
                                 (.success(.anotherCommand), "Another command"),
                                 (.failure(TransportError.unreachable("Hermes Dashboard is unreachable")), "couldn't reach your Hermes")] {
            let h = Harness()
            let answers = Answers()
            answers.outcome = outcome
            answering(h, answers)
            await h.notifier.route(action: "redde.approve", requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                                   sessionID: "20261007_1", approvalDigest: "17f69ae2697b61fd")?.value
            let said = try #require(h.center.added.first)
            #expect(said.content.title == "The approval wasn't answered")
            #expect(said.content.body.contains(words), "\(said.content.body)")
            #expect(said.content.userInfo[PushNote.sessionKey] as? String == "20261007_1", "a tap opens the conversation")
        }
    }

    @Test func aPushedApprovalTheAppStillHasACardForIsAnsweredThere() async throws {
        let h = Harness()
        let answers = Answers()
        answering(h, answers)
        let (conversation, _) = try await pendingApprovalConversation(session: "20261007_1")
        h.notifier.install(conversation: conversation)
        // Another command's notification doesn't answer this card.
        await h.notifier.route(action: "redde.approve", requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                               sessionID: "20261007_1", approvalDigest: PushNote.digest(of: "something else"))?.value
        #expect(conversation.pendingInterrupt != nil)
        #expect(answers.asked.count == 1, "it went to the Dashboard, which says what is waiting")

        let work = h.notifier.route(action: "redde.approve", requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                                    sessionID: "20261007_1", approvalDigest: PushNote.digest(of: "restart"))
        #expect(work == nil && conversation.pendingInterrupt == nil, "the card was answered")
        #expect(answers.asked.count == 1)
    }

    // MARK: An answer on a pushed question

    final class Replies {
        var given: [String] = []
        var outcome: Result<HermesServeClient.WaitingQuestion, Error> = .success(.answered)
    }

    private func replying(_ h: Harness, _ replies: Replies) {
        h.notifier.answerWaitingQuestion = { session, digest, answer in
            replies.given.append("\(session) \(digest) \(answer)")
            return try replies.outcome.get()
        }
    }

    @Test func aPushedQuestionTakesATypedAnswerOnceThePhoneIsUnlocked() {
        let h = Harness()
        h.notifier.registerCategories()
        let pushed = try! #require(h.center.categories.first { $0.identifier == PushNote.questionCategory })
        #expect(pushed.actions.map(\.title) == ["Reply"])
        #expect(pushed.actions[0] is UNTextInputNotificationAction && pushed.actions[0].options.contains(.authenticationRequired))
        #expect(pushed.actions[0].identifier == PushNote.replyAction)
    }

    @Test func anAnswerOnAPushedQuestionGoesToThatSessionAndThatQuestion() async {
        let h = Harness()
        let replies = Replies()
        replying(h, replies)
        // Typed into the notification's Reply field.
        let typed = h.notifier.route(action: PushNote.replyAction, requestID: nil, questionID: nil, approve: nil, deny: nil, userText: " release ",
                                     sessionID: "20261007_1", questionDigest: "54e912433ad05e6b")
        await typed?.value
        // Or one of its choices, tapped: the button's action carries the choice's words.
        let picked = h.notifier.route(action: PushNote.replyAction + ".main (the default)", requestID: nil, questionID: nil, approve: nil, deny: nil,
                                      userText: nil, sessionID: "20261007_2", questionDigest: "0123456789abcdef")
        await picked?.value
        #expect(replies.given == ["20261007_1 54e912433ad05e6b release", "20261007_2 0123456789abcdef main (the default)"])
        #expect(h.center.added.isEmpty, "answered: nothing more to say")
        #expect(typed != nil, "the app is kept running until the answer is given")
        // An empty answer is none, and a tap on the notification itself still only opens the conversation.
        #expect(h.notifier.route(action: PushNote.replyAction, requestID: nil, questionID: nil, approve: nil, deny: nil, userText: "  ",
                                 sessionID: "20261007_1", questionDigest: "54e912433ad05e6b") == nil)
        _ = h.notifier.route(action: UNNotificationDefaultActionIdentifier, requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                             sessionID: "20261007_1", questionDigest: "54e912433ad05e6b")
        #expect(replies.given.count == 2)
        #expect(LaunchRouter.shared.consumeSession() == "20261007_1")
    }

    @Test func anAnswerThatCouldNotBeDeliveredSaysSo() async throws {
        for (outcome, words) in [(Result<HermesServeClient.WaitingQuestion, Error>.success(.nothingWaiting), "no longer waiting"),
                                 (.success(.anotherQuestion), "Something else is being asked"),
                                 (.failure(TransportError.unreachable("Hermes Dashboard is unreachable")), "couldn't reach your Hermes")] {
            let h = Harness()
            let replies = Replies()
            replies.outcome = outcome
            replying(h, replies)
            await h.notifier.route(action: PushNote.replyAction, requestID: nil, questionID: nil, approve: nil, deny: nil, userText: "release",
                                   sessionID: "20261007_1", questionDigest: "54e912433ad05e6b")?.value
            let said = try #require(h.center.added.first)
            #expect(said.content.title == "Your answer wasn't given")
            #expect(said.content.body.contains(words), "\(said.content.body)")
            #expect(said.content.userInfo[PushNote.sessionKey] as? String == "20261007_1", "a tap opens the conversation")
        }
    }

    @Test func aPushedQuestionTheAppStillHasACardForIsAnsweredThere() async throws {
        let h = Harness()
        let replies = Replies()
        replying(h, replies)
        let suite = UserDefaults(suiteName: "notifier-question-\(UUID().uuidString)")!
        let settings = Settings(defaults: suite)
        settings.transport = .chatCompletions
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        let asked = ClarifyRequest(id: "srq-1", questions: [ClarifyQuestion(id: "q0", question: "Which branch should I deploy?", choices: ["main", "release"], multiSelect: false)], isBatch: true)
        let transport = ConversationLifecycleTests.ScriptedTransport([.interrupt(.clarify(asked), runtimeSession: "run1")], hang: true)
        let conversation = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "n-\(UUID().uuidString)")),
                                        transportOverride: transport)
        conversation.replaceForDemo(serverSessionID: "20261007_1", messages: [])
        conversation.send("deploy it")
        for _ in 0 ..< 300 where conversation.pendingInterrupt == nil { try await Task.sleep(for: .milliseconds(10)) }
        h.notifier.install(conversation: conversation)

        // An answer to some other question doesn't settle this card.
        await h.notifier.route(action: PushNote.replyAction, requestID: nil, questionID: nil, approve: nil, deny: nil, userText: "yes",
                               sessionID: "20261007_1", questionDigest: PushNote.digest(of: "Go ahead?"))?.value
        #expect(conversation.pendingInterrupt != nil)
        #expect(replies.given.count == 1, "it went to the Dashboard, which says what is waiting")

        let work = h.notifier.route(action: PushNote.replyAction + ".release", requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                                    sessionID: "20261007_1", questionDigest: PushNote.digest(of: "Which branch should I deploy?"))
        #expect(work == nil && conversation.pendingInterrupt == nil, "the card was answered")
        #expect(replies.given.count == 1)
    }

    @Test func approveWithoutASessionOrADigestDoesNothing() {
        let h = Harness()
        let answers = Answers()
        answering(h, answers)
        #expect(h.notifier.route(action: "redde.approve", requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                                 sessionID: "20261007_1") == nil)
        #expect(h.notifier.route(action: "redde.approve", requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                                 approvalDigest: "17f69ae2697b61fd") == nil)
        #expect(answers.asked.isEmpty)
    }

    @Test func aLocalBannerStillSweepsThePushedTwinOfTheSameEvent() async throws {
        let h = Harness()
        h.center.deliveredList = [.init(id: "pushed", isRelayPush: true, date: .now), .init(id: "older", isRelayPush: true, date: .now.addingTimeInterval(-120)),
                                  .init(id: "local", isRelayPush: false, date: .now)]
        h.notifier.notify(.replied, title: "Redde", body: "Done.")
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.center.removedIDs == ["pushed"])
    }
}

/// The system activity for a reply that runs on after the phone locks needs a progress value,
/// and iOS expires a task whose progress stops moving. A reply has no known length.
struct BackgroundTurnTests {
    @Test func progressKeepsMovingAndNeverFinishesOnItsOwn() {
        #expect(BackgroundTurn.progress(after: 0) == 0)
        #expect(BackgroundTurn.progress(after: -5) == 0)
        var last: Int64 = -1
        for second in stride(from: 0.0, through: 3 * 3600, by: 1) {
            let value = BackgroundTurn.progress(after: second)
            #expect(value > last, "progress stalled at \(second) s")
            #expect(value < BackgroundTurn.progressTotal)
            last = value
        }
        #expect(BackgroundTurn.progress(after: 60) == BackgroundTurn.progressTotal / 3)
    }

    @Test func turnIdentifiersFitTheInfoPlistWildcard() {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        #expect(permitted.contains(BackgroundTurn.identifierPrefix + "*"))
        #expect(BackgroundTurn.identifierPrefix.hasPrefix(Bundle.main.bundleIdentifier ?? "?"))
    }
}

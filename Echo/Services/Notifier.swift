import Foundation
import Observation
import UIKit
import UserNotifications
import os

/// Local notifications for things that happen while Redde isn't in front: the agent waiting
/// on you, a reply landing, a turn failing. No push server; these fire only while the app is
/// still running in the background, which `BackgroundTurn` extends for the length of a turn.
/// The slice of UNUserNotificationCenter that Notifier uses — a seam so tests observe
/// requests and categories instead of talking to the system center (which would demand
/// real authorization from the test host).
@MainActor
protocol NotificationCentering: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func add(_ request: UNNotificationRequest, withCompletionHandler: (@Sendable ((any Error)?) -> Void)?)
    func removeAllDeliveredNotifications()
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    /// The banners currently in Notification Center, reduced to what the dedupe sweep needs.
    func delivered() async -> [Notifier.DeliveredBanner]
    func removeDelivered(ids: [String])
}
extension UNUserNotificationCenter: NotificationCentering {
    func delivered() async -> [Notifier.DeliveredBanner] {
        await deliveredNotifications().map {
            // The push relay stamps a top-level "session" key into its payloads; local
            // banners never set one, so its presence marks a remote relay push.
            Notifier.DeliveredBanner(id: $0.request.identifier,
                                     isRelayPush: $0.request.content.userInfo["session"] != nil,
                                     date: $0.date)
        }
    }
    func removeDelivered(ids: [String]) { removeDeliveredNotifications(withIdentifiers: ids) }
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "notify")
    private let center: any NotificationCentering
    private let settings: Settings
    /// Foreground check, injectable: in front, the UI already shows everything.
    private let isAppActive: () -> Bool

    init(center: any NotificationCentering = UNUserNotificationCenter.current(),
         settings: Settings = .shared,
         isAppActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.center = center
        self.settings = settings
        self.isAppActive = isAppActive
    }

    enum Kind: String { case interrupt, replied, failed }

    /// A delivered banner as the relay-duplicate sweep sees it.
    struct DeliveredBanner: Sendable {
        var id: String
        var isRelayPush: Bool
        var date: Date
    }

    /// The conversation that owns the pending approval; set once at launch.
    weak var conversation: Conversation?

    /// Set while Siri waits on a reply it will speak itself (SiriTurn); the reply and failure
    /// banners for that turn would only repeat it.
    var holdsReplies = false

    /// The reply banner's request identifier (one at a time; each reply replaces the last).
    nonisolated static let replyNotificationID = "redde.replied"

    nonisolated private static let approvalCategory = "redde.approval"
    nonisolated private static let approveAction = "redde.approve"
    nonisolated private static let denyAction = "redde.deny"
    nonisolated private static let clarifyTextCategory = "redde.clarify.text"
    nonisolated private static let clarifyChoicePrefix = "redde.clarify.choice."
    nonisolated private static let replyAction = "redde.reply"

    /// Take the delegate and register categories so Approve/Deny work from the banner.
    func install(conversation: Conversation) {
        attach(conversation: conversation)
        registerCategories()
    }

    /// The cheap half of `install`: iOS hands a banner tap that launched the app to whatever
    /// delegate is set when launching finishes, so this must run in the app's init.
    func attach(conversation: Conversation) {
        self.conversation = conversation
        center.delegate = self
    }

    /// The category round trip to the notification daemon; fine to run after the first frame.
    func registerCategories() {
        let approve = UNNotificationAction(identifier: Self.approveAction, title: "Approve", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.approvalCategory, actions: [approve, deny], intentIdentifiers: [])
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        let clarifyText = UNNotificationCategory(identifier: Self.clarifyTextCategory, actions: [reply], intentIdentifiers: [])
        fixedCategories = [category, clarifyText]
        center.setNotificationCategories(fixedCategories)
    }

    private var fixedCategories: Set<UNNotificationCategory> = []
    /// Per-request clarify categories still in play; registered together so none is dropped.
    private var adHocCategories: [String: UNNotificationCategory] = [:]

    /// Clarify banner: a single question gets either its choices as buttons (up to four) or a
    /// text reply field. Batched or multi-select questions just open the app.
    func notifyClarify(_ request: ClarifyRequest) {
        let body = request.questions.first?.question ?? "Open Redde to answer."
        guard request.questions.count == 1, let q = request.questions.first, !q.multiSelect else {
            notify(.interrupt, title: "Redde has \(request.questions.count) questions", body: body)
            return
        }
        let info: [String: String] = ["requestID": request.id, "questionID": q.id]
        if q.choices.isEmpty || q.choices.count > 4 {
            notify(.interrupt, title: "Redde has a question", body: body, category: Self.clarifyTextCategory, userInfo: info)
        } else {
            // Choices are per request, so register a one-off category alongside the fixed ones.
            let id = Self.clarifyChoicePrefix + request.id
            let actions = q.choices.map { UNNotificationAction(identifier: Self.replyAction + "." + $0, title: $0, options: []) }
            let category = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [])
            adHocCategories[id] = category
            center.setNotificationCategories(fixedCategories.union(adHocCategories.values))
            notify(.interrupt, title: "Redde has a question", body: body, category: id, userInfo: info)
        }
    }

    /// Approval banner with Approve (runs once) and Deny buttons.
    func notifyApproval(_ request: ApprovalRequest) {
        let approveChoice = request.choices.contains("once") ? "once" : request.choices.first { $0 != "deny" }
        let denyChoice = request.choices.contains("deny") ? "deny" : nil
        var info: [String: String] = ["requestID": request.id]
        if let approveChoice { info["approve"] = approveChoice }
        if let denyChoice { info["deny"] = denyChoice }
        notify(.interrupt, title: "Redde needs your approval", body: request.description.map { "\($0)\n\(request.command)" } ?? request.command,
               category: approveChoice != nil && denyChoice != nil ? Self.approvalCategory : nil, userInfo: info)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // The userInfo dictionary is not Sendable; extract the strings before hopping actors.
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let requestID = info["requestID"] as? String
        let questionID = info["questionID"] as? String
        let approve = info["approve"] as? String
        let deny = info["deny"] as? String
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            self.route(action: action, requestID: requestID, questionID: questionID,
                       approve: approve, deny: deny, userText: userText)
        }
    }

    /// Testable core of the banner-action callback: maps the action and the notification's
    /// userInfo fields onto the pending interrupt. A plain tap (no requestID) just opens the app.
    func route(action: String, requestID: String?, questionID: String?,
               approve: String?, deny: String?, userText: String?) {
        let choice = action == Self.approveAction ? approve : action == Self.denyAction ? deny : nil
        let answer: String? = if let userText {
            userText
        } else if action.hasPrefix(Self.replyAction + ".") {
            String(action.dropFirst(Self.replyAction.count + 1))
        } else { nil }
        guard let requestID else { return }
        if let choice {
            answerApproval(requestID: requestID, choice: choice)
        } else if let answer, let questionID {
            answerClarify(requestID: requestID, questionID: questionID, answer: answer)
        }
    }

    private func answerClarify(requestID: String, questionID: String, answer: String) {
        guard let conversation,
              let pending = conversation.pendingInterrupt,
              case let .clarify(request) = pending.interrupt, request.id == requestID else {
            log.notice("clarify \(requestID) no longer pending; ignoring reply")
            return
        }
        BackgroundTurn.shared.begin()
        conversation.respond(clarify: [questionID: answer])
    }

    private func answerApproval(requestID: String, choice: String) {
        guard let conversation,
              let pending = conversation.pendingInterrupt,
              case let .approval(request) = pending.interrupt, request.id == requestID else {
            log.notice("approval \(requestID) no longer pending; ignoring \(choice)")
            return
        }
        BackgroundTurn.shared.begin()   // give the answer and the rest of the turn time to stream
        conversation.respond(approval: choice)
    }

    var isEnabled: Bool { settings.notifyInBackground }

    /// Asks once; returns whether alerts are allowed.
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted { registerForPush() }
            return granted
        } catch {
            log.error("notification authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Remote pushes (companion/push-relay)

    /// Ask iOS for a device token when the relay is configured; the token lands in
    /// `PushDelegate` and is uploaded from there. Safe to call every launch — iOS
    /// coalesces, and the relay refreshes the token's expiry on re-registration.
    func registerForPush() {
        guard settings.notifyInBackground, !settings.pushRelayURL.isEmpty,
              Keychain.read(.pushRegisterSecret) != nil else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Sends the device token to the relay, which fans hermes webhook events out to APNs.
    nonisolated static func uploadDeviceToken(_ token: Data) async {
        let settings = await MainActor.run { Settings.shared.pushRelayURL }
        guard let base = URL(string: settings), let secret = Keychain.read(.pushRegisterSecret) else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let env = "dev"
        #else
        let env = "prod"
        #endif
        var request = URLRequest(url: base.appending(path: "register"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": hex, "env": env])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Posts only when the app isn't the active scene; in front, the UI already shows it.
    /// `messageEntityID` (a reply's `SiriID`) tags the banner for Siri and marks the reply unread.
    /// `body` is an autoclosure: the reply's Markdown strip is only paid when a banner will post.
    func notify(_ kind: Kind, title: String, body: @autoclosure () -> String, category: String? = nil,
                userInfo: [String: String] = [:], messageEntityID: String? = nil) {
        guard isEnabled, !isAppActive() else { return }
        if holdsReplies, kind == .replied || kind == .failed { return }
        let body = body()
        guard !body.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(200))
        content.sound = .default
        // Time-sensitive when asked for: that's what lets Siri announce it on AirPods.
        content.interruptionLevel = settings.announceOnAirPods ? .timeSensitive : .active
        content.threadIdentifier = "redde.turn"
        if let category { content.categoryIdentifier = category }
        content.userInfo = userInfo
        if let messageEntityID { SiriHooks.annotateReply(content, messageEntityID: messageEntityID) }
        // Distinct per request so two approvals in one turn both show; replies/failures replace their kind.
        let suffix = userInfo["requestID"].map { ".\($0)" } ?? ""
        let request = UNNotificationRequest(identifier: "redde.\(kind.rawValue)\(suffix)", content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error { Task { @MainActor in self?.log.error("notify failed: \(error.localizedDescription)") } }
        }
        sweepRelayDuplicates(around: .now)
    }

    private var sweepTask: Task<Void, Never>?

    /// A local banner only posts while the app is still alive in the background — exactly the
    /// case where the push relay ALSO delivers the same event as a remote banner moments later
    /// (or moments earlier, when the webhook outruns the stream). Keep the local banner (it has
    /// the reply text and the action buttons) and remove relay pushes from the same window, in
    /// a few passes because APNs delivery lags the webhook by a couple of seconds.
    private func sweepRelayDuplicates(around posted: Date) {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            for delay in [0.0, 2.0, 8.0] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let self, !Task.isCancelled else { return }
                let stale = await self.center.delivered()
                    .filter { $0.isRelayPush && $0.date >= posted.addingTimeInterval(-30) }
                    .map(\.id)
                if !stale.isEmpty, !Task.isCancelled { self.center.removeDelivered(ids: stale) }
            }
        }
    }

    /// Clear anything still showing once the user is back in the app. Only ours: delivered
    /// banners, plus the one-off clarify categories that are no longer needed.
    func clearDelivered() {
        center.removeAllDeliveredNotifications()
        if !adHocCategories.isEmpty {
            adHocCategories.removeAll()
            center.setNotificationCategories(fixedCategories)
        }
    }
}

/// Keeps the process alive after backgrounding while a turn is streaming, so the reply can
/// finish and a notification can be posted. iOS grants a bounded window (typically ~30 s).
@MainActor
final class BackgroundTurn {
    static let shared = BackgroundTurn()
    private var task: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "redde.turn") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

/// Catches the APNs registration callbacks; everything else stays SwiftUI.
final class PushDelegate: NSObject, UIApplicationDelegate {
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "notify")

    nonisolated func application(_ application: UIApplication,
                                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task.detached { await Notifier.uploadDeviceToken(deviceToken) }
    }

    nonisolated func application(_ application: UIApplication,
                                 didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("push registration failed: \(error.localizedDescription)")
    }
}

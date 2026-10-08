import Foundation
import Observation
import UIKit
import UserNotifications
import os

/// Local notifications for things that happen while Redde isn't in front: the agent waiting
/// on you, a reply landing, a turn failing. These fire only while the app is still running in
/// the background, which `BackgroundTurn` extends for the length of a turn. After that a paired
/// Hermes sends them itself (`PushService`); taps and replies on those are routed here too.
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
            // A notification that came through a push relay carries a top-level "session" key
            // (the notification extension writes it, as the household relay does); local banners
            // never set one, so its presence marks a remote push.
            Notifier.DeliveredBanner(id: $0.request.identifier,
                                     isRelayPush: $0.request.content.userInfo[PushNote.sessionKey] != nil,
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
    /// A finished reply's banner: it can be answered where it is.
    nonisolated static let repliedCategory = "redde.replied"
    nonisolated private static let followUpAction = "redde.followup"
    /// userInfo key on a reply banner: the conversation it came from.
    nonisolated static let conversationKey = "conversation"

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
        // A finished reply takes the next message from its banner. With the app's own lock on,
        // only once the device is unlocked: the lock shouldn't have a letterbox.
        let followUp = UNTextInputNotificationAction(identifier: Self.followUpAction, title: "Reply",
                                                     options: settings.requireBiometrics ? [.authenticationRequired] : [],
                                                     textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let replied = UNNotificationCategory(identifier: Self.repliedCategory, actions: [followUp], intentIdentifiers: [])
        // The same for a reply that came as a push, always behind an unlock: the app is started
        // for it, and can't read its saved passwords while the phone is locked.
        let pushedFollowUp = UNTextInputNotificationAction(identifier: Self.followUpAction, title: "Reply", options: [.authenticationRequired],
                                                           textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let pushed = UNNotificationCategory(identifier: PushNote.repliedCategory, actions: [pushedFollowUp], intentIdentifiers: [])
        // An approval a paired Hermes announced. Deny waits for an unlock too: either answer may
        // have to sign in to the Dashboard first.
        let pushedApprove = UNNotificationAction(identifier: Self.approveAction, title: "Approve", options: [.authenticationRequired])
        let pushedDeny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive, .authenticationRequired])
        let pushedApproval = UNNotificationCategory(identifier: PushNote.approvalCategory, actions: [pushedApprove, pushedDeny], intentIdentifiers: [])
        fixedCategories = [category, clarifyText, replied, pushed, pushedApproval]
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
        let conversationID = info[Self.conversationKey] as? String
        let sessionID = info[PushNote.sessionKey] as? String
        let digest = info[PushNote.approvalKey] as? String
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        let work = await MainActor.run {
            self.route(action: action, requestID: requestID, questionID: questionID, approve: approve, deny: deny,
                       userText: userText, conversationID: conversationID, sessionID: sessionID, approvalDigest: digest)
        }
        // The app may have been started just for this: iOS keeps it running until this returns.
        await work?.value
    }

    /// A notification arriving while Redde is in front. The app's own are only posted from the
    /// background, so this is one a paired Hermes sent: shown unless it is about the conversation
    /// on screen, which already shows it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        let kind = info[PushNote.kindKey] as? String
        let sessionID = info[PushNote.sessionKey] as? String
        let sealed = info[PushNote.sealedKey] as? String
        return await MainActor.run {
            if kind == nil, let sealed { return self.presentUnopened(sealed) }
            return self.presentation(pushKind: kind, sessionID: sessionID)
        }
    }

    /// A note from a paired Hermes that reached the app still sealed: the notification extension
    /// didn't open it (it couldn't read the key, or this is a simulator, where a simulated push
    /// skips extensions). In front, the app can: it opens the note and shows a banner of its own
    /// in place of the one that says nothing. One it can't open either is shown as it came.
    func presentUnopened(_ sealed: String, vault: () -> [PushPairing] = { PushVault.load() },
                         confirm: (PushPairing, String?) -> Void = { PushVault.confirm($0, host: $1) }) -> UNNotificationPresentationOptions {
        guard let (note, pairing) = PushSeal.note(from: sealed, pairings: vault()) else { return shown }
        confirm(pairing, note.n)
        let content = UNMutableNotificationContent()
        content.sound = sound
        guard note.fill(content) else { return shown }
        guard !presentation(pushKind: note.k, sessionID: note.s).isEmpty else { return [] }
        center.add(UNNotificationRequest(identifier: "redde.push.\(UUID().uuidString)", content: content, trigger: nil)) { [weak self] error in
            if let error { Task { @MainActor in self?.log.error("notify failed: \(error.localizedDescription)") } }
        }
        return []
    }

    func presentation(pushKind kind: String?, sessionID: String?) -> UNNotificationPresentationOptions {
        guard let kind else { return [] }
        PushService.shared.reload()   // the first note from a pairing confirms it
        if let sessionID, sessionID == conversation?.serverSessionID, PushNote.Kind(rawValue: kind) != .paired { return [] }
        return shown
    }

    /// A notification's sound, or none: Settings › Voice › Notification sound.
    private var sound: UNNotificationSound? { settings.notificationSound ? .default : nil }
    /// How a notification that arrives while Redde is in front is shown.
    private var shown: UNNotificationPresentationOptions { settings.notificationSound ? [.banner, .list, .sound] : [.banner, .list] }

    /// Testable core of the banner-action callback: maps the action and the notification's
    /// userInfo fields onto the pending interrupt. A plain tap (no requestID) just opens the app.
    /// Returns the work an answer started, when it goes on after this returns.
    @discardableResult
    func route(action: String, requestID: String?, questionID: String?,
               approve: String?, deny: String?, userText: String?, conversationID: String? = nil, sessionID: String? = nil,
               approvalDigest: String? = nil) -> Task<Void, Never>? {
        if action == Self.followUpAction {
            guard let userText else { return nil }
            if let sessionID { followUp(userText, sessionID: sessionID) } else { followUp(userText, conversationID: conversationID) }
            return nil
        }
        // A tap on a notification a paired Hermes sent: open the conversation it is about.
        if action == UNNotificationDefaultActionIdentifier, let sessionID {
            LaunchRouter.shared.requestSession(sessionID)
            return nil
        }
        // Approve or Deny on an approval a paired Hermes announced.
        if let sessionID, let approvalDigest, action == Self.approveAction || action == Self.denyAction {
            return answerPushedApproval(sessionID: sessionID, digest: approvalDigest, approve: action == Self.approveAction)
        }
        let choice = action == Self.approveAction ? approve : action == Self.denyAction ? deny : nil
        let answer: String? = if let userText {
            userText
        } else if action.hasPrefix(Self.replyAction + ".") {
            String(action.dropFirst(Self.replyAction.count + 1))
        } else { nil }
        guard let requestID else { return nil }
        if let choice {
            answerApproval(requestID: requestID, choice: choice)
        } else if let answer, let questionID {
            answerClarify(requestID: requestID, questionID: questionID, answer: answer)
        }
        return nil
    }

    /// How an approval is answered when there is no card for it: by the Dashboard, for a session
    /// and a command. Tests put a stand-in here.
    var answerWaiting: (_ session: String, _ digest: String, _ approve: Bool) async throws -> HermesServeClient.WaitingApproval = {
        try await HermesServeClient.shared.answerWaitingApproval(stored: $0, digest: $1, approve: $2)
    }

    /// Approve or Deny on a notification a paired Hermes sent. If the app is still following that
    /// turn, its card is answered. Otherwise the app was closed since (it may have been started
    /// for this): it signs in to the Dashboard and answers the approval that session is waiting
    /// on, provided it is still for the command the notification showed. An answer that couldn't
    /// be given says so in a notification of its own; silence would read as done.
    @discardableResult
    func answerPushedApproval(sessionID: String, digest: String, approve: Bool) -> Task<Void, Never>? {
        if let conversation, conversation.serverSessionID == sessionID, let pending = conversation.pendingInterrupt,
           case let .approval(request) = pending.interrupt, PushNote.digest(of: request.command) == digest,
           let choice = approve ? request.yesNo?.approve : request.yesNo?.deny {
            BackgroundTurn.shared.begin()
            conversation.respond(approval: choice)
            return nil
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "pushed-approval")
        return Task {
            defer { UIApplication.shared.endBackgroundTask(background) }
            let problem: String?
            do {
                problem = switch try await answerWaiting(sessionID, digest, approve) {
                case .answered: nil
                case .nothingWaiting: "That approval is no longer waiting. It was answered somewhere else, or it timed out."
                case .anotherCommand: "Another command is waiting for approval now. Open Redde to see it."
                }
            } catch {
                problem = "Redde couldn't reach your Hermes to \(approve ? "approve" : "deny") the command. Open Redde to answer. (\(error.localizedDescription))"
            }
            guard let problem else { return }
            log.notice("pushed approval not answered: \(problem, privacy: .public)")
            let content = UNMutableNotificationContent()
            content.title = "The approval wasn't answered"
            content.body = problem
            content.sound = sound
            // Opens the conversation when tapped, like the notification it follows.
            content.userInfo = [PushNote.sessionKey: sessionID, PushNote.kindKey: PushNote.Kind.approval.rawValue]
            center.add(UNNotificationRequest(identifier: "redde.unanswered.\(sessionID)", content: content, trigger: nil), withCompletionHandler: nil)
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

    /// A message typed on a finished reply's banner: the next one in that conversation. The
    /// banner is cleared whenever the app comes forward, so the conversation it names is nearly
    /// always the one still open; if another has been opened since (Siri can), the banner's is
    /// brought back first, unless that would cut off a reply in progress.
    private func followUp(_ text: String, conversationID: String?) {
        guard let conversation else { return }
        if let id = conversationID.flatMap(UUID.init(uuidString:)), id != conversation.id {
            guard !conversation.isStreaming, let record = conversation.storeForContext.record(id: id) else {
                log.notice("reply typed on a banner whose conversation can't be reopened; not sent")
                return
            }
            conversation.load(record)
        }
        conversation.send(text)
    }

    /// A message typed on a pushed reply's banner. The app may have been started for this, with
    /// nothing open: the conversation is fetched from the server first.
    private func followUp(_ text: String, sessionID: String) {
        guard let conversation else { return }
        BackgroundTurn.shared.begin()
        Task {
            do {
                if conversation.serverSessionID != sessionID {
                    guard !conversation.isStreaming else {
                        log.notice("reply typed on a pushed banner while another reply streams; not sent")
                        return
                    }
                    try await conversation.open(serverSession: sessionID)
                }
                conversation.send(text)
            } catch {
                log.error("reply typed on a pushed banner couldn't open its conversation: \(error.localizedDescription)")
            }
        }
    }

    /// Answers the approval that is waiting, if it is still that one: from the banner's buttons
    /// and from the Live Activity's (`ApprovalAnswer`).
    func answerApproval(requestID: String, choice: String) {
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
        content.sound = sound
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

/// Catches the APNs registration callbacks; everything else stays SwiftUI.
final class PushDelegate: NSObject, UIApplicationDelegate {
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "notify")

    nonisolated func application(_ application: UIApplication,
                                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task.detached { await Notifier.uploadDeviceToken(deviceToken) }
        Task { @MainActor in PushService.shared.received(token: deviceToken) }
    }

    nonisolated func application(_ application: UIApplication,
                                 didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("push registration failed: \(error.localizedDescription)")
        let reason = error.localizedDescription
        Task { @MainActor in PushService.shared.failedToRegister(PushError.noToken(reason)) }
    }
}

import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
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
            let info = $0.request.content.userInfo
            return Notifier.DeliveredBanner(id: $0.request.identifier,
                                            isRelayPush: info[PushNote.sessionKey] != nil,
                                            date: $0.date,
                                            session: info[PushNote.sessionKey] as? String,
                                            conversation: info[Notifier.conversationKey] as? String,
                                            room: info[PushNote.roomKey] as? String,
                                            category: $0.request.content.categoryIdentifier,
                                            note: info[PushNote.noteKey] as? String,
                                            server: info[PushNote.serverKey] as? String)
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

    /// Where notes gone here are told, for the person's other devices (`NoteClears`).
    private let clears: NoteClears

    init(center: any NotificationCentering = UNUserNotificationCenter.current(),
         settings: Settings = .shared,
         clears: NoteClears? = nil,
         isAppActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.center = center
        self.settings = settings
        self.clears = clears ?? .shared
        self.isAppActive = isAppActive
    }

    enum Kind: String, CaseIterable { case interrupt, replied, failed }

    /// A delivered banner as the relay-duplicate sweep and the clearing on return see it: which
    /// chat it is about (a Hermes session, the app's own conversation, a group chat).
    struct DeliveredBanner: Sendable {
        var id: String
        var isRelayPush: Bool
        var date: Date
        var session: String?
        var conversation: String?
        var room: String?
        var category: String = ""
        /// The pushed note's own id (`PushNote.m`), and the server it came from.
        var note: String?
        var server: String?

        /// One of the app's own banners for a turn (`notify`): a reply, a failure, an approval or
        /// a question. Without a conversation they are the open one's (`Notifier.conversation`).
        var isTurnBanner: Bool {
            !isRelayPush && Kind.allCases.contains { id.hasPrefix("redde.\($0.rawValue)") }
        }
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
    nonisolated private static let replyAction = PushNote.replyAction
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
        let approve = UNNotificationAction(identifier: Self.approveAction, title: String(localized: "Approve", comment: "Notification button: approves the command once"), options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: String(localized: "Deny", comment: "Notification button: turns the command down"), options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.approvalCategory, actions: [approve, deny], intentIdentifiers: [])
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: String(localized: "Reply", comment: "Notification button: answers by typing"), options: [], textInputButtonTitle: String(localized: "Send", comment: "Notification text field's button"), textInputPlaceholder: String(localized: "Your answer"))
        let clarifyText = UNNotificationCategory(identifier: Self.clarifyTextCategory, actions: [reply], intentIdentifiers: [])
        // A finished reply takes the next message from its banner. With the app's own lock on,
        // only once the device is unlocked: the lock shouldn't have a letterbox.
        let followUp = UNTextInputNotificationAction(identifier: Self.followUpAction, title: String(localized: "Reply", comment: "Notification button: answers by typing"),
                                                     options: settings.requireBiometrics ? [.authenticationRequired] : [],
                                                     textInputButtonTitle: String(localized: "Send", comment: "Notification text field's button"), textInputPlaceholder: String(localized: "Message", comment: "Placeholder of a notification's reply field"))
        let replied = UNNotificationCategory(identifier: Self.repliedCategory, actions: [followUp], intentIdentifiers: [])
        // The same for a reply that came as a push, always behind an unlock: the app is started
        // for it, and can't read its saved passwords while the phone is locked.
        let pushedFollowUp = UNTextInputNotificationAction(identifier: Self.followUpAction, title: String(localized: "Reply", comment: "Notification button: answers by typing"), options: [.authenticationRequired],
                                                           textInputButtonTitle: String(localized: "Send", comment: "Notification text field's button"), textInputPlaceholder: String(localized: "Message", comment: "Placeholder of a notification's reply field"))
        // Every category a pushed note may have tells the app when it is swiped away, so it is
        // cleared on the person's other devices too (`NoteClears`); a note with no buttons gets
        // one of its own for that (`PushNote.noteCategory`).
        let swiped: UNNotificationCategoryOptions = [.customDismissAction]
        let pushedNote = UNNotificationCategory(identifier: PushNote.noteCategory, actions: [], intentIdentifiers: [], options: swiped)
        let pushed = UNNotificationCategory(identifier: PushNote.repliedCategory, actions: [pushedFollowUp], intentIdentifiers: [], options: swiped)
        // An approval a paired Hermes announced. Deny waits for an unlock too: either answer may
        // have to sign in to the Dashboard first.
        let pushedApprove = UNNotificationAction(identifier: Self.approveAction, title: String(localized: "Approve", comment: "Notification button: approves the command once"), options: [.authenticationRequired])
        let pushedDeny = UNNotificationAction(identifier: Self.denyAction, title: String(localized: "Deny", comment: "Notification button: turns the command down"), options: [.destructive, .authenticationRequired])
        let pushedApproval = UNNotificationCategory(identifier: PushNote.approvalCategory, actions: [pushedApprove, pushedDeny], intentIdentifiers: [], options: swiped)
        // A question a paired Hermes announced, answered in words. One with choices arrives
        // under a category of its own that the notification extension registers on the spot
        // (`PushNote.choiceCategory`); this one is what it falls back on.
        let pushedQuestion = UNNotificationCategory(identifier: PushNote.questionCategory, actions: [PushNote.replyField], intentIdentifiers: [], options: swiped)
        // A group chat's, from a paired Hermes: Reply to the room, a bot's command, a turn to retry.
        let groupReplied = UNNotificationCategory(identifier: PushNote.groupRepliedCategory, actions: [pushedFollowUp], intentIdentifiers: [], options: swiped)
        let groupApproval = UNNotificationCategory(identifier: PushNote.groupApprovalCategory, actions: [pushedApprove, pushedDeny], intentIdentifiers: [], options: swiped)
        let retry = UNNotificationAction(identifier: PushNote.retryAction, title: String(localized: "Retry", comment: "Notification button: asks the agent for the reply again"), options: [.authenticationRequired])
        let groupRetry = UNNotificationCategory(identifier: PushNote.groupRetryCategory, actions: [retry], intentIdentifiers: [], options: swiped)
        // A Leave-By Alert: the way there in Apple Maps (`LeaveBy`).
        let maps = UNNotificationAction(identifier: LeaveBy.mapsAction, title: String(localized: "Open in Maps"), options: [.foreground])
        let leave = UNNotificationCategory(identifier: LeaveBy.mapsCategory, actions: [maps], intentIdentifiers: [], options: swiped)
        fixedCategories = [category, clarifyText, replied, pushed, pushedApproval, pushedQuestion, groupReplied, groupApproval, groupRetry, leave, pushedNote]
        center.setNotificationCategories(fixedCategories)
    }

    private var fixedCategories: Set<UNNotificationCategory> = []
    /// Per-request clarify categories still in play; registered together so none is dropped.
    private var adHocCategories: [String: UNNotificationCategory] = [:]

    /// Clarify banner: a single question gets either its choices as buttons (up to four) or a
    /// text reply field. Batched or multi-select questions just open the app.
    func notifyClarify(_ request: ClarifyRequest) {
        let body = request.questions.first?.question ?? String(localized: "Open Redde to answer.")
        guard request.questions.count == 1, let q = request.questions.first, !q.multiSelect else {
            notify(.interrupt, title: String(localized: "Redde has \(request.questions.count) questions"), body: body)
            return
        }
        let info: [String: String] = ["requestID": request.id, "questionID": q.id]
        if q.choices.isEmpty || q.choices.count > 4 {
            notify(.interrupt, title: String(localized: "Redde has a question"), body: body, category: Self.clarifyTextCategory, userInfo: info)
        } else {
            // Choices are per request, so register a one-off category alongside the fixed ones.
            let id = Self.clarifyChoicePrefix + request.id
            let actions = q.choices.map { UNNotificationAction(identifier: Self.replyAction + "." + $0, title: $0, options: []) }
            let category = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [])
            adHocCategories[id] = category
            center.setNotificationCategories(fixedCategories.union(adHocCategories.values))
            notify(.interrupt, title: String(localized: "Redde has a question"), body: body, category: id, userInfo: info)
        }
    }

    /// Approval banner with Approve (runs once) and Deny buttons.
    func notifyApproval(_ request: ApprovalRequest) {
        let approveChoice = request.choices.contains("once") ? "once" : request.choices.first { $0 != "deny" }
        let denyChoice = request.choices.contains("deny") ? "deny" : nil
        var info: [String: String] = ["requestID": request.id]
        if let approveChoice { info["approve"] = approveChoice }
        if let denyChoice { info["deny"] = denyChoice }
        notify(.interrupt, title: String(localized: "Redde needs your approval"), body: request.description.map { "\($0)\n\(request.command)" } ?? request.command,
               category: approveChoice != nil && denyChoice != nil ? Self.approvalCategory : nil, userInfo: info)
    }

    // MARK: UNUserNotificationCenterDelegate

    // Both methods are the ones that take iOS's completion handler, not their `async` twins. An
    // `async` delegate method is wrapped in a task that calls the handler from whatever thread
    // the task ends on, and the handler for a tap saves the app's snapshot, which iOS allows on
    // the main thread only: 1.7 was closed by it whenever a notification was tapped. Here each
    // handler is called on the main actor.

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        // The userInfo dictionary is not Sendable; extract the strings before hopping actors.
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let requestID = info["requestID"] as? String
        let questionID = info["questionID"] as? String
        let approve = info["approve"] as? String
        let deny = info["deny"] as? String
        let conversationID = info[Self.conversationKey] as? String
        let sessionID = info[PushNote.sessionKey] as? String
        let server = info[PushNote.serverKey] as? String
        let digest = info[PushNote.approvalKey] as? String
        let asked = info[PushNote.questionKey] as? String
        let room = info[PushNote.roomKey] as? String
        let task = info[PushNote.taskKey] as? String
        let bot = info[PushNote.botKey] as? String
        let keyRequest = info[PushNote.keyRequestKey] as? String
        let kind = info[PushNote.kindKey] as? String
        let briefing = info[PushNote.briefingKey] as? String
        let runSession = info[PushNote.runSessionKey] as? String
        let profile = info[PushNote.profileKey] as? String
        let title = info[PushNote.titleKey] as? String
        let viaAPI = info[PushNote.viaAPIKey] as? Bool
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        let leaveTitle = info[LeaveTime.eventTitleKey] as? String
        let leaveAt = (info[LeaveBy.latitudeKey] as? Double).flatMap { lat in (info[LeaveBy.longitudeKey] as? Double).map { (lat, $0) } }
        let leaveMode = info[LeaveBy.modeKey] as? String
        let noteID = info[PushNote.noteKey] as? String
        let goal = info[PushNote.goalKey] as? String
        nonisolated(unsafe) let handled = completionHandler   // iOS's own; only ever called below
        Task { @MainActor in
            // Tapped, answered or swiped away here: gone on the person's other devices too.
            if let noteID { self.clears.cleared([noteID], server: server) }
            // Swiped away is all a swipe says: nothing to open or answer.
            if action == UNNotificationDismissActionIdentifier {
                await self.clears.flushSoon()
                handled()
                return
            }
            // The server a pushed chat is on, for its tap to open it there (said for every tap
            // about a session, so one from before doesn't linger).
            if sessionID != nil { LaunchRouter.shared.requestServer(server) }
            // A Leave-By Alert's Open in Maps: the way there.
            if action == LeaveBy.mapsAction, let leaveAt {
                LeaveByAlerts.openInMaps(title: leaveTitle, latitude: leaveAt.0, longitude: leaveAt.1, mode: leaveMode)
                handled()
                return
            }
            // A workstream's: its own chat, in its agent's profile (an approval is answered there).
            if kind == PushNote.Kind.work.rawValue, action == UNNotificationDefaultActionIdentifier, let sessionID {
                LaunchRouter.shared.requestSession(sessionID, profile: profile, title: title, viaAPI: viaAPI ?? false)
                handled()
                return
            }
            // A goal's check-in: the goal, where its steps are ticked off (2026-11-22; it had opened
            // the bot's chat, or nothing, and the steps it asked about were out of reach).
            if let goal, kind == PushNote.Kind.routine.rawValue, action == UNNotificationDefaultActionIdentifier {
                GoalsInbox.shared.reload()
                GoalsInbox.shared.opening = goal
                handled()
                return
            }
            // A mail note (a rule he made said "tell me"): the Inbox.
            if kind == PushNote.Kind.mail.rawValue, action == UNNotificationDefaultActionIdentifier {
                MailCenter.shared.showingInbox = true
                handled()
                return
            }
            let work = self.route(action: action, requestID: requestID, questionID: questionID, approve: approve, deny: deny,
                                  userText: userText, conversationID: conversationID, sessionID: sessionID, approvalDigest: digest,
                                  questionDigest: asked, room: room, task: task, bot: bot, keyRequest: keyRequest,
                                  kind: kind, briefing: briefing, runSession: runSession)
            // The app may have been started just for this: iOS keeps it running until it is told.
            await work?.value
            handled()
        }
    }

    /// A notification arriving while Redde is in front. The app's own are only posted from the
    /// background, so this is one a paired Hermes sent: shown unless it is about the conversation
    /// on screen, which already shows it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        let kind = info[PushNote.kindKey] as? String
        let sessionID = info[PushNote.sessionKey] as? String
        let room = info[PushNote.roomKey] as? String
        let bot = info[PushNote.botKey] as? String
        let profile = info[PushNote.profileKey] as? String
        let sealed = info[PushNote.sealedKey] as? String
        let leaving = notification.request.identifier.hasPrefix(LeaveTime.reminderPrefix)
        let urgent = notification.request.content.interruptionLevel == .timeSensitive
        // Put in the list only by the extension (a summary's kind, quiet hours, a muted chat), or
        // without a sound (Banner Only): the same over Redde (`NoteLevels`).
        let passive = notification.request.content.interruptionLevel == .passive
        let silent = notification.request.content.sound == nil
        // iOS's own; called once on every branch below, on the main actor.
        nonisolated(unsafe) let show = completionHandler
        Task { @MainActor in
            // Time to leave: said over Redde too (the app's own, set for then, `LeaveTime`).
            if leaving { return show(self.shown) }
            // A Leave-By Alert's traffic re-check (`LeaveCheck`): taken in now; over Redde only
            // when the traffic moved the leaving time earlier.
            if kind == PushNote.Kind.leave.rawValue {
                LeaveByAlerts.shared.trafficCheckArrived()
                return show(urgent ? self.shown : [.list])
            }
            // A heads-up came: its leaving reminder and a Leave-By Alert for the same event become one.
            if kind == PushNote.Kind.routine.rawValue { LeaveByAlerts.shared.headsUpArrived() }
            if kind == PushNote.Kind.work.rawValue, let profile { Workstreams.shared.heard(profile: profile) }
            if kind == nil, let sealed {
                show(self.presentUnopened(sealed))
            } else {
                show(self.presentation(pushKind: kind, sessionID: sessionID, room: room, bot: bot, passive: passive, silent: silent))
            }
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
        // A traffic re-check the extension didn't make: the app, in front, checks itself.
        if note.kind == .leave {
            LeaveByAlerts.shared.trafficCheckArrived()
            return []
        }
        StatusWidgets.heard(note)   // as the extension does, for the "Needs you" widget
        AgentIdea.take(note)
        WatchReport.take(note)
        if GoalReport.take(note) { GoalsInbox.shared.reload() }
        if AgentBriefing.take(note) { BriefingsInbox.shared.reload() }
        AgentActivityNote.take(note)
        Workstreams.shared.heard(note)
        let content = UNMutableNotificationContent()
        content.sound = sound
        guard note.fill(content) else { return shown }
        // As the extension would have it (`NoteLevels`): in the list only, or without a sound.
        let level = NoteLevels(text: settings.noteLevels).level(of: note)
        let waits = QuietHours.waits(note) && NoteGroup.of(note) != .needsYou && QuietHours.load().covers(.now)
        if level == .summary || waits { MutedChats.quiet(content) } else if level == .silent { content.sound = nil }
        guard !presentation(pushKind: note.k, sessionID: note.s, room: note.g, bot: note.p, passive: level == .summary || waits,
                            silent: level == .silent).isEmpty else { return [] }
        center.add(UNNotificationRequest(identifier: "redde.push.\(UUID().uuidString)", content: content, trigger: nil)) { [weak self] error in
            if let error { Task { @MainActor in self?.log.error("notify failed: \(error.localizedDescription)") } }
        }
        return []
    }

    /// `passive`: the extension put it in the list only (a summary's kind, quiet hours, a muted
    /// chat); `silent`: Banner Only. Each is shown so over Redde too.
    func presentation(pushKind kind: String?, sessionID: String?, room: String? = nil, bot: String? = nil,
                      passive: Bool = false, silent: Bool = false) -> UNNotificationPresentationOptions {
        guard let kind else { return [] }
        PushService.shared.reload()   // the first note from a pairing confirms it
        // A task's: the chat on screen asks for the report the plugin may have kept (`TaskReports`).
        if PushNote.Kind(rawValue: kind) == .task { TaskReports.shared.nudge() }
        if let sessionID, sessionID == conversation?.serverSessionID, PushNote.Kind(rawValue: kind) != .paired {
            // On screen already, unless it was written on another device: the chat looks.
            if let open = conversation { Task { await open.checkOtherDevices() } }
            return []
        }
        // The group chat on screen shows it already.
        if let room, room == GroupDirectory.shared.open?.id { return [] }
        // A chat the person muted: in the list, not over the screen.
        if MutedChats.isMuted(session: sessionID, room: room, bot: bot) { return [.list] }
        if PushNote.Kind(rawValue: kind) == .widget { return [] }   // it is on the widget; nothing to say with Redde in front
        // Ideas: on the chat list now (the extension kept them), and said in a banner.
        if PushNote.Kind(rawValue: kind) == .ideas { IdeasInbox.shared.reload() }
        // A key asked for: the list in Settings is fetched afresh (the banner opens its card).
        if PushNote.Kind(rawValue: kind) == .key { Task { await KeyRequests.shared.reload() } }
        if PushNote.Kind(rawValue: kind) == .routine { BriefingsInbox.shared.reload(); GoalsInbox.shared.reload() }
        // Quiet hours, a summary's kind: to the list, not over the screen (the extension decided).
        if passive { return [.list] }
        return silent ? [.banner, .list] : shown
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
               approvalDigest: String? = nil, questionDigest: String? = nil, room: String? = nil, task: String? = nil,
               bot: String? = nil, keyRequest: String? = nil, kind: String? = nil, briefing: String? = nil,
               runSession: String? = nil) -> Task<Void, Never>? {
        // A bot asks for a key: its card, to paste it into (`KeyRequests`).
        if let keyRequest, !keyRequest.isEmpty, action == UNNotificationDefaultActionIdentifier {
            KeyRequests.shared.show(id: keyRequest)
            return nil
        }
        // A briefing (a `[redde-notify]` job's answer): opened whole, over the chat list; or, as the
        // person chose, the main agent's run's session, to ask on in it (GitHub issue 62).
        if task == "brief", room == nil, action == UNNotificationDefaultActionIdentifier {
            if Settings.shared.briefingTapsOpenRun, bot == nil, let runSession, !runSession.isEmpty {
                if let briefing { AgentBriefing.markRead(briefing) }
                LaunchRouter.shared.requestSession(runSession)
            } else {
                BriefingsInbox.shared.showNewest(id: briefing)
            }
            return nil
        }
        // A watch saw something change: the Watches list, its update beside the watch. It had no
        // place to go before 2.3.3, so a tap opened Redde on whatever was last on screen.
        if PushNote.Kind(rawValue: kind ?? "") == .watch, room == nil, action == UNNotificationDefaultActionIdentifier {
            WatchDraft.shared.showingWatches = true
            return nil
        }
        // A bot's schedule ran: its chat, where its answer is.
        if let bot, action == UNNotificationDefaultActionIdentifier {
            LaunchRouter.shared.requestBot(bot)
            return nil
        }
        // A group chat's, from a paired Hermes: opened, answered or replied to in the room.
        if let room {
            return routeGroupNote(action: action, room: room, digest: approvalDigest, task: task, text: userText)
        }
        if action == Self.followUpAction {
            guard let userText else { return nil }
            if let sessionID { followUp(userText, sessionID: sessionID) } else { followUp(userText, conversationID: conversationID) }
            return nil
        }
        // A tap on a notification a paired Hermes sent: open the conversation it is about.
        if action == UNNotificationDefaultActionIdentifier, let sessionID {
            // A reply's or a finished task's: read from the start of the reply it showed.
            if PushNote.Kind(rawValue: kind ?? "").map({ $0 == .reply || $0 == .task }) == true {
                conversation?.readFromTask = kind == PushNote.Kind.task.rawValue
                conversation?.readFromReply = sessionID
            }
            LaunchRouter.shared.requestSession(sessionID)
            return nil
        }
        // A tap on the app's own reply banner: its conversation, from the start of the reply.
        if action == UNNotificationDefaultActionIdentifier, let conversationID, requestID == nil,
           let conversation, conversation.id.uuidString == conversationID {
            conversation.readFromReply = conversationID
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
        // An answer, typed or picked, on a question a paired Hermes announced.
        if let sessionID, let questionDigest, let answer {
            return answerPushedQuestion(sessionID: sessionID, digest: questionDigest, answer: answer)
        }
        guard let requestID else { return nil }
        if let choice {
            answerApproval(requestID: requestID, choice: choice)
        } else if let answer, let questionID {
            answerClarify(requestID: requestID, questionID: questionID, answer: answer)
        }
        return nil
    }

    /// The group chat's own calls, over the Dashboard, for answering from a notification. Tests
    /// put stand-ins here.
    var groupCalls = GroupCalls()
    struct GroupCalls {
        var state: (_ room: String) async throws -> GroupState = { try await HermesServeClient.shared.groupState($0).state }
        var approve: (_ room: String, _ approval: GroupApproval, _ choice: String) async throws -> Void = {
            try await HermesServeClient.shared.answerGroupApproval($0, $1, choice: $2)
        }
        var retry: (_ room: String, _ retry: GroupRetry) async throws -> Void = { try await HermesServeClient.shared.retryGroupTask($0, $1) }
        var send: (_ room: String, _ text: String) async throws -> Void = {
            try await HermesServeClient.shared.sendToGroup($0, text: $1, eventID: UUID().uuidString)
        }
    }

    /// A group chat's notification from a paired Hermes: a tap opens the room; Reply says the
    /// words there; Approve or Deny answers the command a bot waits on, provided it is still the
    /// one the notification showed (the room is asked what it waits on); Retry runs the turn
    /// again. One that couldn't be given says so, as for a conversation's.
    @discardableResult
    func routeGroupNote(action: String, room: String, digest: String?, task: String?, text: String?) -> Task<Void, Never>? {
        let calls = groupCalls
        switch action {
        case Self.followUpAction:
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return givePushedAnswer("pushed-group-reply", sessionID: "", room: room, kind: .group, notGiven: String(localized: "Your message wasn't sent"),
                                    reaching: String(localized: "send your message", comment: "Completes \"Redde couldn't reach your Hermes to …\"")) {
                try await calls.send(room, text)
                return nil
            }
        case Self.approveAction, Self.denyAction:
            guard let digest else { return nil }
            let approve = action == Self.approveAction
            return givePushedAnswer("pushed-group-approval", sessionID: "", room: room, kind: .groupWait, notGiven: String(localized: "The approval wasn't answered"),
                                    reaching: approve ? String(localized: "approve the command", comment: "Completes \"Redde couldn't reach your Hermes to …\"") : String(localized: "deny the command", comment: "Completes \"Redde couldn't reach your Hermes to …\"")) {
                guard let waiting = try await calls.state(room).approvals.first(where: { PushNote.digest(of: $0.request.command) == digest }) else {
                    return String(localized: "That approval is no longer waiting. It was answered somewhere else, or it timed out.")
                }
                do {
                    try await calls.approve(room, waiting, approve ? "once" : "deny")
                } catch let error as HermesServeClient.RPCError where [5118, 5119].contains(error.code) {
                    return String(localized: "That approval is no longer waiting. It was answered somewhere else, or it timed out.")
                }
                return nil
            }
        case PushNote.retryAction:
            guard let task else { return nil }
            return givePushedAnswer("pushed-group-retry", sessionID: "", room: room, kind: .groupWait, notGiven: String(localized: "The reply wasn't retried"),
                                    reaching: String(localized: "retry the reply", comment: "Completes \"Redde couldn't reach your Hermes to …\"")) {
                // The notification names the task alone: the room says what else goes back with it
                // (`GroupRetry`). Not asked for there any more, it is tried by the task as before.
                let waiting = try? await calls.state(room).retries.first { $0.taskID == task }
                try await calls.retry(room, waiting ?? GroupRetry(taskID: task))
                return nil
            }
        case UNNotificationDefaultActionIdentifier:
            LaunchRouter.shared.requestRoom(room)
            return nil
        default:
            return nil
        }
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
        return givePushedAnswer("pushed-approval", sessionID: sessionID, kind: .approval, notGiven: String(localized: "The approval wasn't answered"),
                                reaching: approve ? String(localized: "approve the command", comment: "Completes \"Redde couldn't reach your Hermes to …\"") : String(localized: "deny the command", comment: "Completes \"Redde couldn't reach your Hermes to …\"")) {
            switch try await self.answerWaiting(sessionID, digest, approve) {
            case .answered:
                StatusWidgets.settled(sessionID)   // the "Needs you" widget lets go of it
                return nil
            case .nothingWaiting:
                StatusWidgets.settled(sessionID)
                return String(localized: "That approval is no longer waiting. It was answered somewhere else, or it timed out.")
            case .anotherCommand: return String(localized: "Another command is waiting for approval now. Open Redde to see it.")
            }
        }
    }

    /// Takes an answer given on a notification to the Dashboard, for a turn the app has no card
    /// for. `give` returns why it couldn't be given, or nil when it was; `reaching` is what the
    /// app was trying to do, for when Hermes can't be reached at all. The app may have been
    /// started just for this, so it asks for the time to finish.
    private func givePushedAnswer(_ name: String, sessionID: String, room: String? = nil, kind: PushNote.Kind, notGiven title: String,
                                  reaching: String, _ give: @escaping () async throws -> String?) -> Task<Void, Never> {
        let background = UIApplication.shared.beginBackgroundTask(withName: name)
        return Task {
            defer { UIApplication.shared.endBackgroundTask(background) }
            let problem: String?
            do {
                problem = try await give()
            } catch {
                problem = String(localized: "Redde couldn't reach your Hermes to \(reaching). Open Redde to answer. (\(error.localizedDescription))")
            }
            guard let problem else { return }
            log.notice("\(name, privacy: .public) not given: \(problem, privacy: .public)")
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = problem
            content.sound = sound
            // Opens the conversation (or the group chat) when tapped, like the notification it follows.
            content.userInfo = room.map { [PushNote.roomKey: $0, PushNote.kindKey: kind.rawValue] }
                ?? [PushNote.sessionKey: sessionID, PushNote.kindKey: kind.rawValue]
            center.add(UNNotificationRequest(identifier: "redde.unanswered.\(room ?? sessionID)", content: content, trigger: nil), withCompletionHandler: nil)
        }
    }

    /// How a question is answered when there is no card for it. Tests put a stand-in here.
    var answerWaitingQuestion: (_ session: String, _ digest: String, _ answer: String) async throws -> HermesServeClient.WaitingQuestion = {
        try await HermesServeClient.shared.answerWaitingQuestion(stored: $0, digest: $1, answer: $2)
    }

    /// An answer given on a question's notification, the way `answerPushedApproval` gives a yes
    /// or a no: to the card if the app still has it, otherwise to the question that session is
    /// waiting on, provided it is still the one the notification asked. An empty answer is none.
    @discardableResult
    func answerPushedQuestion(sessionID: String, digest: String, answer: String) -> Task<Void, Never>? {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return nil }
        if let conversation, conversation.serverSessionID == sessionID, let pending = conversation.pendingInterrupt,
           case let .clarify(request) = pending.interrupt, request.questions.count == 1, let question = request.questions.first,
           PushNote.digest(of: question.question) == digest {
            BackgroundTurn.shared.begin()
            conversation.respond(clarify: [question.id: answer])
            return nil
        }
        return givePushedAnswer("pushed-answer", sessionID: sessionID, kind: .question, notGiven: String(localized: "Your answer wasn't given"),
                                reaching: String(localized: "give your answer", comment: "Completes \"Redde couldn't reach your Hermes to …\"")) {
            switch try await self.answerWaitingQuestion(sessionID, digest, answer) {
            case .answered:
                StatusWidgets.settled(sessionID)
                return nil
            case .nothingWaiting:
                StatusWidgets.settled(sessionID)
                return String(localized: "That question is no longer waiting. It was answered somewhere else, or it timed out.")
            case .anotherQuestion: return String(localized: "Something else is being asked now. Open Redde to see it.")
            }
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
    /// `session`, the chat's on Hermes: the relay's push of the same event is taken away.
    /// `body` is an autoclosure: the reply's Markdown strip is only paid when a banner will post.
    func notify(_ kind: Kind, title: String, body: @autoclosure () -> String, category: String? = nil,
                userInfo: [String: String] = [:], session: String? = nil, messageEntityID: String? = nil) {
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
        // A bot's chat the person muted: quietly, in the list only.
        if let bot = conversation?.bot, Mutes.isMuted(bot: bot.profile, settings: settings) {
            MutedChats.quiet(content)
        } else {
            // As the person has replies (or what needs them) come (`NoteLevels`).
            let levels = NoteLevels(text: settings.noteLevels)
            switch levels.level(kind == .interrupt ? .needsYou : .replies) {
            case .sound: break
            case .silent: content.sound = nil
            case .summary:
                MutedChats.quiet(content)
                content.threadIdentifier = HeldNote.thread
                HeldNote.wait(HeldNote(kind: .reply, title: title, at: .now),
                              until: levels.nextSummary(after: .now, quiet: QuietHours.load()), afterQuiet: false)
            }
        }
        // Distinct per request so two approvals in one turn both show; replies/failures replace their kind.
        let suffix = userInfo["requestID"].map { ".\($0)" } ?? ""
        let request = UNNotificationRequest(identifier: "redde.\(kind.rawValue)\(suffix)", content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error { Task { @MainActor in self?.log.error("notify failed: \(error.localizedDescription)") } }
        }
        // The same event's push, when the relay sends one: of this chat's session only (the open
        // conversation's, for a question or an approval the app asks about itself).
        if let session = session ?? conversation?.serverSessionID { sweepRelayDuplicates(of: session, around: .now) }
    }

    private var sweepTask: Task<Void, Never>?

    /// A local banner only posts while the app is still alive in the background — exactly the
    /// case where the push relay ALSO delivers the same event as a remote banner moments later
    /// (or moments earlier, when the webhook outruns the stream). Keep the local banner (it has
    /// the reply text and the action buttons) and remove relay pushes from the same window, in
    /// a few passes because APNs delivery lags the webhook by a couple of seconds. Only the same
    /// session's: another chat's push in that window is no duplicate (GitHub #63, it went too).
    private func sweepRelayDuplicates(of session: String, around posted: Date) {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            for delay in [0.0, 2.0, 8.0] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let self, !Task.isCancelled else { return }
                let stale = await self.center.delivered()
                    .filter { $0.isRelayPush && $0.session == session && $0.date >= posted.addingTimeInterval(-30) }
                    .map(\.id)
                if !stale.isEmpty, !Task.isCancelled { self.center.removeDelivered(ids: stale) }
            }
        }
    }

    /// Every notification gone, and the one-off question categories with them: Erase Everything.
    func clearDelivered() {
        center.removeAllDeliveredNotifications()
        if !adHocCategories.isEmpty {
            adHocCategories.removeAll()
            center.setNotificationCategories(fixedCategories)
        }
    }

    private var clearTask: Task<Void, Never>?

    /// Back in the app, or a chat opened: the notifications about the chat on screen go, as in
    /// Messages; every other stays in Notification Center until it is tapped or its chat opened.
    /// Opening Redde used to clear them all, so one glanced at and not tapped was lost (GitHub #63).
    /// The one-off question categories go once no notification shows their buttons.
    func clearDelivered(session: String?, conversation: String?, room: String?) {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            guard let self else { return }
            let delivered = await self.center.delivered()
            guard !Task.isCancelled else { return }
            let open = self.conversation?.id.uuidString
            let about = delivered.filter { banner in
                if let room { return banner.room == room }
                if let session, banner.session == session, banner.room == nil { return true }
                guard banner.isTurnBanner else { return false }
                return (banner.conversation ?? open) == conversation
            }
            if !about.isEmpty { self.center.removeDelivered(ids: about.map(\.id)) }
            // Its chat opened here: those notes are seen, on the other devices too.
            for banner in about { if let note = banner.note { self.clears.cleared([note], server: banner.server) } }
            let gone = Set(about.map(\.id))
            let left = Set(delivered.filter { !gone.contains($0.id) }.map(\.category))
            let stale = self.adHocCategories.keys.filter { !left.contains($0) }
            if !stale.isEmpty {
                for id in stale { self.adHocCategories[id] = nil }
                self.center.setNotificationCategories(self.fixedCategories.union(self.adHocCategories.values))
            }
        }
    }
}

/// Notifications in sync on the person's devices (asked 2026-11-17: the iPad still showed an
/// evening wrap-up already cleared on the phone). A pushed note goes to each device on its own,
/// so clearing it on one left the others. Now each carries one id everywhere (`PushNote.m`, from
/// Redde's plugin 1.33), and a note tapped, answered, swiped away or seen in its chat here is told
/// to the plugin (`/redde-push cleared`), which sends the other devices a silent push that takes
/// it out of their Notification Center (`ClearedNotes`). A device that missed that push (Redde
/// force-quit, or offline) asks what was cleared when it comes forward (`cleared since`).
/// Notes from a server that isn't the open one wait here until it is.
@MainActor
final class NoteClears {
    static let shared = NoteClears()

    private let defaults: UserDefaults
    /// Says a plugin command to the open server's plugin, Dashboard or Hermes API.
    private let command: @MainActor (String) async throws -> String
    private let settings: Settings
    /// This device's own ids, as the plugin knows them, so it isn't told of its own clears.
    private let ownIDs: @MainActor () -> [String]
    private var flushing: Task<Void, Never>?

    private static let pendingKey = "noteClears.pending"
    private static let sinceKey = "noteClears.since"
    /// At most so many of a server's waiting clears are kept, and said in one command.
    static let most = 64

    init(defaults: UserDefaults = .standard, settings: Settings = .shared,
         command: (@MainActor (String) async throws -> String)? = nil,
         ownIDs: (@MainActor () -> [String])? = nil) {
        self.defaults = defaults
        self.settings = settings
        self.command = command ?? { arguments in try await PushService.command(over: settings)(arguments) }
        self.ownIDs = ownIDs ?? { PushService.shared.pairings.filter(\.isPaired).map(\.id) }
    }

    /// The servers' clears not yet said, by server (`Settings.activeServerID`).
    var pending: [String: [String]] {
        get { (defaults.dictionary(forKey: Self.pendingKey) as? [String: [String]]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.pendingKey) }
    }

    private var openServer: String { settings.activeServerID.uuidString }

    /// Notes gone here: said to their server's plugin shortly (several swiped together go as one).
    func cleared(_ ids: [String], server: String?) {
        let ids = ids.filter(PushNote.isNoteID)
        guard !ids.isEmpty else { return }
        // A briefing's notification gone here: its tile on Today read, as on the other devices.
        if AgentBriefing.markRead(notes: Set(ids)) { BriefingsInbox.shared.reload() }
        let key = server.flatMap { $0.isEmpty ? nil : $0 } ?? openServer
        var all = pending
        all[key] = Array(((all[key] ?? []) + ids).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.suffix(Self.most))
        pending = all
        flushing?.cancel()
        flushing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Says what waits now: for a swipe, which iOS gives the app only a moment for.
    func flushSoon() async {
        flushing?.cancel()
        flushing = nil
        await flush()
    }

    /// Says the open server's waiting clears to its plugin. Kept for later when it can't be
    /// reached; dropped when its plugin is too old to know the command (it would never).
    func flush() async {
        guard settings.transport.isHermes, let ids = pending[openServer], !ids.isEmpty else { return }
        let me = ownIDs()
        do {
            let reply = try await command("cleared \(me.isEmpty ? "-" : me.joined(separator: ",")) \(ids.joined(separator: ","))")
            // Said, or a plugin that doesn't know the command: either way not said again.
            _ = reply
            var all = pending
            all[openServer] = (all[openServer] ?? []).filter { !ids.contains($0) }
            if all[openServer]?.isEmpty == true { all[openServer] = nil }
            pending = all
        } catch PushError.noPlugin {
            var all = pending
            all[openServer] = nil
            pending = all
        } catch {
            // Not reached now: said when Redde next comes forward.
        }
    }

    /// Back in front: what waits is said, and what was cleared elsewhere meanwhile is cleared here.
    func cameForward() async {
        await flush()
        await catchUp()
    }

    /// Asks the open server's plugin which notes were cleared elsewhere since last asked, and
    /// takes them out of Notification Center here.
    func catchUp() async {
        guard settings.transport.isHermes else { return }
        let key = "\(Self.sinceKey).\(openServer)"
        // The first time, the last two days (all the plugin keeps).
        let since = defaults.object(forKey: key) as? Int ?? 0
        guard let reply = try? await command("cleared since \(since)") else { return }
        guard let found = Self.clearedSince(reply) else { return }
        defaults.set(found.now - 5, forKey: key)   // a little back, for a clear said as this was asked
        if !found.ids.isEmpty {
            ClearedNotes.remove(found.ids) { _ in Task { @MainActor in BriefingsInbox.shared.reload(); IdeasInbox.shared.reload() } }
        }
    }

    /// The plugin's answer to `cleared since`: its clock now, and the notes cleared since.
    /// Nil for any other answer (a plugin older than 1.33).
    nonisolated static func clearedSince(_ reply: String) -> (now: Int, ids: [String])? {
        let words = reply.split(separator: " ").map(String.init)
        guard words.count == 4, words[0] == "redde-push", words[1] == "cleared-since", let now = Int(words[2]) else { return nil }
        return (now, words[3] == "-" ? [] : words[3].split(separator: ",").map(String.init).filter(PushNote.isNoteID))
    }

    /// A silent push from the plugin: the notes cleared on another device, cleared here.
    /// True when it was one.
    nonisolated static func take(remote userInfo: [AnyHashable: Any], done: @escaping @Sendable (Bool) -> Void) {
        guard let payload = userInfo[PushNote.sealedKey] as? String,
              let (note, _) = PushSeal.note(from: payload, pairings: PushVault.load()),
              note.kind == .clear else { done(false); return }
        ClearedNotes.remove(note.clearedIDs) { _ in
            Task { @MainActor in BriefingsInbox.shared.reload(); IdeasInbox.shared.reload() }   // their briefings read, ideas gone (`ClearedNotes`)
            done(true)
        }
    }
}

#if os(iOS)
/// Catches the APNs registration callbacks; everything else stays SwiftUI.
final class PushDelegate: NSObject, UIApplicationDelegate {
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "notify")

    /// Health may have woken Redde for new sleep or a workout: its watch is set up again at once.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if canImport(HealthKit)
        HealthDays.startIfOn()
        #endif
        // Leave-By Alerts' background refresh: registered before launch finishes, as iOS requires.
        LeaveByAlerts.registerRefresh()
        // And the photo library's overnight look on the charger (`PhotoLooking`).
        PhotoLooking.registerOvernight()
        return true
    }

    /// Portrait on an iPhone, unless it folds (`Foldable`); every way on an iPad.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Foldable.orientations
    }

    nonisolated func application(_ application: UIApplication,
                                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task.detached { await Notifier.uploadDeviceToken(deviceToken) }
        Task { @MainActor in PushService.shared.received(token: deviceToken) }
    }

    /// A silent push: notes the person cleared on another device (`NoteClears`). The completion
    /// form, called once: the async one is called off the main thread.
    nonisolated func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                                 fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        nonisolated(unsafe) let finish = completionHandler
        NoteClears.take(remote: userInfo) { cleared in finish(cleared ? .newData : .noData) }
    }

    /// Keys stored before 2.2 are moved to being readable while the iPhone is locked
    /// (`Keychain.moveToAfterFirstUnlock`) as it is unlocked, if the car started Redde while it
    /// was locked and launch couldn't.
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        Keychain.moveToAfterFirstUnlock()
        AgentCalls.shared.unlocked()   // a call answered locked listens from now on
    }

    nonisolated func application(_ application: UIApplication,
                                 didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("push registration failed: \(error.localizedDescription)")
        let reason = error.localizedDescription
        Task { @MainActor in PushService.shared.failedToRegister(PushError.noToken(reason)) }
    }
}
#elseif os(macOS)
/// The Mac's APNs registration callbacks, as `PushDelegate` takes the iPhone's (asked 2026-10-30,
/// "pair the mac and ipad for push"): the address goes to `PushService`, which pairs with it and
/// keeps the relay's registration current. The notes themselves are opened by `EchoPushMac`.
final class MacPushDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "notify")

    nonisolated func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushService.shared.received(token: deviceToken) }
    }

    /// A silent push, while Redde runs: notes cleared on another device (`NoteClears`).
    nonisolated func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        NoteClears.take(remote: userInfo) { _ in }
    }

    nonisolated func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        log.error("push registration failed: \(error.localizedDescription)")
        let reason = error.localizedDescription
        Task { @MainActor in PushService.shared.failedToRegister(PushError.noToken(reason)) }
    }
}
#endif

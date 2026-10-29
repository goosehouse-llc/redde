import UserNotifications
import WidgetKit

/// Opens a notification from the person's Hermes before it is shown. What arrives says only
/// "Open Redde to see what's new" and carries a sealed note (`e`); this replaces the words with
/// what the note says, using a key that only this iPhone and that Hermes hold (`PushSeal`).
/// Anything that can't be opened is shown as it came.
final class NotificationService: UNNotificationServiceExtension {
    private var deliver: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content
        deliver = contentHandler
        var choices: UNNotificationCategory?
        var headsUp: AgentBriefing?
        if let payload = request.content.userInfo[PushNote.sealedKey] as? String,
           let (note, pairing) = PushSeal.note(from: payload, pairings: PushVault.load()),
           note.fill(content) {
            PushVault.confirm(pairing, host: note.n)
            // A request the agent stopped for goes on the "Needs you" widget, and comes off it
            // when a later note says the turn went on: this is how the widget hears of either
            // while Redde is closed.
            if NeedsYou.take(note) { WidgetCenter.shared.reloadTimelines(ofKind: NeedsYou.widgetKind) }
            // And what the agent wrote for its own widget in a turn the phone wasn't following.
            if AgentBoard.take(note) { WidgetCenter.shared.reloadTimelines(ofKind: AgentBoard.widgetKind) }
            // And ideas it offered, for the chat list to show when Redde opens.
            if AgentIdea.take(note) { WidgetCenter.shared.reloadTimelines(ofKind: UpNext.widgetKind) }
            WatchReport.take(note)   // and what a watch saw, for the Watches list
            // And a briefing's whole text; a heads-up's with when to leave for its event.
            if AgentBriefing.take(note) { WidgetCenter.shared.reloadTimelines(ofKind: UpNext.widgetKind) }
            if note.u != nil, note.r != nil, AgentBriefing.all().contains(where: { $0.title == note.t }) {
                headsUp = AgentBriefing.all().first { $0.title == note.t && $0.eventAt != nil }
            }
            AgentActivityNote.take(note)   // and, for Agent Activity, that it happened
            choices = note.choiceCategory
            // A chat the person muted (Mute… in Redde): in the list, without a sound or a banner.
            if MutedChats.isMuted(session: note.s, room: note.g, bot: note.p) { MutedChats.quiet(content) }
            // Quiet hours: what an agent sent on its own goes to the list only, and is told of
            // in one notification when the quiet ends (`QuietHours`).
            let quiet = QuietHours.load()
            if quiet.covers(.now), QuietHours.waits(note) {
                MutedChats.quiet(content)
                HeldNote.scheduleDigest(HeldNote.hold(note), at: quiet.ends(after: .now))
            }
            if note.repeatsTheApp() {
                // The app said so when it happened. This takes its banner's place without
                // sounding or lighting the screen a second time.
                content.sound = nil
                content.interruptionLevel = .passive
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [PushNote.appsFailureBanner])
            }
        }
        if !NotificationSound.isOn { content.sound = nil }
        // A heads-up with an address: when to leave, worked out here from where the phone is, first.
        if let headsUp {
            nonisolated(unsafe) let content = content
            nonisolated(unsafe) let contentHandler = contentHandler
            Task {
                if let line = await LeaveTime.work(out: headsUp) { content.body = line + "\n" + content.body }
                WidgetCenter.shared.reloadTimelines(ofKind: UpNext.widgetKind)
                contentHandler(content)
            }
            return
        }
        // A question with choices: its buttons need a category of their own, registered now.
        if let category = choices {
            // (The system hands these over to be used once, from wherever the work finishes.)
            nonisolated(unsafe) let category = category
            nonisolated(unsafe) let content = content
            nonisolated(unsafe) let contentHandler = contentHandler
            Task {
                if await Self.registered(category) { content.categoryIdentifier = category.identifier }
                contentHandler(content)
            }
            return
        }
        contentHandler(content)
    }

    /// Adds a question's own category to the ones the app registered, so its choices show as
    /// buttons. False when it can't be seen to have taken: the note then keeps the category
    /// the app did register, with its Reply field and no buttons.
    private static func registered(_ category: UNNotificationCategory) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories()
        // Added to what is there; if the app's own aren't, this isn't the list to add to.
        guard existing.contains(where: { $0.identifier == PushNote.questionCategory }) else { return false }
        center.setNotificationCategories(existing.union([category]))
        // Asked again: the answer comes back once the new set is in place.
        return await center.notificationCategories().contains { $0.identifier == category.identifier }
    }

    override func serviceExtensionTimeWillExpire() {
        if let deliver, let content { deliver(content) }
    }
}

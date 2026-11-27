import UserNotifications
import WidgetKit

/// Opens a notification from the person's Hermes before it is shown. What arrives says only
/// "Open Redde to see what's new" and carries a sealed note (`e`); this replaces the words with
/// what the note says, using a key that only this iPhone and that Hermes hold (`PushSeal`).
/// Anything that can't be opened is shown as it came.
final class NotificationService: UNNotificationServiceExtension {
    /// The system's handler, used once: by the work in `didReceive` or, should time run out
    /// first, by `serviceExtensionTimeWillExpire` (on another thread), whichever comes first.
    private let lock = NSLock()
    private var deliver: ((UNNotificationContent) -> Void)?
    /// The note as `didReceive` left it, never changed after: what time running out sends.
    private var content: UNMutableNotificationContent?

    /// Hands a note to iOS once; nil sends the note as `didReceive` left it (time ran out).
    private func finish(_ shown: UNNotificationContent?) {
        let (handler, original) = lock.withLock {
            defer { deliver = nil }
            return (deliver, content)
        }
        if let handler, let note = shown ?? original { handler(note) }
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        lock.withLock {
            self.content = content
            deliver = contentHandler
        }
        var choices: UNNotificationCategory?
        var headsUp: AgentBriefing?
        var leaveCheck: String?
        if let payload = request.content.userInfo[PushNote.sealedKey] as? String,
           let (note, pairing) = PushSeal.note(from: payload, pairings: PushVault.load()),
           note.fill(content) {
            PushVault.confirm(pairing, host: note.n)
            if let server = pairing.server, !server.isEmpty { content.userInfo[PushNote.serverKey] = server }
            // Its own id, the same on the person's other devices, for clearing it there too; and a
            // category, if it has none, so a swipe is heard (`NoteClears`).
            if let id = note.m, PushNote.isNoteID(id) { content.userInfo[PushNote.noteKey] = id }
            if content.categoryIdentifier.isEmpty, note.kind != .clear { content.categoryIdentifier = PushNote.noteCategory }
            // Cleared on another device and sent the way an older relay sends everything, as an alert.
            let cleared = note.clearedIDs
            if !cleared.isEmpty { ClearedNotes.remove(cleared) }
            // A request the agent stopped for goes on the "Needs you" widget, and comes off it
            // when a later note says the turn went on: this is how the widget hears of either
            // while Redde is closed.
            if NeedsYou.take(note) { WidgetCenter.shared.reloadTimelines(ofKind: NeedsYou.widgetKind) }
            // And what the agent wrote for its own widget in a turn the phone wasn't following.
            if AgentBoard.take(note) { WidgetCenter.shared.reloadTimelines(ofKind: AgentBoard.widgetKind) }
            // And ideas it offered, for the chat list to show when Redde opens.
            // (Up Next and Your Day count them: `WidgetKind` in the app, `com.goosehouse.echo.day`.)
            if AgentIdea.take(note) {
                WidgetCenter.shared.reloadTimelines(ofKind: UpNext.widgetKind)
                WidgetCenter.shared.reloadTimelines(ofKind: "com.goosehouse.echo.day")
            }
            WatchReport.take(note)   // and what a watch saw, for the Watches list
            // And a goal's check-in, for its card atop the chat list and the Goals widget.
            if GoalReport.take(note) { WidgetCenter.shared.reloadTimelines(ofKind: "com.goosehouse.echo.goals") }
            // And a briefing's whole text; a heads-up's with when to leave for its event.
            if AgentBriefing.take(note) {
                WidgetCenter.shared.reloadTimelines(ofKind: UpNext.widgetKind)
                WidgetCenter.shared.reloadTimelines(ofKind: "com.goosehouse.echo.day")
            }
            // Its banner without the model's narration ahead of the brief, as Redde shows it.
            if note.x == "brief" { content.body = DayBrief.withoutNarration(content.body) }
            // Kept quiet by the person's own choice, or sent here only so this device has it too:
            // into the list, and not told of again in a digest.
            var hushed = false
            // One job's notifications together in the list, and quiet for a job the person keeps
            // to the drawer, or hides (Hermes's plugin, told, sends none; an older one still does).
            if let job = JobNotices.jobKey(of: note) {
                content.threadIdentifier = "brief." + job
                if JobNotices.choice(for: job) != .notify { MutedChats.quiet(content); hushed = true }
            }
            if note.u != nil, note.r != nil, AgentBriefing.all().contains(where: { $0.title == note.t }) {
                headsUp = AgentBriefing.all().first { $0.title == note.t && $0.eventAt != nil }
            }
            AgentActivityNote.take(note)   // and, for Agent Activity, that it happened
            choices = note.choiceCategory
            // Time to check the traffic for a Leave-By Alert (`LeaveCheck`).
            if note.kind == .leave, let wake = note.i, !wake.isEmpty { leaveCheck = wake }
            // Heard on another device, the one in use (Only Where You Are, plugin 1.42): kept here
            // so every device shows the same cards, and into the list without a sound or a banner.
            if note.z == "away" { MutedChats.quiet(content); hushed = true }
            // A chat the person muted (Mute… in Redde): in the list, without a sound or a banner.
            if MutedChats.isMuted(session: note.s, room: note.g, bot: note.p) { MutedChats.quiet(content); hushed = true }
            // How loudly the person has this kind come (`NoteLevels`, 2026-11-27).
            let levels = NoteLevels.load()
            let level = levels.level(of: note)
            // What an agent sent on its own, unless it needs the person (a reminder they set, a
            // watch's URGENT find: as it comes, plugin 1.57).
            let waits = QuietHours.waits(note) && NoteGroup.of(note) != .needsYou
            let quiet = QuietHours.load()
            if hushed {
                // (quiet already)
            } else if quiet.covers(.now), waits || level == .summary {
                // Quiet hours: into the list only, and told of in one notification when the quiet
                // ends (`QuietHours`); a summary's kind, at the first summary after it.
                MutedChats.quiet(content)
                content.threadIdentifier = HeldNote.thread
                let summary = level == .summary
                HeldNote.wait(note, until: summary ? levels.nextSummary(after: .now, quiet: quiet) : quiet.ends(after: .now), afterQuiet: !summary)
            } else if level == .summary {
                // In the Summary: into the list, and told of at the next summary time.
                MutedChats.quiet(content)
                content.threadIdentifier = HeldNote.thread
                HeldNote.wait(note, until: levels.nextSummary(after: .now, quiet: quiet), afterQuiet: false)
            } else if note.z == "drawer", note.kind != .routine {
                // Quiet from the plugin (1.36): ideas left alone set after set, a watch paused for
                // finding nothing. (A briefing's own Drawer Only is the job's choice, above.)
                MutedChats.quiet(content)
            } else if waits, quiet.spent(at: .now) {
                // Past the day's limit (2026-11-22): into the list, without a sound or a banner.
                MutedChats.quiet(content)
            } else if level == .silent {
                // Banner Only.
                content.sound = nil
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
        // A Leave-By Alert's traffic re-check: Apple Maps asked again, the alert moved, and what
        // came of it shown in place of the note (which, should time run out, says it looked).
        // The work below runs on a copy and hands it over through `finish`, so the note time
        // running out would send is never written while it's read. (`finish` holds the lock.)
        nonisolated(unsafe) let service = self
        if let leaveCheck {
            Task { service.finish(await LeaveCheck.run(wake: leaveCheck)) }
            return
        }
        // A heads-up with an address: when to leave, worked out here from where the phone is, first.
        if let headsUp {
            nonisolated(unsafe) let shown = (content.mutableCopy() as? UNMutableNotificationContent) ?? content
            Task {
                if let line = await LeaveTime.work(out: headsUp) { shown.body = line + "\n" + shown.body }
                WidgetCenter.shared.reloadTimelines(ofKind: UpNext.widgetKind)
                service.finish(shown)
            }
            return
        }
        // A question with choices: its buttons need a category of their own, registered now.
        if let category = choices {
            // (The system hands these over to be used once, from wherever the work finishes.)
            nonisolated(unsafe) let category = category
            nonisolated(unsafe) let shown = (content.mutableCopy() as? UNMutableNotificationContent) ?? content
            Task {
                if await Self.registered(category) { shown.categoryIdentifier = category.identifier }
                service.finish(shown)
            }
            return
        }
        finish(content)
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
        finish(nil)
    }
}

import UserNotifications

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
        if let payload = request.content.userInfo[PushNote.sealedKey] as? String,
           let (note, pairing) = PushSeal.note(from: payload, pairings: PushVault.load()),
           note.fill(content) {
            PushVault.confirm(pairing, host: note.n)
            choices = note.choiceCategory
            if note.repeatsTheApp() {
                // The app said so when it happened. This takes its banner's place without
                // sounding or lighting the screen a second time.
                content.sound = nil
                content.interruptionLevel = .passive
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [PushNote.appsFailureBanner])
            }
        }
        if !NotificationSound.isOn { content.sound = nil }
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

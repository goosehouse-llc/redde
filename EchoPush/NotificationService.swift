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
        if let payload = request.content.userInfo[PushNote.sealedKey] as? String,
           let (note, pairing) = PushSeal.note(from: payload, pairings: PushVault.load()),
           note.fill(content) {
            PushVault.confirm(pairing, host: note.n)
            if note.repeatsTheApp() {
                // The app said so when it happened. This takes its banner's place without
                // sounding or lighting the screen a second time.
                content.sound = nil
                content.interruptionLevel = .passive
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [PushNote.appsFailureBanner])
            }
        }
        if !NotificationSound.isOn { content.sound = nil }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let deliver, let content { deliver(content) }
    }
}

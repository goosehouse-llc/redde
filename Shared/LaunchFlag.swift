import Foundation

/// A "start listening when you come forward" note left for the app by a control or intent
/// running in another process. Lives in the App Group; valid for a few seconds.
nonisolated enum LaunchFlag {
    private static let key = "launchFlag.voice"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: ShareInbox.appGroup) }

    static func requestVoice(handsFree: Bool) {
        defaults?.set(["handsFree": handsFree, "at": Date.now.timeIntervalSince1970], forKey: key)
    }

    /// Returns the hands-free flag if a fresh request is waiting, clearing it.
    static func consumeVoice(maxAge: TimeInterval = 20) -> Bool? {
        guard let d = defaults?.dictionary(forKey: key) else { return nil }
        defaults?.removeObject(forKey: key)
        guard let at = d["at"] as? TimeInterval, Date.now.timeIntervalSince1970 - at < maxAge else { return nil }
        return d["handsFree"] as? Bool ?? false
    }
}

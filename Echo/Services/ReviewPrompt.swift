import Foundation

/// When to ask for an App Store rating: only once someone has plainly got something out of Redde
/// (enough finished replies, on enough different days), at most once per version. StoreKit then
/// decides whether the prompt actually shows (three times a year at most, and never if the person
/// turned review requests off).
nonisolated struct ReviewPrompt {
    static let repliesNeeded = 8
    static let daysNeeded = 3

    var defaults: UserDefaults = .standard

    private enum Key {
        static let replies = "review.finishedReplies"
        static let days = "review.activeDays"
        static let askedVersion = "review.askedVersion"
    }

    var finishedReplies: Int { defaults.integer(forKey: Key.replies) }
    var activeDays: [String] { defaults.stringArray(forKey: Key.days) ?? [] }

    /// A reply came back whole (not failed, not stopped). Counts it and the day it came.
    func recordReply(on date: Date = .now) {
        defaults.set(finishedReplies + 1, forKey: Key.replies)
        let day = Self.dayStamp(date)
        var days = activeDays
        if !days.contains(day) {
            days.append(day)
            defaults.set(Array(days.suffix(30)), forKey: Key.days)   // only the count matters
        }
    }

    /// Worth asking now, for this app version.
    func isDue(version: String) -> Bool {
        finishedReplies >= Self.repliesNeeded && activeDays.count >= Self.daysNeeded
            && defaults.string(forKey: Key.askedVersion) != version
    }

    func markAsked(version: String) { defaults.set(version, forKey: Key.askedVersion) }

    private static func dayStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}

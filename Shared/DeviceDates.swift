import Foundation

/// Dates as the agent writes them and as it is told them. Here and not with the phone tools
/// because the notification extension reads them too, on a note for the agent's widget: a
/// time written without a zone means the phone's own, which only the phone knows.
nonisolated enum DeviceDates {
    /// "2026-10-13T09:00:00-04:00", the same without seconds or without a zone (the phone's own
    /// time), with fractions of a second, or a day alone ("2026-10-13": its first moment here).
    static func parse(_ text: String, calendar: Calendar = .current) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = calendar
        local.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    /// Whether what was written names a day and no time.
    static func isDayOnly(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
    }

    /// With the phone's own offset, so the agent reads the time the person lives in.
    static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// For a person: "Tuesday, October 13 at 9:00 AM".
    static func spoken(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())
    }
}

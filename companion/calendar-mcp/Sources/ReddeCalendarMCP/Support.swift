import Foundation
import Security

enum Log {
    private static let formatter: ISO8601DateFormatter = ISO8601DateFormatter()
    static func info(_ message: String) {
        FileHandle.standardError.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8))
    }
}

/// The bearer token lives in Application Support, readable only by this user.
enum TokenStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redde Calendar MCP", isDirectory: true)
    }

    static func loadOrCreate() throws -> String {
        let file = directory.appendingPathComponent("token")
        if let existing = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            return existing
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "TokenStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "no randomness"])
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try Data(token.utf8).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }
}

/// Constant-time comparison, so the token can't be guessed a byte at a time from response timing.
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in 0 ..< x.count { diff |= x[i] ^ y[i] }
    return diff == 0
}

/// Dates in and out. Accepts "2026-09-15", "2026-09-15T14:30", "2026-09-15T14:30:00", with or
/// without seconds, fractions and a UTC offset; no offset means this Mac's time zone.
enum DateCodec {
    private static let withOffset: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let withOffsetFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let localFormats: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = $0
        return f
    }
    private static let output: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()

    static func parse(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespaces)
        if let d = withOffset.date(from: s) ?? withOffsetFraction.date(from: s) { return d }
        for f in localFormats { if let d = f.date(from: s) { return d } }
        return nil
    }

    static func string(_ date: Date) -> String { output.string(from: date) }

    static func isDateOnly(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespaces).count == 10
    }
}

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Optional `settings.json` beside the token. Read on each use, so edits apply without a restart.
///
///   { "hide_calendars": ["Team Schedule"] }
///
/// Names (or ids) listed there join subscription, birthday and holiday calendars as "background"
/// calendars: left out of get_agenda and find_free_time unless asked for.
enum ServerSettings {
    static var file: URL { TokenStore.directory.appendingPathComponent("settings.json") }

    static var hiddenCalendars: Set<String> {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = json["hide_calendars"] as? [String] else { return [] }
        return Set(names.map { $0.lowercased() })
    }
}

/// Day words the agent is likely to send: today, tomorrow, yesterday, a weekday name (its next
/// occurrence, today included), or any date DateCodec understands. Returns the start of that day.
enum DayParser {
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    static func startOfDay(_ text: String, now: Date = Date()) -> Date? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch word {
        case "today": return today
        case "tomorrow": return cal.date(byAdding: .day, value: 1, to: today)
        case "yesterday": return cal.date(byAdding: .day, value: -1, to: today)
        default: break
        }
        if let index = weekdays.firstIndex(of: word) {
            let ahead = (index + 1 - cal.component(.weekday, from: today) + 7) % 7
            return cal.date(byAdding: .day, value: ahead, to: today)
        }
        let parts = word.split(separator: " ").map(String.init)
        // "this friday" is its next occurrence; "next friday" is the one after this week's.
        if parts.count == 2, ["this", "next", "coming", "last"].contains(parts[0]), let index = weekdays.firstIndex(of: parts[1]) {
            let ahead = (index + 1 - cal.component(.weekday, from: today) + 7) % 7
            switch parts[0] {
            case "next":
                let upcoming = cal.date(byAdding: .day, value: ahead == 0 ? 7 : ahead, to: today)!
                let sameWeek = cal.isDate(upcoming, equalTo: today, toGranularity: .weekOfYear)
                return sameWeek ? cal.date(byAdding: .day, value: 7, to: upcoming) : upcoming
            case "last":
                return cal.date(byAdding: .day, value: ahead == 0 ? -7 : ahead - 7, to: today)
            default:
                return cal.date(byAdding: .day, value: ahead, to: today)
            }
        }
        if parts.count == 2, ["next", "this"].contains(parts[0]), parts[1] == "week" {
            // Monday of this or next week.
            let monday = (2 - cal.component(.weekday, from: today) - 7) % 7
            return cal.date(byAdding: .day, value: monday + (parts[0] == "next" ? 7 : 0), to: today)
        }
        if parts.count == 3, parts[0] == "in", let n = Int(parts[1]), ["day", "days"].contains(parts[2]) {
            return cal.date(byAdding: .day, value: n, to: today)
        }
        return DateCodec.parse(text).map { cal.startOfDay(for: $0) }
    }

    static func isDayWord(_ text: String) -> Bool {
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        return ["today", "tomorrow", "yesterday"].contains(word) || weekdays.contains(word) || DateCodec.isDateOnly(text)
            || (!DateCodec.isDateOnly(text) && DateCodec.parse(text) == nil && startOfDay(text) != nil)
    }

    static let weekdayName: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEEE"; return f
    }()
    static let dayString: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static let clock: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f
    }()
}

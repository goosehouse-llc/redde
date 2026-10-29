import Foundation

/// A Week Ahead briefing read as a calendar (asked 2026-10-29: "the week ahead should show in a
/// calendar card, easy to read"). The job asks for a first line on the week, then each day as
/// "## Friday, Oct 30" with "- 11:30 AM Planning session" lines under it and "> " notes, then
/// "Get ready: " lines (`WeekAhead.prompt`). Read leniently, since a model writes it: a day may be
/// a bold "**Friday, Oct 30** — Heavy day. …" line instead (how the first ones came), any list
/// mark will do, and a time is only one written as one. Nil when it isn't a week of days, so the
/// briefing shows as text.
nonisolated struct WeekPlan: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var time: String?
        var what: String
    }

    struct Day: Equatable, Sendable, Identifiable {
        var id: String { title }
        /// As written: "Friday, Oct 30".
        var title: String
        /// "FRI", in the phone's language when the model wrote in it.
        var weekday: String
        /// "30", or nil when the day has no date.
        var number: String?
        var items: [Item] = []
        var notes: [String] = []
    }

    var intro: String
    var days: [Day]
    /// After the days: what to get ready for.
    var after: [String]

    var count: Int { days.reduce(0) { $0 + $1.items.count } }

    static func parse(_ text: String, locale: Locale = .current) -> WeekPlan? {
        var intro: [String] = [], days: [Day] = [], after: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.trimmingCharacters(in: CharacterSet(charactersIn: "-—_*= ")).isEmpty == false else { continue }
            if let day = day(in: line, locale: locale) {
                days.append(day.day)
                if let rest = day.rest { days[days.count - 1].notes.append(rest) }
                continue
            }
            if let ready = line.firstMatch(of: /^\**(?i:get ready|due)\**\s*[:：]\**\s*(.+)$/) {
                after.append(plain(String(ready.output.1)))
                continue
            }
            guard !days.isEmpty else { intro.append(plain(line)); continue }
            if let mark = line.firstMatch(of: /^(?:[-*•–]|\d+\.)\s+(.+)$/) {
                days[days.count - 1].items.append(item(plain(String(mark.output.1))))
            } else if line.hasPrefix(">") {
                days[days.count - 1].notes.append(plain(String(line.drop { $0 == ">" || $0 == " " })))
            } else if after.isEmpty {
                days[days.count - 1].notes.append(plain(line))
            } else {
                after.append(plain(line))
            }
        }
        guard days.count >= 2 else { return nil }
        return WeekPlan(intro: intro.joined(separator: " "), days: days, after: after)
    }

    // MARK: Pieces

    /// A day's heading: "## Friday, Oct 30", "**Friday, Oct 30** — Heavy day.", "Fri 30:".
    private static func day(in line: String, locale: Locale) -> (day: Day, rest: String?)? {
        var head = line.drop { $0 == "#" || $0 == " " }
        let hashed = head.count < line.count
        var rest: String?
        if head.hasPrefix("**"), let close = head.dropFirst(2).range(of: "**") {
            rest = String(head[close.upperBound...])
            head = head.dropFirst(2)[..<close.lowerBound]
        } else if !hashed {
            return nil
        }
        let title = plain(String(head)).trimmingCharacters(in: CharacterSet(charactersIn: " :：—–-"))
        guard let weekday = weekday(starting: title, locale: locale) else { return nil }
        let number = title.firstMatch(of: /\b(\d{1,2})\b/).map { String($0.output.1) }
        let note = rest.map { plain($0).trimmingCharacters(in: CharacterSet(charactersIn: " :：—–-")) }
        return (Day(title: title, weekday: weekday, number: number), note?.isEmpty == false ? note : nil)
    }

    /// The short weekday a heading starts with, in the phone's language or English.
    private static func weekday(starting title: String, locale: Locale) -> String? {
        let lowered = title.lowercased()
        for language in [locale, Locale(identifier: "en_US")] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = language
            let short = calendar.shortWeekdaySymbols
            for (i, name) in calendar.weekdaySymbols.enumerated() where lowered.hasPrefix(name.lowercased()) || lowered.hasPrefix(short[i].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                return short[i].trimmingCharacters(in: CharacterSet(charactersIn: ".")).uppercased(with: language)
            }
        }
        return nil
    }

    /// "11:30 AM Planning session" → 11:30 AM, Planning session; "9–12 Morning blocks" too.
    private static func item(_ text: String) -> Item {
        let timed = /^((?:\d{1,2}:\d{2}(?:\s?[AaPp]\.?[Mm]\.?)?|\d{1,2}\s?[AaPp]\.?[Mm]\.?|[Nn]oon|\d{1,2}(?=\s?[–-]\s?\d))(?:\s?[–-]\s?\d{1,2}(?::\d{2})?(?:\s?[AaPp]\.?[Mm]\.?)?)?)[\s:—–·,-]+(.+)$/
        if let found = text.firstMatch(of: timed) {
            return Item(time: String(found.output.1), what: String(found.output.2))
        }
        return Item(time: nil, what: text)
    }

    /// Markdown's marks off: bold, italics, code, links' brackets.
    static func plain(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        out = out.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.output.1) }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

import Foundation

/// A briefing read as one day's calendar (asked 2026-10-31: "the daily morning brief showed my
/// calendar but not in the card"): a daily brief the agent set up, as a model writes one. Its day
/// from a date in its title or headings ("Saturday, October 31, 2026", "Sat Oct 31"), or "today"
/// or "tomorrow" there, read against when it came; else, with a title that names a calendar
/// ("Daily meeting brief", "Your agenda", "Today's schedule"), the day it came. And a schedule in
/// it: a Markdown table with a time column, or two lines or more that start with a time or "All
/// day" (one will do under such a title). Nil otherwise, so the briefing shows as text: one with
/// no schedule, one about several days (the Week Ahead's is `WeekPlan`'s), and the heads-up, the
/// wrap-up and Morning Ideas, which the app leaves out by their titles.
///
/// Its rows are kept too, deduplicated (a brief may list an event twice, in two tables), for the
/// card to draw when the phone's own calendar can't be read. Pure: no clock, no calendar store.
nonisolated struct DayBrief: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        var title: String
        /// Minutes into the day it starts; nil all day.
        var start: Int?
        /// Minutes into the day it ends, when written and after its start.
        var end: Int?
        /// Where, or its meeting link (a Zoom column's).
        var place: String?

        var allDay: Bool { start == nil }
    }

    /// The day, "2026-10-31".
    var day: String
    /// Its first moment, in the calendar it was read with.
    var date: Date
    /// All-day rows first, then by start.
    var rows: [Row]

    var allDay: [Row] { rows.filter(\.allDay) }
    var timed: [Row] { rows.filter { !$0.allDay } }

    // MARK: Reading

    static func read(title: String, text: String, at: Date, calendar: Calendar = .current, locale: Locale = .current) -> DayBrief? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let named = namesCalendar(title)
        let (tabled, listed) = (tableRows(lines), lineRows(lines))
        guard !tabled.isEmpty || listed.count >= 2 || (named && !listed.isEmpty) else { return nil }
        guard let date = day(title: title, lines: lines, named: named, at: at, calendar: calendar, locale: locale) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = parts.year, let m = parts.month, let d = parts.day else { return nil }
        return DayBrief(day: String(format: "%04d-%02d-%02d", y, m, d), date: date, rows: dedupe(tabled + listed))
    }

    /// A title that says it is about the calendar.
    static func namesCalendar(_ title: String) -> Bool {
        title.range(of: #"\b(?:meetings?|agenda|calendar|schedule|appointments?|events|your day|day ahead|daily brief(?:ing)?|morning brief(?:ing)?|today)\b"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: The day

    /// The day it is about: one date in the title or the headings (two different ones: not a day),
    /// else one in the first lines; else "today" or "tomorrow" there; else, under a calendar's
    /// title, the day it came.
    private static func day(title: String, lines: [String], named: Bool, at: Date, calendar: Calendar, locale: Locale) -> Date? {
        let today = calendar.startOfDay(for: at)
        let dates = Dates(locale: locale)
        let heads = [title] + lines.filter { $0.hasPrefix("#") || ($0.hasPrefix("**") && $0.hasSuffix("**")) }
        let headed = Set(heads.compactMap { dates.date(in: $0, near: today, calendar: calendar) })
        if headed.count > 1 { return nil }
        if let one = headed.first { return one }
        let opening = lines.filter { !$0.hasPrefix("|") }.prefix(4)
        if let found = opening.lazy.compactMap({ dates.date(in: $0, near: today, calendar: calendar) }).first { return found }
        for line in heads + Array(opening) {
            if line.range(of: #"\btomorrow(?:'s|’s)?\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return calendar.date(byAdding: .day, value: 1, to: today)
            }
            if line.range(of: #"\b(?:today(?:'s|’s)?|tonight)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return today }
        }
        return named ? today : nil
    }

    /// A date written with its month's name, in English or the phone's language: "October 31",
    /// "Oct 31st, 2026", "31 October", "Sat, Oct 31". Without a year, the one nearest `near`.
    static func date(in line: String, near: Date, calendar: Calendar = .current, locale: Locale = .current) -> Date? {
        Dates(locale: locale).date(in: line, near: near, calendar: calendar)
    }

    /// What finds a date in a line, made once for a briefing: the months' names and the two
    /// orders they are written in.
    private struct Dates {
        let months: [String: Int]
        let first: NSRegularExpression?
        let after: NSRegularExpression?

        init(locale: Locale) {
            var months: [String: Int] = ["sept": 9]
            for language in [Locale(identifier: "en_US"), locale] {
                var calendar = Calendar(identifier: .gregorian)
                calendar.locale = language
                for list in [calendar.monthSymbols, calendar.shortMonthSymbols, calendar.standaloneMonthSymbols, calendar.shortStandaloneMonthSymbols] {
                    for (i, name) in list.enumerated() {
                        let key = name.lowercased(with: language).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        if key.count >= 3 { months[key] = i + 1 }
                    }
                }
            }
            self.months = months
            let names = months.keys.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            first = try? NSRegularExpression(pattern: #"\b("# + names + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4}))?"#)
            after = try? NSRegularExpression(pattern: #"\b(\d{1,2})(?:st|nd|rd|th|\.)?\s+(?:of\s+|de\s+)?("# + names + #")\b\.?(?:,?\s+(?:de\s+)?(\d{4}))?"#)
        }

        func date(in line: String, near: Date, calendar: Calendar) -> Date? {
            let text = line.lowercased()
            let range = NSRange(text.startIndex..., in: text)
            func number(_ match: NSTextCheckingResult, _ at: Int) -> Int? { Range(match.range(at: at), in: text).flatMap { Int(text[$0]) } }
            func month(_ match: NSTextCheckingResult, _ at: Int) -> Int? { Range(match.range(at: at), in: text).flatMap { months[String(text[$0])] } }
            var found: (month: Int?, day: Int?, year: Int?)?
            if let match = first?.firstMatch(in: text, range: range) {
                found = (month(match, 1), number(match, 2), number(match, 3))
            } else if let match = after?.firstMatch(in: text, range: range) {
                found = (month(match, 2), number(match, 1), number(match, 3))
            }
            guard let found, let month = found.month, let day = found.day, (1...31).contains(day) else { return nil }
            let year = calendar.component(.year, from: near)
            let candidates = (found.year.map { [$0] } ?? [year - 1, year, year + 1]).compactMap { y -> Date? in
                guard let date = calendar.date(from: DateComponents(year: y, month: month, day: day)),
                      calendar.component(.day, from: date) == day else { return nil }
                return date
            }
            return candidates.min { abs($0.timeIntervalSince(near)) < abs($1.timeIntervalSince(near)) }
        }
    }

    // MARK: Rows

    /// The rows of each table with a time column: its title column ("Title", "Event", "Meeting",
    /// else the first other), and a place ("Location", "Where") or else its link ("Zoom Link").
    static func tableRows(_ lines: [String]) -> [Row] {
        var rows: [Row] = []
        var i = 0
        while i < lines.count {
            guard lines[i].hasPrefix("|"), i + 1 < lines.count, isDivider(lines[i + 1]),
                  let columns = columns(cells(lines[i]).map { $0.lowercased() }) else { i += 1; continue }
            i += 2
            while i < lines.count, lines[i].hasPrefix("|") {
                let raw = rawCells(lines[i])
                func cell(_ n: Int?) -> String? { n.flatMap { $0 < raw.count ? raw[$0] : nil } }
                let title = cell(columns.what).map(WeekPlan.plain) ?? ""
                if !isNone(title) {
                    var when = cell(columns.time).map(WeekPlan.plain) ?? ""
                    if let finish = cell(columns.end).map(WeekPlan.plain), !isNone(finish) { when += " – " + finish }
                    let span = clock(when)
                    rows.append(Row(title: String(title.prefix(160)), start: span?.start, end: span?.end,
                                    place: cell(columns.place).flatMap(placeText) ?? cell(columns.link).flatMap(placeText)))
                }
                i += 1
            }
        }
        return rows
    }

    /// A table's columns by their headers; nil without one for the time.
    private static func columns(_ header: [String]) -> (time: Int, end: Int?, what: Int, place: Int?, link: Int?)? {
        func find(_ pattern: String, besides: [Int?]) -> Int? {
            header.indices.first { !besides.contains($0) && header[$0].range(of: pattern, options: .regularExpression) != nil }
        }
        guard let time = find(#"\b(?:time|when|start|starts|hours?)\b"#, besides: []) else { return nil }
        let end = header.indices.first { $0 != time && ["end", "ends", "end time", "until", "to"].contains(header[$0]) }
        guard let what = find(#"\b(?:title|event|meeting|what|subject|name|item|activity|appointment|summary)s?\b"#, besides: [time, end])
                ?? header.indices.first(where: { $0 != time && $0 != end }) else { return nil }
        let place = find(#"\b(?:location|where|place|room|venue|address)\b"#, besides: [time, end, what])
        let link = find(#"\b(?:zoom|link|meet|call|url|join)\b"#, besides: [time, end, what, place])
        return (time, end, what, place, link)
    }

    /// Lines that start with a time or "All day", with or without a list's mark: "- 10:00 AM
    /// Bowling", "**9:30–10:00** · Stand-up @ Room 4", "All day: Halloween".
    static func lineRows(_ lines: [String]) -> [Row] {
        lines.compactMap { line in
            guard !line.hasPrefix("|"), !line.hasPrefix("#"), !line.hasPrefix(">") else { return nil }
            var text = WeekPlan.plain(line)
            if let mark = text.firstMatch(of: /^(?:[-*•–]|\d+[.)])\s+/) { text = String(text[mark.range.upperBound...]) }
            var start: Int?, end: Int?, rest: Substring
            if let allDay = text.firstMatch(of: /^(?i:all[\s-]?day)\b/) {
                rest = text[allDay.range.upperBound...]
            } else if let span = clock(text), span.length > 0 {
                (start, end) = (span.start, span.end)
                rest = text.dropFirst(span.length)
            } else {
                return nil
            }
            // What's after the time: past a separator, without a "(…)" the time left behind.
            let what = rest.drop { " :：—–-·,|)".contains($0) }.trimmingCharacters(in: .whitespaces)
            guard !what.isEmpty, what.count <= 140 else { return nil }
            var title = what, place: String?
            for separator in [" @ ", " · ", " 📍 "] {
                if let cut = title.range(of: separator) {
                    place = placeText(String(title[cut.upperBound...]))
                    title = String(title[..<cut.lowerBound])
                    break
                }
            }
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: " .;"))
            return title.isEmpty ? nil : Row(title: title, start: start, end: end, place: place)
        }
    }

    /// The same event twice (two tables, or a table and a list) once: the same title at the same
    /// time, or with one of them untimed; the timed one kept, with what the other adds. All day
    /// first, then by time, as found.
    static func dedupe(_ rows: [Row]) -> [Row] {
        var kept: [Row] = []
        for row in rows {
            let key = squeezed(row.title)
            if let i = kept.firstIndex(where: { squeezed($0.title) == key && ($0.start == row.start || $0.start == nil || row.start == nil) }) {
                let timedNow = kept[i].start == nil && row.start != nil
                var merged = timedNow ? row : kept[i]
                let other = timedNow ? kept[i] : row
                if merged.end == nil, merged.start == other.start { merged.end = other.end }
                merged.place = merged.place ?? other.place
                kept[i] = merged
            } else {
                kept.append(row)
            }
        }
        let order = kept.enumerated().sorted { a, b in
            switch (a.element.start, b.element.start) {
            case (nil, nil): a.offset < b.offset
            case (nil, _): true
            case (_, nil): false
            case let (x?, y?): x == y ? a.offset < b.offset : x < y
            }
        }
        return order.map(\.element)
    }

    // MARK: Times

    /// A time or a span at the start of `text`, in minutes into the day, and how much of the text
    /// it took: "10:00 AM", "10am", "Noon", "10:00 – 11:00", "9:30 AM–12 PM", "11–1 PM", "14:00".
    /// A bare hour counts only as a span's start ("9–12"). With no AM or PM, 1:00 to 6:59 are
    /// afternoon (a meeting brief's), unless written as 01:00; a start without one takes the end's.
    static func clock(_ text: String) -> (start: Int, end: Int?, length: Int)? {
        let pattern = /^(?<h1>\d{1,2})(?:[:.](?<m1>\d{2}))?\s*(?<p1>[AaPp]\.?\s?[Mm]\b\.?)?(?:\s*(?:[–—-]|to|until)\s*(?<h2>\d{1,2})(?:[:.](?<m2>\d{2}))?\s*(?<p2>[AaPp]\.?\s?[Mm]\b\.?)?)?/
        if let noon = text.firstMatch(of: /^(?i:noon|midday)\b/) { return (12 * 60, nil, text.distance(from: text.startIndex, to: noon.range.upperBound)) }
        guard let found = text.prefixMatch(of: pattern) else { return nil }
        let o = found.output
        // "10:00", "10 AM", a span ("9–12"): a time. A number alone ("3 meetings", "2026"): not.
        guard o.m1 != nil || o.p1 != nil || o.h2 != nil else { return nil }
        func hour(_ h: Substring, _ m: Substring?) -> (Int, Int)? {
            guard let h = Int(h), h <= 24, (m.flatMap { Int($0) } ?? 0) < 60 else { return nil }
            return (h, m.flatMap { Int($0) } ?? 0)
        }
        func pm(_ p: Substring?) -> Bool? { p.map { $0.lowercased().hasPrefix("p") } }
        func minutes(_ h: Int, _ m: Int, _ afternoon: Bool?, zero: Bool) -> Int {
            if let afternoon { return (h % 12 + (afternoon ? 12 : 0)) * 60 + m }
            if (1...6).contains(h), !zero { return (h + 12) * 60 + m }
            return h * 60 + m
        }
        guard let first = hour(o.h1, o.m1) else { return nil }
        let length = text.distance(from: text.startIndex, to: found.range.upperBound)
        guard let h2 = o.h2, let second = hour(h2, o.m2) else {
            return (minutes(first.0, first.1, pm(o.p1), zero: o.h1.hasPrefix("0")), nil, length)
        }
        let end = minutes(second.0, second.1, pm(o.p2), zero: h2.hasPrefix("0"))
        var start = minutes(first.0, first.1, pm(o.p1) ?? pm(o.p2), zero: o.h1.hasPrefix("0"))
        // "11–1 PM": the start in the morning, not at 11 at night.
        if o.p1 == nil, start > end, start - 12 * 60 >= 0, start - 12 * 60 < end { start -= 12 * 60 }
        return (start, end > start ? end : nil, length)
    }

    // MARK: Pieces

    /// Whether a line is a table's divider: "|---|:---:|".
    private static func isDivider(_ line: String) -> Bool {
        line.contains("-") && line.allSatisfy { "|-: ".contains($0) }
    }

    /// A table row's cells, as written.
    private static func rawCells(_ line: String) -> [String] {
        var inner = Substring(line)
        if inner.hasPrefix("|") { inner = inner.dropFirst() }
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func cells(_ line: String) -> [String] { rawCells(line).map(WeekPlan.plain) }

    /// "—", "-", "n/a", "none", "TBD": nothing written there.
    private static func isNone(_ text: String) -> Bool {
        let key = text.trimmingCharacters(in: CharacterSet(charactersIn: " .*_")).lowercased()
        return ["", "—", "–", "-", "--", "n/a", "na", "none", "no", "tbd", "tba", "null", "nil", "·"].contains(key)
    }

    /// A place or a link as written in a cell: a Markdown link's address, else its words.
    private static func placeText(_ written: String) -> String? {
        if let link = written.firstMatch(of: /\[[^\]]*\]\((?<url>[^)\s]+)\)/) { return String(link.output.url) }
        let text = WeekPlan.plain(written)
        return isNone(text) ? nil : String(text.prefix(200))
    }

    /// A title to compare: its letters and digits, lowercased.
    static func squeezed(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    // MARK: The words under the card

    /// A day's brief under its calendar card: without the schedule the card already shows (asked
    /// 2026-11-06: "No need to display this in the daily morning brief if the calendar card is
    /// already there"): its tables with a time column, its lines that start with a time or "All
    /// day", and the headings over them, or naming the day, or left with nothing under. What else it says (a conflict, what to
    /// prepare) stays. For showing only.
    static func withoutSchedule(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        var gone = Set<Int>()
        var i = 0
        while i < trimmed.count {
            if trimmed[i].hasPrefix("|"), i + 1 < trimmed.count, isDivider(trimmed[i + 1]),
               columns(cells(trimmed[i]).map { $0.lowercased() }) != nil {
                var end = i + 2
                while end < trimmed.count, trimmed[end].hasPrefix("|") { end += 1 }
                gone.formUnion(i ..< end)
                i = end
                continue
            }
            if !lineRows([trimmed[i]]).isEmpty { gone.insert(i) }
            i += 1
        }
        guard !gone.isEmpty else { return text }
        // A heading whose section is now empty: from the last heading up, so a heading over only
        // emptied headings goes too.
        func isHeading(_ line: String) -> Bool { line.hasPrefix("#") || (line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4) }
        for h in trimmed.indices.reversed() where isHeading(trimmed[h]) {
            let level = trimmed[h].prefix { $0 == "#" }.count
            var j = h + 1, empty = true
            while j < trimmed.count {
                let line = trimmed[j]
                if isHeading(line) {
                    let deeper = line.hasPrefix("#") && level > 0 && line.prefix { $0 == "#" }.count > level
                    if !deeper { break }
                }
                if !line.isEmpty, !gone.contains(j) { empty = false; break }
                j += 1
            }
            // A heading that names the day ("Today, Friday, November 6", "Morning Brief — Friday,
            // November 6"): the card's own title says it. One that led into the schedule
            // ("Meetings from 9:00 AM onwards:"): what it introduced is gone.
            let namesTheDay = date(in: trimmed[h], near: .now) != nil
            let ledIn = trimmed[(h + 1)...].firstIndex { !$0.isEmpty }.map { gone.contains($0) } ?? false
            if empty || namesTheDay || ledIn { gone.insert(h) }
        }
        var kept: [String] = []
        for (n, line) in lines.enumerated() where !gone.contains(n) {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, kept.last.map({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? true { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The model's own words before it

    /// The text to show for a briefing: without the model's narration ahead of the brief itself
    /// ("No attendees on the Bowling event. Now let me compile the brief." then "---"), when a
    /// rule comes within its first few short paragraphs and a heading follows. Any other text as
    /// it is. For showing only: the briefing's text is kept as it came.
    static func withoutNarration(_ text: String) -> String {
        withoutAnnouncement(beforeRule(text))
    }

    /// A short first paragraph that ends by announcing the report ("These are session logs, not a
    /// prior milestone record. I have enough. Let me report the findings.", 2026-11-08), when more
    /// follows: the model's working words. "Here's what changed:" leading into a list stays.
    static func withoutAnnouncement(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gap = trimmed.firstRange(of: /\n[ \t]*\n/) else { return text }
        let first = trimmed[..<gap.lowerBound].trimmingCharacters(in: .whitespaces)
        let rest = trimmed[gap.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty, first.count <= 300, !first.contains("\n"),
              String(first[(first.ranges(of: /[.:!?]\s+/).last?.upperBound ?? first.startIndex)...]).firstMatch(of: announcement) != nil
        else { return text }
        return rest
    }

    /// "Let me report the findings.", "Now I'll write up the summary:", "Time to compose the notification.",
    /// "Here is the evening wrap-up:" (not "Here's the update:", which leads into a finding).
    private static var announcement: Regex<AnyRegexOutput> {
        try! Regex(#"^(?:(?:now|ok(?:ay)?|alright|good|great|perfect|right)[,.!]?\s+)?(?:let me|let['’]s|let us|i['’]ll|i will|i['’]m going to|time to)\s+(?:now\s+)?(?:report|summari[sz]e|compose|write|draft|put|share|give|send|present|lay|deliver|prepare)\b(?:(?:\W+\w+){0,5}?\W+(?:findings|results|report|summary|update|notification|brief|briefing|answer|status|everything)\b|\W*$)|^(?:here['’]s|here is|below is)\s+(?:the|your|today['’]s|tonight['’]s|this (?:morning|evening|week)['’]s)\s+(?:\w+\s+){0,2}?(?:wrap-?up|brief|briefing|summary|report|notification|digest|rundown)\W*$"#)
            .ignoresCase()
    }

    private static func beforeRule(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var paragraphs = 0, characters = 0, inParagraph = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { inParagraph = false; continue }
            if line.wholeMatch(of: /([-*_])(?:\s*\1){2,}/) != nil {
                guard paragraphs > 0 else { return text }
                let rest = lines[(i + 1)...].drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard let next = rest.first?.trimmingCharacters(in: .whitespaces),
                      next.hasPrefix("#") || (next.hasPrefix("**") && next.hasSuffix("**") && next.count > 4) else { return text }
                return rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.hasPrefix("#") || line.hasPrefix("|") || line.hasPrefix("```") { return text }
            if !inParagraph { paragraphs += 1; inParagraph = true }
            characters += line.count
            if paragraphs > 3 || characters > 600 { return text }
        }
        return text
    }
}

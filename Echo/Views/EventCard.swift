import SwiftUI

/// A heads-up's event as a calendar card, at the top of its sheet (asked 2026-10-29: "is there a
/// way we could put a calendar type card on here for these messages?"): the day as Calendar's
/// icon draws it, what and when, how long until it starts, where (an address, or online and on
/// what, with Join when the words carry the meeting's link), when to leave, and the day opened in
/// Calendar. When it starts is what Redde's plugin sent (1.9, `u`), else read from the words
/// ("today at 12:30 PM EDT"); with neither there is no card.
struct EventCard: View {
    let briefing: AgentBriefing
    let starts: Date

    var body: some View {
        let online = EventDetails.online(in: briefing.text)
        CardBox {
            HStack(alignment: .top, spacing: 14) {
                badge
                VStack(alignment: .leading, spacing: 4) {
                    Text(briefing.heading).font(.headline).lineLimit(2)
                    TimelineView(.everyMinute) { context in
                        Text("\(starts.formatted(date: .omitted, time: .shortened)) · \(EventDetails.until(starts, now: Self.now(context.date)))")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let place = briefing.place, !place.isEmpty {
                        // Its links tappable: a meeting's place may be its link (asked 2026-10-30).
                        Label { Text(EventPlace.linked(place)) } icon: { Image(systemName: EventPlace.isAddress(place) ? "mappin.and.ellipse" : "location") }
                            .font(.subheadline).lineLimit(2)
                    } else if let online {
                        Label(online.service.map { String(localized: "Online · \($0)") } ?? String(localized: "Online"), systemImage: "video")
                            .font(.subheadline)
                    }
                    if let leave = briefing.leaveAt, leave > Self.now(.now) {
                        Label(String(localized: "Leave by \(leave.formatted(date: .omitted, time: .shortened))"), systemImage: "car")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                if let link = online?.link {
                    Link(destination: link) { Label("Join", systemImage: "video.fill") }
                        .font(.footnote.weight(.semibold))
                }
                Spacer(minLength: 0)
                if let calendar = EventDetails.calendarURL(for: starts) {
                    Link(destination: calendar) { Label("Open in Calendar", systemImage: "calendar") }
                        .font(.footnote.weight(.semibold))
                }
            }
        }
    }

    /// What it counts down from: the phone's clock, or the story's in the day's video (`DemoDay`).
    private static func now(_ clock: Date) -> Date {
        #if DEBUG
        if let story = DemoDay.storyNow { return story }
        #endif
        return clock
    }

    /// The day as Calendar's icon has it: the weekday in red over the date.
    private var badge: some View {
        VStack(spacing: 0) {
            Text(starts.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.caption2.weight(.bold)).foregroundStyle(.red)
            Text(starts.formatted(.dateTime.day()))
                .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
        }
        .frame(width: 54, height: 58)
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(starts.formatted(date: .complete, time: .omitted))
    }
}

/// What an event card reads from a heads-up's words.
nonisolated enum EventDetails {
    struct Online: Equatable, Sendable {
        /// "Zoom", "Google Meet", "Teams", "Webex", "FaceTime", where it's named.
        var service: String?
        /// The meeting's own link, where the words carry it.
        var link: URL?
    }

    private static let services: [(host: String, name: String)] = [
        ("zoom.us", "Zoom"), ("meet.google.com", "Google Meet"), ("teams.microsoft.com", "Teams"), ("teams.live.com", "Teams"),
        ("webex.com", "Webex"), ("facetime.apple.com", "FaceTime"), ("whereby.com", "Whereby"),
    ]

    /// Online, and on what: a meeting link's service, else one named in the words. Nil for an
    /// event that names no such thing.
    static func online(in text: String) -> Online? {
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, let host = url.host()?.lowercased() else { continue }
                if let service = services.first(where: { host == $0.host || host.hasSuffix("." + $0.host) }) {
                    return Online(service: service.name, link: url)
                }
            }
        }
        let lowered = text.lowercased()
        for name in ["Zoom", "Google Meet", "Teams", "Webex", "FaceTime", "Whereby"] where lowered.contains(name.lowercased()) {
            return Online(service: name, link: nil)
        }
        return lowered.contains("virtual") || lowered.contains("video call") ? Online(service: nil, link: nil) : nil
    }

    /// When the event starts, read from the words: the first time named that falls near when the
    /// heads-up came (from an hour before to a day and a half after).
    static func start(in text: String, near at: Date) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let plain = text.replacingOccurrences(of: "**", with: "")
        let range = NSRange(plain.startIndex..., in: plain)
        return detector.matches(in: plain, range: range).lazy.compactMap(\.date)
            .first { $0 > at.addingTimeInterval(-3600) && $0 < at.addingTimeInterval(36 * 3600) }
    }

    /// "in 28 min", "in 2 hr", "now", "started 5 min ago".
    static func until(_ starts: Date, now: Date = .now) -> String {
        let minutes = Int((starts.timeIntervalSince(now) / 60).rounded())
        if abs(minutes) < 1 { return String(localized: "now", comment: "An event card: it starts now") }
        let units: Set<Duration.UnitsFormatStyle.Unit> = abs(minutes) >= 120 ? [.hours, .minutes] : [.minutes]
        let span = Duration.seconds(abs(minutes) * 60).formatted(.units(allowed: units, width: .abbreviated))
        return minutes > 0 ? String(localized: "in \(span)", comment: "An event card: it starts in this long")
            : String(localized: "started \(span) ago", comment: "An event card: it started this long ago")
    }

    /// Calendar opened on that day and time (`calshow:`, seconds since 2001).
    static func calendarURL(for date: Date) -> URL? {
        URL(string: "calshow:\(Int(date.timeIntervalSinceReferenceDate))")
    }
}

extension AgentBriefing {
    /// When a heads-up's event starts: as the plugin sent it, else read from its words; read once.
    var startsAt: Date? {
        if let eventAt { return eventAt }
        guard isHeadsUp else { return nil }
        if let kept = Self.starts[id], kept.text == text { return kept.at }
        let at = EventDetails.start(in: text, near: self.at)
        Self.starts[id] = (text, at)
        return at
    }

    private static var starts: [String: (text: String, at: Date?)] = [:]
}

import EventKit
import Foundation

/// Appointments that come round again (plugin 1.54, `appointments.py`; asked 2026-11-26, "do 4":
/// "Redde learns your usual gap from past calendar events, like a haircut every 5 weeks or a
/// dentist visit every 6 months. When one is due and nothing is booked, it offers to book it or set
/// a reminder. After a doctor's visit, it asks whether there's a follow-up to schedule").
///
/// The calendar is on the phone, so it's read here: events of a few kinds of appointment, found by
/// their titles' words (haircut, dentist, vet…), go to the plugin as each kind's visits, when the
/// last ended, where, and the next one booked. Nothing else of the calendar leaves the device. The
/// plugin learns the usual gap and offers the cards (Settings › Your Day › Follow-Through ›
/// Appointments), the same from every device's find.
nonisolated enum Appointments {
    struct Event: Sendable, Equatable {
        var title: String
        var start: Date
        var end: Date
        var location: String? = nil
        var allDay = false
    }

    /// One kind, as the plugin is told it.
    struct Found: Codable, Equatable, Sendable {
        var kind: String
        var visits: [String]
        var ended: String?
        var next: String?
        var `where`: String?
    }

    /// How far back visits are read, and ahead for one booked.
    static let back: TimeInterval = 3 * 365 * 86400
    static let ahead: TimeInterval = 365 * 86400
    /// The newest visits of each kind sent.
    static let visits = 12
    /// How often a device sends what it found, per server.
    static let every: TimeInterval = 6 * 3600

    /// The kind of appointment a title is, by its words (English for now), or nil. The order
    /// matters: a nail salon before a hair salon, an eye doctor before a doctor, a dental
    /// check-up before a check-up. "Call the dentist" or "Book a haircut" is a job, not a visit.
    static func kind(of title: String) -> String? {
        let words = title.lowercased()
        if words.contains(/^\s*(call|book|schedule|re-?schedule|cancel|confirm|remind\w*|pay|email|text|ring)\b/) { return nil }
        if words.contains(/\b(nail salon|nails|manicure|pedicure|mani[- ]?pedi)\b/) { return "nails" }
        if words.contains(/\b(groomer|grooming)\b/) { return "grooming" }
        if words.contains(/\b(vet|vets|veterinar\w*|animal hospital)\b/) { return "vet" }
        if words.contains(/\b(dentist|dental|orthodont\w*|hygienist|teeth cleaning)\b/) { return "dentist" }
        if words.contains(/\b(eye exam|eye doctor|optometrist|ophthalmolog\w*|optician)\b/) { return "eyes" }
        if words.contains(/\b(dermatolog\w*|derm|skin check)\b/) { return "skin" }
        if words.contains(/\b(physio\w*|physical therapy|chiropract\w*)\b/) { return "physio" }
        if words.contains(/\bmassage\b/) { return "massage" }
        if words.contains(/\b(oil change|car service|tire rotation|car inspection|state inspection|mechanic)\b/) { return "car" }
        if words.contains(/\b(hair ?cut|barber\w*|hair salon|salon|hair appointment|hairdresser|hair stylist)\b/) { return "haircut" }
        if words.contains(/\b(doctor|dr\.?|physical|check-?up|annual exam|gp|pediatrician|paediatrician|primary care|well visit)\b/) { return "doctor" }
        return nil
    }

    /// What to tell the plugin of these events: each kind's past visits (the newest few), when
    /// the last one ended and where, and the soonest one booked ahead. All-day events aren't visits.
    static func found(_ events: [Event], now: Date) -> [Found] {
        var kinds: [String: [Event]] = [:]
        for event in events where !event.allDay {
            if let kind = kind(of: event.title) { kinds[kind, default: []].append(event) }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        return kinds.keys.sorted().compactMap { kind in
            let all = kinds[kind]!.sorted { $0.start < $1.start }
            let past = all.filter { $0.start <= now }
            let next = all.first { $0.start > now }
            guard let last = past.last else { return nil }   // only booked: nothing to learn from yet
            let place = last.location?.split(whereSeparator: \.isNewline).first
                .map { String($0).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
            return Found(kind: kind, visits: past.suffix(visits).map { iso.string(from: $0.start) },
                         ended: iso.string(from: last.end), next: next.map { iso.string(from: $0.start) }, where: place)
        }
    }

    /// The plugin's command for a device's find: `follow appts <device> <base64url JSON>`.
    static func line(device: String, _ found: [Found]) -> String? {
        guard let data = try? JSONEncoder().encode(found) else { return nil }
        let raw = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "follow appts \(device) \(raw)"
    }

    /// Full calendar access: what reading past events needs. Never asked for here.
    static var canRead: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// The events around now, from every calendar but birthdays and subscribed ones (holidays).
    static func read(now: Date) async -> [Event] {
        await CalendarReader.shared.read { store in
            // (EventKit finds events within four years at most: the past and the year ahead apart.)
            let spans = [(now.addingTimeInterval(-back), now), (now, now.addingTimeInterval(ahead))]
            let calendars = store.calendars(for: .event).filter { $0.type != .birthday && $0.type != .subscription }
            guard !calendars.isEmpty else { return [] }
            var seen = Set<String>()
            var events: [Event] = []
            for (from, to) in spans {
                for event in store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: calendars)) {
                    guard let start = event.startDate, let end = event.endDate,
                          seen.insert("\(event.calendarItemIdentifier)|\(start.timeIntervalSince1970)").inserted else { continue }
                    events.append(Event(title: event.title ?? "", start: start, end: end, location: event.location, allDay: event.isAllDay))
                }
            }
            return events
        }
    }

    private static let sentKey = "appointments.sent"
    private static let deviceKey = "appointments.device"

    /// Sends this device's find to the plugin, at most every six hours per server, with full calendar
    /// access only. A plugin before 1.54 doesn't know the command, and is asked again after as long.
    @MainActor
    static func send(now: Date = .now, defaults: UserDefaults = .standard,
                     server: String = Settings.shared.activeServerID.uuidString,
                     allowed: Bool = Appointments.canRead,
                     events: (@Sendable (Date) async -> [Event])? = nil,
                     command: PushService.PluginCommand? = nil) async {
        guard allowed else { return }
        var sent = defaults.dictionary(forKey: sentKey) as? [String: Double] ?? [:]
        if let at = sent[server], now.timeIntervalSince1970 - at < every, now.timeIntervalSince1970 >= at { return }
        let device: String
        if let id = defaults.string(forKey: deviceKey), !id.isEmpty {
            device = id
        } else {
            device = UUID().uuidString.lowercased()
            defaults.set(device, forKey: deviceKey)
        }
        let read = events ?? { await Appointments.read(now: $0) }
        guard let line = line(device: device, found(await read(now), now: now)) else { return }
        let run = command ?? PushService.command(over: .shared)
        guard (try? await run(line)) != nil else { return }   // unreached: asked again next time
        sent[server] = now.timeIntervalSince1970
        defaults.set(sent, forKey: sentKey)
    }
}

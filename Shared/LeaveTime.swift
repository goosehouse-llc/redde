import CoreLocation
import Foundation
import MapKit
import UserNotifications

/// When to leave for a heads-up's event (asked 2026-10-28, "Proactive": "Leave in 10 minutes, 25
/// minutes in traffic"): worked out on the iPhone, from where it is to the event's address, by
/// Apple Maps, as the heads-up arrives. Where the phone is never leaves it: the agent sent the
/// address; the phone adds the leaving time to the notification, sets a reminder for it, and the
/// Up Next widget counts down to it. Where the phone last was is kept in the app group, so the
/// notification extension has it when it can't ask for a fix of its own.
nonisolated enum LeaveTime {
    enum Mode: String, CaseIterable, Codable, Sendable, Identifiable {
        case driving, transit, walking, off
        var id: String { rawValue }
        var transport: MKDirectionsTransportType {
            switch self {
            case .transit: .transit
            case .walking: .walking
            default: .automobile
            }
        }
    }

    private static let modeKey = "leaveMode", placeKey = "lastPlace"
    /// Time kept in hand: there a few minutes early.
    static let spare: TimeInterval = 5 * 60
    /// How old a remembered place may be.
    static let placeKeptFor: TimeInterval = 12 * 3600
    static let reminderPrefix = "redde.leave."

    static func mode(in defaults: UserDefaults? = NeedsYou.shared) -> Mode {
        defaults?.string(forKey: modeKey).flatMap(Mode.init) ?? .driving
    }

    static func setMode(_ mode: Mode, in defaults: UserDefaults? = NeedsYou.shared) {
        defaults?.set(mode.rawValue, forKey: modeKey)
    }

    // MARK: Where the phone is

    static func remember(_ location: CLLocation, in defaults: UserDefaults? = NeedsYou.shared) {
        defaults?.set([location.coordinate.latitude, location.coordinate.longitude, location.timestamp.timeIntervalSince1970], forKey: placeKey)
    }

    static func lastKnown(in defaults: UserDefaults? = NeedsYou.shared, now: Date = .now) -> CLLocation? {
        guard let kept = defaults?.array(forKey: placeKey) as? [Double], kept.count == 3,
              now.timeIntervalSince1970 - kept[2] < placeKeptFor else { return nil }
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: kept[0], longitude: kept[1]), altitude: 0,
                          horizontalAccuracy: 100, verticalAccuracy: -1, timestamp: Date(timeIntervalSince1970: kept[2]))
    }

    /// The phone's own fix where it may ask, else where it last was.
    static func here(in defaults: UserDefaults? = NeedsYou.shared) -> CLLocation? {
        let manager = CLLocationManager()
        #if os(macOS)
        let allowed = manager.authorizationStatus == .authorizedAlways
        #else
        let allowed = [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus)
        #endif
        if allowed, let fix = manager.location, Date.now.timeIntervalSince(fix.timestamp) < placeKeptFor {
            remember(fix, in: defaults)
            return fix
        }
        return lastKnown(in: defaults)
    }

    // MARK: The way there

    /// How long the way there takes, arriving by `arriveBy`; nil when it can't be told.
    static func travel(from origin: CLLocation, to address: String, mode: Mode, arriveBy: Date) async -> TimeInterval? {
        let search = MKLocalSearch.Request()
        search.naturalLanguageQuery = address
        search.region = MKCoordinateRegion(center: origin.coordinate, latitudinalMeters: 200_000, longitudinalMeters: 200_000)
        guard let destination = try? await MKLocalSearch(request: search).start().mapItems.first else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(location: origin, address: nil)
        request.destination = destination
        request.transportType = mode.transport
        request.arrivalDate = arriveBy
        return try? await MKDirections(request: request).calculateETA().expectedTravelTime
    }

    static func leave(for event: Date, travel: TimeInterval) -> Date { event.addingTimeInterval(-travel - spare) }

    /// The line put first on the heads-up: "Leave by 2:05 PM · 25 min by car".
    static func line(leave: Date, travel: TimeInterval, mode: Mode, now: Date = .now) -> String {
        let minutes = max(1, Int((travel / 60).rounded()))
        let way = switch mode {
        case .transit: String(localized: "\(minutes) min by transit")
        case .walking: String(localized: "\(minutes) min on foot")
        default: String(localized: "\(minutes) min by car")
        }
        if leave <= now.addingTimeInterval(60) { return String(localized: "Leave now · \(way)") }
        return String(localized: "Leave by \(leave.formatted(date: .omitted, time: .shortened)) · \(way)")
    }

    /// A reminder at the leaving time, replacing one set for the same event.
    static func remind(event title: String, id: String, at leave: Date, travel: TimeInterval, mode: Mode,
                       center: UNUserNotificationCenter = .current(), now: Date = .now) {
        guard leave > now.addingTimeInterval(60) else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time to leave for \(title)")
        content.body = line(leave: leave, travel: travel, mode: mode, now: leave)
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "redde.leave"
        content.userInfo = [PushNote.taskKey: "brief"]
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: leave)
        center.add(UNNotificationRequest(identifier: reminderPrefix + id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }

    /// For a heads-up as it arrives: the line for its notification, its leaving time kept with
    /// it and a reminder set. Nil when there's no address, the way is off, or it can't be told.
    static func work(out briefing: AgentBriefing, in defaults: UserDefaults? = NeedsYou.shared) async -> String? {
        let mode = mode(in: defaults)
        guard mode != .off, let event = briefing.eventAt, event > .now, let address = briefing.place,
              EventPlace.isAddress(address), let origin = here(in: defaults),
              let travel = await travel(from: origin, to: address, mode: mode, arriveBy: event) else { return nil }
        let leave = leave(for: event, travel: travel)
        AgentBriefing.setLeave(briefing.id, at: leave, in: defaults)
        remind(event: briefing.heading, id: briefing.id, at: leave, travel: travel, mode: mode)
        return line(leave: leave, travel: travel, mode: mode)
    }
}

/// Whether an event's place is somewhere to go (asked 2026-10-30: "calendar events that do not
/// have an address, should not create a directions card"): a street address with its number, as
/// the system's address reader finds one, not a room ("Office · Room 4"), a meeting link or an
/// app's name, which Maps would otherwise search for and find somewhere. Read once per place.
nonisolated enum EventPlace {
    nonisolated(unsafe) private static let known = NSCache<NSString, NSNumber>()   // (NSCache is thread-safe)

    static func isAddress(_ place: String?) -> Bool {
        guard let place = place?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty,
              place.count < 400, place.contains(where: \.isNumber), !place.contains("://") else { return false }
        if let kept = known.object(forKey: place as NSString) { return kept.boolValue }
        var found = false
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue) {
            found = detector.matches(in: place, range: NSRange(place.startIndex..., in: place)).contains { match in
                // A street with a number, not a city or a state alone.
                match.addressComponents?[.street]?.contains(where: \.isNumber) ?? false
            }
        }
        known.setObject(NSNumber(value: found), forKey: place as NSString)
        return found
    }

    /// The links in an event's words (a meeting's, a document's), for a card to make tappable.
    static func linked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard text.contains("."), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let span = Range(match.range, in: text),
                  let lower = AttributedString.Index(span.lowerBound, within: out),
                  let upper = AttributedString.Index(span.upperBound, within: out) else { continue }
            out[lower..<upper].link = url
        }
        return out
    }
}

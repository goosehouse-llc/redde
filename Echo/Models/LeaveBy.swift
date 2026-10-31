import CoreLocation
import Foundation

/// Leave-By Alerts (asked 2026-10-30, approved: "worked out on the device, independent of the
/// agent and the server"): Redde reads the next day and a half of this device's calendars (the
/// ones chosen in Settings → Agent → Calendars), and for each event at a street address asks Apple
/// Maps how long the way there takes from where the device is, by the person's way of getting
/// about, with the traffic expected for arriving on time; a time-sensitive notification goes off
/// at the leaving time, a few minutes in hand, more for a longer way (`LeaveTime.spare`). Nothing
/// of it leaves the device but the two ends of the way, to Apple Maps. Off until turned on; this
/// device's own (not synced: the permissions are the device's). `LeaveByAlerts` runs it; what is
/// decided is here, testable.
///
/// The traffic re-check (asked 2026-10-30, "so the last minutes don't depend on iOS's background
/// schedule"): with the paired Hermes's Redde plugin 1.11 and its Dashboard login, the device asks
/// that Hermes to wake it twenty minutes before each leaving time (`wakes`, `wakeCommand`); the
/// notification extension then asks Apple Maps again and moves the alert (`LeaveCheck`). Hermes
/// learns an opaque id per alert, the event's title and the time; nothing else.
nonisolated enum LeaveBy {
    /// Settings' key; read straight from the defaults, so a background run has it too.
    static let key = "leaveByAlerts"
    /// What was worked out for each event, by its alert's identifier (`Worked`).
    static let workedKey = "leaveByWorked"
    /// Where Apple Maps found each address, so it is looked up once (`LeaveByAlerts`).
    static let placesKey = "leaveByPlaces"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// How far ahead the calendar is read.
    static let horizon: TimeInterval = 36 * 3600
    /// The least time between two runs, but for one something changed for (the calendar, a move,
    /// the switch).
    static let runEvery: TimeInterval = 10 * 60
    /// How far the device moves before every way is worked out again.
    static let movedFar: CLLocationDistance = 1000
    /// An event this close has its way worked out at every run (each at least `runEvery` apart,
    /// less for a forced one, `soonAgain`); one further off, once its estimate is `freshFor` old;
    /// one more than `farOff` away, every `farFreshFor`, since tomorrow's traffic changes little.
    static let soon: TimeInterval = 2 * 3600
    static let soonAgain: TimeInterval = 5 * 60
    static let freshFor: TimeInterval = 20 * 60
    static let farOff: TimeInterval = 12 * 3600
    static let farFreshFor: TimeInterval = 2 * 3600
    /// A leaving time this far gone still goes off at once ("Leave now"), if the event hasn't started.
    static let lateBy: TimeInterval = 2 * 60
    /// The background refresh comes this long before the soonest alert, to move it with the
    /// traffic; never sooner than `refreshAtLeast` from now, nor later than `refreshIdle`.
    static let refreshAhead: TimeInterval = 40 * 60
    static let refreshAtLeast: TimeInterval = 15 * 60
    static let refreshIdle: TimeInterval = 4 * 3600
    /// The most ways asked of Apple Maps in one run (it limits how often an app may ask).
    static let mostAsked = 12

    /// What its identifiers start with: a heads-up's reminders have `LeaveTime.reminderPrefix` alone.
    static let idPrefix = LeaveTime.alertPrefix
    /// The notification's button, and its category.
    static let mapsCategory = "redde.leave.maps"
    static let mapsAction = "redde.leave.openMaps"
    static let latitudeKey = LeaveTime.alertLatitudeKey, longitudeKey = LeaveTime.alertLongitudeKey, modeKey = LeaveTime.alertModeKey

    // MARK: Events

    /// A calendar event as read from EventKit, in plain values.
    struct Event: Equatable, Sendable {
        /// The calendar's own id for it; a repeating event's occurrences share it.
        var id: String
        var title: String
        var start: Date
        var place: String?
        /// Where it is, when the event was given a place from Maps (`EKStructuredLocation`).
        var latitude: Double?
        var longitude: Double?
        var calendar: String?
        var allDay = false
        var cancelled = false
        var declined = false

        /// Its alert's identifier: the event and its start, so each occurrence has its own and
        /// one moved to another time is another.
        var alertID: String { LeaveBy.alertID(event: id, start: start) }

        var coordinate: CLLocationCoordinate2D? {
            guard let latitude, let longitude, latitude != 0 || longitude != 0 else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    static func alertID(event: String, start: Date) -> String {
        idPrefix + event + "." + String(Int(start.timeIntervalSince1970))
    }

    /// The events to leave for, soonest first: not all-day, not declined or cancelled, not
    /// started, within the horizon, in a calendar shown (`CalendarChoice`), at a street address
    /// (`EventPlace`; a room, a meeting link or an app's name gets nothing).
    static func qualifying(_ events: [Event], chosen: [String], now: Date) -> [Event] {
        var seen = Set<String>()
        return events
            .filter { event in
                !event.allDay && !event.cancelled && !event.declined && event.start > now
                    && event.start <= now.addingTimeInterval(horizon)
                    && CalendarChoice.shows(event.calendar, among: chosen) && EventPlace.isAddress(event.place)
            }
            .sorted { $0.start < $1.start }
            .filter { seen.insert($0.alertID).inserted }
    }

    // MARK: Worked out

    /// What was worked out for an event, kept between runs.
    struct Worked: Codable, Equatable, Sendable {
        var title: String
        var start: Date
        var place: String
        var mode: LeaveTime.Mode
        /// Where the way was worked out from.
        var fromLatitude: Double
        var fromLongitude: Double
        /// And to.
        var toLatitude: Double
        var toLongitude: Double
        var travel: TimeInterval
        /// When Apple Maps was asked.
        var at: Date
        /// When its alert goes off (or went off, or a heads-up's for the same event does); nil
        /// while none is set.
        var alertAt: Date?

        var leave: Date { LeaveTime.leave(for: start, travel: travel, mode: mode) }
        var from: CLLocation { CLLocation(latitude: fromLatitude, longitude: fromLongitude) }
        var to: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: toLatitude, longitude: toLongitude) }

        /// Its alert has gone off, or its time went by: nothing more for it.
        func done(at now: Date) -> Bool { alertAt.map { $0 <= now } ?? false }
    }

    static func worked(in defaults: UserDefaults = .standard) -> [String: Worked] {
        defaults.data(forKey: workedKey).flatMap { try? JSONDecoder().decode([String: Worked].self, from: $0) } ?? [:]
    }

    static func keep(_ worked: [String: Worked], in defaults: UserDefaults = .standard) {
        if worked.isEmpty { defaults.removeObject(forKey: workedKey) } else { defaults.set(try? JSONEncoder().encode(worked), forKey: workedKey) }
    }

    // MARK: When to work it out

    /// A run, now: the first, one something changed for, or `runEvery` after the last.
    static func shouldRun(last: Date?, now: Date, forced: Bool) -> Bool {
        forced || last.map { now.timeIntervalSince($0) >= runEvery || now < $0 } ?? true
    }

    /// The way to this event is asked of Apple Maps again: never asked, its place, start or the
    /// way of getting about changed, the device moved far, or the last estimate is old for how
    /// soon the event is. Never for one whose alert went off: it goes off once.
    static func needsTravel(_ event: Event, worked: Worked?, from origin: CLLocation, mode: LeaveTime.Mode, now: Date) -> Bool {
        guard let worked else { return true }
        if worked.done(at: now) { return false }
        if worked.place != (event.place ?? "") || worked.mode != mode || abs(worked.start.timeIntervalSince(event.start)) >= 1
            || origin.distance(from: worked.from) > movedFar { return true }
        let age = now.timeIntervalSince(worked.at), until = event.start.timeIntervalSince(now)
        if until <= soon { return age >= soonAgain }
        return age >= (until > farOff ? farFreshFor : freshFor)
    }

    /// Where the device is: the newer of Current Location's kept place and the device's own (or
    /// last remembered) fix.
    static func origin(kept: CurrentLocation.Here?, here: CLLocation?) -> CLLocation? {
        let fromKept = kept.map { CLLocation(coordinate: $0.coordinate, altitude: 0, horizontalAccuracy: 100, verticalAccuracy: -1, timestamp: $0.at) }
        switch (fromKept, here) {
        case let (kept?, here?): return kept.timestamp > here.timestamp ? kept : here
        case let (kept?, nil): return kept
        case let (nil, here): return here
        }
    }

    // MARK: The plan

    /// An alert to set.
    struct Alert: Equatable, Sendable {
        var id: String
        var title: String
        var start: Date
        var leave: Date
        var travel: TimeInterval
        var mode: LeaveTime.Mode
        var to: CLLocationCoordinate2D
        /// When it was worked out.
        var worked: Date
        /// It goes off at once: the leaving time is now, or just went by.
        var now: Bool

        static func == (a: Alert, b: Alert) -> Bool {
            a.id == b.id && a.title == b.title && a.start == b.start && a.leave == b.leave && a.travel == b.travel && a.mode == b.mode
                && a.to.latitude == b.to.latitude && a.to.longitude == b.to.longitude && a.worked == b.worked && a.now == b.now
        }
    }

    struct Plan: Equatable, Sendable {
        /// The alerts to set, soonest first: ones already pending as they are needn't be set again.
        var alerts: [Alert] = []
        /// Pending requests to take away: alerts for events gone or moved, and heads-up reminders
        /// a fresher alert replaces.
        var remove: [String] = []
        /// What to keep for the next run.
        var worked: [String: Worked] = [:]
    }

    /// What to set and take away, from the events to leave for, what is worked out for them (new
    /// estimates already in), the heads-ups' reminders pending and this feature's own pending ids.
    /// A heads-up's reminder for the same event that was worked out later wins, and this one's
    /// alert is not set (its time is kept, so it never goes off later as well); otherwise the
    /// heads-up's goes. A leaving time already gone by goes off at once if it is less than
    /// `lateBy` gone and the event hasn't started; one further gone is let go.
    static func plan(events: [Event], worked: [String: Worked], headsUps: [LeaveTime.Reminder], pending: Set<String>, now: Date) -> Plan {
        var plan = Plan()
        for event in events {
            guard var kept = worked[event.alertID] else { continue }
            kept.title = event.title
            defer { plan.worked[event.alertID] = kept }
            if kept.done(at: now) { continue }
            let mine = LeaveTime.Reminder(id: event.alertID, title: event.title, start: event.start, fireAt: kept.leave, worked: kept.at)
            if let theirs = headsUps.first(where: { LeaveTime.sameEvent($0, mine) }) {
                if (theirs.worked, theirs.id) > (kept.at, mine.id) {
                    kept.alertAt = theirs.fireAt ?? now
                    continue
                }
                plan.remove.append(theirs.id)
            }
            let leave = kept.leave
            let alert = Alert(id: event.alertID, title: event.title, start: event.start, leave: leave, travel: kept.travel, mode: kept.mode,
                              to: kept.to, worked: kept.at, now: false)
            if leave > now.addingTimeInterval(60) {
                kept.alertAt = leave
                plan.alerts.append(alert)
            } else if leave >= now.addingTimeInterval(-lateBy), event.start > now {
                kept.alertAt = now
                var atOnce = alert
                atOnce.now = true
                plan.alerts.append(atOnce)
            } else {
                kept.alertAt = leave   // too late to be of use: let go
            }
        }
        let setting = Set(plan.alerts.map(\.id))
        plan.remove += pending.filter { $0.hasPrefix(idPrefix) && !setting.contains($0) }.sorted()
        return plan
    }

    // MARK: Next

    /// The background refresh: `refreshAhead` before the soonest alert still to go off, at least
    /// `refreshAtLeast` from now, at most `refreshIdle`.
    static func nextRefresh(after now: Date, alerts: [Date]) -> Date {
        let idle = now.addingTimeInterval(refreshIdle)
        guard let soonest = alerts.filter({ $0 > now }).min() else { return idle }
        return min(idle, max(now.addingTimeInterval(refreshAtLeast), soonest.addingTimeInterval(-refreshAhead)))
    }

    /// The next alert to go off, for the settings row: "Next: Dentist, leave by 2:05 PM".
    struct Next: Equatable, Sendable {
        var title: String
        var leave: Date
    }

    static func next(in worked: [String: Worked], now: Date) -> Next? {
        worked.values.filter { ($0.alertAt ?? .distantPast) > now && $0.start > now }
            .min { $0.alertAt! < $1.alertAt! }
            .map { Next(title: $0.title, leave: $0.alertAt!) }
    }

    // MARK: The traffic re-check

    /// A wake asked of the paired Hermes: at `at`, it sends this device a note to check the way to
    /// the event again (`LeaveCheck`). `id` is the alert's opaque id (`LeaveCheck.id(of:)`).
    struct Wake: Equatable, Sendable {
        var id: String
        var title: String
        var at: Date
    }

    /// The most wakes asked for (the plugin keeps as many a device).
    static let mostWakes = 30
    /// A leaving time this close gets no wake: there's no time left for one to help.
    static let wakeLeast: TimeInterval = 3 * 60

    /// The wakes for the alerts set, soonest first: each `LeaveCheck.ahead` before its leaving
    /// time. One whose time has gone by is asked for at once if its leaving time is still
    /// `wakeLeast` off and the estimate in hand is older than `soonAgain` (Apple Maps couldn't be
    /// asked just now); otherwise the estimate is as fresh as a check would make it, and none is.
    static func wakes(for alerts: [Alert], now: Date) -> [Wake] {
        let wakes = alerts.compactMap { alert -> Wake? in
            guard !alert.now else { return nil }
            var at = alert.leave.addingTimeInterval(-LeaveCheck.ahead)
            if at <= now {
                guard alert.leave > now.addingTimeInterval(wakeLeast), now.timeIntervalSince(alert.worked) >= soonAgain else { return nil }
                at = now
            }
            // To the minute, as the alert is: an estimate a few seconds off says nothing new.
            return Wake(id: LeaveCheck.id(of: alert.id), title: alert.title,
                        at: Date(timeIntervalSince1970: (at.timeIntervalSince1970 / 60).rounded(.down) * 60))
        }
        return Array(wakes.sorted { ($0.at, $0.id) < ($1.at, $1.id) }.prefix(mostWakes))
    }

    /// The plugin command that says all of this device's wakes (`/redde-push leave set <device ids>
    /// <wakes>`, base64url JSON of `i`, `t`, `w`), or cancels them when there are none. The device
    /// is named by its pairing ids; the plugin keeps the ones paired with it.
    static func wakeCommand(_ wakes: [Wake], devices: [String]) -> String {
        let ids = devices.joined(separator: ",")
        guard !wakes.isEmpty else { return "leave cancel \(ids)" }
        let listed: [[String: Any]] = wakes.map { ["i": $0.id, "t": $0.title, "w": Int($0.at.timeIntervalSince1970)] }
        let json = (try? JSONSerialization.data(withJSONObject: listed, options: [.sortedKeys])) ?? Data("[]".utf8)
        return "leave set \(ids) \(PushSeal.base64URL(json))"
    }

    /// What the notification extension found at its checks (`LeaveCheck.take`), into what is
    /// worked out: a newer estimate takes the place of the one kept (so the next run neither asks
    /// Apple Maps again nor sets the alert back), and an alert it set off at once has gone off.
    static func merge(_ checked: [String: LeaveCheck.Checked], into worked: [String: Worked]) -> [String: Worked] {
        var worked = worked
        for (id, check) in checked {
            guard var kept = worked[id] else { continue }
            if check.at > kept.at {
                kept.travel = check.travel
                kept.at = check.at
            }
            if let fired = check.fired { kept.alertAt = fired }
            worked[id] = kept
        }
        return worked
    }

    /// What was last said to each server's plugin about the wakes (`LeaveByAlerts`), so the same
    /// isn't said again; "unheard <seconds>" for a server whose plugin didn't take it then.
    static let wakesSaidKey = "leaveByWakesSaid"
    /// A plugin that didn't take the wakes (one from before 1.11) is asked again after this long.
    static let unheardFor: TimeInterval = 6 * 3600

    /// Whether to say `command` to a server's plugin, from what was said last.
    static func shouldSay(_ command: String, after said: String?, now: Date) -> Bool {
        guard let said else { return !command.hasPrefix("leave cancel ") }   // never asked: nothing to take back
        if said.hasPrefix("unheard "), let at = Double(said.dropFirst("unheard ".count)) {
            return now.timeIntervalSince1970 - at >= unheardFor
        }
        return said != command
    }
}

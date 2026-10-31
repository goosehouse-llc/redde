import CoreLocation
import CryptoKit
import Foundation
import UserNotifications

/// Leave-By Alerts' traffic re-check (asked 2026-10-30, "so the last minutes don't depend on iOS's
/// background schedule"): twenty minutes before a leaving time the paired Hermes sends this device
/// a note (`PushNote.Kind.leave`, `companion/hermes-plugin/redde-push/leave.py`), and the
/// notification extension, here, asks Apple Maps the way again (one estimate, from where the
/// device last was: the extension asks for no fix, and reads no calendar), moves the alert waiting
/// for that time (removed and added under its own identifier, as the app does), and shows one
/// notification of what came of it: quiet, unless the traffic moved the leaving time five minutes
/// or more earlier. What it found is kept in the app group for the app's next run (`take`).
///
/// The note names the alert by an opaque id (`id(of:)`), never by anything from the calendar but
/// its title. An alert gone since (the event deleted or moved: the app takes its wake back, but a
/// note may cross that) gets a one-line note that says only that the calendar was looked at:
/// iOS shows whatever a notification extension hands back.
nonisolated enum LeaveCheck {
    /// How long before the leaving time the device is woken.
    static let ahead: TimeInterval = 20 * 60
    /// A leaving time moved this much is said to be (heavier or lighter traffic).
    static let moved: TimeInterval = 5 * 60
    /// The app group's record of what the checks found, for the app (`Checked`).
    static let checkedKey = "leaveChecked"
    /// On the notification shown: what came of the check (`Outcome`'s raw value).
    static let outcomeKey = "leaveCheck"
    /// The most checks kept for the app.
    private static let mostKept = 40

    /// The opaque id the Hermes is told for an alert: sixteen hex digits of a hash of its
    /// identifier (which holds the calendar's own id for the event, and its start).
    static func id(of alertID: String) -> String {
        PushSeal.hex(SHA256.hash(data: Data("redde.leave.wake\n\(alertID)".utf8)).prefix(8))
    }

    // MARK: What came of it

    enum Outcome: String, Equatable, Sendable {
        /// Within five minutes of before: the alert moves to the fresh time, quietly.
        case same
        /// Five minutes or more earlier.
        case heavier
        /// Five minutes or more later.
        case lighter
        /// The fresh leaving time is now, or gone: this is the alert.
        case leaveNow
        /// Apple Maps couldn't be asked, or the device's place isn't known: the alert stays.
        case unchecked
        /// No alert waits for it any more.
        case gone
    }

    static func outcome(was: Date, now leave: Date?, at now: Date) -> Outcome {
        guard let leave else { return .unchecked }
        if leave <= now.addingTimeInterval(60) { return .leaveNow }
        let shift = leave.timeIntervalSince(was)
        if shift <= -moved { return .heavier }
        if shift >= moved { return .lighter }
        return .same
    }

    /// What the notification says: "Dentist: traffic checked" over "Leave by 2:05 PM · 25 min by
    /// car"; "Dentist: traffic is heavier" (time-sensitive) or "… lighter" over the new time; "Time
    /// to leave for Dentist" over "Leave now · 35 min by car" when that is now; the alert's own
    /// words when the traffic couldn't be checked; and for an alert gone, only "Leave-By Alerts
    /// checked your calendar."
    static func content(_ outcome: Outcome, title: String, leave: Date, travel: TimeInterval?, mode: LeaveTime.Mode,
                        alertBody: String = "", sound: Bool = NotificationSound.isOn) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = "redde.leave"
        content.interruptionLevel = .passive
        let line = travel.map { LeaveTime.line(leave: leave, travel: $0, mode: mode, now: .distantPast) } ?? alertBody
        switch outcome {
        case .same:
            content.title = String(localized: "\(title): traffic checked", comment: "Notification: Leave-By Alerts checked the traffic again for an event, by its title; the leaving time stays about the same")
            content.body = line
        case .heavier:
            content.title = String(localized: "\(title): traffic is heavier", comment: "Notification: Leave-By Alerts checked the traffic again for an event, by its title; leave earlier")
            content.body = line
            content.interruptionLevel = .timeSensitive
        case .lighter:
            content.title = String(localized: "\(title): traffic is lighter", comment: "Notification: Leave-By Alerts checked the traffic again for an event, by its title; leave later")
            content.body = line
        case .leaveNow:
            content.title = String(localized: "Time to leave for \(title)")
            content.body = travel.map { LeaveTime.line(leave: leave, travel: $0, mode: mode, now: leave) } ?? alertBody
            content.interruptionLevel = .timeSensitive
        case .unchecked:
            content.title = String(localized: "\(title): traffic couldn't be checked", comment: "Notification: Leave-By Alerts couldn't ask Apple Maps again for an event, by its title; its alert stays as it was")
            content.body = alertBody
        case .gone:
            content.body = String(localized: "Leave-By Alerts checked your calendar.", comment: "Notification: a traffic re-check found no alert waiting any more (the event was deleted or moved)")
        }
        content.sound = sound && content.interruptionLevel == .timeSensitive ? .default : nil
        content.userInfo = [PushNote.kindKey: PushNote.Kind.leave.rawValue, outcomeKey: outcome.rawValue]
        return content
    }

    // MARK: The check

    /// For the notification extension: the alert `wake` names, checked and moved, and what to
    /// show. One estimate from Apple Maps at most; nothing else from the network.
    static func run(wake: String, center: UNUserNotificationCenter = .current(), defaults: UserDefaults? = NeedsYou.shared,
                    now: Date = .now) async -> UNMutableNotificationContent {
        let pending = await center.pendingNotificationRequests()
        guard let request = pending.first(where: { $0.identifier.hasPrefix(LeaveTime.alertPrefix) && id(of: $0.identifier) == wake }),
              let alert = LeaveTime.reminder(request), let was = alert.fireAt, was > now, alert.start > now else {
            return content(.gone, title: "", leave: now, travel: nil, mode: .driving)
        }
        let info = request.content.userInfo
        let mode = (info[LeaveTime.alertModeKey] as? String).flatMap(LeaveTime.Mode.init) ?? .driving
        var travel: TimeInterval?
        if mode != .off, let latitude = info[LeaveTime.alertLatitudeKey] as? Double, let longitude = info[LeaveTime.alertLongitudeKey] as? Double,
           let origin = LeaveTime.here(in: defaults) {
            travel = await LeaveTime.travel(from: origin, to: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                            mode: mode, arriveBy: alert.start)
        }
        let leave = travel.map { LeaveTime.leave(for: alert.start, travel: $0, mode: mode) }
        let outcome = outcome(was: was, now: leave, at: now)
        let shown = content(outcome, title: alert.title, leave: leave ?? was, travel: travel, mode: mode, alertBody: request.content.body)
        // Open in Maps on it too, as on the alert.
        shown.categoryIdentifier = request.content.categoryIdentifier
        for key in [LeaveTime.alertLatitudeKey, LeaveTime.alertLongitudeKey, LeaveTime.alertModeKey] { shown.userInfo[key] = info[key] }
        guard let leave, let travel else { return shown }
        center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
        if outcome != .leaveNow, let moved = request.content.mutableCopy() as? UNMutableNotificationContent {
            moved.body = LeaveTime.line(leave: leave, travel: travel, mode: mode, now: .distantPast)
            moved.userInfo[LeaveTime.workedKey] = now.timeIntervalSince1970
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: leave)
            try? await center.add(UNNotificationRequest(identifier: request.identifier, content: moved,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
        keep(Checked(travel: travel, at: now, fired: outcome == .leaveNow ? now : nil), for: request.identifier, in: defaults)
        return shown
    }

    // MARK: For the app

    /// What a check found for an alert, kept in the app group until the app's next run.
    struct Checked: Codable, Equatable, Sendable {
        var travel: TimeInterval
        /// When Apple Maps was asked.
        var at: Date
        /// When the check set the alert off itself (its leaving time had come); nil when it moved it.
        var fired: Date?
    }

    static func keep(_ checked: Checked, for alertID: String, in defaults: UserDefaults? = NeedsYou.shared) {
        guard let defaults else { return }
        var all = kept(in: defaults)
        all[alertID] = checked
        if all.count > mostKept {
            for old in all.sorted(by: { $0.value.at < $1.value.at }).prefix(all.count - mostKept) { all[old.key] = nil }
        }
        defaults.set(try? JSONEncoder().encode(all), forKey: checkedKey)
    }

    static func kept(in defaults: UserDefaults? = NeedsYou.shared) -> [String: Checked] {
        defaults?.data(forKey: checkedKey).flatMap { try? JSONDecoder().decode([String: Checked].self, from: $0) } ?? [:]
    }

    /// What the checks found since the app last looked, by alert; taken, so each is merged once.
    static func take(in defaults: UserDefaults? = NeedsYou.shared) -> [String: Checked] {
        let found = kept(in: defaults)
        if !found.isEmpty { defaults?.removeObject(forKey: checkedKey) }
        return found
    }
}

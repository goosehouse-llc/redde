import CoreLocation
import EventKit
import Foundation
import MapKit
import UserNotifications
import os
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// Runs Leave-By Alerts (`LeaveBy`, asked 2026-10-30): when Redde comes forward (a moment after,
/// out of the first frames' way), when a heads-up arrives in front, when the calendar changes,
/// when Current Location finds the device has moved far, and in a background refresh shortly
/// before the next alert is due (the iPhone's; the Mac's while Redde runs, every `LeaveBy.runEvery`).
/// Cheap by design: a run at most every ten minutes unless something changed, the calendar read
/// off the main actor, each address looked up once, and a way asked of Apple Maps again only
/// when its inputs changed or its estimate is old for how soon the event is (`LeaveBy.needsTravel`).
/// Moving an alert replaces its pending request; an event gone or moved takes its alert with it.
///
/// And, where the paired Hermes has the Redde plugin 1.11 and Redde its Dashboard login, the
/// traffic re-check (asked 2026-10-30): each run that sets, moves or takes away alerts tells that
/// Hermes when to wake this device for each (`askForWakes`); the notification extension does the
/// check (`LeaveCheck`), and what it found is taken in at the next run. Over the Hermes API alone,
/// or with an older plugin, nothing is said and the alerts work as before.
@MainActor
@Observable
final class LeaveByAlerts {
    static let shared = LeaveByAlerts()

    /// What the device doesn't allow that alerts need, for the settings row to say.
    enum Missing: Hashable, Sendable { case calendar, location, notifications }

    /// The next alert to go off.
    private(set) var next: LeaveBy.Next?
    private(set) var missing: Set<Missing> = []
    /// Asking for the permissions, or a run under way.
    private(set) var working = false

    @ObservationIgnored private var lastRun: Date?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var runAgain = false
    @ObservationIgnored private var calendarObserver: NSObjectProtocol?
    @ObservationIgnored private var settle: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let reader = LeaveByCalendar()
    @ObservationIgnored private var places: [String: [Double]]
    @ObservationIgnored private let log = Logger(subsystem: "com.goosehouse.echo", category: "leaveby")
    /// The plugin's command on the Hermes in use, over its Dashboard (`askForWakes`).
    @ObservationIgnored var plugin: PushService.PluginCommand = PushService.command(over: .shared)

    /// The background refresh's identifier, in `BGTaskSchedulerPermittedIdentifiers`.
    nonisolated static let refreshID = "com.goosehouse.echo.leaveby"
    private static let mostPlaces = 40

    private init() {
        next = LeaveBy.next(in: LeaveBy.worked(), now: .now)
        places = UserDefaults.standard.dictionary(forKey: LeaveBy.placesKey) as? [String: [Double]] ?? [:]
    }

    // MARK: Turned on and off

    /// At launch: with the switch on, the calendar is followed (and, on the Mac, a run every ten minutes).
    func start() {
        guard LeaveBy.isOn else { return }
        follow()
    }

    /// The switch turned on or off. On, the calendar (full access), location (while using) and
    /// notifications are asked for where they never were, one after the other, and a run follows;
    /// off, every alert set is taken away and nothing worked out is kept.
    func turned(on: Bool) async {
        guard on else {
            stopFollowing()
            await Self.removeAllPending()
            LeaveBy.keep([:])
            next = nil
            missing = []
            lastRun = nil
            #if os(iOS)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
            #endif
            await askForWakes([], now: .now)   // and the Hermes wakes this device for none
            return
        }
        working = true
        var missing = Set<Missing>()
        if !(await DeviceCalendar.allowed(.event)) { missing.insert(.calendar) }
        if !(await CurrentLocationService.shared.askToUse()) { missing.insert(.location) }
        if !(await Self.notificationsAllowed(asking: true)) { missing.insert(.notifications) }
        self.missing = missing
        working = false
        follow()
        await run(force: true)
    }

    /// What the device allows, without asking (the settings page, as it appears).
    func check() async {
        guard LeaveBy.isOn else { missing = []; return }
        var missing = Set<Missing>()
        if ComposerContext.calendarAccess != .granted { missing.insert(.calendar) }
        if !CurrentLocationService.shared.allowed { missing.insert(.location) }
        if !(await Self.notificationsAllowed(asking: false)) { missing.insert(.notifications) }
        self.missing = missing
        next = LeaveBy.next(in: LeaveBy.worked(), now: .now)
    }

    // MARK: Reasons to run

    /// Redde came forward: a run, a moment later, if the last is ten minutes old.
    func cameForward() {
        guard LeaveBy.isOn else { return }
        soon(after: .seconds(1.5), force: false)
    }

    /// A heads-up arrived: its reminder and this alert for the same event become one.
    func headsUpArrived() {
        guard LeaveBy.isOn else { return }
        soon(after: .seconds(2), force: true)
    }

    /// Getting There changed: every way is worked out again by the new one (or, off, every alert goes).
    func wayChanged() {
        guard LeaveBy.isOn else { return }
        soon(after: .seconds(0.5), force: true)
    }

    /// A fresh fix (Current Location's): every way is worked out again if it is far from where
    /// the last ones were worked out from.
    func moved(to fix: CLLocation) {
        guard LeaveBy.isOn, let from = LeaveBy.worked().values.max(by: { $0.at < $1.at })?.from,
              fix.distance(from: from) > LeaveBy.movedFar else { return }
        soon(after: .seconds(1), force: true)
    }

    /// One run shortly, however many reasons come meanwhile (a calendar syncing posts many changes).
    private func soon(after delay: Duration, force: Bool) {
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await run(force: force)
        }
    }

    private func follow() {
        if calendarObserver == nil {
            calendarObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { LeaveByAlerts.shared.soon(after: .seconds(3), force: true) }
            }
        }
        #if os(macOS)
        // No background refresh on the Mac: while Redde runs, a run every ten minutes (most skip
        // Apple Maps altogether: nothing changed).
        if ticker == nil {
            ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(LeaveBy.runEvery))
                    guard !Task.isCancelled else { return }
                    await run(force: false)
                }
            }
        }
        #endif
    }

    private func stopFollowing() {
        if let calendarObserver { NotificationCenter.default.removeObserver(calendarObserver) }
        calendarObserver = nil
        ticker?.cancel()
        ticker = nil
        settle?.cancel()
    }

    // MARK: A run

    /// Reads the calendar, works out the ways that need it, and sets, moves and takes away the
    /// alerts. `force`: something changed, so the ten minutes between runs don't apply.
    func run(force: Bool, now: Date = .now) async {
        guard LeaveBy.isOn else { return }
        if running { runAgain = runAgain || force; return }
        let mode = LeaveTime.mode()
        #if os(iOS)
        // Locked since it was turned on, the calendar can't be read: it isn't empty, it is shut.
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        #endif
        guard mode != .off, ComposerContext.calendarAccess == .granted else {
            // Nothing can be worked out: no alert is left to go off at a time no longer right.
            await Self.removeAllPending()
            LeaveBy.keep([:])
            next = nil
            await askForWakes([], now: now)
            return
        }
        guard LeaveBy.shouldRun(last: lastRun, now: now, forced: force) else { return }
        running = true
        working = true
        defer {
            running = false
            working = false
        }
        lastRun = now

        let events = LeaveBy.qualifying(await reader.events(from: now, to: now.addingTimeInterval(LeaveBy.horizon)),
                                        chosen: CalendarChoice.chosen, now: now)
        // What the traffic re-checks found since (`LeaveCheck`): fresher estimates, and alerts
        // they set off themselves.
        var worked = LeaveBy.merge(LeaveCheck.take(), into: LeaveBy.worked())
        if let origin = LeaveBy.origin(kept: CurrentLocation.isOn ? CurrentLocation.kept() : nil, here: LeaveTime.here()) {
            var asked = 0
            for event in events where asked < LeaveBy.mostAsked
                && LeaveBy.needsTravel(event, worked: worked[event.alertID], from: origin, mode: mode, now: now) {
                guard !Task.isCancelled else { break }
                asked += 1
                guard let place = event.place, let to = await destination(of: event, near: origin),
                      let travel = await LeaveTime.travel(from: origin, to: to, mode: mode, arriveBy: event.start) else { continue }
                worked[event.alertID] = LeaveBy.Worked(
                    title: event.title, start: event.start, place: place, mode: mode,
                    fromLatitude: origin.coordinate.latitude, fromLongitude: origin.coordinate.longitude,
                    toLatitude: to.latitude, toLongitude: to.longitude, travel: travel, at: .now,
                    alertAt: worked[event.alertID]?.alertAt)
            }
        }
        let pending = await Self.pendingLeave()
        let plan = LeaveBy.plan(events: events, worked: worked, headsUps: pending.headsUps,
                                pending: Set(pending.mine.keys), now: .now)
        if !plan.remove.isEmpty { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: plan.remove) }
        for alert in plan.alerts where alert.now || pending.mine[alert.id] != Self.signature(alert) {
            await Self.set(alert)
        }
        LeaveBy.keep(plan.worked)
        next = LeaveBy.next(in: plan.worked, now: .now)
        log.notice("run: \(events.count) events at an address, \(plan.alerts.count) alerts, \(plan.remove.count) taken away")
        #if DEBUG
        for alert in plan.alerts {
            log.notice("alert \(alert.id, privacy: .public): \(alert.title, privacy: .public) leave \(alert.leave.formatted(date: .omitted, time: .shortened), privacy: .public) travel \(Int(alert.travel / 60)) min\(alert.now ? " (now)" : "", privacy: .public)")
        }
        #endif
        #if os(iOS)
        scheduleRefresh(alerts: plan.alerts.filter { !$0.now }.map(\.leave), now: .now)
        #endif
        await askForWakes(plan.alerts, now: .now)
        if runAgain {
            runAgain = false
            Task { await run(force: true) }
        }
    }

    /// Where the event is: its own place from Maps if it was given one, else its address as
    /// Apple Maps found it, looked up once and kept.
    private func destination(of event: LeaveBy.Event, near origin: CLLocation) async -> CLLocationCoordinate2D? {
        if let at = event.coordinate { return at }
        guard let address = event.place?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let kept = places[address], kept.count == 2 { return CLLocationCoordinate2D(latitude: kept[0], longitude: kept[1]) }
        guard let found = await LeaveTime.place(of: address, near: origin) else { return nil }
        if places.count >= Self.mostPlaces { places.removeAll() }
        places[address] = [found.latitude, found.longitude]
        UserDefaults.standard.set(places, forKey: LeaveBy.placesKey)
        return found
    }

    // MARK: The traffic re-check

    /// Tells the Hermes in use when to wake this device for each alert (`LeaveBy.wakes`), all of
    /// them each time they change, or none (turned off): a moved alert's wake replaces its old one,
    /// one taken away goes. Only over the Dashboard, with this device paired for notifications;
    /// once per change (`LeaveBy.shouldSay`). An older plugin answers with its usage line: it is
    /// left alone for a few hours, and the alerts go on as they always have. Nothing is shown.
    private func askForWakes(_ alerts: [LeaveBy.Alert], now: Date) async {
        let settings = Settings.shared
        let devices = PushService.shared.pairings.filter(\.isPaired).map(\.id)
        guard settings.serveBaseURL != nil, !devices.isEmpty else { return }
        let server = settings.activeServerID.uuidString   // (the plugin keeps them in the main home, whichever profile)
        let command = LeaveBy.wakeCommand(LeaveBy.wakes(for: alerts, now: now), devices: devices)
        var said = UserDefaults.standard.dictionary(forKey: LeaveBy.wakesSaidKey) as? [String: String] ?? [:]
        guard LeaveBy.shouldSay(command, after: said[server], now: now), await HermesServeClient.shared.canUse() else { return }
        do {
            let reply = try await plugin(command)
            said[server] = reply.hasPrefix("redde-push leave ") ? command : "unheard \(Int(now.timeIntervalSince1970))"
            log.notice("wakes: \(reply, privacy: .public)")
        } catch PushError.noPlugin {
            said[server] = "unheard \(Int(now.timeIntervalSince1970))"
        } catch {
            log.info("wakes not said: \(error.localizedDescription, privacy: .public)")   // unreachable: said at the next run
            return
        }
        UserDefaults.standard.set(said, forKey: LeaveBy.wakesSaidKey)
    }

    /// A traffic re-check's notification arrived with Redde in front (or reached it unopened): what
    /// it found is taken in, or the app checks itself.
    func trafficCheckArrived() {
        guard LeaveBy.isOn else { return }
        soon(after: .seconds(1), force: true)
    }

    // MARK: Notifications

    /// This feature's pending alerts (by id, with what they say and when), and the heads-ups'
    /// leaving reminders, read in one go.
    private nonisolated static func pendingLeave() async -> (mine: [String: String], headsUps: [LeaveTime.Reminder]) {
        var mine: [String: String] = [:], headsUps: [LeaveTime.Reminder] = []
        for request in await UNUserNotificationCenter.current().pendingNotificationRequests()
        where request.identifier.hasPrefix(LeaveTime.reminderPrefix) {
            if request.identifier.hasPrefix(LeaveBy.idPrefix) {
                let at = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                mine[request.identifier] = signature(title: request.content.title, body: request.content.body, at: at)
            } else if let reminder = LeaveTime.reminder(request) {
                headsUps.append(reminder)
            }
        }
        return (mine, headsUps)
    }

    /// What tells a pending alert apart from the one to set: same words, same minute.
    private nonisolated static func signature(title: String, body: String, at: Date?) -> String {
        "\(title)\u{1F}\(body)\u{1F}\(at.map { Int($0.timeIntervalSince1970 / 60) } ?? -1)"
    }

    private nonisolated static func signature(_ alert: LeaveBy.Alert) -> String {
        let content = content(for: alert)
        return signature(title: content.title, body: content.body, at: alert.leave)
    }

    /// "Time to leave for Dentist", "Leave by 2:05 PM · 25 min by car" (which still reads right
    /// in Notification Center later), or "Leave now · …" for one that goes off at once.
    private nonisolated static func content(for alert: LeaveBy.Alert) -> UNMutableNotificationContent {
        let content = LeaveTime.content(event: alert.title, startsAt: alert.start, leave: alert.leave, travel: alert.travel,
                                        mode: alert.mode, worked: alert.worked, saying: alert.now ? alert.leave : .distantPast)
        content.categoryIdentifier = LeaveBy.mapsCategory
        content.userInfo[LeaveBy.latitudeKey] = alert.to.latitude
        content.userInfo[LeaveBy.longitudeKey] = alert.to.longitude
        content.userInfo[LeaveBy.modeKey] = alert.mode.rawValue
        content.sound = NotificationSound.isOn ? .default : nil
        return content
    }

    /// Sets an alert, replacing the one pending for the same event: at the leaving time, to the
    /// minute, or at once.
    private nonisolated static func set(_ alert: LeaveBy.Alert) async {
        let trigger: UNNotificationTrigger? = alert.now ? nil : UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: alert.leave), repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.id, content: content(for: alert), trigger: trigger))
    }

    /// Takes away this feature's pending alerts, leaving the heads-ups' reminders.
    private nonisolated static func removeAllPending() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(LeaveBy.idPrefix) }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
    }

    /// Whether notifications may be shown, asking the first time when `asking`.
    private static func notificationsAllowed(asking: Bool) async -> Bool {
        switch await notificationStatus() {
        case .authorized, .provisional, .ephemeral: return true
        // Never asked (turned on elsewhere, or the answer is still to come): not refused.
        case .notDetermined: return asking ? await Notifier.shared.requestAuthorization() : true
        default: return false
        }
    }

    private nonisolated static func notificationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: Open in Maps

    /// The notification's Open in Maps: the way there in Apple Maps, by the way the alert was worked out.
    static func openInMaps(title: String?, latitude: Double, longitude: Double, mode: String?) {
        let item = MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
        item.name = title
        let way = switch LeaveTime.Mode(rawValue: mode ?? "") {
        case .transit: MKLaunchOptionsDirectionsModeTransit
        case .walking: MKLaunchOptionsDirectionsModeWalking
        default: MKLaunchOptionsDirectionsModeDriving
        }
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: way])
    }

    // MARK: Background refresh (the iPhone's)

    #if os(iOS)
    /// At launch, before it finishes (`PushDelegate`). The handler is called off the main actor's
    /// executor by the scheduler, so it is formed here, nonisolated; it runs on the main queue.
    nonisolated static func registerRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: .main) { task in
            nonisolated(unsafe) let task = task
            let work = Task { @MainActor in
                await LeaveByAlerts.shared.run(force: true)
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// The next refresh, before the soonest alert (or in a few hours, for events added meanwhile).
    private func scheduleRefresh(alerts: [Date], now: Date) {
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        request.earliestBeginDate = LeaveBy.nextRefresh(after: now, alerts: alerts)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.info("refresh not accepted: \(error.localizedDescription, privacy: .public)")   // the simulator refuses it
        }
    }
    #endif
}

/// This device's calendars, read off the main actor with one store kept for the life of the app
/// (making one is the dear part).
actor LeaveByCalendar {
    private var store: EKEventStore?

    /// The events from `start` to `end` in every calendar, in plain values; none without full access.
    func events(from start: Date, to end: Date) -> [LeaveBy.Event] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = store ?? EKEventStore()
        self.store = store
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).map { event in
            let at = event.structuredLocation?.geoLocation?.coordinate
            return LeaveBy.Event(
                id: event.eventIdentifier ?? event.calendarItemIdentifier, title: event.title ?? "", start: event.startDate,
                place: event.location, latitude: at?.latitude, longitude: at?.longitude, calendar: event.calendar?.title,
                allDay: event.isAllDay, cancelled: event.status == .canceled,
                declined: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false)
        }
    }
}

import EventKit
import SwiftUI

/// Each calendar's own colour as Calendar shows it, by title, from this device's calendars
/// (asked 2026-11-05: "By Calendar should match the actual calendar"). Read once Redde may see the
/// calendars, again when they change. A calendar card names its events' calendars by title (the
/// agent's are on the server), so a title this device doesn't have gets no colour here.
@Observable
final class CalendarTints {
    static let shared = CalendarTints()

    /// Lowercased title → colour. Two calendars with one title (the same team in two accounts):
    /// the first Calendar lists.
    var tints: [String: Color] = [:]
    @ObservationIgnored private var loaded: Bool
    @ObservationIgnored private var changes: NSObjectProtocol?
    @ObservationIgnored private var store: EKEventStore?

    /// `reads`: false for a test's own colours, never replaced by the device's calendars.
    init(reads: Bool = true) { loaded = !reads }

    /// The calendar's colour, or nil when this device has no calendar by that title or Redde may
    /// not see the calendars.
    func color(of calendar: String) -> Color? {
        if !loaded { load() }
        return tints[calendar.lowercased()]
    }

    /// Reads the colours when Redde may see the calendars; otherwise waits to be asked again.
    func load() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        loaded = true
        let store = store ?? EKEventStore()
        self.store = store
        var found: [String: Color] = [:]
        for calendar in store.calendars(for: .event) where found[calendar.title.lowercased()] == nil {
            found[calendar.title.lowercased()] = Color(cgColor: calendar.cgColor)
        }
        if found != tints { tints = found }
        if changes == nil {
            changes = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
                MainActor.assumeIsolated { CalendarTints.shared.load() }
            }
        }
    }
}

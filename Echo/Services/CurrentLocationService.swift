import CoreLocation
import Foundation
import MapKit

/// Keeps where the person is for `CurrentLocation` (Settings → Agent → Current Location, asked
/// 2026-10-30): one fix at a time, at reduced accuracy, asked for when the setting is turned on and
/// when Redde comes forward (at most every `CurrentLocation.askEvery`), and when a place question
/// is sent with the kept place gone stale; never followed, never in the background. Each new fix is
/// put in words once (Apple's maps), and kept with them, rounded; sending reads what is kept and
/// never waits. The fix also goes to `LeaveTime.remember`, for the places card's walks and the
/// heads-ups' leaving times.
@MainActor
@Observable
final class CurrentLocationService: NSObject, CLLocationManagerDelegate {
    static let shared = CurrentLocationService()

    private(set) var authorization: CLAuthorizationStatus
    /// What the agent is told, as last found: the settings row shows it.
    private(set) var kept: CurrentLocation.Here?
    /// A fix is being asked for or put in words.
    private(set) var finding = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var lastAsked: Date?
    @ObservationIgnored private var naming: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        kept = CurrentLocation.kept(in: defaults)
        authorization = manager.authorizationStatus
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.delegate = self
    }

    /// Location allowed for Redde: on the Mac, a granted app is "always" allowed.
    var allowed: Bool {
        #if os(macOS)
        authorization == .authorizedAlways
        #else
        authorization == .authorizedAlways || authorization == .authorizedWhenInUse
        #endif
    }

    var refused: Bool { authorization == .denied || authorization == .restricted }

    /// When the kept place was last found, for a card to measure again from it; nil with the
    /// setting off, without making the service (and its location manager) then.
    static var fixedAt: Date? { CurrentLocation.isOn ? shared.kept?.at : nil }

    // MARK: Asked for

    /// The setting turned on or off. On, the permission is asked for the first time, and a fix
    /// right after; off, the place kept is forgotten.
    func turned(on: Bool) {
        guard on else {
            naming?.cancel()
            CurrentLocation.forget(in: defaults)
            kept = nil
            finding = false
            return
        }
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            refresh(force: true)
        }
    }

    /// Redde came forward: a fresh fix, if the last is a few minutes old.
    func cameForward() {
        authorization = manager.authorizationStatus
        refresh()
    }

    /// A fix, once, unless one was asked for or taken in the last few minutes, or one is on its way.
    func refresh(force: Bool = false, now: Date = .now) {
        guard CurrentLocation.isOn, allowed, !finding else { return }
        if !force {
            if let lastAsked, now.timeIntervalSince(lastAsked) < CurrentLocation.askEvery { return }
            if let kept, now.timeIntervalSince(kept.at) < CurrentLocation.askEvery { return }
        }
        lastAsked = now
        finding = true
        manager.requestLocation()
    }

    // MARK: Found

    private func found(_ fix: CLLocation) {
        LeaveTime.remember(fix)
        guard CurrentLocation.isOn else { finding = false; return }
        // Not far from the place in words already: the same words, at the new time.
        if let kept, kept.words != nil,
           fix.distance(from: CLLocation(latitude: kept.latitude, longitude: kept.longitude)) < CurrentLocation.movedFar {
            store(.init(words: kept.words, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, at: fix.timestamp))
            finding = false
            return
        }
        naming?.cancel()
        naming = Task {
            let words = await Self.words(for: fix)
            guard !Task.isCancelled, CurrentLocation.isOn else { return }
            store(.init(words: words, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, at: fix.timestamp))
            finding = false
        }
    }

    private func store(_ here: CurrentLocation.Here) {
        kept = here
        CurrentLocation.keep(here, in: defaults)
    }

    /// The place in words, as Apple's maps name it, in English (the words go to the model, as
    /// Redde's other notes do); nil where it can't be (offline, or nothing found).
    private static func words(for fix: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: fix) else { return nil }
        request.preferredLocale = Locale(identifier: "en_US")
        guard let item = try? await request.mapItems.first else { return nil }
        let town = item.addressRepresentations?.cityWithContext(.short) ?? item.addressRepresentations?.cityName
        return CurrentLocation.words(neighbourhood: neighbourhood(of: item), town: town)
    }

    /// The neighbourhood ("Thornton Park"): only the item's placemark names it, which iOS 26 marks
    /// deprecated (its replacements go from the street to the town, with nothing in between), so
    /// it's read by name where the item still has one, without the warning the build refuses.
    private static func neighbourhood(of item: MKMapItem) -> String? {
        guard item.responds(to: NSSelectorFromString("placemark")) else { return nil }
        return (item.value(forKey: "placemark") as? CLPlacemark)?.subLocality
    }

    // MARK: CLLocationManagerDelegate (nonisolated: CoreLocation calls these off the main actor)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let was = allowed
            authorization = status
            // Just allowed, with the setting on: where the person is, now. Taken back: nothing kept.
            if allowed, !was { refresh(force: true) }
            if refused, kept != nil {
                CurrentLocation.forget(in: defaults)
                kept = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        Task { @MainActor in found(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in finding = false }
    }
}

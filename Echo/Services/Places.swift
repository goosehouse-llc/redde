import CoreLocation
import Foundation
#if canImport(UIKit)
import UIKit

/// The time iOS gives a woken app, handed back once.
@MainActor
final class BackgroundTime: @unchecked Sendable {
    var id = UIBackgroundTaskIdentifier.invalid
    nonisolated func end() {
        Task { @MainActor in
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
#endif

/// Places (asked 2026-10-28, "Proactive"): arriving at or leaving a place the person set in Redde
/// (Home, Work, the gym) tells the agent or bot they chose, with what they wrote for it, without a
/// Shortcuts automation. The iPhone watches a circle round each place (CoreLocation's region
/// monitoring, which wakes Redde when it is closed); where the person is stays on the phone, and
/// the server hears only "arrived at Home". The answer comes as a notification when it comes
/// within the time iOS gives a woken app; else it is in the bot's chat. iPhone only.
nonisolated struct PlaceAction: Codable, Equatable, Sendable {
    /// The bot's profile ("default", the main agent).
    var profile: String
    var message: String
}

nonisolated struct WatchedPlace: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    /// Metres.
    var radius: Double = 150
    var arrive: PlaceAction?
    var leave: PlaceAction?

    /// What goes to the agent for `arrived` or left, with what it is told of it. Words to the
    /// model: English, as Redde's other notes are.
    func message(arrived: Bool) -> (text: String, note: String)? {
        guard let action = arrived ? arrive : leave, !action.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let note = "\n\n[Redde: sent because the user just \(arrived ? "arrived at" : "left") \(name), as they set in Redde's Places; "
            + "they aren't looking at this chat. Keep it short: your answer comes to them as a notification.]"
        return (action.message, note)
    }
}

#if os(iOS)
@MainActor
@Observable
final class Places: NSObject, CLLocationManagerDelegate {
    static let shared = Places()

    private(set) var places: [WatchedPlace]
    private(set) var authorization: CLAuthorizationStatus
    /// A place's last known side of its circle (inside or not), so a place newly watched, or the
    /// app newly started, doesn't count where it already is as an arrival.
    private var inside: [UUID: Bool]
    private let manager = CLLocationManager()
    private var monitor: CLMonitor?
    private var making: Task<CLMonitor, Never>?
    private var listening: Task<Void, Never>?
    private var located: CheckedContinuation<CLLocation?, Never>?

    private static let placesKey = "places", insideKey = "placesInside"
    static let most = 20
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        places = defaults.data(forKey: Self.placesKey).flatMap { try? JSONDecoder().decode([WatchedPlace].self, from: $0) } ?? []
        inside = (defaults.dictionary(forKey: Self.insideKey) as? [String: Bool] ?? [:])
            .reduce(into: [:]) { out, pair in if let id = UUID(uuidString: pair.key) { out[id] = pair.value } }
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var allowedAlways: Bool { authorization == .authorizedAlways }

    // MARK: Places

    func save(_ place: WatchedPlace) {
        if let i = places.firstIndex(where: { $0.id == place.id }) { places[i] = place } else { places.append(place) }
        inside[place.id] = nil   // its side is learned afresh
        store()
        Task { await watch() }
    }

    func remove(_ place: WatchedPlace) {
        places.removeAll { $0.id == place.id }
        inside[place.id] = nil
        store()
        Task { await watch() }
    }

    private func store() {
        defaults.set(try? JSONEncoder().encode(places), forKey: Self.placesKey)
        defaults.set(Dictionary(uniqueKeysWithValues: inside.map { ($0.key.uuidString, $0.value) }), forKey: Self.insideKey)
    }

    // MARK: Permission and where the phone is

    /// Asks for "While Using" then "Always", which watching places when Redde is closed needs.
    func askPermission() {
        switch authorization {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    /// Where the phone last was, kept on the phone for working out when to leave (`LeaveTime`):
    /// what iOS already has, asked for nothing new. Each time Redde comes forward.
    func noteWhereThePhoneIs() {
        guard [.authorizedAlways, .authorizedWhenInUse].contains(authorization), let fix = manager.location else { return }
        LeaveTime.remember(fix)
    }

    /// Where the phone is now, once.
    func here() async -> CLLocation? {
        if authorization == .notDetermined { askPermission() }
        located?.resume(returning: nil)
        return await withCheckedContinuation { continuation in
            located = continuation
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            authorization = status
            if status == .authorizedWhenInUse { self.manager.requestAlwaysAuthorization() }
            await watch()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        if let last { LeaveTime.remember(last) }
        Task { @MainActor in located?.resume(returning: last); located = nil }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in located?.resume(returning: nil); located = nil }
    }

    // MARK: Watching

    /// At launch, and after any change: the circles the monitor watches are the places, and its
    /// events are listened to (iOS wakes Redde for them when it is closed; they come here).
    func start() { Task { await watch() } }

    /// The one monitor, made once: CoreLocation aborts when a second is made with the same name,
    /// and making one waits, so two `watch()`es at once (a place saved as permission comes back,
    /// 2026-10-28) both found none and both made one. They share the making now.
    private func theMonitor() async -> CLMonitor {
        if let monitor { return monitor }
        if let making { return await making.value }
        // Letters and digits only: iOS 27 aborts on "redde.places" ("Monitor name is not valid").
        let task = Task { await CLMonitor("ReddePlaces") }
        making = task
        let made = await task.value
        monitor = made
        return made
    }

    private func watch() async {
        guard !places.isEmpty, authorization == .authorizedAlways || authorization == .authorizedWhenInUse else {
            if let monitor { for id in await monitor.identifiers { await monitor.remove(id) } }
            return
        }
        let monitor = await theMonitor()
        let wanted = Set(places.map(\.id.uuidString))
        for id in await monitor.identifiers where !wanted.contains(id) { await monitor.remove(id) }
        for place in places {
            let circle = CLMonitor.CircularGeographicCondition(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                                                               radius: max(100, place.radius))
            await monitor.add(circle, identifier: place.id.uuidString, assuming: .unknown)
        }
        guard listening == nil else { return }
        listening = Task { [weak self] in
            do {
                for try await event in await monitor.events {
                    guard let self, let id = UUID(uuidString: event.identifier) else { continue }
                    switch event.state {
                    case .satisfied: await crossed(id, now: true)
                    case .unsatisfied: await crossed(id, now: false)
                    default: continue
                    }
                }
            } catch {}
        }
    }

    /// A place's circle crossed, or its side learned. Only a change from a known side is an
    /// arrival or a leaving.
    private func crossed(_ id: UUID, now isInside: Bool) async {
        let before = inside[id]
        inside[id] = isInside
        store()
        guard let before, before != isInside, let place = places.first(where: { $0.id == id }),
              let (text, note) = place.message(arrived: isInside) else { return }
        await fire(place, arrived: isInside, text: text, note: note)
    }

    /// Tells the bot, waiting as long as iOS lets a woken app (about half a minute): its answer
    /// as a notification, or, cut short, left to go on in its chat.
    private func fire(_ place: WatchedPlace, arrived: Bool, text: String, note: String) async {
        guard let action = arrived ? place.arrive : place.leave else { return }
        let background = BackgroundTime()
        background.id = UIApplication.shared.beginBackgroundTask(withName: "redde.place") { background.end() }
        defer { background.end() }
        let departure = TurnDeparture()
        let asking = Task { () -> (String, String)? in
            if BotDirectory.available() {
                return try? await BotTrigger.run(action.profile, text, note: note, departure: departure)
            }
            // No bots on this connection: the agent, in Redde's Shortcuts chat.
            return (try? await ShortcutRunner.ask(text + note)).map { (Settings.shared.headerTitle, $0) }
        }
        let timer = Task { try? await Task.sleep(for: .seconds(25)); departure.leave(); asking.cancel() }
        let answer = await asking.value
        timer.cancel()
        if let (name, said) = answer, !said.isEmpty {
            await BotTrigger.post(said, from: name, profile: action.profile)
        }
    }
}
#endif

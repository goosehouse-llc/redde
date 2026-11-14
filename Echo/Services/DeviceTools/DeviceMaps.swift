import CoreLocation
import Foundation
import MapKit

/// Maps for the agent (asked 2026-11-13, the first thing on the build list): places near the
/// person or near a place they name, how long the way there takes with the traffic now, its
/// turns, and Apple Maps opened to go there. Apple Maps answers, as it does in Maps itself; the
/// agent hears places, times and distances, and where the phone is only as how far each place is
/// from it. Without Location for Redde, a place to search near (`near`, `from`) still works.
nonisolated enum DeviceMaps {
    /// How the person goes: the agent's word for it, and Apple Maps'.
    enum Mode: String, CaseIterable, Sendable {
        case driving, walking, transit, cycling

        init(_ said: String?) {
            switch said?.lowercased() ?? "" {
            case "walking", "walk", "foot": self = .walking
            case "transit", "public transit", "bus", "train", "subway": self = .transit
            case "cycling", "bike", "bicycle", "cycle": self = .cycling
            default: self = .driving
            }
        }

        var transport: MKDirectionsTransportType {
            switch self {
            case .driving: .automobile
            case .walking: .walking
            case .transit: .transit
            case .cycling: .cycling
            }
        }

        /// Apple Maps' own launch option.
        var launch: String {
            switch self {
            case .driving: MKLaunchOptionsDirectionsModeDriving
            case .walking: MKLaunchOptionsDirectionsModeWalking
            case .transit: MKLaunchOptionsDirectionsModeTransit
            case .cycling: MKLaunchOptionsDirectionsModeCycling
            }
        }

        /// maps.apple.com's `dirflg`.
        var flag: String {
            switch self {
            case .driving: "d"
            case .walking: "w"
            case .transit: "r"
            case .cycling: "c"
            }
        }
    }

    /// Where a search or a way starts: a place found from the agent's words, or the phone.
    struct Origin {
        var location: CLLocation
        /// "the iPhone's location", or the place found ("Lake Eola Park, Orlando").
        var said: String
    }

    // MARK: Tools

    /// `phone_maps_search`: `query`, `near`, `radius_km`, `limit`.
    static func search(_ args: JSONValue) async throws -> JSONValue {
        let query = try args.required("query")
        let origin = try await origin(near: args["near"]?.string)
        let radius = min(max(args["radius_km"]?.number ?? 10, 0.5), 100) * 1000
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: origin.location.coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        let items: [MKMapItem]
        do {
            items = try await MKLocalSearch(request: request).start().mapItems
        } catch {
            throw DeviceToolError("Apple Maps found nothing for “\(query)” near \(origin.said).")
        }
        let limit = args.limit(default: 5, most: 10)
        let places = items.prefix(limit).map { place($0, from: origin.location) }
        return .object([
            "near": .string(origin.said),
            "places": .array(places),
            "note": .string("Apple Maps' places. To show them, use a 'places' card with each one's name, address and coordinates."),
        ])
    }

    /// `phone_maps_directions`: `to`, `from`, `mode`, `arrive_by` or `depart_at`, `steps`.
    static func directions(_ args: JSONValue) async throws -> JSONValue {
        let origin = try await origin(near: args["from"]?.string)
        let destination = try await item(for: args.required("to"), near: origin)
        let mode = Mode(args["mode"]?.string)
        let request = MKDirections.Request()
        request.source = MKMapItem(location: origin.location, address: nil)
        request.destination = destination
        request.transportType = mode.transport
        if let arrive = try args.date("arrive_by") { request.arrivalDate = arrive }
        else if let depart = try args.date("depart_at") { request.departureDate = depart }
        var answer: [String: JSONValue] = [
            "from": .string(origin.said),
            "to": place(destination, from: origin.location),
            "mode": .string(mode.rawValue),
            "maps_url": .string(directionsURL(to: destination, mode: mode).absoluteString),
        ]
        // Transit: Apple Maps gives apps its time, not its route.
        if mode == .transit {
            guard let eta = try? await MKDirections(request: request).calculateETA() else {
                throw DeviceToolError("Apple Maps has no transit times for that way.")
            }
            answer["routes"] = .array([.object([
                "travel_time": .string(duration(eta.expectedTravelTime)),
                "minutes": .number((eta.expectedTravelTime / 60).rounded()),
                "distance": .string(distance(eta.distance)),
                "depart": .string(DeviceDates.string(eta.expectedDepartureDate)),
                "arrive": .string(DeviceDates.string(eta.expectedArrivalDate)),
            ])])
            return .object(answer)
        }
        request.requestsAlternateRoutes = args["alternatives"]?.bool ?? false
        let routes: [MKRoute]
        do {
            routes = try await MKDirections(request: request).calculate().routes
        } catch {
            throw DeviceToolError("Apple Maps found no \(mode.rawValue) way from \(origin.said) to \(destination.name ?? "there").")
        }
        let withSteps = args["steps"]?.bool ?? false
        let start = request.departureDate ?? .now
        answer["routes"] = .array(routes.prefix(3).map { route in
            var one: [String: JSONValue] = [
                "name": .string(route.name),
                "travel_time": .string(duration(route.expectedTravelTime)),
                "minutes": .number((route.expectedTravelTime / 60).rounded()),
                "distance": .string(distance(route.distance)),
                "arrive": .string(DeviceDates.string(request.arrivalDate ?? start.addingTimeInterval(route.expectedTravelTime))),
            ]
            if route.hasTolls { one["tolls"] = .bool(true) }
            if route.hasHighways { one["highways"] = .bool(true) }
            if !route.advisoryNotices.isEmpty { one["notices"] = .array(route.advisoryNotices.map { .string($0) }) }
            if withSteps {
                one["steps"] = .array(route.steps.filter { !$0.instructions.isEmpty }.prefix(25).map { step in
                    .object(["do": .string(step.instructions), "for": .string(distance(step.distance))])
                })
            }
            return .object(one)
        })
        return .object(answer)
    }

    /// `phone_maps_open`: `to`, `mode`. Apple Maps opens on the phone with the way there, ready to
    /// go; only with Redde on the screen (iOS opens apps for the one in front).
    @MainActor
    static func open(_ args: JSONValue) async throws -> JSONValue {
        let origin = try? await origin(near: nil)
        let destination = try await item(for: args.required("to"), near: origin)
        let mode = Mode(args["mode"]?.string)
        #if os(macOS)
        let opened = await destination.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.launch])
        #else
        let opened = destination.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.launch])
        #endif
        guard opened else { throw DeviceToolError("Apple Maps didn't open on the iPhone.") }
        return .object(["opened": .bool(true), "to": place(destination, from: origin?.location), "mode": .string(mode.rawValue)])
    }

    // MARK: Places

    /// Where to start: the place the agent named, else where the phone is.
    static func origin(near said: String?) async throws -> Origin {
        if let said = said?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty, !Self.meansHere(said) {
            let here = await phone()
            let found = try await item(for: said, near: here.map { Origin(location: $0, said: "") })
            guard let location = found.location as CLLocation? else { throw DeviceToolError("Apple Maps couldn't place “\(said)”.") }
            return Origin(location: location, said: [found.name, address(of: found)].compactMap(\.self).joined(separator: ", "))
        }
        guard let here = await phone() else {
            throw DeviceToolError("Where the iPhone is isn't known: Location is off for Redde, or no fix came. Give a place to start from (near or from).")
        }
        return Origin(location: here, said: "the iPhone's location")
    }

    /// "here", "me", "my location": the phone.
    static func meansHere(_ said: String) -> Bool {
        ["here", "me", "my location", "current location", "where i am"].contains(said.lowercased().trimmingCharacters(in: .punctuationCharacters))
    }

    /// A place from words ("Lake Eola Park", "123 Main St, Orlando") or coordinates ("28.54,-81.37").
    static func item(for said: String, near origin: Origin?) async throws -> MKMapItem {
        if let coordinate = coordinate(said) {
            return MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = said
        if let origin {
            request.region = MKCoordinateRegion(center: origin.location.coordinate, latitudinalMeters: 200_000, longitudinalMeters: 200_000)
        }
        guard let found = try? await MKLocalSearch(request: request).start().mapItems.first else {
            throw DeviceToolError("Apple Maps couldn't find “\(said)”.")
        }
        return found
    }

    /// "28.5383, -81.3792" as a coordinate; nil for anything else.
    static func coordinate(_ said: String) -> CLLocationCoordinate2D? {
        let parts = said.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              (-90 ... 90).contains(lat), (-180 ... 180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// A place as the agent reads it.
    static func place(_ item: MKMapItem, from origin: CLLocation?) -> JSONValue {
        let location = item.location
        var out: [String: JSONValue] = [
            "latitude": .number((location.coordinate.latitude * 100_000).rounded() / 100_000),
            "longitude": .number((location.coordinate.longitude * 100_000).rounded() / 100_000),
        ]
        if let name = item.name { out["name"] = .string(name) }
        if let address = address(of: item) { out["address"] = .string(address) }
        if let category = category(item.pointOfInterestCategory) { out["category"] = .string(category) }
        if let origin { out["distance"] = .string(distance(location.distance(from: origin))) }
        if let phone = item.phoneNumber, !phone.isEmpty { out["phone"] = .string(phone) }
        if let url = item.url { out["website"] = .string(url.absoluteString) }
        return .object(out)
    }

    static func address(of item: MKMapItem) -> String? {
        (item.address?.fullAddress ?? item.address?.shortAddress)?
            .replacingOccurrences(of: "\n", with: ", ").trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    /// "MKPOICategoryNationalPark" as "national park".
    static func category(_ category: MKPointOfInterestCategory?) -> String? {
        guard let raw = category?.rawValue.replacingOccurrences(of: "MKPOICategory", with: ""), !raw.isEmpty else { return nil }
        var words = ""
        for character in raw {
            if character.isUppercase, let last = words.last, last.isLowercase { words.append(" ") }
            words.append(character)
        }
        return words.lowercased()
    }

    /// Apple Maps' page for the way there, for a card's or a reply's link.
    static func directionsURL(to item: MKMapItem, mode: Mode) -> URL {
        var parts = URLComponents(string: "https://maps.apple.com/")!
        let c = item.location.coordinate
        parts.queryItems = [URLQueryItem(name: "daddr", value: "\(c.latitude),\(c.longitude)"), URLQueryItem(name: "dirflg", value: mode.flag)]
            + (item.name.map { [URLQueryItem(name: "q", value: $0)] } ?? [])
        return parts.url!
    }

    // MARK: Words

    /// "25 min", "1 hr 10 min".
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(60, (seconds / 60).rounded() * 60)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// "1.2 mi", "350 m": in the person's units, the agent's language.
    static func distance(_ meters: CLLocationDistance, locale: Locale = .current) -> String {
        // English, in the person's units: miles on US and UK roads, kilometres elsewhere.
        let english = Locale(identifier: locale.measurementSystem == .us ? "en_US" : locale.measurementSystem == .uk ? "en_GB" : "en_150")
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0 ... 1))).locale(english))
    }

    // MARK: Where the phone is

    /// A fix now if Redde may have one (a few seconds at most), else the last one kept; nil
    /// without Location for Redde.
    static func phone(wait: Duration = .seconds(6)) async -> CLLocation? {
        let status = CLLocationManager().authorizationStatus
        #if os(macOS)
        guard status == .authorizedAlways else { return LeaveTime.lastKnown() }
        #else
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return nil }
        #endif
        let fresh = await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { return location }
                        if Task.isCancelled { return nil }
                    }
                } catch {}
                return nil
            }
            group.addTask { try? await Task.sleep(for: wait); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let fresh { LeaveTime.remember(fresh); return fresh }
        return LeaveTime.here()
    }
}

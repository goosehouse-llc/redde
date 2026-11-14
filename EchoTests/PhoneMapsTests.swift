import CoreLocation
import Foundation
import MapKit
import Testing
@testable import Echo

/// Maps for the agent (2026-11-13): the tools are filed under Maps, opening Apple Maps needs the
/// person in front of it, the agent's words are read leniently, and what it hears is in words.
/// `liveLookups` asks Apple Maps itself; it runs only with `TEST_RUNNER_REDDE_LIVE_MAPS=1`.
struct PhoneMapsTests {
    @Test func theToolsAreMapsAndOpeningIsDoneInFrontOfThePerson() {
        #expect([DeviceTool.mapsSearch, .mapsDirections, .mapsOpen].allSatisfy { $0.area == .maps })
        #expect(DeviceTool.mapsOpen.asksItself && !DeviceTool.mapsSearch.asksItself && !DeviceTool.mapsDirections.asksItself)
        let changing = [DeviceTool.mapsSearch, .mapsDirections, .mapsOpen].filter(\.changes)
        #expect(changing.isEmpty, "nothing of the person's changes")
        #expect(DeviceArea.maps.offersAsking && DeviceArea.maps.agentLabel == "Maps")
    }

    @Test func theAgentsWordsAreReadLeniently() {
        #expect(DeviceMaps.Mode("walk") == .walking && DeviceMaps.Mode("Bus") == .transit && DeviceMaps.Mode("bike") == .cycling)
        #expect(DeviceMaps.Mode(nil) == .driving && DeviceMaps.Mode("car") == .driving)
        let c = DeviceMaps.coordinate("28.5383, -81.3792")
        #expect(c?.latitude == 28.5383 && c?.longitude == -81.3792)
        #expect(DeviceMaps.coordinate("Lake Eola Park") == nil && DeviceMaps.coordinate("100, 200") == nil)
        #expect(DeviceMaps.meansHere("Here") && DeviceMaps.meansHere("my location") && !DeviceMaps.meansHere("Home Depot"))
    }

    @Test func whatTheAgentHearsIsInWords() {
        #expect(DeviceMaps.category(.nationalPark) == "national park" && DeviceMaps.category(.cafe) == "cafe" && DeviceMaps.category(nil) == nil)
        #expect(DeviceMaps.distance(1609.344, locale: Locale(identifier: "en_US")) == "1 mi")
        #expect(DeviceMaps.distance(2500, locale: Locale(identifier: "fr_FR")) == "2.5 km")
        #expect(DeviceMaps.duration(25 * 60) == "25 min")
        #expect(DeviceMaps.duration(70 * 60) == "1 hr, 10 min")
        let url = DeviceMaps.directionsURL(to: MKMapItem(location: CLLocation(latitude: 28.5, longitude: -81.4), address: nil), mode: .walking)
        #expect(url.absoluteString.hasPrefix("https://maps.apple.com/?daddr=28.5,-81.4&dirflg=w"))
    }

    @Test func thePersonIsAskedInPlainWords() {
        let search = DeviceAsk(.mapsSearch, .object(["query": .string("coffee")]))
        #expect(search.title == "Look up places in Apple Maps" && search.detail == "“coffee” near your iPhone")
        let way = DeviceAsk(.mapsDirections, .object(["to": .string("Lake Eola Park"), "from": .string("the office")]))
        #expect(way.title == "Work out the way to “Lake Eola Park”" && way.detail == "From “the office”")
        #expect(DeviceAsk(.mapsOpen, .object(["to": .string("MCO")])).title == "Open Apple Maps to “MCO”")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDDE_LIVE_MAPS"] == "1"))
    func liveLookups() async throws {
        let found = try await DeviceMaps.search(.object(["query": .string("coffee"), "near": .string("Lake Eola Park, Orlando, FL"), "limit": .number(3)]))
        let places = try #require(found["places"]?.array)
        #expect(!places.isEmpty && places.count <= 3)
        #expect(places.allSatisfy { $0["name"]?.string != nil && $0["distance"]?.string != nil })
        #expect(found["near"]?.string?.contains("Lake Eola") == true)

        let way = try await DeviceMaps.directions(.object(["to": .string("Orlando International Airport"), "from": .string("Lake Eola Park, Orlando, FL"),
                                                           "steps": .bool(true)]))
        let route = try #require(way["routes"]?.array?.first)
        #expect((route["minutes"]?.number ?? 0) > 5 && route["steps"]?.array?.isEmpty == false)
        let walk = try await DeviceMaps.directions(.object(["to": .string("28.5463,-81.3726"), "from": .string("Lake Eola Park, Orlando, FL"), "mode": .string("walking")]))
        #expect(walk["mode"]?.string == "walking" && walk["routes"]?.array?.count == 1)
        print("maps live:", found, way["routes"]?.array?.first?["travel_time"] ?? "")
    }
}

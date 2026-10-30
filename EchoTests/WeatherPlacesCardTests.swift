import Foundation
import Testing
@testable import Echo

/// The weather and places cards' new look (asked 2026-10-30): the hours' gusts and when the
/// forecast was read, the rain callout worked out from the hours, and what a place's row shows
/// (its price, whether it is open, the agent's pick), all read leniently and only where given.
@MainActor
struct WeatherPlacesCardTests {
    private func json(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }

    private func places(_ text: String) throws -> ReplyCard.Places {
        guard case let .places(list) = try #require(ReplyCards.parse(json(text)).first) else { throw CardError.notThatCard }
        return list
    }

    private func weather(_ text: String) throws -> ReplyCard.Weather {
        guard case let .weather(w) = try #require(ReplyCards.parse(json(text)).first) else { throw CardError.notThatCard }
        return w
    }

    private enum CardError: Error { case notThatCard }

    // MARK: Places

    @Test func aPlaceSaysItsPriceItsHoursAndThePick() throws {
        let list = try places(#"""
        {"cards": [{"type": "places", "places": [
          {"name": "Rossio Roasters", "price": "$$", "rating": 4.7, "hours": "Open until 9 PM", "pick": true},
          {"name": "Tram 28 Café", "price_level": 1, "closes": "5 PM"},
          {"name": "Alfama Bean", "price": "3", "open_until": "7 PM", "best": false},
          {"name": "Lineage", "price": "very dear indeed", "open_now": false},
          {"name": "Foxtail", "price_level": 9, "status": "Closes soon"}]}]}
        """#)
        let p = list.places
        #expect(p[0].price == "$$" && p[0].hours == "Open until 9 PM" && p[0].pick == true && p[0].opening == .open)
        #expect(p[1].price == "$" && p[1].hours == "Closes at 5 PM" && p[1].opening == .closing, "a level as dollar signs, a closing time in words")
        #expect(p[2].price == "$$$" && p[2].hours == "Open until 7 PM" && p[2].pick == nil)
        #expect(p[3].price == nil && p[3].hours == nil && p[3].open == false && p[3].opening == .closed, "words too long for a price are dropped")
        #expect(p[4].price == nil && p[4].opening == .closing)
        #expect(list.lead?.name == "Rossio Roasters")
    }

    @Test func directionsGoToThePickElseTheFirst() throws {
        #expect(try places(#"{"type": "places", "places": ["A", {"name": "B", "pick": true}]}"#).lead?.name == "B")
        #expect(try places(#"{"type": "places", "places": ["A", "B"]}"#).lead?.name == "A")
    }

    @Test func openOrNotFromTheWords() {
        func opening(_ hours: String?, open: Bool? = nil) -> ReplyCard.Place.Opening? {
            var place = ReplyCard.Place(name: "X")
            place.hours = hours
            place.open = open
            return place.opening
        }
        #expect(opening("Open 24 hours") == .open && opening("open now") == .open)
        #expect(opening("Closing in 20 min") == .closing && opening("Closed today") == .closed && opening("Temporarily closed now") == .closed)
        #expect(opening("Mon–Fri 8–6") == nil, "words that don't say: no colour")
        #expect(opening(nil, open: true) == .open && opening(nil) == nil)
    }

    // MARK: Weather

    @Test func hoursCarryTheirGustsAndTheCardWhenItWasRead() throws {
        let w = try weather(#"""
        {"type": "weather", "place": "Orlando", "units": "F", "updated": "2026-10-23T17:45:00-04:00",
         "hours": [{"time": "2026-10-23T17:00", "temperature": 77, "condition": "clear", "precipitation": "40%", "gusts": "18"},
                   {"time": "18:00", "temperature": 75, "condition": "rain", "chance_of_rain": 140, "wind_gusts": -3}]}
        """#)
        #expect(w.hours[0].gusts == 18 && w.hours[0].precipitation == 40)
        #expect(w.hours[1].precipitation == 100 && w.hours[1].gusts == nil, "a chance is a percentage; a gust isn't below nothing")
        #expect(w.updatedAt == ISO8601DateFormatter().date(from: "2026-10-23T21:45:00Z"))
        #expect(try weather(#"{"type": "weather", "place": "X", "updated": "17:45", "now": {"temperature": 3, "condition": "snow"}}"#).updatedAt == nil,
                "without its offset, when it was read can't be told")
    }

    @Test func anHourAsItIsWritten() {
        let clock = ReplyCard.Weather.clock
        #expect(clock("2026-10-23T14:00")! == (14, 0) && clock("14:30")! == (14, 30))
        #expect(clock("2 PM")! == (14, 0) && clock("2pm")! == (14, 0) && clock("12 a.m.")! == (0, 0) && clock("12 PM")! == (12, 0))
        #expect(clock("2026-10-23T17:45:00-04:00")! == (17, 45) && clock("09:05:00Z")! == (9, 5))
        #expect(clock("14") == nil && clock("25:00") == nil && clock("13 PM") == nil && clock("tonight") == nil && clock("2026-10-23") == nil)
    }

    private func hours(_ chances: [Int?], conditions: [String]? = nil, gusts: [Double?]? = nil) -> ReplyCard.Weather {
        let list = chances.enumerated().map { i, chance in
            ReplyCard.Weather.Hour(time: String(format: "%02d:00", 12 + i), temperature: 20,
                                   condition: ReplyCard.Condition(lenient: conditions?[i] ?? "cloudy"), precipitation: chance, gusts: gusts?[i] ?? nil)
        }
        return .init(place: "X", units: "F", hours: list, days: [])
    }

    @Test func rainComingIsTheFirstRunOfLikelyHours() throws {
        let storms = try #require(hours([10, 20, 55, 80, 75, 40, 60, 5], conditions: ["clear", "clear", "rain", "thunderstorm", "rain", "rain", "rain", "clear"],
                                        gusts: [8, 9, 20, 31, 26, nil, 40, 5]).spell)
        #expect(storms == .init(first: 2, last: 4, peak: 3, chance: 80, kind: .storms, gusts: 31, open: false),
                "the first run only, its likeliest hour, and the strongest gust in it")
        let open = try #require(hours([0, 0, 50, 70], conditions: ["clear", "clear", "snow", "snow"]).spell)
        #expect(open.kind == .snow && open.open && open.gusts == nil, "to the last hour there is: when it ends isn't known")
        #expect(hours([10, 40, 49, nil]).spell == nil)
        #expect(hours([]).spell == nil)
    }

    @Test func aCardSavedBeforeStillReads() throws {
        // Saved without the new fields, as every card was: they come back empty.
        let saved = Data(#"{"weather":{"_0":{"place":"Lisbon","units":"C","hours":[{"time":"10:00","temperature":19,"condition":"rain"}],"days":[]}}}"#.utf8)
        guard case let .weather(w) = try JSONDecoder().decode(ReplyCard.self, from: saved) else { Issue.record("not weather"); return }
        #expect(w.updated == nil && w.hours[0].gusts == nil)
        let place = Data(#"{"places":{"_0":{"places":[{"name":"A","rating":4.5}]}}}"#.utf8)
        guard case let .places(list) = try JSONDecoder().decode(ReplyCard.self, from: place) else { Issue.record("not places"); return }
        #expect(list.places[0].pick == nil && list.places[0].price == nil && list.lead?.name == "A")
    }

    // MARK: Looked up on the phone

    @Test func openMeteosHoursBringTheirGustsAndTheReadingItsTime() throws {
        let answer = json(#"""
        {"utc_offset_seconds": -14400,
         "current": {"time": "2026-10-23T17:45", "temperature_2m": 75.5, "weather_code": 0, "is_day": 1},
         "hourly": {"time": ["2026-10-23T17:00", "2026-10-23T18:00"], "temperature_2m": [77.3, 74.9], "weather_code": [0, 95],
                    "precipitation_probability": [0, 70], "is_day": [1, 1], "wind_gusts_10m": [18.6, 33.1]},
         "daily": {"time": ["2026-10-23"], "weather_code": [0], "temperature_2m_max": [81.9], "temperature_2m_min": [64]}}
        """#)
        let card = try #require(OpenMeteo.weather(answer, place: "Orlando FL", units: "F"))
        #expect(card.hours.map(\.gusts) == [18.6, 33.1])
        #expect(card.updated == "2026-10-23T17:45:00-04:00")
        #expect(card.spell?.kind == .storms && card.spell?.open == true)
        #expect(OpenMeteo.url(at: .init(latitude: 28.5, longitude: -81.4), units: "F").absoluteString.contains("wind_gusts_10m"))
        #expect(OpenMeteo.stamp("2026-10-23T17:45", offset: 19800) == "2026-10-23T17:45:00+05:30")
        #expect(OpenMeteo.stamp("2026-10-23T17:45", offset: nil) == nil)
    }
}

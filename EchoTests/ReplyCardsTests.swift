import Foundation
import Testing
@testable import Echo

/// A reply's cards (`ReplyCards`, `redde_show`): read leniently from the call's arguments, kept
/// as JSON on the step, shown live as the call is made, and found again when a conversation is
/// read back from either connection. Weather and time cards filled from the plugin's answer, or
/// looked up on the phone (`CardLookup`, faked here: no test reaches MapKit or the network).
@MainActor
struct ReplyCardsTests {
    private func json(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }

    @Test func aMapARouteAndItsPlaces() throws {
        let cards = ReplyCards.parse(json(#"""
        {"cards": [{"type": "map", "title": "To the café", "route": {"mode": "Walking", "from": "here",
          "to": {"name": "Rossio Roasters", "address": "Rua das Portas 136", "lat": "38.7176", "lng": -9.1404}}},
          {"type": "map", "places": ["Tram 28 Café", {"name": "Nowhere", "latitude": 120, "longitude": 10}]}]}
        """#))
        #expect(cards.count == 2)
        guard case let .map(walk) = cards[0], case let .map(pins) = cards[1] else { Issue.record("not maps"); return }
        let route = try #require(walk.route)
        #expect(route.mode == .walking && route.from == nil, "\"here\" is where the person is")
        #expect(route.to.name == "Rossio Roasters" && route.to.latitude == 38.7176 && route.to.longitude == -9.1404, "numbers as text, lat and lng")
        #expect(pins.places.map(\.name) == ["Tram 28 Café", "Nowhere"])
        #expect(!pins.places[1].hasCoordinate && pins.places[1].latitude == nil, "a coordinate off the globe is dropped")
    }

    @Test func placesLeniently() throws {
        let cards = ReplyCards.parse(json(#"""
        {"cards": [{"type": "places", "places": [{"name": "A", "rating": "4.6", "url": "javascript:alert(1)", "website": "x"},
          {"name": "B", "rating": 9, "url": "https://b.example"}, {"address": "no name"}]}]}
        """#))
        guard case let .places(list) = try #require(cards.first) else { Issue.record("not places"); return }
        #expect(list.places.map(\.name) == ["A", "B"], "a place without a name is dropped")
        #expect(list.places[0].rating == 4.6 && list.places[0].url == nil, "a link that isn't the web is dropped")
        #expect(list.places[1].rating == 5 && list.places[1].url == "https://b.example", "a rating is out of five")
    }

    @Test func theWeatherInWhateverWordsItComes() throws {
        let cards = ReplyCards.parse(json(#"""
        {"cards": [{"type": "weather", "location": "Boston", "units": "fahrenheit",
          "current": {"temp": "61°F", "condition": "Partly Cloudy", "humidity": "55%"},
          "hours": [{"time": "14:00", "temperature": 63, "condition": "sunny"}, {"time": "15:00", "condition": "rain"}],
          "days": [{"day": "2026-10-23", "high": 64, "low": 50, "condition": "Thunderstorms", "precipitation": 80}]},
          {"type": "weather", "place": "Nowhere"}]}
        """#))
        #expect(cards.count == 2, "a forecast with only its place is kept, to be looked up")
        guard case let .weather(w) = try #require(cards.first), case let .weather(bare) = cards[1] else { Issue.record("not weather"); return }
        #expect(!bare.hasReading && w.hasReading)
        #expect(w.place == "Boston" && w.units == "F")
        #expect(w.now?.temperature == 61 && w.now?.condition == .partlyCloudy && w.now?.humidity == 55)
        #expect(w.hours.count == 1 && w.hours[0].condition == .clear, "an hour without a temperature is dropped")
        #expect(w.days.first?.condition == .thunderstorm && w.days.first?.precipitation == 80)
        #expect(ReplyCard.Condition(lenient: "something odd") == .unknown)
    }

    /// Seen 2026-10-23: the reply said 85°F and clear, and the call it made held 0 and no condition. A
    /// reading names its condition, so that one isn't drawn: alone, the card has only its place, to be
    /// looked up.
    @Test func aPlaceholderReadingIsntDrawn() throws {
        let placeholder = #"{"type":"weather","units":"F","now":{"temperature":0,"condition":""},"place":"Orlando FL"}"#
        #expect(!hasReading(ReplyCards.parse(json(#"{"cards":["# + placeholder + "]}"))), "a 0 with no condition is no reading")
        let withDays = ReplyCards.parse(json(#"{"cards":[{"type":"weather","place":"Orlando FL","now":{"temperature":0,"condition":""},"#
                                             + #""days":[{"date":"2026-10-24","high":88,"low":72,"condition":"clear"},{"date":"2026-10-25","high":0,"low":0}]}]}"#))
        guard case let .weather(w) = try #require(withDays.first) else { Issue.record("not weather"); return }
        #expect(w.now == nil, "the placeholder is left out")
        #expect(w.days.count == 1 && w.days[0].high == 88, "a day with no condition is left out too")
        let real = ReplyCards.parse(json(#"{"cards":[{"type":"weather","place":"Orlando FL","units":"F","now":{"temperature":85,"condition":"clear"}}]}"#))
        guard case let .weather(r) = try #require(real.first) else { Issue.record("not weather"); return }
        #expect(r.now?.temperature == 85 && r.now?.condition == .clear)
        #expect(ReplyCards.parse(json(#"{"cards":[{"type":"weather","place":"Fairbanks","now":{"temperature":0,"condition":"snow","feels_like":-12}}]}"#)).count == 1,
                "a real 0 comes with its other numbers")
        // Later the same day: 0 and "clear", the weather never looked up. Nothing else read with it, so no reading.
        #expect(!hasReading(ReplyCards.parse(json(#"{"cards":[{"place":"Orlando FL","now":{"temperature":0,"condition":"clear"},"type":"weather","units":"F"}]}"#))))
    }

    private func hasReading(_ cards: [ReplyCard]) -> Bool {
        guard case let .weather(w) = cards.first else { return false }
        return w.hasReading
    }

    @Test func theTimeSomewhereOrHere() throws {
        let cards = ReplyCards.parse(json(#"""
        {"cards": [{"type": "time", "place": "Lisbon", "timezone": "Europe/Lisbon"}, {"type": "time"},
                   {"type": "clock", "place": "Tokyo", "time_zone": "Mars/Base"}]}
        """#))
        #expect(cards == [.time(.init(place: "Lisbon", timeZone: "Europe/Lisbon")), .time(.init(place: nil, timeZone: nil)),
                          .time(.init(place: "Tokyo", timeZone: nil))], "a zone that isn't one is left to be looked up")
        #expect(cards.map(CardLookup.needsLookup) == [false, false, true], "with no place it is the phone's own time")
        #expect(ReplyCard.Clock.difference(0) == "Same time")
        #expect(ReplyCard.Clock.difference(-14_400) == "4 hr behind")
        #expect(ReplyCard.Clock.difference(46_800) == "13 hr ahead")
        #expect(ReplyCard.Clock.difference(19_800) == "5½ hr ahead")
        #expect(ReplyCard.Clock.difference(20_700) == "5¾ hr ahead")
        #expect(ReplyCard.Clock.difference(1_800) == "½ hr ahead")
    }

    /// Plugin 1.7.0 answers with the cards filled in: the weather looked up replaces what the agent wrote.
    @Test func thePluginsAnswerWinsOverTheCall() throws {
        var step = ToolActivity(name: ReplyCards.tool, preview: nil, status: .completed,
                                args: ToolActivity.args(ReplyCards.tool, json(#"{"cards": [{"type": "weather", "place": "Orlando FL", "now": {"temperature": 66, "condition": "clear"}}]}"#)))
        step.output = #"""
        {"shown": ["weather: Orlando FL (now 75.5°F clear, 1 hours)"], "said": ["weather: Orlando FL: now 76°F clear"],
         "cards": [{"type": "weather", "place": "Orlando FL", "units": "F", "source": "Open-Meteo.com",
                    "now": {"temperature": 75.5, "condition": "clear", "night": true, "feels_like": 71.9, "wind": "12 mph NE"},
                    "hours": [{"time": "2026-10-23T19:00", "temperature": 70.1, "condition": "clear", "night": true, "precipitation": 0}], "days": []}]}
        """#
        guard case let .weather(w) = try #require(ReplyCards.cards(from: step)?.first) else { Issue.record("no weather"); return }
        #expect(w.now?.temperature == 75.5 && w.now?.night == true && w.hours.first?.night == true && w.units == "F")
        #expect(!CardLookup.needsLookup(.weather(w)), "looked up already")
        step.output = #"{"error": "Nothing could be shown: card 1: the weather needs 'now'."}"#
        guard case let .weather(old) = try #require(ReplyCards.cards(from: step)?.first) else { Issue.record("no weather"); return }
        #expect(old.now?.temperature == 66 && CardLookup.needsLookup(.weather(old)), "an older plugin's answer: the call, to be looked up on the phone")
    }

    @Test func openMeteoAsACard() throws {
        let card = try #require(OpenMeteo.weather(json(Self.openMeteoAnswer), place: "Orlando FL", units: "F"))
        #expect(card.source == ReplyCards.lookedUpSource && card.place == "Orlando FL" && card.units == "F")
        let now = try #require(card.now)
        #expect(now.temperature == 75.5 && now.condition == .clear && now.feelsLike == 71.9 && now.humidity == 49)
        #expect(now.wind == "12 mph NE" && now.high == 81.9 && now.low == 64 && now.precipitation == 0 && now.night == false)
        #expect(card.hours.count == 3 && card.hours[2].night == true && card.hours[2].condition == .partlyCloudy && card.hours[1].precipitation == 40)
        #expect(card.days.map(\.condition) == [.clear, .rain] && card.days[1].precipitation == 60)
        #expect([0, 2, 3, 45, 53, 57, 63, 65, 75, 95].map { OpenMeteo.condition(Double($0)) }
                == [.clear, .partlyCloudy, .cloudy, .fog, .drizzle, .sleet, .rain, .heavyRain, .snow, .thunderstorm])
        let url = OpenMeteo.url(at: .init(latitude: 28.53834, longitude: -81.37924), units: "C").absoluteString
        #expect(url.contains("latitude=28.538") && url.contains("temperature_unit=celsius") && url.contains("wind_speed_unit=kmh"), "coordinates only, to three places")
        #expect(OpenMeteo.weather(json(#"{"current": {}}"#), place: "X", units: "C") == nil)
    }

    static let openMeteoAnswer = #"""
    {"current": {"time": "2026-10-23T17:45", "temperature_2m": 75.5, "apparent_temperature": 71.9, "relative_humidity_2m": 49,
                 "weather_code": 0, "wind_speed_10m": 12.3, "wind_direction_10m": 31, "is_day": 1},
     "hourly": {"time": ["2026-10-23T17:00", "2026-10-23T18:00", "2026-10-23T19:00"], "temperature_2m": [77.3, 74.9, 70.1],
                "weather_code": [0, 61, 2], "precipitation_probability": [0, 40, 5], "is_day": [1, 1, 0]},
     "daily": {"time": ["2026-10-23", "2026-10-24"], "weather_code": [0, 63], "temperature_2m_max": [81.9, 78],
               "temperature_2m_min": [64, 62], "precipitation_probability_max": [0, 60]}}
    """#

    /// An older plugin, or an answer that can't be read: the phone looks the place up itself, once the call is done.
    @Test func filledOnThePhoneWhenThePluginDidnt() async throws {
        let args = ToolActivity.args(ReplyCards.tool, json(#"{"cards": [{"type": "weather", "place": "Orlando FL", "units": "F", "now": {"temperature": 0, "condition": "clear"}}, {"type": "time", "place": "Orlando FL"}]}"#))
        var asked: [String] = []
        let lookup = CardLookup(find: { place in
            asked.append(place)
            return .init(coordinate: .init(latitude: 28.538, longitude: -81.379), timeZone: "America/New_York")
        }, fetch: { _ in Data(Self.openMeteoAnswer.utf8) })
        let shown = try await reply([.toolStarted(name: ReplyCards.tool, preview: nil, args: args),
                                     .toolFinished(name: ReplyCards.tool, failed: false, output: #"{"error": "Nothing could be shown"}"#),
                                     .textDelta("Here."), .done], lookup: lookup) { message in
            if case let .weather(w) = message.cards?.first { return w.source == ReplyCards.lookedUpSource }
            return false
        }
        guard case let .weather(w) = shown.cards?.first, case let .time(clock) = shown.cards?.last else { Issue.record("no cards"); return }
        #expect(w.now?.temperature == 75.5 && w.days.count == 2)
        #expect(clock.timeZone == "America/New_York")
        #expect(asked == ["Orlando FL", "Orlando FL"])
    }

    @Test func thePhoneSaysItsZoneAndUnits() {
        #expect(ReplyCardsSwitch.command(on: true, zone: TimeZone(identifier: "America/New_York")!, units: "F") == "cards on tz=America/New_York units=F")
        #expect(ReplyCardsSwitch.command(on: false) == "cards off")
    }

    @Test func atMostFourAndOnlyKnownKinds() {
        let one = #"{"type": "places", "places": ["A"]}"#
        let cards = ReplyCards.parse(json(#"{"cards": [{"type": "chart"}, "#
                                          + Array(repeating: one, count: 6).joined(separator: ",") + "]}"))
        #expect(cards.count == 4)
        #expect(ReplyCards.parse(json(#"{"type": "places", "places": ["A"]}"#)).count == 1, "one card without the list")
        #expect(ReplyCards.cards(fromCall: "web_search", args: json(one)) == nil, "another tool's call")
    }

    @Test func theCallsArgumentsStayJSONOnItsStep() throws {
        let args = json(#"{"cards": [{"type": "places", "places": [{"name": "A", "note": "line one\nline two"}]}]}"#)
        let kept = try #require(ToolActivity.args(ReplyCards.tool, args))
        #expect((try? JSONValue.parse(Data(kept.utf8))) == args)
        #expect(ToolActivity.args("terminal", json(#"{"command": "ls"}"#)) == "command: ls", "any other tool reads as before")
        let step = ToolActivity(name: ReplyCards.tool, preview: nil, status: .completed, args: kept)
        #expect(ReplyCards.cards(from: step)?.count == 1)
        var failed = step
        failed.status = .failed
        #expect(ReplyCards.cards(from: failed) == nil, "a call the plugin turned down shows nothing")
    }

    @Test func readBackOverTheHermesAPI() throws {
        let rows = try JSONDecoder().decode([HermesSessionsAPI.StoredMessage].self, from: Data(#"""
        [{"role": "user", "content": "Coffee?"},
         {"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "redde_show",
           "arguments": "{\"cards\": [{\"type\": \"places\", \"places\": [{\"name\": \"Rossio Roasters\"}]}]}"}}]},
         {"role": "tool", "tool_name": "redde_show", "content": "{\"shown\": [\"places: 1\"]}"},
         {"role": "assistant", "content": "Rossio Roasters is closest."}]
        """#.utf8))
        var messages = Conversation.mapStored(rows)
        ReplyCards.resolve(&messages)
        let reply = try #require(messages.last)
        #expect(reply.text == "Rossio Roasters is closest.")
        guard case let .places(list) = try #require(reply.cards?.first) else { Issue.record("no places"); return }
        #expect(list.places.first?.name == "Rossio Roasters")
    }

    @Test func readBackOverTheDashboard() throws {
        let rows: [JSONValue] = [
            json(#"{"role": "user", "text": "Weather?"}"#),
            json(#"{"role": "assistant", "text": "Rain after three."}"#),
            json(#"{"role": "tool", "name": "tool_call", "args": {"calls": [{"name": "redde_show", "arguments": {"cards": [{"type": "weather", "place": "Lisbon", "now": {"temperature": 19, "condition": "rain"}}]}}]}}"#),
        ]
        var messages = Conversation.messages(fromServeRows: rows)
        ReplyCards.resolve(&messages)
        guard case let .weather(w) = try #require(messages.last?.cards?.first) else { Issue.record("no weather"); return }
        #expect(w.place == "Lisbon" && w.now?.condition == .rain, "reached through tool_call, as 0.21.3 and later do")
    }

    @Test func shownLiveAsTheCallIsMadeAndTakenBackIfItFails() async throws {
        let args = ToolActivity.args(ReplyCards.tool, json(#"{"cards": [{"type": "places", "places": ["A"]}, {"type": "weather", "place": "X", "source": "Open-Meteo.com", "now": {"temperature": 1, "condition": "snow"}}]}"#))
        let shown = try await reply([.toolStarted(name: ReplyCards.tool, preview: nil, args: args), .toolFinished(name: ReplyCards.tool, failed: false),
                                     .textDelta("Here."), .done])
        #expect(shown.cards?.count == 2)
        let refused = try await reply([.toolStarted(name: ReplyCards.tool, preview: nil, args: args), .toolFinished(name: ReplyCards.tool, failed: true),
                                       .textDelta("Hm."), .done])
        #expect(refused.cards == nil)
    }

    /// The reply to a scripted turn, once it's done and, given `until`, once that holds of it (a lookup after the call).
    private func reply(_ events: [TurnEvent], lookup: CardLookup? = nil, until: ((Message) -> Bool)? = nil) async throws -> Message {
        let settings = Settings(defaults: UserDefaults(suiteName: "cards-\(UUID().uuidString)")!)
        settings.transport = .chatCompletions
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        let c = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "cards-\(UUID().uuidString)")),
                             transportOverride: ConversationLifecycleTests.ScriptedTransport(events))
        if let lookup { c.cardLookup = lookup }
        _ = c.send("Show me.")
        for _ in 0 ..< 300 where c.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        if let until {
            for _ in 0 ..< 300 where !(c.messages.last.map(until) ?? false) { try await Task.sleep(for: .milliseconds(10)) }
        }
        return try #require(c.messages.last)
    }
}

import Foundation
import Testing
@testable import Echo

/// A reply's cards (`ReplyCards`, `redde_show`): read leniently from the call's arguments, kept
/// as JSON on the step, shown live as the call is made, and found again when a conversation is
/// read back from either connection.
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
        #expect(cards.count == 1, "a forecast with nothing in it is dropped")
        guard case let .weather(w) = try #require(cards.first) else { Issue.record("not weather"); return }
        #expect(w.place == "Boston" && w.units == "F")
        #expect(w.now?.temperature == 61 && w.now?.condition == .partlyCloudy && w.now?.humidity == 55)
        #expect(w.hours.count == 1 && w.hours[0].condition == .clear, "an hour without a temperature is dropped")
        #expect(w.days.first?.condition == .thunderstorm && w.days.first?.precipitation == 80)
        #expect(ReplyCard.Condition(lenient: "something odd") == .unknown)
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
        let args = ToolActivity.args(ReplyCards.tool, json(#"{"cards": [{"type": "places", "places": ["A"]}, {"type": "weather", "place": "X", "now": {"temperature": 1, "condition": "snow"}}]}"#))
        let shown = try await reply([.toolStarted(name: ReplyCards.tool, preview: nil, args: args), .toolFinished(name: ReplyCards.tool, failed: false),
                                     .textDelta("Here."), .done])
        #expect(shown.cards?.count == 2)
        let refused = try await reply([.toolStarted(name: ReplyCards.tool, preview: nil, args: args), .toolFinished(name: ReplyCards.tool, failed: true),
                                       .textDelta("Hm."), .done])
        #expect(refused.cards == nil)
    }

    private func reply(_ events: [TurnEvent]) async throws -> Message {
        let settings = Settings(defaults: UserDefaults(suiteName: "cards-\(UUID().uuidString)")!)
        settings.transport = .chatCompletions
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        let c = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "cards-\(UUID().uuidString)")),
                             transportOverride: ConversationLifecycleTests.ScriptedTransport(events))
        _ = c.send("Show me.")
        for _ in 0 ..< 300 where c.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(c.messages.last)
    }
}

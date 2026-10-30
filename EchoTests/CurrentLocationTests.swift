import CoreLocation
import Foundation
import Testing
@testable import Echo

/// Current Location (asked 2026-10-30, "so it knows where we are for maps"): the agent hears roughly
/// where the person is only on a question about places, directions, maps or the weather, with the
/// setting on and a recent place kept; the place is rounded and in words; the note it rides in on
/// the Dashboard is hidden again; and a weather card for here takes the kept place.
struct CurrentLocationTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private var thorntonPark: CurrentLocation.Here {
        .init(words: "Thornton Park, Orlando, FL", latitude: 28.54213, longitude: -81.36728, at: now.addingTimeInterval(-300))
    }

    // MARK: Which questions

    @Test func onlyAQuestionAboutPlacesIsTold() {
        for asked in ["Find coffee near me", "Any good bars around here?", "Where's the nearest pharmacy?", "closest gas station",
                      "Directions to the airport", "How far is Disney?", "How long does it take to get to downtown?",
                      "Show me a map of the lake", "Restaurants nearby", "Where can I get sushi tonight?",
                      "What's the weather tomorrow?", "Will it rain this afternoon?", "Do I need an umbrella?",
                      "What time is sunset?", "Where am I?", "Things to do this weekend", "Is there a park in the neighborhood?",
                      "How do I get home from here?", "best brunch spots", "Cafés open now"] {
            #expect(CurrentLocation.asksPlace(asked), "\(asked)")
        }
        for said in ["Tell me a joke", "What's on my calendar tomorrow?", "Summarize this article", "Write a haiku about autumn",
                     "Delete the temp file in my downloads", "Remind me to call Mom at 5",
                     "What time is it in Tokyo?", "Turn off the living room lights"] {
            #expect(!CurrentLocation.asksPlace(said), "\(said)")
        }
    }

    @Test func thePlaceGoesOnlyWhenOnAskedAndRecent() {
        let here = thorntonPark
        #expect(CurrentLocation.forAgent(asked: "coffee near me", on: true, kept: here, now: now) == here)
        #expect(CurrentLocation.forAgent(asked: "coffee near me", on: false, kept: here, now: now) == nil, "off: nothing")
        #expect(CurrentLocation.forAgent(asked: "Tell me a joke", on: true, kept: here, now: now) == nil, "no tokens on other messages")
        #expect(CurrentLocation.forAgent(asked: "coffee near me", on: true, kept: nil, now: now) == nil, "nothing kept yet")
        let old = CurrentLocation.Here(words: here.words, latitude: here.latitude, longitude: here.longitude,
                                       at: now.addingTimeInterval(-CurrentLocation.freshFor - 1))
        #expect(CurrentLocation.forAgent(asked: "coffee near me", on: true, kept: old, now: now) == nil, "older than half an hour: not sent")
    }

    // MARK: What the agent hears

    @Test func theCoordinatesAreRoundedAndThePlaceInWords() {
        let here = thorntonPark
        #expect(here.latitude == 28.542 && here.longitude == -81.367)
        #expect(CurrentLocation.instruction(here)
                == "The user is near Thornton Park, Orlando, FL (28.542, -81.367). Use it for places, directions and weather unless they name somewhere else.")
        let unnamed = CurrentLocation.Here(words: nil, latitude: 51.52261, longitude: -0.07786, at: now)
        #expect(CurrentLocation.instruction(unnamed) == "The user is near 51.523, -0.078. Use it for places, directions and weather unless they name somewhere else.")
        #expect(CurrentLocation.Here(words: "  ", latitude: 0, longitude: 0, at: now).words == nil)
        #expect(CurrentLocation.Here(words: "Line one\nLine two", latitude: 0, longitude: 0, at: now).words == "Line one Line two", "one line")
    }

    @Test func theNeighbourhoodComesBeforeTheTown() {
        #expect(CurrentLocation.words(neighbourhood: "Thornton Park", town: "Orlando, FL") == "Thornton Park, Orlando, FL")
        #expect(CurrentLocation.words(neighbourhood: nil, town: "Orlando, FL") == "Orlando, FL")
        #expect(CurrentLocation.words(neighbourhood: "Orlando", town: "Orlando, FL") == "Orlando, FL", "not the town twice")
        #expect(CurrentLocation.words(neighbourhood: "Hackney", town: nil) == "Hackney")
        #expect(CurrentLocation.words(neighbourhood: nil, town: nil) == nil)
    }

    @Test func theNoteOnTheDashboardIsHiddenWhenReadBack() {
        let asked = "Find coffee near me"
        let sent = asked + CurrentLocation.note(thorntonPark)
        #expect(sent.hasSuffix("(The user is near Thornton Park, Orlando, FL (28.542, -81.367). Use it for places, directions and weather unless they name somewhere else.)"))
        #expect(CurrentLocation.strip(sent) == asked)
        #expect(CurrentLocation.strip(asked) == asked)
        // Among the others, in the order the Dashboard's message carries them: all of them go.
        let all = asked + ReplyLanguage.note("de") + MeasureUnits.note(.us) + CalendarChoice.note(["Work"])
            + CurrentLocation.note(thorntonPark) + CarBrevity.note
        #expect(ReplyLanguage.stripNote(all) == asked)
    }

    @Test func theTurnCarriesThePlaceOnAPlaceQuestionOnly() {
        // The setting and the place as the app keeps them, put back as they were after.
        let defaults = UserDefaults.standard
        let (wasOn, wasKept) = (defaults.object(forKey: CurrentLocation.key), defaults.data(forKey: CurrentLocation.keptKey))
        defer {
            defaults.set(wasOn, forKey: CurrentLocation.key)
            defaults.set(wasKept, forKey: CurrentLocation.keptKey)
        }
        let here = CurrentLocation.Here(words: "Thornton Park, Orlando, FL", latitude: 28.5421, longitude: -81.3673, at: .now)
        defaults.set(true, forKey: CurrentLocation.key)
        CurrentLocation.keep(here)
        var request = TurnRequest(userText: "Tell me a joke", history: [], sessionID: nil, model: nil, instructions: nil)
        #expect(request.location == nil)
        #expect(!HermesSessionsTransport.instructions(for: request).contains("The user is near"))
        request.userText = "Directions to the airport"
        #expect(request.location == here)
        #expect(HermesSessionsTransport.instructions(for: request).contains(CurrentLocation.instruction(here)))
        defaults.set(false, forKey: CurrentLocation.key)
        #expect(request.location == nil, "off: nothing")
    }

    // MARK: Kept, and cards

    @Test func thePlaceIsKeptAndForgotten() throws {
        let defaults = try #require(UserDefaults(suiteName: "CurrentLocationTests"))
        defaults.removePersistentDomain(forName: "CurrentLocationTests")
        CurrentLocation.keep(thorntonPark, in: defaults)
        #expect(CurrentLocation.kept(in: defaults) == thorntonPark)
        CurrentLocation.forget(in: defaults)
        #expect(CurrentLocation.kept(in: defaults) == nil)
        defaults.removePersistentDomain(forName: "CurrentLocationTests")
    }

    @Test func aWeatherCardForHereTakesTheKeptPlace() throws {
        let here = thorntonPark
        let found = try #require(CurrentLocation.standIn(for: "here", on: true, kept: here, now: now))
        #expect(found.latitude == 28.542 && found.longitude == -81.367)
        #expect(CurrentLocation.standIn(for: "", on: true, kept: here, now: now) != nil, "no place: where they are")
        #expect(CurrentLocation.standIn(for: "thornton park, orlando, fl", on: true, kept: here, now: now) != nil, "the place the agent was told")
        #expect(CurrentLocation.standIn(for: "Lisbon", on: true, kept: here, now: now) == nil, "somewhere else: looked up")
        #expect(CurrentLocation.standIn(for: "here", on: false, kept: here, now: now) == nil, "off: as before")
    }
}

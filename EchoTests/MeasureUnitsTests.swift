import Foundation
import Testing
@testable import Echo

/// US or metric units (asked 2026-10-29): what the agent is told, and how distances read.
struct MeasureUnitsTests {
    private let us = Locale(identifier: "en_US")
    private let uk = Locale(identifier: "en_GB")

    @Test func automaticFollowsTheRegionAndAChoiceWins() {
        #expect(MeasureUnits.usesUS(.automatic, locale: us))
        #expect(!MeasureUnits.usesUS(.automatic, locale: uk))
        #expect(MeasureUnits.usesUS(.us, locale: uk))
        #expect(!MeasureUnits.usesUS(.metric, locale: us))
    }

    @Test func theAgentIsToldUSOrAChosenMetricOnly() {
        #expect(MeasureUnits.forAgent(.automatic, locale: us) == .us)
        #expect(MeasureUnits.forAgent(.automatic, locale: uk) == nil, "a model writes metric unasked")
        #expect(MeasureUnits.forAgent(.metric, locale: us) == .metric)
        #expect(MeasureUnits.instruction(.us).contains("miles") && MeasureUnits.instruction(.us).contains("°F"))
    }

    @Test func theNoteOnAMessageIsHiddenWhenItIsReadBack() {
        let sent = "How far is the beach?" + MeasureUnits.note(.us)
        #expect(ReplyLanguage.stripNote(sent) == "How far is the beach?")
        let both = "¿Qué tan lejos está?" + ReplyLanguage.note("es") + MeasureUnits.note(.metric)
        #expect(ReplyLanguage.stripNote(both) == "¿Qué tan lejos está?")
    }

    @Test func theTurnsInstructionsCarryTheUnits() {
        var request = TurnRequest(userText: "hi", history: [], sessionID: nil, model: nil, provider: nil, reasoningEffort: nil, instructions: nil)
        request.units = .us
        #expect(HermesSessionsTransport.instructions(for: request).contains(MeasureUnits.instruction(.us)))
        request.units = nil
        #expect(!HermesSessionsTransport.instructions(for: request).contains("customary"))
    }

    @Test func distancesReadInMilesOrKilometres() {
        #expect(MeasureUnits.distance(8047, us: true).contains("5"))
        #expect(MeasureUnits.distance(8047, us: true).localizedCaseInsensitiveContains("mi"))
        #expect(MeasureUnits.distance(60, us: true).localizedCaseInsensitiveContains("ft"))
        #expect(MeasureUnits.distance(100, us: true).contains("330"), "Places' Close, in feet to the nearest ten")
        #expect(MeasureUnits.distance(500, us: true).contains("0.3"), "Places' Around, in miles")
        #expect(MeasureUnits.distance(100, us: false).contains("100"))
        #expect(MeasureUnits.distance(8047, us: false).localizedCaseInsensitiveContains("km"))
        #expect(MeasureUnits.distance(400, us: false).contains("400"))
    }
}

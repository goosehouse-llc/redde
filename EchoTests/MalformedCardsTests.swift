import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Echo

/// Cards as an agent may really write them, at their worst (from the UAT of 2.3.1, 2026-10-31,
/// where twelve of them crashed Redde as they were read, and so each time their chat opened): huge
/// whole numbers (a 22-digit tracking number written as a number, a score of 1e20, a timer of
/// 1e308 seconds), "nan" and "inf" as text, wrong types, nulls in lists, nonsense dates, lists far
/// past what a card shows. Each is read, kept and read back as stored messages are, and drawn light
/// and dark, narrow and wide: passing means nothing crashed and nothing read wrongly.
@MainActor
struct MalformedCardsTests {
    static let long = String(repeating: "Supercalifragilistic ", count: 100)
    static let rtl = "שלום עולם مرحبا بالعالم"
    static let emoji = "🍝🔥👩‍👩‍👧‍👦🇵🇹"

    static func many(_ n: Int, _ make: (Int) -> String) -> String { (0 ..< n).map(make).joined(separator: ", ") }

    /// Name and JSON of one card (or a {"cards": …} call).
    static let variants: [(String, String)] = {
        var v: [(String, String)] = []
        let types = ["map", "places", "weather", "time", "agenda", "purchase", "home", "reminder", "timer", "compare", "score",
                     "recipe", "delivery", "flight", "show", "conversion", "stock", "review", "choice", "checklist", "form"]
        for t in types {
            v.append(("\(t)-bare", #"{"type": "\#(t)"}"#))
            v.append(("\(t)-emptyArrays", #"{"type": "\#(t)", "items": [], "events": [], "devices": [], "games": [], "options": [], "rows": [], "legs": [], "ingredients": [], "steps": [], "fields": [], "places": []}"#))
            v.append(("\(t)-wrongTypes", #"{"type": "\#(t)", "title": 5, "items": "x", "events": {"a": 1}, "devices": 3, "games": null, "options": true, "amount": "lots", "price": [1], "servings": "four", "date": 7}"#))
            v.append(("\(t)-nullsInArrays", #"{"type": "\#(t)", "items": [null, 1, "", {}], "events": [null, {}], "devices": [null, {}], "games": [null, {}], "options": [null, {}, ""], "rows": [null], "legs": [null, {}], "ingredients": [null, ""], "steps": [null, ""], "fields": [null, {}]}"#))
        }
        // Weather, places, maps, the time.
        v.append(("weather-odd", #"{"type": "weather", "place": "\#(rtl) \#(emoji)", "units": "K", "now": {"temp": "hot", "code": -5}, "hourly": [{"time": "25:99", "temp": 1e308}, {"temp": -1e308}], "daily": [{"high": "x", "low": null}]}"#))
        v.append(("weather-huge", #"{"type": "weather", "place": "\#(long)", "temperature": 1e308, "high": -1e308, "low": 1e308, "hours": [\#(many(300) { #"{"time": "\#($0 % 24):00", "temp": \#($0), "rain": \#($0 * 7)}"# })]}"#))
        v.append(("weather-readings-huge", #"{"type": "weather", "place": "X", "now": {"temperature": 1e300, "condition": "clear", "humidity": 1e20, "precipitation": -1e20, "high": 1e19, "low": -1e19}, "hours": [{"time": "14:00", "temperature": 1e300, "condition": "rain", "precipitation": 1e300}], "days": [{"date": "2026-11-01", "high": 1e300, "low": -1e300, "condition": "clear", "precipitation": 1e300}]}"#))
        v.append(("weather-nan-text", #"{"type": "weather", "place": "X", "now": {"temperature": "nan", "condition": "clear", "humidity": "inf"}, "hours": [{"time": "14:00", "temperature": "-inf", "condition": "rain"}]}"#))
        v.append(("places-odd", #"{"type": "places", "places": [{"name": "\#(long)", "rating": 99, "latitude": 999, "longitude": -999, "price": 5, "hours": 3}, {"name": "\#(rtl)", "rating": "-3", "category": "\#(emoji)"}, {"name": "x", "rating": "NaN", "price": "inf"}, {"name": "y", "price": 1e300}]}"#))
        v.append(("places-many", #"{"type": "places", "places": [\#(many(500) { #"{"name": "Place \#($0)", "latitude": \#(Double($0) / 100), "longitude": 1}"# })]}"#))
        v.append(("map-route-only", #"{"type": "map", "route": {"from": {"name": "A"}, "to": {}, "mode": "teleport"}}"#))
        v.append(("map-same-point", #"{"type": "map", "places": [{"name": "A", "latitude": 0, "longitude": 0}, {"name": "A", "latitude": 0, "longitude": 0}]}"#))
        v.append(("time-badzone", #"{"type": "time", "place": "\#(long)", "timezone": "Mars/Olympus"}"#))
        // Calendars.
        v.append(("agenda-odd", #"{"type": "agenda", "title": "\#(rtl)", "date": "not a date", "events": [{"title": "\#(long)", "start": "2026-10-31T25:61:00Z"}, {"title": "end before start", "start": "2026-11-01T10:00:00Z", "end": "2026-11-01T09:00:00Z"}, {"title": "\#(emoji)", "start": "2026-11-01", "all_day": "yes"}, {"title": "dup", "start": "2026-11-01T10:00:00Z", "end": "2026-11-01T10:00:00Z"}, {"title": "dup", "start": "2026-11-01T10:00:00Z", "end": "2026-11-03T10:00:00Z"}, {"title": "all", "start": "2026-11-01"}, {"title": "all", "start": "2026-11-01"}]}"#))
        v.append(("agenda-many", #"{"type": "agenda", "dates": [\#(many(40) { #""2026-11-\#(String(format: "%02d", $0 % 28 + 1))""# })], "events": [\#(many(200) { #"{"title": "E\#($0)", "start": "2026-11-01T\#(String(format: "%02d", $0 % 24)):00:00Z", "end": "2026-11-01T\#(String(format: "%02d", $0 % 24)):30:00Z", "calendar": "C\#($0 % 9)"}"# })]}"#))
        v.append(("agenda-years", #"{"type": "agenda", "events": [{"title": "far", "start": "0001-01-01T00:00:00Z", "end": "9999-12-31T23:59:59Z"}, {"title": "neg", "start": "-2026-01-01"}]}"#))
        // Things to buy.
        v.append(("purchase-odd", #"{"type": "purchase", "items": [{"name": "\#(long)", "price": "free", "was_price": -1, "rating": "11/5", "reviews": "-3", "url": "javascript:alert(1)", "image": "http://x", "pros": "one", "cons": [1, null], "specs": [1, 2]}, {"name": "\#(rtl) \#(emoji)", "price": 1e308, "currency": "ZZZ", "rating": -2, "pick": 7}, {"name": "zero", "price": 0, "was_price": 0}]}"#))
        v.append(("purchase-many", #"{"type": "purchase", "items": [\#(many(200) { #"{"name": "P\#($0)", "price": \#($0), "pick": true}"# })]}"#))
        v.append(("purchase-reviews-1e20", #"{"type": "purchase", "items": [{"name": "P", "price": 5, "reviews": 1e20}, {"name": "Q", "price": 6, "reviews": "1e400"}, {"name": "R", "price": 7, "reviews": "9999999999999999999999k"}]}"#))
        // Home.
        v.append(("home-odd", #"{"type": "home", "devices": [{"name": "\#(long)", "kind": "light", "state": "maybe", "brightness": 9999}, {"name": "T", "kind": "climate", "temperature": "x", "target": 1e308, "min": 30, "max": 10}, {"name": "Lock", "kind": "lock", "state": "jammed"}, {"name": "\#(rtl)", "kind": "fan", "percentage": -50}, {"name": "dup", "kind": "switch"}, {"name": "dup", "kind": "switch"}, {"name": "S", "kind": "sensor"}, {"name": "B", "kind": "light", "state": "on", "brightness": 1e300}]}"#))
        v.append(("home-many", #"{"type": "home", "devices": [\#(many(300) { #"{"name": "D\#($0)", "kind": "light", "state": "on", "entity": "light.d\#($0)"}"# })]}"#))
        // Reminders and timers.
        v.append(("reminder-odd", #"{"cards": [{"type": "reminder", "kind": "timer", "title": "\#(long)", "duration": "-20 min"}, {"type": "reminder", "kind": "timer", "title": "inf", "duration": 1e308}, {"type": "reminder", "kind": "alarm", "title": "\#(rtl)", "at": "yesterday"}, {"type": "reminder", "kind": "schedule", "title": "\#(emoji)", "at": "1970-01-01T00:00:00Z", "repeat": "\#(long)"}]}"#))
        v.append(("timer-1e15-seconds", #"{"type": "reminder", "kind": "timer", "title": "T", "duration": 1e15}"#))
        v.append(("timer-huge-minutes", #"{"type": "reminder", "kind": "timer", "title": "T", "minutes": 1e307}"#))
        v.append(("timer-huge-words", #"{"type": "reminder", "kind": "timer", "title": "T", "duration": "99999999999999999999 h"}"#))
        // Comparisons.
        v.append(("compare-odd", #"{"type": "compare", "options": ["A", "A", "\#(long)", "\#(rtl)", "\#(emoji)", "six", "seven"], "rows": [{"criterion": "x", "values": ["only one"], "best": 99}, {"criterion": "y", "values": [], "best": -1}, {"criterion": "\#(long)", "values": [1, null, true]}], "pick": 42}"#))
        v.append(("compare-one", #"{"type": "compare", "options": ["Lonely"], "rows": [{"criterion": "x", "values": ["a"]}]}"#))
        v.append(("compare-pick-1e20", #"{"type": "compare", "options": ["A", "B"], "rows": [{"criterion": "x", "values": ["a", "b"], "best": 1e20}], "pick": 1e20}"#))
        v.append(("compare-verdict-only", #"{"type": "compare", "options": ["A", "B"], "rows": [{"criterion": "x", "values": []}], "verdict": "A, for now"}"#))
        // Scores.
        v.append(("score-odd", ##"{"type": "score", "games": [{"status": "weird", "home": {"name": "\##(long)", "score": "lots", "color": "#GGGGGG"}, "away": {"name": "\##(rtl)", "score": -1, "color": "red"}}, {"status": "live", "home": {}, "away": null}, {"home": {"name": "\##(emoji)", "score": 1e308}, "away": {"name": "B", "score": 2}, "start": "garbage"}]}"##))
        v.append(("score-many", #"{"type": "score", "games": [\#(many(200) { #"{"status": "final", "home": {"name": "H\#($0)", "score": \#($0)}, "away": {"name": "A\#($0)", "score": 1}}"# })]}"#))
        v.append(("score-1e20", #"{"type": "score", "games": [{"status": "final", "home": {"name": "A", "score": 1e20}, "away": {"name": "B", "score": "inf"}}]}"#))
        // Recipes.
        v.append(("recipe-zeroServings", #"{"type": "recipe", "title": "Zero", "servings": 0, "ingredients": ["1 cup x", "0 tsp y", "1/0 cup z", "½ cup w"], "steps": ["a"]}"#))
        v.append(("recipe-negServings", #"{"type": "recipe", "title": "Neg", "servings": -4, "prep": -10, "cook": "forever", "ingredients": ["2 cups x"], "steps": ["a"]}"#))
        v.append(("recipe-hugeServings", #"{"type": "recipe", "title": "Huge", "servings": 1e308, "ingredients": ["1e308 cups x", "99999999999999999999 g y", {"name": "z", "amount": 1e308, "unit": "cups"}], "steps": ["a"]}"#))
        v.append(("recipe-strServings", #"{"type": "recipe", "title": "\#(rtl) \#(emoji)", "servings": "4-6", "ingredients": ["\#(long)", "2–3 cloves garlic", "a pinch"], "steps": ["\#(long)"]}"#))
        v.append(("recipe-many", #"{"type": "recipe", "title": "Many", "servings": 2, "ingredients": [\#(many(500) { #""\#($0) g thing \#($0)""# })], "steps": [\#(many(300) { #""Step \#($0)""# })]}"#))
        v.append(("recipe-servings-1e20", #"{"type": "recipe", "title": "R", "servings": 1e20, "ingredients": ["1 cup x"], "steps": ["a"]}"#))
        v.append(("recipe-prep-1e20", #"{"type": "recipe", "title": "R", "prep": 1e20, "cook": "1e400", "total": "PT99999999999999999999H", "ingredients": ["1 cup x"], "steps": ["a"]}"#))
        // Deliveries and flights.
        v.append(("delivery-odd", #"{"type": "delivery", "title": "\#(long)", "status": "teleporting", "expected": "soon", "events": [{"text": null}, {"text": "\#(rtl)", "at": "x"}], "last": "string"}"#))
        v.append(("delivery-many", #"{"type": "delivery", "title": "Many", "status": "In transit", "events": [\#(many(400) { #"{"text": "Scan \#($0)", "at": "2026-10-\#(String(format: "%02d", $0 % 28 + 1))T10:00:00Z"}"# })]}"#))
        v.append(("delivery-tracking-as-number", #"{"type": "delivery", "title": "Book", "carrier": "USPS", "status": "In transit", "tracking": 9400111899223197428490}"#))
        v.append(("flight-odd", #"{"type": "flight", "number": "\#(long)", "from": {"code": "\#(emoji)", "time": "x"}, "to": {"code": "ZZZ", "time": "2026-11-01T10:00:00Z", "new_time": "2026-10-01T10:00:00Z"}}"#))
        v.append(("flight-legs-bad", #"{"type": "flight", "legs": [null, {}, {"from": "LIS", "to": "JFK"}, {"from": {"code": "LIS", "time": "2026-11-02T10:00:00+14:00"}, "to": {"code": "HNL", "time": "2026-11-01T10:00:00-10:00"}, "duration": 1e300}]}"#))
        v.append(("flight-many", #"{"type": "flight", "legs": [\#(many(60) { #"{"number": "NW\#($0)", "from": {"code": "LIS", "time": "2026-11-01T10:00:00Z"}, "to": {"code": "JFK", "time": "2026-11-01T18:00:00Z"}}"# })]}"#))
        v.append(("flight-confirmation-as-number", #"{"type": "flight", "confirmation": 12345678901234567890, "from": {"code": "LIS"}, "to": {"code": "JFK"}}"#))
        v.append(("place-phone-as-number", #"{"type": "places", "places": [{"name": "Café", "phone": 351912345678901234567}]}"#))
        // Films and series.
        v.append(("show-odd", #"{"type": "show", "items": [{"title": "\#(long)", "year": 99999, "runtime": -5, "seasons": "many", "ratings": "x", "genres": 3, "watch": [null, 1, "Netflix", "Netflix"], "poster": "file:///etc/passwd"}, {"title": "\#(rtl) \#(emoji)", "ratings": [{"source": null}], "cast": "\#(long)", "runtime": 1e300}]}"#))
        v.append(("show-many", #"{"type": "show", "items": [\#(many(200) { #"{"title": "T\#($0)"}"# })]}"#))
        v.append(("show-seasons-1e20", #"{"type": "show", "items": [{"title": "T", "seasons": 1e20}]}"#))
        // Conversions and shares.
        v.append(("conversion-odd", #"{"type": "conversion", "amount": "lots", "from": "parsecs", "to": "furlongs"}"#))
        v.append(("conversion-incompatible", #"{"type": "conversion", "amount": 5, "from": "kg", "to": "km"}"#))
        v.append(("conversion-huge", #"{"type": "conversion", "amount": 1e308, "from": "mi", "to": "mm"}"#))
        v.append(("conversion-huge-rate", #"{"type": "conversion", "amount": 9214000, "from": "USD", "to": "EUR", "rate": 1e21}"#))
        v.append(("conversion-currency-norate", #"{"type": "conversion", "amount": 100, "from": "USD", "to": "XYZ"}"#))
        v.append(("conversion-zero-rate", #"{"type": "conversion", "amount": 100, "from": "USD", "to": "EUR", "rate": 0}"#))
        v.append(("conversion-neg-rate", #"{"type": "conversion", "amount": -100, "from": "USD", "to": "EUR", "rate": -1e308}"#))
        v.append(("stock-odd", #"{"type": "stock", "symbol": "\#(long)", "price": "up", "change": "a lot", "points": ["x", null, 1e308, -1e308], "low": 10, "high": 5, "year_range": "garbage"}"#))
        v.append(("stock-big-words", #"{"type": "stock", "symbol": "BIG", "price": 3, "change": "+\#(String(repeating: "9", count: 400))", "market_cap": "\#(String(repeating: "9", count: 400))T", "day_range": "\#(String(repeating: "9", count: 400)) - 1"}"#))
        v.append(("stock-flat", #"{"type": "stock", "symbol": "FLAT", "price": 0, "change": 0, "percent": 0, "points": [5, 5, 5, 5]}"#))
        v.append(("stock-one-point", #"{"type": "stock", "symbol": "ONE", "price": 3, "points": [3]}"#))
        v.append(("stock-many", #"{"type": "stock", "items": [\#(many(200) { #"{"symbol": "S\#($0)", "price": \#($0), "points": [\#(many(1000) { String($0 % 17) })]}"# })]}"#))
        // Cards answered with a tap.
        v.append(("review-odd", #"{"type": "review", "kind": "email", "title": "\#(long)", "fields": [{"label": "To", "value": "\#(rtl)"}, {"label": "Body", "value": "\#(String(repeating: "line\\n", count: 3000))"}, {"label": "\#(emoji)"}]}"#))
        v.append(("choice-odd", #"{"type": "choice", "options": ["A", "A", "\#(long)", {"title": "\#(rtl)", "image": "http://insecure"}], "multiple": "yes"}"#))
        v.append(("checklist-many", #"{"type": "checklist", "title": "\#(emoji)", "emoji": "not an emoji", "items": [\#(many(500) { #"{"text": "Item \#($0)", "done": \#($0 % 2 == 0), "section": "S\#($0 % 30)"}"# })]}"#))
        v.append(("checklist-dups", #"{"type": "checklist", "items": ["same", "same", "same", "\#(long)", "\#(rtl)"]}"#))
        v.append(("form-odd", #"{"type": "form", "title": "F", "fields": [{"label": "x", "kind": "choice", "options": ["a", "a", "b"]}, {"label": "y", "kind": "date", "value": "never"}, {"label": "z", "kind": "number", "value": "abc"}, {"label": "t", "kind": "toggle", "value": "maybe"}, {"label": "\#(long)", "kind": "time", "value": "99:99"}]}"#))
        // Calls of many cards, or none.
        v.append(("cards-many", #"{"cards": [\#(many(50) { _ in #"{"type": "weather", "place": "X"}"# })]}"#))
        v.append(("cards-not-array", #"{"cards": {"type": "weather"}}"#))
        v.append(("type-number", #"{"type": 5}"#))
        v.append(("type-unknown", #"{"type": "\#(emoji)"}"#))
        return v
    }()

    /// Every variant, read both ways (as the transport reads JSON, and as a card call is read, its
    /// long whole numbers kept as written), kept and read back, and drawn.
    @Test func everyOddCardIsReadAndDrawnWithoutCrashing() throws {
        for (name, json) in Self.variants {
            for keep in [false, true] {
                let value = try JSONValue.parse(Data(json.utf8), keepingLongWholeNumbers: keep)
                let cards = ReplyCards.parse(value)
                let back = try JSONDecoder().decode([ReplyCard].self, from: JSONEncoder().encode(cards))
                #expect(back == cards, "\(name): kept and read back")
                _ = cards.map(\.key)
                guard keep, !cards.isEmpty else { continue }
                for (scheme, width) in [(ColorScheme.light, 390.0), (.light, 220), (.dark, 390), (.dark, 220)] {
                    let view = ReplyCardsView(cards: cards).padding(8).frame(width: width)
                        .background(scheme == .dark ? Color.black : Color.white)
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: view)
                    renderer.proposedSize = ProposedViewSize(width: width, height: nil)
                    #expect(renderer.uiImage != nil, "\(name) drew")
                }
            }
        }
    }

    /// A daily brief in odd words is read, or isn't, and drawn either way.
    @Test func oddDailyBriefsReadWithoutCrashing() {
        let texts = [
            "", "|", "| Time | Title |\n|---|---|", "| Time | Title |\n|---|---|\n| 25:99 – 99:00 | x |\n| 9:00 – 8:00 | backwards |",
            "| Time | Title | Zoom Link |\n|---|---|---|\n| All day | \(Self.long) | [Join](javascript:x) |",
            "## Morning Meeting Brief — Feb 30\n" + (0 ..< 400).map { "| \($0 % 24):00 – \($0 % 24):30 | E\($0) |" }.joined(separator: "\n"),
            "| Time |\n|---|\n| 9:00 |", "| Title |\n|---|\n| only a title |", "\(Self.rtl)\n| שעה | כותרת |\n|---|---|\n| 9:00 | פגישה |",
            "- 9:00 AM \(Self.emoji)\n- 0:00 – 0:00 nothing\n- 12:00 PM – 12:00 AM wraps",
        ]
        for text in texts {
            for title in ["Daily meeting brief", "Morning brief", "", Self.long] {
                if let brief = DayBrief.read(title: title, text: text, at: .now) {
                    _ = ImageRenderer(content: DayBriefAgenda(brief: brief).frame(width: 390)).uiImage
                    _ = ImageRenderer(content: DayStrip(brief: brief).frame(width: 300, height: 120)).uiImage
                }
                _ = DayBrief.withoutNarration(text)
            }
        }
    }

    // MARK: What the odd ones read as

    private func card(_ json: String, keep: Bool = true) throws -> ReplyCard {
        try #require(ReplyCards.parse(try JSONValue.parse(Data(json.utf8), keepingLongWholeNumbers: keep)).first)
    }

    @Test func wholeNumbersBecomeIntsOnlyWhenTheyFit() {
        #expect(2.6.nearestInt == 3 && (-2.6).nearestInt == -3 && 0.0.nearestInt == 0)
        #expect(1e20.nearestInt == nil && (-1e20).nearestInt == nil && Double.nan.nearestInt == nil && Double.infinity.nearestInt == nil)
        #expect(9.3e18.nearestInt == nil && 9.1e18.nearestInt == Int(9.1e18))
        #expect(1e20.nearestInt(in: 0 ... 100) == 100 && (-5.0).nearestInt(in: 0 ... 100) == 0 && Double.nan.nearestInt(in: 0 ... 100) == nil)
        #expect(1e20.wholeFigures == "100000000000000000000" && 42.0.wholeFigures == "42" && (-7.0).wholeFigures == "-7")
        #expect(ReplyCards.text(.number(1e20)) == "100000000000000000000", "no exponent")
        #expect(ReplyCards.text(.number(.nan)) == nil && ReplyCards.text(.number(.infinity)) == nil)
        #expect(ReplyCards.number(.string("nan")) == nil && ReplyCards.number(.string("inf")) == nil && ReplyCards.number(.string("21°")) == 21)
    }

    @Test func identifiersWrittenAsNumbersKeepTheirFigures() throws {
        // As a card call is read (`ReplyCards.cards(from:)`): every figure as the agent wrote it.
        let step = ToolActivity(name: ReplyCards.tool, preview: nil, status: .completed,
                                args: #"{"cards": [{"type": "delivery", "title": "Book", "carrier": "USPS", "status": "In transit", "tracking": 9400111899223197428490}, {"type": "flight", "confirmation": 12345678901234567890, "from": {"code": "LIS"}, "to": {"code": "JFK"}}, {"type": "places", "places": [{"name": "Café", "phone": 351912345678901234567}]}]}"#)
        let cards = try #require(ReplyCards.cards(from: step))
        guard cards.count == 3, case let .delivery(d) = cards[0], case let .flight(f) = cards[1], case let .places(p) = cards[2] else {
            Issue.record("not the three cards: \(cards)"); return
        }
        #expect(d.tracking == "9400111899223197428490")
        #expect(f.confirmation == "123456789012", "cut to twelve as any confirmation is")
        #expect(p.places.first?.phone == "351912345678901234567")
        // The transport still reads numbers as numbers.
        #expect(try JSONValue.parse(Data("9400111899223197428490".utf8)).number == 9.400111899223197e21)
        #expect(try JSONValue.parse(Data("[123, 1.5, 1e20]".utf8)) == .array([.number(123), .number(1.5), .number(1e20)]))
    }

    @Test func numbersPastAnyUseAreLeftOut() throws {
        guard case let .score(s) = try card(#"{"type": "score", "games": [{"status": "final", "home": {"name": "A", "score": 1e20}, "away": {"name": "B", "score": 2}}]}"#) else {
            Issue.record("no score"); return
        }
        #expect(s.games.first?.home.score == nil && s.games.first?.away.score == 2)
        guard case let .recipe(r) = try card(#"{"type": "recipe", "title": "R", "servings": 1e20, "prep": 1e20, "cook": 25, "ingredients": ["1 cup x"]}"#) else {
            Issue.record("no recipe"); return
        }
        #expect(r.servings == nil && r.prep == nil && r.cook == 25 * 60)
        guard case let .reminder(t) = try card(#"{"type": "reminder", "kind": "timer", "title": "T", "duration": 1e308}"#) else {
            Issue.record("no timer"); return
        }
        #expect(t.duration == nil && t.at == nil)
        _ = ReplyCard.reminder(t).key
        guard case let .show(show) = try card(#"{"type": "show", "items": [{"title": "T", "seasons": 1e20, "runtime": 1e20}]}"#) else {
            Issue.record("no show"); return
        }
        #expect(show.items.first?.seasons == nil && show.items.first?.runtime == nil)
        guard case let .compare(c) = try card(#"{"type": "compare", "options": ["A", "B"], "rows": [{"criterion": "x", "values": ["a", "b"], "best": 1e20}], "pick": 1e20}"#) else {
            Issue.record("no comparison"); return
        }
        #expect(c.pick == nil && c.rows.first?.best == nil)
        guard case let .weather(w) = try card(#"{"type": "weather", "place": "X", "now": {"temperature": 20, "condition": "clear", "humidity": 1e20, "precipitation": "nan"}}"#) else {
            Issue.record("no weather"); return
        }
        #expect(w.now?.humidity == 100 && w.now?.precipitation == nil)
        #expect(ReplyCards.lasting(1e300) == .seconds(ReplyCards.longestSpan) && ReplyCards.lasting(.nan) == .zero)
    }
}

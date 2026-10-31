import Foundation
import Testing
import UIKit
@testable import Echo

/// The recipe, delivery, flight, show, conversion and stock cards (asked 2026-10-31): read
/// leniently as agents write them, what they work out on the phone (servings, units, a currency at
/// the agent's rate, each flight time in its airport's zone), and the messages their chips send.
@MainActor
struct NewestCardsTests {
    private let us = Locale(identifier: "en_US")

    private func card(_ text: String) throws -> ReplyCard { try #require(ReplyCards.parse(try JSONValue.parse(Data(text.utf8))).first) }

    // MARK: Recipes

    @Test func ingredientsAreReadWithTheirAmountsAndUnits() {
        func read(_ line: String) -> ReplyCard.Recipe.Ingredient { ReplyCard.Recipe.ingredient(line) }
        #expect(read("1 1/2 cups flour") == .init(amount: 1.5, unit: "cups", name: "flour"))
        #expect(read("½ tsp red pepper flakes") == .init(amount: 0.5, unit: "tsp", name: "red pepper flakes"))
        #expect(read("1½ cups of milk") == .init(amount: 1.5, unit: "cups", name: "milk"), "\"of\" dropped")
        #expect(read("2-3 cloves garlic, crushed") == .init(amount: 2, upTo: 3, unit: "cloves", name: "garlic, crushed"))
        #expect(read("2 large eggs") == .init(amount: 2, name: "large eggs"), "a word that isn't a unit stays in the name")
        #expect(read("250 g butter") == .init(amount: 250, unit: "g", name: "butter"))
        #expect(read("2 fl oz cream") == .init(amount: 2, unit: "fl oz", name: "cream"))
        #expect(read("Salt, to taste") == .init(name: "Salt, to taste"), "nothing to scale")
        #expect(read("1,5 kg potatoes").amount == 1.5)
    }

    @Test func amountsScaleAndAreWrittenAsACookWould() {
        let flour = ReplyCard.Recipe.ingredient("1 1/2 cups flour")
        #expect(ReplyCard.Recipe.scaled(flour, by: 2, locale: us) == ("3", "cups flour"))
        #expect(ReplyCard.Recipe.scaled(flour, by: 0.5, locale: us) == ("¾", "cup flour"), "one cup or less: the unit made one")
        let pepper = ReplyCard.Recipe.ingredient("½ tsp red pepper flakes")
        #expect(ReplyCard.Recipe.scaled(pepper, by: 1.5, locale: us) == ("¾", "tsp red pepper flakes"))
        let oil = ReplyCard.Recipe.ingredient("2 tbsp olive oil")
        #expect(ReplyCard.Recipe.scaled(oil, by: 1, locale: us).rest == "tbsp olive oil", "a short form stays as it is")
        let cup = ReplyCard.Recipe.ingredient("1 cup basil")
        #expect(ReplyCard.Recipe.scaled(cup, by: 2, locale: us) == ("2", "cups basil"))
        let pinch = ReplyCard.Recipe.ingredient("2 pinches salt")
        #expect(ReplyCard.Recipe.scaled(pinch, by: 0.5, locale: us) == ("1", "pinch salt"))
        let garlic = ReplyCard.Recipe.ingredient("2-3 cloves garlic")
        #expect(ReplyCard.Recipe.scaled(garlic, by: 2, locale: us).amount == "4–6")
        let butter = ReplyCard.Recipe.ingredient("250 g butter")
        #expect(ReplyCard.Recipe.scaled(butter, by: 1.5, locale: us).amount == "375", "weighed: in decimals")
        #expect(ReplyCard.Recipe.quantity(1.0 / 3, locale: us) == "⅓" && ReplyCard.Recipe.quantity(2.333, locale: us) == "2⅓")
        #expect(ReplyCard.Recipe.quantity(0.45, locale: us) == "0.45", "no fraction near: decimals")
        #expect(ReplyCard.Recipe.quantity(0.375, locale: us) == "⅜")
        #expect(ReplyCard.Recipe.quantity(12.4, locale: us) == "12")
        #expect(ReplyCard.Recipe.scaled(.init(name: "Salt"), by: 3, locale: us) == (nil, "Salt"))
    }

    @Test func aRecipeIsReadLeniently() throws {
        guard case let .recipe(r) = try card(#"""
        {"type": "recipe", "title": "Banana Bread", "source": "Redde Kitchen", "url": "https://example.com/bread", "image": "http://example.com/a.jpg",
         "prep": "PT15M", "cook": 60, "servings": "Makes 8 slices",
         "ingredients": ["3 ripe bananas", {"amount": "1 1/2", "unit": "cups", "name": "flour"}, {"name": "salt", "amount": "a pinch"}],
         "sections": [{"title": "Topping", "ingredients": ["2 tbsp sugar"]}],
         "steps": "1. Mash the bananas.\n2) Mix in the rest.\nStep 3: Bake."}
        """#) else { Issue.record("not a recipe"); return }
        #expect(r.title == "Banana Bread" && r.url == "https://example.com/bread" && r.image == nil, "pictures only by https")
        #expect(r.prep == 900 && r.cook == 3600 && r.allTime == 4500 && r.servings == 8)
        #expect(r.ingredients.map(\.name) == ["ripe bananas", "flour", "a pinch salt", "sugar"])
        #expect(r.ingredients[1].amount == 1.5 && r.ingredients[1].unit == "cups" && r.ingredients[3].section == "Topping")
        #expect(r.steps == ["Mash the bananas.", "Mix in the rest.", "Bake."], "numbers dropped: the card numbers them")
        let lines = RecipeCard.lines(r, servings: 16, locale: us)
        #expect(lines[0].spoken == "6 ripe bananas" && lines[1].spoken == "3 cups flour")
        #expect(ReplyCards.parse(try JSONValue.parse(Data(#"{"type": "recipe", "title": "Nothing in it"}"#.utf8))).isEmpty)
        let shown = RecipeCard.Shown(r)
        #expect(shown.times.map(\.name) == ["Prep", "Cook", "Total"] && shown.view == "View Recipe at Redde Kitchen")
    }

    @Test func aRecipesChipsSayWhatWasAsked() throws {
        guard case let .recipe(r) = try card(#"{"type": "recipe", "title": "Pasta", "servings": 4, "ingredients": ["12 oz spaghetti"], "steps": ["Boil."]}"#)
        else { Issue.record("not a recipe"); return }
        let lines = RecipeCard.lines(r, servings: 6, locale: us)
        let list = RecipeCard.ask(.shopping, r, servings: 6, lines: lines)
        #expect(list.shown == "Make a shopping list for the Pasta" && list.said.contains("18 oz spaghetti") && list.said.contains("set to 6 servings"))
        #expect(list.said.contains("'checklist' card"))
        let veg = RecipeCard.ask(.vegetarian, r, servings: 4, lines: lines)
        #expect(veg.said.contains("'recipe' card") && veg.said.contains("never make up a source"))
        for chip in RecipeCard.FollowUp.allCases {
            #expect(RecipeCard.FollowUp.asked(in: CardNote.note(key: "k", said: RecipeCard.ask(chip, r, servings: 4, lines: lines).said)) == chip)
            #expect(UIImage(systemName: chip.symbol) != nil)
        }
        #expect(ReplyCard.recipe(r).answerable && !ReplyCard.recipe(r).key.isEmpty)
    }

    // MARK: Deliveries

    @Test func aPackageIsReadWithWhereItStands() throws {
        guard case let .delivery(d) = try card(#"""
        {"type": "package", "title": "Headphones", "carrier": "UPS", "tracking": "1ZDEMO0000000001", "status": "Out for delivery",
         "expected": "2026-11-05", "window": "By 8 PM",
         "history": [{"text": "Departed", "at": "2026-11-04T21:40:00-05:00"}, {"text": "Out for delivery", "place": "Orlando, FL", "at": "2026-11-05T06:12:00-05:00"}]}
        """#) else { Issue.record("not a delivery"); return }
        #expect(d.stage == .outForDelivery && !d.problem && d.window == "By 8 PM" && d.expectedAllDay)
        #expect(d.events.map(\.text) == ["Out for delivery", "Departed"], "the newest scan first")
        #expect(ReplyCard.Delivery.stage("Delivery attempted")! == (.shipped, true))
        #expect(ReplyCard.Delivery.stage("Delivered, front door")! == (.delivered, false))
        #expect(ReplyCard.Delivery.stage("Label created")! == (.ordered, false))
        #expect(ReplyCard.Delivery.stage("In transit")! == (.shipped, false))
        #expect(ReplyCard.Delivery.trackingPage(carrier: "UPS", number: "1Z DEMO 0000000001")?.absoluteString == "https://www.ups.com/track?tracknum=1ZDEMO0000000001")
        #expect(ReplyCard.Delivery.trackingPage(carrier: "Northwind Couriers", number: "12345678") == nil, "only carriers whose pages are known")
        #expect(ReplyCards.parse(try JSONValue.parse(Data(#"{"type": "delivery", "title": "A box"}"#.utf8))).isEmpty, "nothing on where it stands")
        let shown = DeliveryCard.Shown(d)
        #expect(shown.view == "Track at UPS" && shown.url?.host() == "www.ups.com")
        let refresh = DeliveryCard.refresh(d)
        #expect(refresh.said.contains("UPS tracking 1ZDEMO0000000001") && refresh.said.contains("tapped Refresh") && refresh.said.contains("never guess"))
    }

    @Test func whenAPackageComesIsSaidInDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = us
        let now = ISO8601DateFormatter().date(from: "2026-11-02T15:00:00Z")!   // a Monday
        func day(_ days: Double) -> Date { now.addingTimeInterval(days * 86_400) }
        #expect(DeliveryCard.arrives(day(0), now: now, calendar: calendar) == "Arrives today")
        #expect(DeliveryCard.arrives(day(1), now: now, calendar: calendar) == "Arrives tomorrow")
        #expect(DeliveryCard.arrives(day(3), now: now, calendar: calendar).hasPrefix("Arrives "))
        #expect(DeliveryCard.arrives(day(-2), now: now, calendar: calendar).hasPrefix("Was due"))
        #expect(DeliveryCard.day(day(-1), now: now, calendar: calendar) == "yesterday")
    }

    // MARK: Flights

    @Test func aFlightKeepsEachAirportsOwnTime() throws {
        guard case let .flight(t) = try card(#"""
        {"type": "flight", "airline": "Northwind Air", "number": "NW238", "seat": "23A",
         "from": {"code": "lis", "city": "Lisbon", "name": "Humberto Delgado Airport", "terminal": "1", "gate": "14",
                  "time": "2026-11-05T10:35:00+00:00", "new_time": "2026-11-05T11:20:00+00:00"},
         "to": {"code": "JFK", "city": "New York", "time": "2026-11-05T13:20:00-05:00", "new_time": "2026-11-05T14:05:00-05:00"}}
        """#) else { Issue.record("not a flight"); return }
        let f = try #require(t.legs.first)
        #expect(f.number == "NW 238" && f.from.code == "LIS" && f.status == .delayed, "late by its times: delayed")
        #expect(f.departs?.offset == 0 && f.arrives?.offset == -5 * 3600)
        #expect(f.flightTime == 27_900.0, "7h 45m")
        let leg = FlightCard.Leg(t, 0)
        #expect(leg.departs?.replacing(/\s/, with: " ") == FlightCard.clock(f.departsNew!, locale: Locale.current).replacing(/\s/, with: " "))
        let lisbon = try #require(f.departsNew), newYork = try #require(f.arrivesNew)
        #expect(FlightCard.clock(lisbon, locale: us).replacing(/\s/, with: " ") == "11:20 AM", "in Lisbon's time, wherever the phone is")
        #expect(FlightCard.clock(newYork, locale: us).replacing(/\s/, with: " ") == "2:05 PM")
        #expect(FlightCard.dayShift(lisbon, newYork) == 0 && leg.length == "7h 45m")
        #expect(f.from.mapsQuery == "Humberto Delgado Airport (LIS)" && f.to.mapsQuery == "New York Airport (JFK)")
        #expect(ReplyCard.Trip.Airport(code: "XXXX", city: "Nowhere").mapsQuery == nil && ReplyCard.Trip.Airport(code: "LIS").mapsQuery == nil,
                "Maps only for a real place")
        let refresh = FlightCard.refresh(t)
        #expect(refresh.shown == "Check on my flight" && refresh.said.contains("Northwind Air NW 238 (LIS→JFK) departing 2026-11-05T10:35:00Z"))
    }

    @Test func aTripsLegsAndTheirLayover() throws {
        guard case let .flight(t) = try card(#"""
        {"type": "trip", "confirmation": "DEMO42", "legs": [
          {"number": "NW 102", "status": "On time", "from": "Lisbon (LIS)", "to": {"code": "EWR", "city": "Newark", "time": "2026-11-10T11:05:00-05:00"},
           "departs": "2026-11-10T08:05:00+00:00"},
          {"number": "NW 1517", "status": "cancelled", "from": {"code": "EWR", "city": "Newark", "time": "2026-11-10T13:15:00-05:00"},
           "to": {"code": "DEN", "time": "2026-11-10T15:45:00-07:00"}},
          {"number": "NW 9", "from": "2026-11-10"}]}
        """#) else { Issue.record("not a trip"); return }
        #expect(t.legs.count == 2 && t.confirmation == "DEMO42", "a leg without both ends is left out")
        #expect(t.legs[0].from == .init(code: "LIS", city: "Lisbon") && t.legs[0].status == .onTime && t.legs[1].status == .cancelled)
        #expect(FlightCard.Leg(t, 1).layover == "Layover in Newark · 2h 10m")
        #expect(FlightCard.route(t) == "LIS → EWR → DEN")
        #expect(ReplyCards.flightStatus("En route") == .departed && ReplyCards.flightStatus("Gate closing") == .boarding
                && ReplyCards.flightStatus("Arrived") == .landed && ReplyCards.flightStatus("whatever") == nil)
        for status in ReplyCard.Trip.Flight.Status.allCases { #expect(UIImage(systemName: FlightCard.symbol(status)) != nil, "\(status)") }
    }

    // MARK: Shows

    @Test func titlesAreReadWithTheirRatingsAndWhereToWatch() throws {
        guard case let .show(s) = try card(#"""
        {"type": "show", "title": "Like what you liked", "items": [
          {"title": "Northbound", "year": "2021–2023", "seasons": "3 seasons", "genres": "Thriller, Drama", "rating": "8.1/10", "watch": "StreamBox, Harbor TV"},
          {"name": "The Quiet Floor", "year": 2022, "format": "TV series", "pick": true, "poster": "https://img.example.com/p.jpg",
           "ratings": [{"source": "Critics", "value": "96%"}, "Audience 8.6/10"], "creator": "Jo Marlow", "cast": ["Ana Reyes"], "watch": [{"name": "StreamBox"}]},
          {"title": "Paper Moons", "runtime": 118, "ratings": {"Critics": 91}}]}
        """#) else { Issue.record("not a show card"); return }
        #expect(s.lead == 1 && s.title == "Like what you liked")
        let a = s.items[0], b = s.items[1], c = s.items[2]
        #expect(a.year == 2021 && a.endYear == 2023 && a.seasons == 3 && a.format == .series && a.genres == ["Thriller", "Drama"])
        #expect(a.ratings == [.init(value: "8.1/10")] && a.watch == ["StreamBox", "Harbor TV"])
        #expect(b.ratings == [.init(source: "Critics", value: "96%"), .init(source: "Audience", value: "8.6/10")] && b.watch == ["StreamBox"])
        #expect(c.format == .movie && c.runtime == 118 * 60 && c.ratings == [.init(source: "Critics", value: "91")])
        #expect(ShowCard.Shown(a).facts == "2021–2023 · Series · 3 seasons")
        #expect(ShowCard.Shown(b).people == "Created by Jo Marlow · With Ana Reyes")
        guard case let .show(one) = try card(#"{"type": "movie", "title": "Paper Moons", "year": 2019}"#) else { Issue.record("one title"); return }
        #expect(one.items.map(\.name) == ["Paper Moons"] && one.title == nil, "a card that is one title")
        let similar = ShowCard.ask(.similar, s)
        #expect(similar.shown == "More like The Quiet Floor" && similar.said.contains("'show' card") && similar.said.contains("not these"))
        #expect(ShowCard.ask(.watch, s).said.contains("never guess a service"))
    }

    // MARK: Conversions

    @Test func unitsAreWorkedOutOnThePhone() throws {
        guard case let .conversion(c) = try card(#"{"type": "conversion", "from": "5 miles", "to": "km", "result": 99}"#) else { Issue.record("not a conversion"); return }
        #expect(c.amount == 5 && c.units != nil)
        #expect(abs((c.convert(5) ?? 0) - 8.04672) < 0.0001, "the phone's answer, not the agent's")
        #expect(ConversionCard.figure(8.04672, locale: us) == "8.05" && ConversionCard.figure(26_400, locale: us) == "26,400" && ConversionCard.figure(0.03110, locale: us) == "0.0311")
        guard case let .conversion(t) = try card(#"{"type": "conversion", "amount": 350, "from": "°F", "to": "celsius"}"#) else { Issue.record("temperature"); return }
        #expect(abs((t.convert(350) ?? 0) - 176.6667) < 0.001 && abs((t.convert(-40) ?? 0) + 40) < 0.0001)
        #expect(ConversionCard.Shown.formula(UnitTemperature.fahrenheit, UnitTemperature.celsius, "°F", "°C", locale: us) == "°C = (°F − 32) × 5/9")
        let fuel = ReplyCard.Conversion(amount: 30, from: "mpg", to: "L/100km")
        #expect(abs((fuel.convert(30) ?? 0) - 7.84) < 0.01, "miles per gallon to litres per 100 km: one over the other")
        #expect(ConversionCard.nearby(5, temperature: false) == [1, 2, 10, 20] && ConversionCard.nearby(350, temperature: true) == [340, 360, 370])
        #expect(ReplyCard.Conversion.unit("mi")?.symbol == "mi" && ReplyCard.Conversion.unit("degrees Fahrenheit")?.symbol == "°F" && ReplyCard.Conversion.unit("parsecs") == nil)
        #expect(ReplyCard.Conversion(amount: 1, from: "mi", to: "kg").units == nil, "of two kinds: not worked out")
        #expect(ReplyCard.Conversion(amount: 1, from: "kg", to: "lb").convert(1).map { abs($0 - 2.2046) < 0.001 } == true)
        #expect(ReplyCard.Conversion(amount: 1, from: "GB", to: "MB").convert(1) == 1000)
        #expect(ReplyCards.parse(try JSONValue.parse(Data(#"{"type": "conversion", "amount": 3, "from": "smoots", "to": "m"}"#.utf8))).isEmpty,
                "a unit the phone doesn't know needs the agent's answer")
        guard case let .conversion(odd) = try card(#"{"type": "conversion", "amount": 3, "from": "smoots", "to": "m", "result": 5.1}"#) else { Issue.record("odd"); return }
        #expect(abs((odd.convert(6) ?? 0) - 10.2) < 0.0001, "the agent's answer, scaled")
    }

    @Test func aCurrencyIsOnlyEverAtTheAgentsRate() throws {
        guard case let .conversion(c) = try card(#"{"type": "currency", "amount": 100, "from": "usd", "to": "EUR", "rate": 0.9214, "as_of": "2026-10-31T09:00:00-04:00", "source": "ECB"}"#)
        else { Issue.record("not a conversion"); return }
        #expect(c.isCurrency && c.from == "USD" && c.rate == 0.9214 && c.asOf != nil)
        #expect(c.convert(250) == 250 * 0.9214, "scaled by the rate given, nothing looked up")
        let shown = ConversionCard.Shown(c, locale: us)
        #expect(shown.rate?.hasPrefix("Rate from ") == true && shown.rate?.hasSuffix("· ECB") == true)
        #expect(shown.formula == "1 USD = 0.9214 EUR · 1 EUR = 1.0853 USD")
        #expect(shown.money(92.14, in: "EUR") == "€92.14")
        guard case let .conversion(byAnswer) = try card(#"{"type": "conversion", "amount": 100, "from": "USD", "to": "JPY", "result": 15230}"#) else { Issue.record("by answer"); return }
        #expect(byAnswer.rate == 152.3)
        #expect(ReplyCards.parse(try JSONValue.parse(Data(#"{"type": "conversion", "amount": 100, "from": "USD", "to": "EUR"}"#.utf8))).isEmpty,
                "no rate: no card, never a guess")
        #expect(!ReplyCard.conversion(c).answerable)
    }

    // MARK: Stocks

    @Test func aQuoteIsReadAndItsMoveWorkedOut() throws {
        guard case let .stock(s) = try card(#"""
        {"type": "stock", "symbol": "nwnd", "name": "Northwind Systems", "price": "$191.20", "change": "+2.40", "day_range": "189.00 - 192.10",
         "year_range": [141.22, 205.1], "market_cap": "2.71T", "volume": "48.2M", "as_of": "2026-10-30T16:00:00-04:00", "delayed": "15 min",
         "points": [188.8, 189.5, 190.1, 191.2]}
        """#) else { Issue.record("not a stock card"); return }
        let q = try #require(s.items.first)
        #expect(q.symbol == "NWND" && q.price == 191.2 && q.change == 2.4 && q.direction == 1)
        #expect(abs((q.percent ?? 0) - 1.2712) < 0.001, "the percent from the change")
        #expect(q.low == 189 && q.high == 192.1 && q.yearLow == 141.22 && q.marketCap == 2.71e12 && q.volume == 48_200_000 && q.delayed == true)
        let shown = StockCard.Shown(q, locale: us)
        #expect(shown.price == "$191.20" && shown.move == "+2.40 (+1.27%)")
        #expect(shown.line.count == 4 && shown.line.allSatisfy { (0 ... 1).contains($0) } && shown.base != nil)
        #expect(shown.facts.map(\.name) == ["Market cap", "Volume", "52-week range"] && shown.facts[0].value == "$2.71T")
        #expect(shown.spoken.contains("up 2.40 (1.27%)"), "said, not only coloured")
        #expect(ReplyCards.signed(.string("−0.5")) == -0.5 && ReplyCards.signed(.string("(0.4%)")) == -0.4 && ReplyCards.signed(.string("+1.2%")) == 1.2)
        #expect(abs((ReplyCards.big(.string("$512.3B")) ?? 0) - 512.3e9) < 1 && ReplyCards.big(.string("1,234,567")) == 1_234_567)
        guard case let .stock(few) = try card(#"{"type": "stock", "items": [{"symbol": "A", "price": 10, "percent": -2}, {"symbol": "B"}, {"price": 3}]}"#)
        else { Issue.record("several"); return }
        #expect(few.items.count == 1 && few.items[0].direction == -1 && abs((few.items[0].change ?? 0) + 0.2041) < 0.001)
        let refresh = StockCard.refresh(s)
        #expect(refresh.shown == "Update NWND" && refresh.said.contains("never buy or sell"))
        #expect(StockCard.asOf(q, now: ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!)?.hasSuffix("· Delayed") == true)
    }

    // MARK: All six

    @Test func theNewestCardsKeepTheirKeysAndRoundTrip() throws {
        let all = ReplyCards.parse(try JSONValue.parse(Data(#"""
        {"cards": [{"type": "recipe", "title": "Pasta", "ingredients": ["1 cup x"]},
                   {"type": "delivery", "carrier": "UPS", "tracking": "1ZDEMO", "status": "In transit"},
                   {"type": "flight", "from": "LIS", "to": "JFK", "departs": "2026-11-05T10:35:00+00:00"},
                   {"type": "show", "title": "Paper Moons"}]}
        """#.utf8)))
        let more = ReplyCards.parse(try JSONValue.parse(Data(#"""
        {"cards": [{"type": "conversion", "amount": 5, "from": "mi", "to": "km"}, {"type": "stock", "symbol": "A", "price": 1}]}
        """#.utf8)))
        #expect(all.count == 4 && more.count == 2)
        let every = all + more
        let again = try JSONDecoder().decode([ReplyCard].self, from: JSONEncoder().encode(every))
        #expect(again == every && again.map(\.key) == every.map(\.key))
        #expect(every.map(\.answerable) == [true, true, true, true, false, true])
        #expect(Set(every.filter(\.answerable).map(\.key)).count == 5)
        for card in every { #expect(!CardLookup.needsLookup(card), "nothing looked up on the phone") }
    }

    @Test func picturesOfAnySizeComeOnceAndOnlyWithLinkPreviews() async throws {
        let images = ProductImages()
        images.fetch = { _ in
            UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { _ in UIColor.blue.setFill(); UIRectFill(.init(x: 0, y: 0, width: 1200, height: 800)) }.pngData()
        }
        let url = try #require(URL(string: "https://img.example.com/recipes/a.jpg"))
        let banner = try #require(await images.image(url, side: 1_000))
        #expect(max(banner.size.width * banner.scale, banner.size.height * banner.scale) <= 1_000)
        #expect(images.cached(url, side: 1_000) != nil && images.cached(url) == nil, "each size kept on its own")
        let settings = Settings(defaults: UserDefaults(suiteName: "newest-\(UUID().uuidString)")!)
        #expect(ProductImages.allowed(url, settings: settings) == nil, "off: no site sees a visit")
    }
}

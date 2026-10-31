import Foundation
import Testing
import UIKit
@testable import Echo

/// The purchase card (asked 2026-10-30: "a 'purchase' card for when asking for purchase
/// recommendations"): products read leniently as agents write them (a price as "$279" or 279, a
/// rating as "4.6/5", the pick by its flag or its badge), prices in the person's way of writing
/// money, the chips' messages, and pictures only with Link previews on.
@MainActor
struct PurchaseCardTests {
    private let us = Locale(identifier: "en_US")

    private func purchase(_ text: String, locale: Locale = Locale(identifier: "en_US")) throws -> ReplyCard.Purchase {
        let value = try JSONValue.parse(Data(text.utf8))
        guard case .purchase = try #require(ReplyCards.parse(value).first) else { throw CardError.notThatCard }
        return try #require(ReplyCards.purchase(value["cards"]?.array?.first ?? value, locale: locale))
    }

    private enum CardError: Error { case notThatCard }

    @Test func productsAreReadAsAgentsWriteThem() throws {
        let card = try purchase(#"""
        {"cards": [{"type": "purchase", "title": "Headphones under $300", "note": "Prices checked Oct 30; they change.", "items": [
          {"name": "Aurora Q5", "brand": "Northwind", "price": "$279", "was_price": "$349.00", "rating": "4.6/5", "reviews": "12,480",
           "retailer": "Best Buy", "url": "https://example.com/a", "image": "https://img.example.com/a.jpg", "pick": true,
           "pros": ["Quiet", "Light"], "cons": "Bulky case; No aptX", "specs": {"Weight": "254 g", "Battery": "30 h", "Multipoint": true}},
          {"name": "Tidal Air", "price": 199.99, "rating": 9.2, "reviews": "2.1k", "badge": "Best value", "url": "ftp://example.com/b",
           "image": "http://img.example.com/b.jpg", "pick": true},
          {"title": "Drift Buds", "price": "From $99", "rating": "4.3 out of 5", "reviews": "(3,201 reviews)",
           "specs": [{"name": "Battery", "value": "8 h"}, "Water: IPX4"]},
          {"brand": "No name, so left out"},
          "Plain Name"]}]}
        """#)
        #expect(card.title == "Headphones under $300" && card.note == "Prices checked Oct 30; they change.")
        #expect(card.items.map(\.name) == ["Aurora Q5", "Tidal Air", "Drift Buds", "Plain Name"], "one with no name is dropped")
        let a = card.items[0], b = card.items[1], c = card.items[2]
        #expect(a.price == 279 && a.currency == "USD" && a.wasPrice == 349 && a.rating == 4.6 && a.reviews == 12480)
        #expect(a.retailer == "Best Buy" && a.url == "https://example.com/a" && a.image == "https://img.example.com/a.jpg")
        #expect(a.pros == ["Quiet", "Light"] && a.cons == ["Bulky case", "No aptX"], "cons in a line split at its semicolons")
        #expect(a.specs.map(\.name) == ["Battery", "Multipoint", "Weight"] && a.specs[1].value == "Yes", "a dictionary's specs by name")
        #expect(b.price == 199.99 && b.currency == nil && b.rating == 4.6 && b.reviews == 2100)
        #expect(b.url == nil && b.image == nil, "only http(s) pages, and https pictures")
        #expect(!b.pick && a.pick, "one pick: the first flagged")
        #expect(c.price == nil && c.priceWords == "From $99" && c.rating == 4.3 && c.reviews == 3201)
        #expect(c.specs == [.init(name: "Battery", value: "8 h"), .init(name: "Water", value: "IPX4")], "a list's specs in their order")
        #expect(card.lead == 0 && card.hasPick)
    }

    @Test func thePickByItsFlagOrItsBadge() throws {
        let byWords = try purchase(#"{"type": "purchase", "items": [{"name": "A"}, {"name": "B", "pick": "Best overall"}, {"name": "C", "badge": "Budget pick"}]}"#)
        #expect(byWords.lead == 1 && byWords.items[1].badge == "Best overall")
        let byBadge = try purchase(#"{"type": "purchase", "items": [{"name": "A", "badge": "Budget pick"}, {"name": "B", "badge": "Top pick"}]}"#)
        #expect(byBadge.lead == 1 && byBadge.items[1].pick && !byBadge.items[0].pick, "a budget pick isn't the pick")
        let none = try purchase(#"{"type": "purchase", "items": [{"name": "A", "pick": false}, {"name": "B", "pick": "no"}]}"#)
        #expect(!none.hasPick && none.lead == 0, "no pick: the first is shown first")
        let flagged = try purchase(#"{"type": "purchase", "items": [{"name": "A"}, {"name": "B", "pick": "yes"}]}"#)
        #expect(flagged.lead == 1 && flagged.items[1].badge == nil)
        #expect(ReplyCards.parse(try JSONValue.parse(Data(#"{"type": "purchase", "items": [{"price": 3}]}"#.utf8))).isEmpty, "nothing named: no card")
        let many = try purchase(#"{"type": "products", "products": ["A", "B", "C", "D", "E", "F", "G", "H"]}"#)
        #expect(many.items.count == ReplyCards.maxProducts)
    }

    @Test func pricesAsAgentsWriteThem() {
        func read(_ text: String) -> (Double?, String?, String?) {
            let found = ReplyCards.money(.string(text), locale: Locale(identifier: "en_US"))
            return (found.amount, found.currency, found.words)
        }
        #expect(read("$279") == (279, "USD", nil))
        #expect(read("1,299.99") == (1299.99, nil, nil))
        #expect(read("1.299,00 €") == (1299, "EUR", nil))
        #expect(read("£1,299") == (1299, "GBP", nil))
        #expect(read("USD 279") == (279, "USD", nil))
        #expect(read("279 eur") == (279, "EUR", nil))
        #expect(read("CA$ 349") == (349, "CAD", nil))
        #expect(read("12,50") == (12.5, nil, nil))
        #expect(read("From $199") == (nil, nil, "From $199"), "words around it are kept")
        #expect(ReplyCards.money(.number(279)).amount == 279 && ReplyCards.money(.number(-1)).amount == nil)
        // A "$" is the person's own dollar where theirs is one.
        #expect(ReplyCards.money(.string("$279"), locale: Locale(identifier: "en_CA")).currency == "CAD")
        #expect(ReplyCards.money(.string("$279"), locale: Locale(identifier: "pt_PT")).currency == "USD")
    }

    @Test func ratingsAndReviews() {
        #expect(ReplyCards.stars(.string("4.6/5")) == 4.6 && ReplyCards.stars(.string("9.2/10")) == 4.6)
        #expect(ReplyCards.stars(.string("92%")) == 4.6 && ReplyCards.stars(.number(4.65)) == 4.7)
        #expect(ReplyCards.stars(.string("4,5 stars")) == 4.5 && ReplyCards.stars(.string("great")) == nil)
        #expect(ReplyCards.stars(.number(7)) == 3.5 && ReplyCards.stars(.number(500)) == nil)
        #expect(ReplyCards.count(.string("1.2M")) == 1_200_000 && ReplyCards.count(.string("12,480")) == 12480 && ReplyCards.count(.number(87)) == 87)
    }

    @Test func pricesAreShownInThePersonsWay() throws {
        #expect(ReplyCard.Purchase.money(279, currency: "USD", locale: us) == "$279")
        #expect(ReplyCard.Purchase.money(199.99, currency: "USD", locale: us) == "$199.99")
        #expect(ReplyCard.Purchase.money(279, currency: "EUR", locale: Locale(identifier: "de_DE")).contains("279"))
        #expect(ReplyCard.Purchase.money(279, currency: "EUR", locale: Locale(identifier: "de_DE")).contains("€"))
        #expect(ReplyCard.Purchase.homeCurrency(Locale(identifier: "en_GB")) == "GBP")

        let card = try purchase(#"""
        {"type": "purchase", "items": [{"name": "Tidal Air", "price": 199, "rating": 4.5, "reviews": 812, "retailer": "Amazon", "badge": "Best value"},
          {"name": "Aurora Q5", "price": 279, "was_price": 349, "rating": 4.7, "reviews": 12480, "retailer": "Best Buy", "pick": true, "url": "https://example.com/a"},
          {"name": "Kestrel", "price": "€99"}]}
        """#)
        let shown = PurchaseCard.Shown(card, locale: us)
        #expect(shown.lead == 1 && shown.others == [0, 2], "the pick first, then the rest in the agent's order")
        let pick = shown.items[1]
        #expect(pick.price == "$279" && pick.was == "$349" && pick.saving == "Save 20%")
        #expect(pick.ratingText == "4.7 (12K)" && pick.badge == "Pick" && pick.tone == .pick && pick.view == "View at Best Buy")
        #expect(pick.spoken == "Pick, Aurora Q5, $279, was $349, rated 4.7 out of 5, 12,480 reviews, at Best Buy")
        #expect(shown.items[0].facts == "4.5 (812) · Amazon" && shown.items[0].tone == .value)
        #expect(shown.items[2].price == "€99" && shown.items[2].view == "View Product")
        #expect(shown.range == nil, "prices in two currencies have no range")
        let alike = PurchaseCard.Shown(try purchase(#"{"type": "purchase", "items": [{"name": "A", "price": 199}, {"name": "B", "price": 379}]}"#), locale: us)
        #expect(alike.range == "$199 – $379")
    }

    @Test func whatAProductIsDrawnAs() {
        #expect(PurchaseCard.symbol(for: "Noise-cancelling headphones under $300") == "headphones")
        #expect(PurchaseCard.symbol(for: "Drift ANC Earbuds") == "earbuds")
        #expect(PurchaseCard.symbol(for: "Aurora Q5", else: "Best laptops for students") == "laptopcomputer")
        #expect(PurchaseCard.symbol(for: "Pixel phone case") == "iphone" && PurchaseCard.symbol(for: "Headphone stand") == "headphones")
        #expect(PurchaseCard.symbol(for: "Something", else: "Gift ideas for Dad") == "gift")
        #expect(PurchaseCard.symbol(for: "A panel heater") == "bag", "a word inside another isn't it")
        for (_, symbol) in PurchaseCard.symbols {
            #expect(UIImage(systemName: symbol) != nil, "\(symbol) is a symbol")
        }
    }

    @Test func theChipsAskTheAgentAndTellTheirAnswerAgain() throws {
        let card = try purchase(#"""
        {"type": "purchase", "title": "Headphones", "items": [{"name": "Tidal Air", "price": 199}, {"name": "Aurora Q5", "price": 279, "currency": "USD", "pick": true}]}
        """#)
        #expect(PurchaseCard.followUps(card) == [.why, .cheaper, .compare])
        #expect(PurchaseCard.followUps(try purchase(#"{"type": "purchase", "items": ["Only"]}"#)) == [.cheaper])
        let why = PurchaseCard.ask(.why, card)
        #expect(why.shown == "Why the Aurora Q5?")
        #expect(why.said.contains("tapped \"Why this one?\"") && why.said.contains("\"Aurora Q5\" (279 USD)"))
        let compare = PurchaseCard.ask(.compare, card)
        #expect(compare.shown == "Compare the Aurora Q5 and the Tidal Air", "the pick first")
        let cheaper = PurchaseCard.ask(.cheaper, card)
        #expect(cheaper.said.contains("'purchase' card") && cheaper.said.contains("never make up prices"))
        for chip in PurchaseCard.FollowUp.allCases {
            #expect(PurchaseCard.FollowUp.asked(in: CardNote.note(key: "k", said: PurchaseCard.ask(chip, card).said)) == chip)
        }
        let whole = ReplyCard.purchase(card)
        #expect(whole.answerable && !whole.key.isEmpty)
        #expect(whole.key == ReplyCard.purchase(try JSONDecoder().decode(ReplyCard.Purchase.self, from: JSONEncoder().encode(card))).key,
                "kept and read back, the same key")
    }

    @Test func picturesOnlyWithLinkPreviewsOn() async throws {
        let images = ProductImages()
        let asked = Asked()
        images.fetch = { url in
            await asked.add(url)
            return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { _ in UIColor.red.setFill(); UIRectFill(.init(x: 0, y: 0, width: 600, height: 400)) }.pngData()
        }
        let url = try #require(URL(string: "https://img.example.com/a.jpg"))
        #expect(images.cached(url) == nil)
        let image = try #require(await images.image(url))
        #expect(max(image.size.width * image.scale, image.size.height * image.scale) <= ProductImages.side, "made small for the card")
        _ = await images.image(url)
        #expect(await asked.urls == [url], "fetched once, then from memory")
        #expect(images.cached(url) != nil)

        images.fetch = { _ in nil }
        let missing = try #require(URL(string: "https://img.example.com/missing.jpg"))
        #expect(await images.image(missing) == nil)
        images.fetch = { _ in Data() }
        #expect(await images.image(missing) == nil, "a picture that couldn't be had isn't asked again")
        #expect(await ProductImages.download(try #require(URL(string: "http://img.example.com/a.jpg"))) == nil, "https only")
    }

    @Test func picturesAreFetchedOnlyWithLinkPreviewsOn() throws {
        let settings = Settings(defaults: UserDefaults(suiteName: "purchase-\(UUID().uuidString)")!)
        let url = try #require(URL(string: "https://img.example.com/a.jpg"))
        #expect(!settings.linkPreviews && ProductImages.allowed(url, settings: settings) == nil, "off unless turned on: no store sees a visit")
        settings.linkPreviews = true
        #expect(ProductImages.allowed(url, settings: settings) == url)
        #expect(ProductImages.allowed(nil, settings: settings) == nil)
    }

    @Test func cardsKeptBeforeStillReadAndThisOneRoundTrips() throws {
        let card = try purchase(#"{"type": "purchase", "items": [{"name": "A", "price": 5, "pros": ["x"], "specs": {"k": "v"}}]}"#)
        let again = try JSONDecoder().decode([ReplyCard].self, from: JSONEncoder().encode([ReplyCard.purchase(card)]))
        #expect(again == [.purchase(card)])
    }
}

private actor Asked {
    var urls: [URL] = []
    func add(_ url: URL) { urls.append(url) }
}

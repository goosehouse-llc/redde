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
        #expect(b.price == 199.99 && b.currency == "USD" && b.rating == 4.6 && b.reviews == 2100, "no currency of its own: the card's others'")
        #expect(b.url == nil && b.image == nil, "only http(s) pages, and https pictures")
        #expect(!b.pick && a.pick, "one pick: the first flagged")
        #expect(c.price == nil && c.priceWords == "From $99" && c.rating == 4.3 && c.reviews == 3201)
        #expect(c.specs == [.init(name: "Battery", value: "8 h"), .init(name: "Water", value: "IPX4")], "a list's specs in their order")
        #expect(card.lead == 0 && card.hasPick)
    }

    /// One product at several stores (a price check) is shown by store; different products by product.
    @Test func aPriceCheckIsShownByStore() throws {
        let check = try purchase(#"""
        {"cards": [{"type": "purchase", "title": "Shark Navigator NV360", "items": [
          {"name": "Shark Navigator NV360 upright", "price": 148.90, "retailer": "Walmart", "pick": true},
          {"name": "Shark Navigator Lift-Away Deluxe NV360", "price": 149.99, "retailer": "Amazon"},
          {"name": "Shark NV360 Navigator", "price": 107.99, "retailer": "eBay (seller)"}]}]}
        """#)
        let shown = PurchaseCard.Shown(check, locale: us)
        #expect(shown.byStore && shown.ordered == [0, 1, 2], "a model number they all name: one product, the pick first")
        #expect(shown.items[1].storeLine == "Shark Navigator Lift-Away Deluxe NV360", "a store's line, with no rating: its name for the product")
        #expect(PurchaseCard.followUps(check) == [.why, .cheaper], "no Compare the top two: they're the same product")

        let same = try purchase(#"""
        {"cards": [{"type": "purchase", "items": [{"name": "Bounty Paper Towels", "price": 21.99, "retailer": "Target"},
          {"name": "bounty paper towels", "price": 19.99, "retailer": "Publix", "pick": true}]}]}
        """#)
        let shownSame = PurchaseCard.Shown(same, locale: us)
        #expect(shownSame.byStore && shownSame.ordered == [1, 0], "the same name at two stores")

        let choices = try purchase(#"""
        {"cards": [{"type": "purchase", "title": "Cordless vacuums", "items": [
          {"name": "Dyson V15 Detect", "price": 649, "retailer": "Dyson", "pick": true},
          {"name": "Shark Stratos IZ862H", "price": 399, "retailer": "Shark"}]}]}
        """#)
        #expect(!PurchaseCard.Shown(choices, locale: us).byStore, "different products, each at its store")
        let noStores = try purchase(#"""
        {"cards": [{"type": "purchase", "items": [{"name": "Aurora Q5"}, {"name": "Aurora Q5"}]}]}
        """#)
        #expect(!PurchaseCard.Shown(noStores, locale: us).byStore, "no store named: nothing to show by store")
    }

    /// Design F (2026-11-13): the deal meter from what the pick usually sells for, else its store's
    /// old price; every store folded into one row, those with nothing to sell last.
    @Test func theDealMeterAndTheFoldedRow() throws {
        let card = try purchase(#"""
        {"cards": [{"type": "purchase", "title": "Cuisinart 4-Cup Rice Cooker", "usual_price": "$80", "items": [
          {"name": "Cuisinart CRC-400", "price": 59.99, "retailer": "Target", "pick": true, "badge": "Best pick"},
          {"name": "Cuisinart CRC-400", "retailer": "Walmart", "availability": "OutOfStock", "price": 61},
          {"name": "Cuisinart CRC-400", "price": 59.95, "retailer": "Amazon"},
          {"name": "Cuisinart CRC-400", "retailer": "Best Buy"}]}]}
        """#)
        #expect(card.usual == 80)
        let shown = PurchaseCard.Shown(card, locale: us)
        let meter = try #require(shown.meter)
        #expect(meter.verdict == .good && meter.title == "Good deal" && meter.gap == "About $20 under usual" && meter.reference == "Usual $80")
        #expect(meter.low == "$45" && meter.price > 0 && meter.price < meter.usual && meter.usual < 1, "the price on the bar, before the usual zone")
        #expect(shown.byStore && shown.listed == [0, 2, 1, 3], "the pick, the one with a price, then those with none to sell")
        #expect(shown.everyTitle == "4 stores checked" && shown.everyLine == "Amazon $59.95 · 2 not available")

        let ladder = PurchaseCard.meter(price: 50, usual: 100, was: nil, currency: "USD", locale: us)
        #expect(ladder?.verdict == .great && ladder?.gap == "About $50 under usual")
        #expect(PurchaseCard.meter(price: 100, usual: 100, was: nil, currency: "USD", locale: us)?.gap == nil, "about usual: no gap said")
        let over = try #require(PurchaseCard.meter(price: 110, usual: 100, was: 130, currency: "USD", locale: us))
        #expect(over.verdict == .above && over.gap == "About $10 over usual" && over.price > over.usual, "the usual price over the store's old one")
        let sale = try #require(PurchaseCard.meter(price: 148.90, usual: nil, was: 219.99, currency: "USD", locale: us))
        #expect(sale.verdict == .sale && sale.reference == "Was $219.99" && sale.gap == "$71 off")
        #expect(PurchaseCard.meter(price: 149, usual: nil, was: nil, currency: "USD", locale: us) == nil, "nothing to measure against")
        #expect(PurchaseCard.meter(price: 149, usual: nil, was: 120, currency: "USD", locale: us) == nil, "an old price under the new isn't a sale")
    }

    @Test func watchPriceAsksTheAgentToKeepAnEyeOnThePick() throws {
        let card = try purchase(#"""
        {"cards": [{"type": "purchase", "title": "Rice cooker", "items": [
          {"name": "Cuisinart CRC-400", "price": 59.99, "retailer": "Target", "url": "https://example.com/t", "pick": true}]}]}
        """#)
        let asked = PurchaseCard.ask(.watch, card)
        #expect(asked.shown == "Watch the price of the Cuisinart CRC-400")
        #expect(asked.said.contains("keep_an_eye_on") && asked.said.contains("at Target (https://example.com/t)"))
        #expect(PurchaseCard.FollowUp.asked(in: asked.said) == .watch)
        #expect(!PurchaseCard.followUps(card).contains(.watch), "at the card's foot, not among the chips")
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

    /// The listing names its real site and page, so a link that isn't at the store the agent named
    /// shows as what it is (2026-10-31).
    @Test func aListingReadsAsItsSiteAndPage() {
        #expect(ListingLink.address(URL(string: "https://www.bestbuy.com/site/aurora-q5/6501234.p?skuId=6501234#reviews")!) == "bestbuy.com/site/aurora-q5/6501234.p")
        #expect(ListingLink.address(URL(string: "https://www.amazon.com/")!) == "amazon.com")
        #expect(ListingLink.address(URL(string: "https://shop.example.com/tidal-air-3/")!) == "shop.example.com/tidal-air-3")
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
          {"name": "Aurora Q5", "price": 279, "currency": "USD", "was_price": 349, "rating": 4.7, "reviews": 12480, "retailer": "Best Buy", "pick": true, "url": "https://example.com/a"},
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

    /// UAT 2.3.1 (2026-10-31): in Japan, products with no currency showed "¥299" beside "$279".
    @Test func aProductWithNoCurrencyTakesTheCards() throws {
        let japan = Locale(identifier: "ja_JP")
        let mixed = try purchase(#"{"type": "purchase", "items": [{"name": "A", "price": "$279"}, {"name": "B", "price": 299}, {"name": "C", "price": "$199.99"}, {"name": "D", "price": 129, "currency": "eur"}, {"name": "E", "price": 99}]}"#, locale: japan)
        #expect(mixed.items.map(\.currency) == ["USD", "USD", "USD", "EUR", "USD"], "the one given most")
        let tie = try purchase(#"{"type": "purchase", "items": [{"name": "A", "price": 1, "currency": "GBP"}, {"name": "B", "price": 2, "currency": "EUR"}, {"name": "C", "price": 3}]}"#, locale: japan)
        #expect(tie.items[2].currency == "GBP", "on a tie, the first given")
        let named = try purchase(#"{"type": "purchase", "currency": "CAD", "items": [{"name": "A", "price": 1}, {"name": "B", "price": 2, "currency": "USD"}]}"#, locale: japan)
        #expect(named.items.map(\.currency) == ["CAD", "USD"], "the card's own currency first")
        let none = try purchase(#"{"type": "purchase", "items": [{"name": "A", "price": 1}, {"name": "B", "price": 2}]}"#, locale: japan)
        #expect(none.items.allSatisfy { $0.currency == nil }, "none given: the person's own, when drawn")
        let shown = PurchaseCard.Shown(mixed, locale: japan)
        #expect(shown.items[1].price?.contains("$") == true && shown.items[1].price?.contains("¥") == false, "\(shown.items[1].price ?? "")")
        #expect(PurchaseCard.Shown(none, locale: japan).items[0].price?.contains("¥") == true)
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

    /// Plugin 1.14.0 reads each product's store page before the card shows (2026-10-31): whether
    /// it is in stock, and when the page was read, for the note when the plugin gave none.
    @Test func inStockOrNotAndWhenThePagesWereRead() throws {
        let card = try purchase(#"""
        {"type": "purchase", "items": [
          {"name": "A", "price": 24.99, "availability": "in_stock", "checked": "2026-10-31T19:42:00+00:00"},
          {"name": "B", "availability": "out_of_stock", "checked": "2026-10-31T19:40:00+00:00"},
          {"name": "C", "availability": "https://schema.org/OutOfStock"}, {"name": "D", "availability": "In Stock"},
          {"name": "E", "stock": "Only 3 left in stock"}, {"name": "G", "availability": "Ships in 2 weeks"}]}
        """#)
        #expect(card.items.map(\.availability) == [.inStock, .outOfStock, .outOfStock, .inStock, .inStock, nil])
        let more = try purchase(#"{"type": "purchase", "items": [{"name": "F", "in_stock": false}, {"name": "H", "availability": "Sold out", "checked": "yesterday"}]}"#)
        #expect(more.items.map(\.availability) == [.outOfStock, .outOfStock])
        let newest = try #require(ReplyCard.Agenda.when("2026-10-31T19:42:00+00:00")?.date)
        #expect(card.items[0].checked == newest && more.items[1].checked == nil, "only an ISO time")
        #expect(card.checked == newest, "the newest page read")
        let shown = PurchaseCard.Shown(card, locale: us)
        #expect(shown.items[0].stock == "In stock" && shown.items[0].inStock)
        #expect(shown.items[1].stock == "Out of stock" && !shown.items[1].inStock)
        #expect(shown.items[5].stock == nil)
        #expect(shown.items[0].spoken == "A, $24.99, In stock", "VoiceOver hears it too")
        #expect(shown.note?.hasPrefix("Prices checked ") == true, "no note: when the pages were read")
        #expect(PurchaseCard.checkedNote(newest, now: newest.addingTimeInterval(60), locale: us).hasPrefix("Prices checked "))
        #expect(!PurchaseCard.checkedNote(newest, now: newest.addingTimeInterval(60), locale: us).contains("2026"), "today: the time alone")
        #expect(PurchaseCard.checkedNote(newest, now: newest.addingTimeInterval(3 * 86_400), locale: us).contains("Oct 31"))
        let noted = PurchaseCard.Shown(try purchase(#"{"type": "purchase", "note": "Prices checked Oct 31, 3:42 PM", "items": [{"name": "A", "checked": "2026-10-31T19:42:00+00:00"}]}"#), locale: us)
        #expect(noted.note == "Prices checked Oct 31, 3:42 PM", "the plugin's own note stands")
        #expect(PurchaseCard.Shown(try purchase(#"{"type": "purchase", "items": [{"name": "A"}]}"#), locale: us).note == nil)
    }

    /// A product with no picture of its own shows its store page's, as its listing read it, with
    /// Link previews on, never the site's icon, and never from a preview kept before it said which.
    @Test func aProductWithNoPictureShowsItsStorePagesPicture() throws {
        let page = try #require(URL(string: "https://shop.example.com/plug"))
        let own = try #require(URL(string: "https://img.example.com/plug.jpg"))
        let photo = Data([1, 2, 3])
        let read = LinkPreview(url: page, title: "Plug", site: "shop.example.com", image: photo, imageSource: .page)
        #expect(PurchaseCard.picture(image: nil, page: page, preview: read, linkPreviews: true) == .listing(photo))
        #expect(PurchaseCard.picture(image: own, page: page, preview: read, linkPreviews: true) == .own(own), "its own picture first")
        #expect(PurchaseCard.picture(image: nil, page: page, preview: read, linkPreviews: false) == .drawn, "nothing with Link previews off")
        var icon = read
        icon.imageSource = .icon
        #expect(PurchaseCard.picture(image: nil, page: page, preview: icon, linkPreviews: true) == .drawn, "a logo is no photo of the product")
        var unknown = read
        unknown.imageSource = nil
        #expect(PurchaseCard.picture(image: nil, page: page, preview: unknown, linkPreviews: true) == .drawn, "kept before it said: not known")
        #expect(PurchaseCard.picture(image: nil, page: page, preview: nil, linkPreviews: true) == .drawn, "not read yet")
        #expect(PurchaseCard.picture(image: nil, page: nil, preview: read, linkPreviews: true) == .drawn)
        let elsewhere = LinkPreview(url: try #require(URL(string: "https://shop.example.com/other")), title: nil, site: "x", image: photo, imageSource: .page)
        #expect(PurchaseCard.picture(image: nil, page: page, preview: elsewhere, linkPreviews: true) == .drawn, "another page's picture")

        // A preview kept on disk before 2026-10-31 has no source: it reads, as not known.
        let kept = try JSONEncoder().encode(LinkPreview(url: page, title: "Plug", site: "shop.example.com", image: photo))
        var old = try #require(try JSONSerialization.jsonObject(with: kept) as? [String: Any])
        old.removeValue(forKey: "imageSource")
        let back = try JSONDecoder().decode(LinkPreview.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(back.image == photo && back.imageSource == nil && back.pagePicture == nil)
        let again = try JSONDecoder().decode(LinkPreview.self, from: JSONEncoder().encode(read))
        #expect(again == read && again.pagePicture == photo)
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

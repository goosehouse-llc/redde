import Foundation
import Testing
@testable import Echo

/// The review and the checklist drawn to the approved designs (asked 2026-10-30): a review as the
/// thing itself, by the kind the agent said or by its fields; a checklist in its groups, with a
/// word beside an item and how it stands in the agent's word.
struct AnswerCardStyleTests {
    private func cards(_ json: String) -> [ReplyCard] { ReplyCards.parse(try? JSONValue.parse(Data(json.utf8))) }

    private func review(_ json: String) -> ReplyCard.Review? {
        guard case let .review(review) = cards(#"{"cards": [\#(json)]}"#).first else { return nil }
        return review
    }

    @Test func aReviewSaysWhatItIsOrItsFieldsDo() throws {
        let email = try #require(review(#"""
        {"type": "review", "kind": "E-mail", "subtitle": "From your Gmail · as you", "title": "Email to send", "action": "Send",
         "fields": [{"label": "To", "value": "Ana Okafor"}, {"label": "Subject", "value": "Late"}, {"label": "Body", "value": "Hi Ana,\n\nStart without me."}]}
        """#))
        #expect(email.kind == .email && email.shownKind == .email && email.subtitle == "From your Gmail · as you")
        #expect(email.layout == .init(to: 0, subject: 1, body: 2, rows: []))

        // No kind: told by the labels, any case, a colon after.
        let fields = { (labels: [String: String]) in
            #"{"type": "review", "title": "x", "fields": [\#(labels.sorted { $0.key < $1.key }.map { #"{"label": "\#($0.key)", "value": "\#($0.value)"}"# }.joined(separator: ","))]}"#
        }
        #expect(review(fields(["to:": "Ana", "SUBJECT": "Hi"]))?.shownKind == .email)
        #expect(review(fields(["To": "Milo", "Message": "Late"]))?.shownKind == .message)
        #expect(review(fields(["To": "milo@example.com", "Message": "Late"]))?.shownKind == .email, "to an address: an email")
        #expect(review(fields(["When": "Sat 7:30", "Party": "4"]))?.shownKind == .event)
        #expect(review(fields(["Item": "Lamp", "Total": "$40"]))?.shownKind == .purchase)
        #expect(review(fields(["Light": "Porch", "Turn": "Off"]))?.shownKind == .other)
        #expect(review(fields(["Light": "Porch"]).replacingOccurrences(of: #""type": "review""#, with: #""type": "review", "kind": "a fax""#))?.kind == nil,
                "a kind it can't place is left to the fields")
        #expect(ReplyCard.Review.Kind(lenient: "Booking") == .purchase && ReplyCard.Review.Kind(lenient: "SMS") == .message)

        // A message's words are its long field when none is named; other kinds are all rows.
        let text = try #require(review(#"{"type": "review", "kind": "message", "title": "x", "fields": [{"label": "Cc", "value": "Ben"}, {"label": "To", "value": "Milo"}, {"label": "Note", "value": "a\nb"}]}"#))
        #expect(text.layout == .init(to: 1, subject: nil, body: 2, rows: [0]))
        #expect(review(fields(["When": "Sat", "Where": "Lupa"]))?.layout == .init(rows: [0, 1]))
    }

    @Test func initialsAreTheNamesBeforeAnAddress() {
        #expect(ReplyCard.Review.initials("Ana Okafor") == "AO")
        #expect(ReplyCard.Review.initials("Ana María de la Cruz") == "AC")
        #expect(ReplyCard.Review.initials("milo") == "M")
        #expect(ReplyCard.Review.initials("ana.okafor@example.com") == "AO")
        #expect(ReplyCard.Review.initials("Ana Okafor <ana@example.com>, Ben") == "AO")
        #expect(ReplyCard.Review.initials("+1 555 0100") == "", "a number: no letters, a figure instead")
        #expect(ReplyCard.Review.initials("") == "")
    }

    @Test func aChecklistComesInGroupsWithNotes() throws {
        guard case let .checklist(list) = cards(#"""
        {"cards": [{"type": "checklist", "title": "Cocoa Beach weekend", "subtitle": "Nov 7 – 8", "verb": "packed", "groups": [
          {"name": "Clothes", "items": [{"text": "Swimsuits", "note": "×2", "done": true}, "Sandals"]},
          {"name": "Beach", "items": [{"text": "Sunscreen", "note": 50}]}],
          "items": [{"text": "Chargers", "group": "Everything else"}]}]}
        """#).first else { Issue.record("no checklist"); return }
        #expect(list.subtitle == "Nov 7 – 8" && list.verb == "packed")
        #expect(list.sections.map(\.title) == ["Everything else", "Clothes", "Beach"])
        #expect(list.items.map(\.note) == [nil, "×2", nil, "50"])

        guard case let .checklist(plain) = cards(#"{"cards": [{"type": "checklist", "title": "Shop", "items": ["Eggs", "Milk"]}]}"#).first else {
            Issue.record("no list"); return
        }
        #expect(plain.sections.count == 1 && plain.sections[0].title == nil, "ungrouped: one panel")
        #expect(plain.subtitle == nil && plain.verb == nil && plain.items.allSatisfy { $0.note == nil })
    }

    @Test func cardsKeptBeforeTheseFieldsStillRead() throws {
        // Saved conversations hold cards as they were: without a kind, a subtitle, a verb or notes.
        let old = #"""
        [{"review": {"_0": {"title": "Email to Ana", "action": "Send", "fields": [{"label": "To", "value": "Ana", "long": false}]}}},
         {"checklist": {"_0": {"title": "Packing", "items": [{"text": "Passport", "done": true}]}}}]
        """#
        let read = try JSONDecoder().decode([ReplyCard].self, from: Data(old.utf8))
        guard case let .review(review) = read[0], case let .checklist(list) = read[1] else { Issue.record("kinds"); return }
        #expect(review.kind == nil && review.subtitle == nil && list.verb == nil && list.items[0].note == nil)
        let again = try JSONDecoder().decode([ReplyCard].self, from: JSONEncoder().encode(cards(#"{"cards": [{"type": "review", "kind": "event", "title": "x", "fields": [{"label": "When", "value": "Sat"}]}]}"#)))
        #expect(again.first.map { if case let .review(r) = $0 { r.kind == .event } else { false } } == true)
        #expect(read[0].key == ReplyCard.review(.init(title: "Email to Ana", action: "Send", fields: [.init(label: "To", value: "Ana", long: false)], note: nil)).key,
                "the key an answer goes by is unchanged")
    }
}

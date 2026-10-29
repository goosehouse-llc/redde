import Foundation
import SwiftUI
import Testing
@testable import Echo

/// Cards the person answers with a tap (asked 2026-10-28, after Meta's Muse): read from the call,
/// answered as the person's next message with a note of exactly what they chose, and shown answered
/// when the conversation is read back.
@MainActor
struct AnswerCardTests {
    private func cards(_ json: String) -> [ReplyCard] { ReplyCards.parse(try? JSONValue.parse(Data(json.utf8))) }

    @Test func theFourKindsAreRead() {
        let read = cards(#"""
        {"cards": [
          {"type": "review", "title": "Email to Ana", "action": "Send", "fields": [{"label": "To", "value": "ana@example.com"}, {"label": "Message", "value": "Line one\nLine two"}]},
          {"type": "choice", "title": "Where to eat?", "options": [{"title": "Lupa", "detail": "Italian", "image": "http://insecure.example/x.jpg"}, "Sushi Ko"]},
          {"type": "checklist", "title": "Packing", "items": [{"text": "Passport", "done": true}, "Charger"]},
          {"type": "form", "title": "Booking", "fields": [{"label": "Date", "kind": "date"}, {"label": "Where", "kind": "choice"}, {"label": "People", "kind": "number", "required": true}]}
        ]}
        """#)
        #expect(read.count == 4 && read.allSatisfy(\.answerable))
        guard case let .review(review) = read[0], case let .choice(choice) = read[1], case let .checklist(list) = read[2], case let .form(form) = read[3] else {
            Issue.record("kinds"); return
        }
        #expect(review.action == "Send" && review.fields[1].long && !review.fields[0].long)
        #expect(choice.options.map(\.title) == ["Lupa", "Sushi Ko"] && choice.options[0].image == nil, "only https pictures")
        #expect(list.items.map(\.done) == [true, false])
        #expect(form.fields.map(\.kind) == [.date, .text, .number], "a choice with no options is typed")
        #expect(cards(#"{"cards": [{"type": "choice", "options": ["Only one"]}]}"#).isEmpty)
        #expect(cards(#"{"cards": [{"type": "review", "title": "Nothing in it"}]}"#).isEmpty)
    }

    @Test func aChecklistComesInSectionsWithItsEmoji() {
        let read = cards(#"""
        {"cards": [{"type": "checklist", "title": "Cabin", "emoji": "🏕️ camping", "sections": [
          {"title": "Clothing", "items": ["Swimsuits", {"text": "Hoodies", "done": true}]}],
          "items": [{"text": "Sunscreen", "section": "Toiletries"}, {"text": "Towels", "section": "Clothing"}]}]}
        """#)
        guard case let .checklist(list) = read.first else { Issue.record("no checklist"); return }
        #expect(list.emoji == "🏕️" && list.items.count == 4)
        #expect(list.sections.map(\.title) == ["Toiletries", "Clothing"])
        #expect(list.sections[1].items.count == 3, "a section's items together, wherever they came")
        #expect(list.items.first { $0.text == "Hoodies" }?.done == true)
    }

    @Test func aChecklistIsPinnedSharedAsTextAndDrawnReadable() throws {
        guard case let .checklist(list) = cards(#"""
        {"cards": [{"type": "checklist", "title": "Cabin", "emoji": "🏕️", "items": [{"text": "Swimsuits", "section": "Clothing"},
          {"text": "Sunscreen", "section": "Toiletries"}, {"text": "Hoodies", "section": "Clothing"}]}]}
        """#).first else { Issue.record("no checklist"); return }
        #expect(ChecklistExport.text(list, done: [0]) == "🏕️ Cabin\n\n## Clothing\n- [x] Swimsuits\n- [ ] Hoodies\n\n## Toiletries\n- [ ] Sunscreen")

        let pins = PinnedCards(defaults: UserDefaults(suiteName: "pins-\(UUID().uuidString)")!)
        let card = ReplyCard.checklist(list)
        pins.pin(card, title: "Cabin", conversation: nil, agent: nil)
        pins.pin(card, title: "Cabin", conversation: nil, agent: nil)
        #expect(pins.pins.count == 1 && pins.isPinned(card.key), "pinned once")
        pins.unpin(card.key)
        #expect(pins.pins.isEmpty)

        // A pale theme colour on a light card gives way to the text; a strong one stays.
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        let pale = Color(red: 0.75, green: 0.9, blue: 1), strong = Color(red: 0.1, green: 0.35, blue: 0.9)
        #expect(pale.readable(on: .white, or: .black, in: environment) == .black)
        #expect(strong.readable(on: .white, or: .black, in: environment) == strong)
    }

    @Test func aCardsKeyIsTheSameEachTimeItIsRead() {
        let json = #"{"cards": [{"type": "choice", "title": "Where?", "options": ["A", "B"]}]}"#
        #expect(cards(json)[0].key == cards(json)[0].key && !cards(json)[0].key.isEmpty)
        #expect(cards(json)[0].key != cards(#"{"cards": [{"type": "choice", "title": "Where?", "options": ["A", "C"]}]}"#)[0].key)
    }

    @Test func theAnswerNoteIsFoundAndHidden() {
        let sent = "Lupa" + CardNote.note(key: "k1", said: "from \"Where?\" the user picked: \"Lupa\"") + "\n\n(Reply in English.)"
        #expect(CardNote.find(in: sent)?.key == "k1" && CardNote.find(in: sent)?.said.contains("Lupa") == true)
        #expect(ReplyLanguage.stripNote(sent) == "Lupa")
        // After an aside's note too.
        let both = "Lupa" + (AsideNote.note(for: [.init(agent: "ops", name: "Home", asked: "@home hi", answer: "Hello")]) ?? "")
            + CardNote.note(key: "k2", said: "x")
        #expect(ReplyLanguage.stripNote(both) == "Lupa")
        #expect(CardNote.find(in: both)?.key == "k2")
    }

    @Test func aTapSendsTheAnswerWithItsNoteAndTheCardStaysAnswered() async throws {
        let settings = Settings(defaults: UserDefaults(suiteName: "answers-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "answers-\(UUID().uuidString)"))
        let transport = BotsTests.RecordingTransport()
        let conversation = Conversation(settings: settings, store: store, transportOverride: transport)
        conversation.reset()
        let card = cards(#"{"cards": [{"type": "choice", "title": "Where to eat?", "options": ["Lupa", "Sushi Ko"]}]}"#)[0]
        conversation.answerCard(card, shown: "Lupa", said: "from \"Where to eat?\" the user picked: \"Lupa\"")
        for _ in 0 ..< 200 where transport.requests.isEmpty || conversation.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        let sent = try #require(transport.requests.last)
        #expect(sent.userText.hasPrefix("Lupa\n\n[Redde card \(card.key): "))
        #expect(conversation.messages.first { $0.role == .user }?.text == "Lupa", "the note isn't shown")
        #expect(CardAnswers.shared.said[card.key]?.contains("Lupa") == true)
        // Read back elsewhere: the note marks it answered.
        let other = cards(#"{"cards": [{"type": "checklist", "title": "Packing", "items": ["Passport"]}]}"#)[0]
        _ = Conversation.messages(fromServeRows: [.object(["role": .string("user"), "text": .string("Done" + CardNote.note(key: other.key, said: "\"Packing\" now has done (0): Passport; not done: "))])])
        for _ in 0 ..< 50 where CardAnswers.shared.said[other.key] == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(CardAnswers.shared.said[other.key] != nil)
        #expect(ChecklistCard.ticked(in: CardAnswers.shared.said[other.key] ?? "") == [0])
    }
}

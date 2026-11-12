import Foundation
import Testing
@testable import Echo

struct MessageQuoteTests {
    @Test func aQuotedMessageGoesOutAsMarkdownAndComesBackApart() {
        let quote = QuotedText(text: "Leave by 8:10 for the 9:00.\nTraffic is light.", speaker: "Sol")
        let sent = Quote.message("Can I leave at 8:20?", quoting: quote)
        #expect(sent == "> Leave by 8:10 for the 9:00.\n> Traffic is light.\n\nCan I leave at 8:20?")
        let back = Quote.split(sent)
        #expect(back?.quote == "Leave by 8:10 for the 9:00.\nTraffic is light.")
        #expect(back?.rest == "Can I leave at 8:20?")
    }

    @Test func noQuoteLeavesTheMessageAsTyped() {
        #expect(Quote.message("Hello", quoting: nil) == "Hello")
        #expect(Quote.message("Hello", quoting: QuotedText(text: "  ")) == "Hello")
    }

    @Test func onlyAQuoteWithWordsUnderItIsSplit() {
        #expect(Quote.split("Hello") == nil)
        #expect(Quote.split("> just a pasted quote") == nil)
        #expect(Quote.split("> a quote\nno blank line") == nil)
        #expect(Quote.split(">\n\nwords") == nil)
        let blank = Quote.split("> first\n>\n> third\n\nAnd?")
        #expect(blank?.quote == "first\n\nthird")
        #expect(blank?.rest == "And?")
    }

    @Test func aLongMessageIsQuotedFromItsStart() {
        let long = String(repeating: "word ", count: 100)
        let excerpt = Quote.excerpt(long)
        #expect(excerpt.count <= Quote.wholeLimit + 1)
        #expect(excerpt.hasSuffix("word…"))
        #expect(Quote.excerpt("**Short** reply.") == "Short reply.")
    }

    @Test func quotingAQuotingMessageTakesItsOwnWords() {
        #expect(Quote.excerpt("> the agent's words\n\nMy question") == "My question")
    }

    @Test func aQuoteFindsTheMessageItCameFrom() {
        let first = Message(role: .assistant, text: "Leave by 8:10 for the 9:00. Traffic is light.")
        let other = Message(role: .assistant, text: "Something else entirely.")
        let mine = Message(role: .user, text: "> Leave by 8:10 for the 9:00.\n\nCan I leave later?")
        let later = Message(role: .assistant, text: "Leave by 8:10 for the 9:00, again.")
        let all = [first, other, mine, later]
        #expect(Quote.source(of: "Leave by 8:10 for the 9:00.", in: all, before: mine.id) == first.id)
        #expect(Quote.source(of: "Not said anywhere", in: all, before: mine.id) == nil)
        // The quoting message's own quote doesn't count as where it came from.
        #expect(Quote.source(of: "Leave by 8:10", in: [mine, later], before: later.id) == nil)
    }
}

struct SuggestedReplyTests {
    @Test func suggestionsAreTidiedIntoChips() {
        let chips = FollowUps.tidy(["\"Yes, book it.\"", "No thanks", "no thanks", "Want me to book it?", "x"],
                                   reply: "I found a table at 7. Want me to book it?")
        #expect(chips == ["Yes, book it", "No thanks"])
    }

    @Test func aReplyThatEndsByAskingIsAnsweredNotQuestioned() {
        #expect(FollowUps.endingQuestion("I found a table at 7:30. Want me to book it?") == "Want me to book it?")
        #expect(FollowUps.endingQuestion("**Navy** or green?") == "Navy or green?")
        #expect(FollowUps.endingQuestion("Done. The file is saved.") == nil)
        #expect(FollowUps.endingQuestion("Why? Because it was late.") == nil)
    }

    @Test func atMostThreeAndOneLineEach() {
        let chips = FollowUps.tidy(["One\nmore line", "Two", "Three", "Four"], reply: "")
        #expect(chips == ["One", "Two", "Three"])
    }
}

/// Apple's on-device model, where this machine has it (Apple Intelligence on): what it suggests
/// for a reply that asks something, and for one that doesn't. Skipped where it isn't available.
struct OnDeviceSuggestionTests {
    @Test(.enabled(if: FollowUps.onDeviceAvailable)) func theOnDeviceModelSuggestsReplies() async {
        let asked = await FollowUps.suggestOnDevice(question: "Find me a table for two tonight near the office",
                                                    reply: "I found a table for two at Lupa at 7:30 pm, ten minutes' walk from the office. Want me to book it?")
        let told = await FollowUps.suggestOnDevice(question: "How long do I boil an egg?",
                                                   reply: "About 9 minutes for a hard-boiled egg, 6 for a jammy yolk. Start them in boiling water and cool them in ice water.")
        let choice = await FollowUps.suggestOnDevice(question: "Which jacket should I get?",
                                                     reply: "Both are warm enough for Chicago. The navy one is lighter, the green one has a hood. Navy or green?")
        print("SUGGESTED asked: \(asked)\nSUGGESTED told: \(told)\nSUGGESTED choice: \(choice)")
        #expect(!asked.isEmpty && asked.count <= 3)
        #expect(!told.isEmpty && told.count <= 3)
    }
}

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
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

    @Test func optionsAReplyListsAreTheChipsAsTheyAre() {
        let flights = "I found three nonstop options on Friday:\n1. **United** 6:05 AM, $189\n2. Southwest 11:40 AM, $214\n3. Frontier 4:15 PM — cheapest\n\nWhich one should I hold?"
        #expect(FollowUps.listedOptions(flights) == ["United 6:05 AM, $189", "Southwest 11:40 AM, $214", "Frontier 4:15 PM"])
        let pick = "Two jackets fit:\n- Navy: lighter\n- Green: has a hood\nWant the navy or the green one?"
        #expect(FollowUps.listedOptions(pick) == ["Navy", "Green"])
        // A list of what was done, then a yes or no: not options.
        #expect(FollowUps.listedOptions("Here's what changed:\n- Fixed the crash\n- Faster launch\nShould I commit it?").isEmpty)
        // No question after the list, or an option too long for a chip.
        #expect(FollowUps.listedOptions("Steps:\n1. Grind\n2. Steep\nThen strain.").isEmpty)
        #expect(FollowUps.listedOptions("Pick:\n1. A\n2. \(String(repeating: "long ", count: 12))\nWhich?").isEmpty)
    }

    @Test func aReplyIsReadForWhatItCallsFor() {
        #expect(FollowUps.kind(of: "Your afternoon is free. Want me to block 2–4 for focus time?") == .yesNo("Want me to block 2–4 for focus time?"))
        #expect(FollowUps.kind(of: "Sure. When should I remind you?") == .ask("When should I remind you?"))
        #expect(FollowUps.kind(of: "Mañana estará soleado. ¿Quieres que lo apunte?") == .ask("Quieres que lo apunte?"))
        #expect(FollowUps.kind(of: "Done — the office lights are off.") == .next)
        // A short "done" gets no chips; a longer answer, or a short question, does.
        #expect(!FollowUps.worthSuggesting("Done — the office lights are off."))
        #expect(FollowUps.worthSuggesting("Sure. When should I remind you?"))
        #expect(FollowUps.worthSuggesting("Mix 1 part coarse-ground coffee with 4 parts cold water and steep it for 12 to 18 hours."))
    }

    /// The end of a reply is read once (`FollowUps.decide`), off the main actor; what it decides
    /// is what asking `listedOptions`, `worthSuggesting` and `kind` in turn gives, long replies
    /// included (a code block, a table and a list above the question, ~12,000 characters).
    @Test func theDecisionAtAReplysEndIsTheOneTheQuestionsGive() async {
        func asked(_ reply: String) -> FollowUps.Decision {
            let options = FollowUps.listedOptions(reply)
            if !options.isEmpty { return .options(options) }
            return FollowUps.worthSuggesting(reply) ? .suggest(FollowUps.kind(of: reply)) : .nothing
        }
        let prose = String(repeating: "The trail climbs through the trees and opens onto the ridge, where the wind picks up. ", count: 120)
        let code = "```swift\nlet kit = [\"water\", \"layers\"]\n// Which one? Not this.\n```\n"
        let table = "| Trail | Miles |\n|---|---|\n| Bear Ridge | 6 |\n| Falls Loop | 4 |\n"
        let long = "## The plan\n\n" + prose + "\n\n" + code + "\n" + table + "\n" + prose
        let replies = [
            long + "\n\nI found three trailheads:\n1. **Bear Ridge** — 6 miles\n2. Falls Loop: shortest\n3. [Cedar Notch](https://example.com)\n\nWhich one should I map?",
            long + "\n\nWant me to add it to your calendar?",
            long + "\n\nWhen do you want to leave?",
            long + "\n\nHave a good hike.",
            long + "\n\n" + code,
            code,
            "Done — the office lights are off.",
            "Sure. When should I remind you?",
            "Two jackets fit:\n- Navy: lighter\n- Green: has a hood\nWant the navy or the green one?",
            "Here's what changed:\n- Fixed the crash\n- Faster launch\nShould I commit it?",
            "",
        ]
        for reply in replies {
            #expect(FollowUps.decide(reply) == asked(reply), "\(reply.suffix(80))")
            #expect(await FollowUps.deciding(reply) == asked(reply))
        }
        #expect(FollowUps.decide(replies[0]) == .options(["Bear Ridge", "Falls Loop", "Cedar Notch"]))
        #expect(FollowUps.decide(replies[1]) == .suggest(.yesNo("Want me to add it to your calendar?")))
        #expect(FollowUps.decide(replies[2]) == .suggest(.ask("When do you want to leave?")))
        #expect(FollowUps.decide(replies[3]) == .suggest(.next))
        #expect(FollowUps.decide(code) == .nothing, "a code block alone is \"[code]\": too short to suggest after")
        #expect(FollowUps.decide("Done — the office lights are off.") == .nothing)
    }

    @Test func theFastLanePicksFromWhatsThere() {
        #expect(FollowUps.source(fastLaneSet: false, preferFastLane: true) == (FollowUps.onDeviceAvailable ? .onDevice : .none))
        #expect(FollowUps.source(fastLaneSet: true, preferFastLane: true) == .fastLane)
        #expect(FollowUps.source(fastLaneSet: true, preferFastLane: false) == (FollowUps.onDeviceAvailable ? .onDevice : .fastLane))
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
        // The simulator says the model is there but has no safety model for it, so every ask
        // fails (2026-11-13): that is the machine, not the suggestions.
        guard await Self.modelAnswers() else {
            print("SKIP: Apple's on-device model is listed but doesn't answer here")
            return
        }
        let asked = await FollowUps.suggestOnDevice(question: "Find me a table for two tonight near the office",
                                                    reply: "I found a table for two at Lupa at 7:30 pm, ten minutes' walk from the office. Want me to book it?")
        let told = await FollowUps.suggestOnDevice(question: "How long do I boil an egg?",
                                                   reply: "About 9 minutes for a hard-boiled egg, 6 for a jammy yolk. Start them in boiling water and cool them in ice water.")
        let choice = await FollowUps.suggestOnDevice(question: "Which jacket should I get?",
                                                     reply: "Both are warm enough for Chicago. The navy one is lighter, the green one has a hood. Navy or green?")
        let done = await FollowUps.suggestOnDevice(question: "Turn off the office lights", reply: "Done — the office lights are off.")
        print("SUGGESTED asked: \(asked)\nSUGGESTED told: \(told)\nSUGGESTED choice: \(choice)\nSUGGESTED done: \(done)")
        #expect(!asked.isEmpty && asked.count <= 3)
        #expect(!told.isEmpty && told.count <= 3)
    }

    /// Whether the on-device model answers at all on this machine.
    private static func modelAnswers() async -> Bool {
        #if canImport(FoundationModels)
        return (try? await LanguageModelSession().respond(to: "Say OK.").content.isEmpty == false) ?? false
        #else
        return false
        #endif
    }
}

import Foundation
import Testing
@testable import Echo

struct StopPhraseTests {
    @Test(arguments: [
        "Stop.", "stop listening", "That's all.", "Okay, that's all, thanks.", "Thanks, Hermes.",
        "Hey Hermes, stop hands-free please", "Thanks, Redde.", "Okay Redde, that's all.", "Stop listening, Redde", "Goodbye!", "We're done for now.", "Never mind.",
    ])
    func recognizesStopPhrases(_ text: String) {
        #expect(StopPhrase.matches(text))
    }

    @Test(arguments: [
        "Stop by the store on the way home", "What time does the pharmacy stop taking orders?",
        "Thanks for that, now tell me about tomorrow's weather", "Is it done compiling yet?",
        "How do I say goodbye in Japanese?", "Redde, stop the timer", "",
    ])
    func ignoresRealQuestions(_ text: String) {
        #expect(!StopPhrase.matches(text))
    }

    // MARK: A person's own phrases

    private let own = ["Das reicht", "basta così", "Feierabend!", "that'll do", "終わり", "  ", "das reicht"]

    @Test(arguments: [
        "Das reicht.", "das reicht", "Okay, das reicht, thanks", "Basta cosi", "BASTA COSÌ!", "Feierabend", "Hey Redde, Feierabend please",
        "That'll do.", "that’ll do for now", "終わり", "Stop.", "Okay, that's all.",
    ])
    func hearsThePersonsOwnBesideTheBuiltIn(_ text: String) {
        #expect(StopPhrase.matches(text, own: own))
    }

    @Test(arguments: [
        "Das reicht mir noch lange nicht für die Präsentation morgen", "Wann ist heute Feierabend?", "that'll do nicely as a title, write the rest",
        "Was reicht?", "basta", "終わりましたか", "",
    ])
    func aPhraseInsideASentenceIsStillAQuestion(_ text: String) {
        #expect(!StopPhrase.matches(text, own: own))
    }

    @Test func withoutTheListTheyAreOrdinaryWords() {
        #expect(!StopPhrase.matches("Das reicht"))
        #expect(!StopPhrase.matches("Feierabend", own: []))
    }

    @Test func ownPhrasesAreComparedCleanedUpAndOnce() {
        #expect(StopPhrase.own(own) == ["das reicht", "basta cosi", "feierabend", "that'll do", "終わり"])
        #expect(StopPhrase.own(["", "  ", "!!!"]).isEmpty)
        // A long phrase of one's own is still heard whole, with its polite wrapping.
        let long = ["we are finished for today thank you very much indeed"]
        #expect(StopPhrase.matches("Okay Redde, we are finished for today, thank you very much indeed.", own: long))
        #expect(!StopPhrase.matches("we are finished for today thank you very much indeed and one more thing about the report please", own: long))
    }

    @Test func whatCanBeAddedToTheList() {
        #expect(StopPhrasesView.addable("  Das reicht ", to: []) == "Das reicht")
        #expect(StopPhrasesView.addable("das reicht.", to: ["Das reicht"]) == nil, "there already")
        #expect(StopPhrasesView.addable("Stop", to: []) == nil, "built in")
        #expect(StopPhrasesView.addable("that's all", to: []) == nil)
        #expect(StopPhrasesView.addable("   ", to: []) == nil)
        #expect(StopPhrasesView.addable("?!", to: []) == nil, "nothing to hear in it")
        #expect(StopPhrasesView.addable(String(repeating: "a", count: StopPhrase.longestOwn + 1), to: []) == nil)
        #expect(StopPhrasesView.addable("one more", to: (1 ... StopPhrase.mostOwn).map { "phrase \($0)" }) == nil, "the list is full")
    }

    @Test func theSettingIsKept() {
        let suite = UserDefaults(suiteName: "stop-\(UUID().uuidString)")!
        let settings = Settings(defaults: suite)
        #expect(settings.stopPhrases.isEmpty)
        settings.stopPhrases = ["Das reicht", "Feierabend"]
        #expect(Settings(defaults: suite).stopPhrases == ["Das reicht", "Feierabend"])
        settings.reset()
        #expect(Settings(defaults: suite).stopPhrases.isEmpty)
    }
}

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
}

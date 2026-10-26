import Foundation
import Testing
@testable import Echo

/// Wake phrases (`WakeMatch`, `Settings.wakeTargets`): which phrase was said, at the start of what
/// was heard, however the recogniser spelled the name, and what was asked after it. Listening
/// itself (`WakeListener`) needs a microphone, and is tried on the phone.
@MainActor
struct WakePhraseTests {
    private let sol = WakeTarget(phrase: "Hey Sol", profile: nil, name: "Sol")
    private let home = WakeTarget(phrase: "Hey Home", profile: "home", name: "Home")
    private var both: [WakeTarget] { [sol, home] }

    @Test func thePhraseAloneWakesItsAgent() {
        let found = WakeMatch.match("Hey Sol.", targets: both)
        #expect(found?.target == sol)
        #expect(found?.rest == "")
    }

    @Test func whatIsSaidAfterThePhraseIsAsked() {
        let found = WakeMatch.match("Hey Home, turn off the lights.", targets: both)
        #expect(found?.target == home)
        #expect(found?.rest == "turn off the lights.")
        #expect(WakeMatch.match("hey sol what's on today?", targets: both)?.rest == "what's on today?")
    }

    @Test func theNameMayBeSpelledAsItSounds() {
        #expect(WakeMatch.match("Hey Saul", targets: both)?.target == sol)
        #expect(WakeMatch.match("Hey, soul.", targets: both)?.target == sol)
        #expect(WakeMatch.match("Hi Sol", targets: both)?.target == sol)
        #expect(WakeMatch.match("Hey hum, lights off", targets: both)?.target == home)
    }

    @Test func otherWordsAreNotIt() {
        #expect(WakeMatch.match("Hey so what now", targets: both) == nil)
        #expect(WakeMatch.match("Hey Sam", targets: both) == nil)
        #expect(WakeMatch.match("Sol", targets: both) == nil)
        #expect(WakeMatch.match("", targets: both) == nil)
        #expect(WakeMatch.match("Hey Sol", targets: []) == nil)
    }

    @Test func aWordOrTwoMayComeFirstButNoMore() {
        #expect(WakeMatch.match("Uh, hey Sol", targets: both)?.target == sol)
        #expect(WakeMatch.match("Okay so hey Home", targets: both)?.target == home)
        #expect(WakeMatch.match("And then I said hey Sol", targets: both) == nil)
    }

    @Test func theEarliestPhraseWins() {
        let found = WakeMatch.match("Hey Home, ask hey Sol", targets: both)
        #expect(found?.target == home)
        #expect(found?.rest == "ask hey Sol")
    }

    @Test func ownPhrasesAndAccents() {
        let zoe = WakeTarget(phrase: "Okay Zoë", profile: "zoe", name: "Zoë")
        #expect(WakeMatch.match("ok zoe, timer for ten minutes", targets: [zoe])?.rest == "timer for ten minutes")
        #expect(WakeMatch.match("Okay, Zoe.", targets: [zoe])?.target == zoe)
        let computer = WakeTarget(phrase: "Computer", profile: nil, name: "Sol")
        #expect(WakeMatch.match("Computer. Lights.", targets: [computer])?.rest == "Lights.")
    }

    @Test func soundexAsWritten() {
        #expect(WakeMatch.soundex("Robert") == "R163")
        #expect(WakeMatch.soundex("Rupert") == "R163")
        #expect(WakeMatch.soundex("Ashcraft") == "A261")
        #expect(WakeMatch.soundex("Tymczak") == "T522")
        #expect(WakeMatch.soundex("Pfister") == "P236")
        #expect(WakeMatch.soundex("ソル") == "")
    }

    @Test func theMainAgentIsOnUntilTurnedOffAndBotsOffUntilTurnedOn() {
        let settings = Settings(defaults: UserDefaults(suiteName: "wake-\(UUID().uuidString)")!)
        settings.displayName = "Sol"
        #expect(settings.wakePhrase(for: "default").on)
        #expect(!settings.wakePhrase(for: "home").on)
        #expect(settings.wakeTargets == [WakeTarget(phrase: "Hey Sol", profile: nil, name: "Sol")])
        settings.wakePhrasesHere["default"] = WakePhrase(on: true, phrase: "  Computer ")
        #expect(settings.wakeTargets.first?.phrase == "Computer")
        settings.wakePhrasesHere["default"] = WakePhrase(on: true, phrase: "   ")
        #expect(settings.wakeTargets.first?.phrase == "Hey Sol")   // blank: back to the default
        settings.wakePhrasesHere["default"] = WakePhrase(on: false)
        #expect(settings.wakeTargets.isEmpty)
    }
}

import Foundation
import Testing
@testable import Echo

/// What the composer makes of keys, pastes and files.
struct ComposerLogicTests {
    @Test func aFileStagedOnTheDashboardIsNamedInTheMessage() {
        let prompt = HermesServeTransport.prompt
        #expect(prompt("Summarise this.", []) == "Summarise this.")
        #expect(prompt("Summarise this.", ["@file:attachments/notes.txt"]) == "Summarise this.\n\n@file:attachments/notes.txt")
        #expect(prompt("", ["@file:attachments/clip.mp4"]) == "@file:attachments/clip.mp4", "a file sent with no words")
        #expect(prompt("Compare", ["@file:attachments/a.csv", "@file:`attachments/b 2.csv`"]) == "Compare\n\n@file:attachments/a.csv @file:`attachments/b 2.csv`")
    }
}

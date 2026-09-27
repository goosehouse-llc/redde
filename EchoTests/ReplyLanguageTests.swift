import Foundation
import Testing
@testable import Echo

struct ReplyLanguageTests {
    /// The model gets the name in English and in the language itself.
    @Test func namesTheLanguageBothWays() {
        #expect(ReplyLanguage.name("nl") == "Dutch (Nederlands)")
        #expect(ReplyLanguage.name("en") == "English")
        #expect(ReplyLanguage.instruction("nl").contains("Always reply in Dutch (Nederlands)"))
    }

    /// The Dashboard's note comes off when the message is loaded back.
    @Test func theDashboardNoteIsHiddenAgain() {
        let sent = "What's on tomorrow?" + ReplyLanguage.note("nl")
        #expect(sent == "What's on tomorrow?\n\n(Reply in Dutch (Nederlands).)")
        #expect(ReplyLanguage.stripNote(sent) == "What's on tomorrow?")
    }

    @Test func ordinaryMessagesAreLeftAlone() {
        #expect(ReplyLanguage.stripNote("Reply in Dutch (please).") == "Reply in Dutch (please).")
        #expect(ReplyLanguage.stripNote("Notes\n\n(Reply in a while.)\nmore") == "Notes\n\n(Reply in a while.)\nmore")
    }

    @Test func historyFromTheServerHidesTheNote() {
        let rows: [JSONValue] = [.object(["role": .string("user"), "text": .string("Hoi" + ReplyLanguage.note("nl"))])]
        #expect(Conversation.messages(fromServeRows: rows).first?.text == "Hoi")
    }

    @Test func everyOfferedLanguageHasAName() {
        for code in ReplyLanguage.codes {
            #expect(ReplyLanguage.displayName(code) != code, "\(code) has no display name")
        }
    }
}

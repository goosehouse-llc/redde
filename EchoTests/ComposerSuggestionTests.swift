import Foundation
import Testing
@testable import Echo

struct FollowUpParsingTests {
    @Test func numberingBulletsAndQuotesAreStripped() {
        let lines = FollowUps.parse("1. What if the 18th slips?\n2) \"Who is the supplier?\"\n- Can the crew start earlier?\n")
        #expect(lines == ["What if the 18th slips?", "Who is the supplier?", "Can the crew start earlier?"])
    }

    @Test func onlyQuestionsCountAndThreeAtMost() {
        let lines = FollowUps.parse("Here are some ideas:\nA?\nIs it late?\nIs it late?\nWhy the 18th?\nWho pays?\nAnd how?")
        #expect(lines == ["Is it late?", "Why the 18th?", "Who pays?"])
    }

    @Test func nothingUsableMeansNoChips() {
        #expect(FollowUps.parse("I cannot help with that.").isEmpty)
        #expect(FollowUps.parse("").isEmpty)
    }
}

struct ComposerContextTests {
    @Test func aDayInTheDraftBecomesACalendarChip() {
        let chips = ComposerContext.suggestions(for: "What do I have on October 24 at 9am?", recentFiles: [])
        guard case let .calendar(day)? = chips.first else { Issue.record("no calendar chip"); return }
        let parts = Calendar.current.dateComponents([.month, .day], from: day)
        #expect(parts.month == 10 && parts.day == 24)
        #expect(chips.count == 1)
    }

    @Test func aFileNamedInTheDraftIsOffered() {
        let plan = Attachment(kind: .text, filename: "plan.md", mimeType: "text/markdown", data: Data("# plan".utf8))
        let notes = Attachment(kind: .text, filename: "notes.txt", mimeType: "text/plain", data: Data())
        let chips = ComposerContext.suggestions(for: "Compare this with Plan.md please", recentFiles: [plan, notes])
        #expect(chips.map(\.title) == ["Attach plan.md"])
    }

    @Test func plainTextMakesNoChips() {
        #expect(ComposerContext.suggestions(for: "Turn on the lights", recentFiles: []).isEmpty)
        #expect(ComposerContext.suggestions(for: "", recentFiles: []).isEmpty)
    }
}

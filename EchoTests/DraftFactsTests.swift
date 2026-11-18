import Testing
@testable import Echo

/// What the composer's layout knows of the draft (`DraftFacts`): it changes only when one of its
/// answers does, so typing doesn't run the whole composer for every letter.
struct DraftFactsTests {
    @Test func plainTypingChangesNothingAfterTheFirstLetter() {
        #expect(DraftFacts("P") == DraftFacts("Plan a hike for Saturday"))
        #expect(DraftFacts("P").hasText && !DraftFacts("   ").hasText && !DraftFacts("").hasText)
    }

    @Test func longIsOver160OrThreeLineBreaks() {
        #expect(!DraftFacts(String(repeating: "a", count: 160)).isLong)
        #expect(DraftFacts(String(repeating: "a", count: 161)).isLong)
        #expect(DraftFacts("a\nb\nc\nd").isLong && !DraftFacts("a\nb\nc").isLong)
    }

    @Test func aSlashCommandIsFollowedOnOneLine() {
        #expect(DraftFacts("/mod").slash == "/mod")
        #expect(DraftFacts("/model\nmore").slash == nil)
        #expect(DraftFacts("a /b").slash == nil)
    }

    @Test func aTagBeingTyped() {
        #expect(DraftFacts("ask @sc").mention == "sc")
        #expect(DraftFacts("ask @").mention == "")
        #expect(DraftFacts("ask @scout now").mention == nil)
        #expect(DraftFacts("line\n@sc").mention == nil)
        #expect(DraftFacts("no tag").mention == nil)
    }
}

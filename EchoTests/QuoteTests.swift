import Testing
@testable import Echo

/// "Ask about this": a selection set as a quote for the next message.
struct QuoteTests {
    @Test func aSelectionBecomesAQuoteWithRoomForTheQuestion() {
        #expect(Quote.markdown("the cabinets are set") == "> the cabinets are set\n\n")
        #expect(Quote.markdown("  first line \n\n second line\n") == "> first line\n>\n> second line\n\n")
        #expect(Quote.markdown(" \n ") == "")
    }
}

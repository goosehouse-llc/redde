import Foundation
import Testing
@testable import Echo

struct ReplyFooterTests {
    @Test func liveThinkingShowsTheNewestPart() {
        let short = "Checking the calendar."
        #expect(MessageRow.tail(of: short, maxCharacters: 360) == short)
        let long = (1 ... 200).map { "step\($0)" }.joined(separator: " ")
        let tail = MessageRow.tail(of: long, maxCharacters: 60)
        #expect(tail.hasPrefix("…"))
        #expect(tail.hasSuffix("step200"))
        #expect(tail.count <= 61)
        // Starts on a whole word, not mid-word.
        #expect(tail.dropFirst().first == "s")
    }

    @Test func durationsReadNaturally() {
        #expect(MessageRow.duration(0.42) == "0.4 s")
        #expect(MessageRow.duration(12.34) == "12.3 s")
        #expect(MessageRow.duration(192) == "3m 12s")
        #expect(MessageRow.duration(65.4) == "1m 05s")
    }
}

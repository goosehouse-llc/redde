import Testing
@testable import Echo

/// The soft edge on a reply that is still arriving, and its coming up to full strength when the
/// text stops for a while.
struct StreamingTailTests {
    @Test func theNewestGlyphsAreFaintAndTheRestAreWhole() {
        #expect(StreamingTail.strength(fromEnd: 0, settle: 0) < 0.1)
        #expect(StreamingTail.strength(fromEnd: StreamingTail.length - 1, settle: 0) < 1)
        #expect(StreamingTail.strength(fromEnd: StreamingTail.length, settle: 0) == 1)
        #expect(StreamingTail.strength(fromEnd: 500, settle: 0) == 1)
        // Further from the end, further up.
        let edge = (0 ..< StreamingTail.length).map { StreamingTail.strength(fromEnd: $0, settle: 0) }
        #expect(edge == edge.sorted())
    }

    /// The model has gone off to think or use a tool: the last word must not stay faint and
    /// blurred for as long as that takes.
    @Test func aSettledEdgeLeavesNothingFaint() {
        for remaining in 0 ..< StreamingTail.length + 2 {
            #expect(StreamingTail.strength(fromEnd: remaining, settle: 1) == 1)
        }
    }

    @Test func settlingBringsEveryGlyphUpTogether() {
        for remaining in 0 ..< StreamingTail.length {
            let quarter = StreamingTail.strength(fromEnd: remaining, settle: 0.25)
            let half = StreamingTail.strength(fromEnd: remaining, settle: 0.5)
            #expect(StreamingTail.strength(fromEnd: remaining, settle: 0) < quarter)
            #expect(quarter < half && half < 1)
        }
        // Out-of-range values (a spring overshooting) don't push a glyph past whole or below its start.
        #expect(StreamingTail.strength(fromEnd: 0, settle: 1.2) == 1)
        #expect(StreamingTail.strength(fromEnd: 0, settle: -0.2) == StreamingTail.strength(fromEnd: 0, settle: 0))
    }
}

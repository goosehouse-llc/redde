import Foundation
import Testing
@testable import Echo

struct LineBufferTests {
    @Test func splitsAcrossChunksAndKeepsBlankLines() {
        var b = LineBuffer()
        #expect(b.append(Data("event: a\ndata: 1\n\nev".utf8)) == ["event: a\n", "data: 1\n", "\n"])
        #expect(b.append(Data("ent: b\n".utf8)) == ["event: b\n"])
        #expect(b.append(Data("data: 2".utf8)).isEmpty)
        #expect(b.flush() == "data: 2")
        #expect(b.flush() == nil)
    }
}

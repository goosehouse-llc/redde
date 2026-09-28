import Foundation
import Testing
@testable import Echo

struct ReviewPromptTests {
    private func prompt() -> ReviewPrompt { ReviewPrompt(defaults: UserDefaults(suiteName: "review-test-\(UUID().uuidString)")!) }
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + Double(n) * 86_400) }

    /// Plenty of replies on one day isn't enough: it takes a few days of use.
    @Test func manyRepliesInOneDayAreNotEnough() {
        let p = prompt()
        for _ in 0..<20 { p.recordReply(on: day(0)) }
        #expect(!p.isDue(version: "1.4.1"))
    }

    @Test func dueAfterEnoughRepliesOnEnoughDays() {
        let p = prompt()
        for i in 0..<ReviewPrompt.repliesNeeded { p.recordReply(on: day(i % ReviewPrompt.daysNeeded)) }
        #expect(p.isDue(version: "1.4.1"))
    }

    /// Once per version: asked on 1.4.1, not again until 1.4.2.
    @Test func onceAVersion() {
        let p = prompt()
        for i in 0..<10 { p.recordReply(on: day(i)) }
        p.markAsked(version: "1.4.1")
        #expect(!p.isDue(version: "1.4.1"))
        #expect(p.isDue(version: "1.4.2"))
    }
}

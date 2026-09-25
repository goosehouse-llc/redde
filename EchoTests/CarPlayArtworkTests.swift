import Testing
import UIKit
@testable import Echo

/// The CarPlay artwork renders at the expected sizes. Set REDDE_ARTWORK_DIR (passed to the test
/// runner as TEST_RUNNER_REDDE_ARTWORK_DIR) to also write PNGs there for a visual check.
@MainActor
struct CarPlayArtworkTests {
    @Test func rendersRowIconsAndVoiceStates() throws {
        let rows: [(String, UIImage)] = [("row-ask", CarPlayArtwork.rowIcon(.ask, size: CGSize(width: 44, height: 44))),
                                         ("row-talk", CarPlayArtwork.rowIcon(.talk, size: CGSize(width: 44, height: 44)))]
        let states = CarPlayArtwork.VoiceState.allCases.map { ("voice-\($0.rawValue)", CarPlayArtwork.voiceStateImage($0)) }
        for (_, image) in rows { #expect(image.size == CGSize(width: 44, height: 44)); #expect(image.scale == 3) }
        for (_, image) in states { #expect(image.size == CGSize(width: 160, height: 160)) }
        if let dir = ProcessInfo.processInfo.environment["REDDE_ARTWORK_DIR"] {
            for (name, image) in rows + states {
                try image.pngData()?.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
            }
        }
    }
}

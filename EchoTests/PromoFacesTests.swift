import Foundation
import Testing
import UIKit
@testable import Echo

/// The bots' faces as pictures, for the BOTS! promo video's title page (design/video, `make_preview.py
/// bots`): Redde's own, the demo bots' and the templates'. Runs only when asked:
/// `TEST_RUNNER_BOT_FACES=<folder> xcodebuild test … -only-testing:EchoTests/PromoFacesTests`.
@MainActor
struct PromoFacesTests {
    @Test func drawTheFaces() throws {
        guard let folder = ProcessInfo.processInfo.environment["BOT_FACES"], !folder.isEmpty else { return }
        let roster = ConversationsList.demoBots
        var faces: [(String, BotFace)] = [("redde", .main)]
        for bot in roster.bots where !bot.isDefault { faces.append((bot.name, roster.faces[bot.name] ?? BotFace(seed: bot.name))) }
        for template in BotTemplate.all { faces.append((template.id, template.face)) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (name, face) in faces {
            let picture = try #require(BotAvatar.picture(of: face, side: 300, scale: 2))
            try #require(picture.pngData()).write(to: URL(fileURLWithPath: folder).appending(path: "face-\(name).png"))
        }
    }
}

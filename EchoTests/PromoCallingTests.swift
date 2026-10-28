import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Echo

/// The Redde bot on a call, for the next release's promo video (design/video, `make_next.py`): its
/// face talking (the mouth voice mode gives it, a few ways open, looking at the phone), blinking,
/// and the tiny phone it holds up in a mitten of its own colour. Pictures only; `make_next.py`
/// moves them. In the Code theme, the takes' (Redde its pale sky, as on the app icon). Runs only when asked:
/// `TEST_RUNNER_BOT_FACES=<folder> xcodebuild test … -only-testing:EchoTests/PromoCallingTests`.
@MainActor
struct PromoCallingTests {
    @Test func drawReddeOnACall() throws {
        guard let folder = ProcessInfo.processInfo.environment["BOT_FACES"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        func save(_ view: some View, _ name: String, side: CGFloat = 300) throws {
            let renderer = ImageRenderer(content: view.frame(width: side, height: side).environment(\.theme, Theme.claudeCode.resolved(with: nil)))
            renderer.scale = 2
            let picture = try #require(renderer.uiImage)
            try #require(picture.pngData()).write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
        }
        // Talking: the mouth a few ways open, the eyes on the phone (up and to its right).
        for (i, open) in [0.0, 0.35, 0.7, 1.0].enumerated() {
            try save(BotAvatar(face: .main, size: 300, pose: BotPose(look: CGPoint(x: 0.9, y: -0.35), mouth: open)), "redde-talk-\(i)")
        }
        try save(BotAvatar(face: .main, size: 300, pose: BotPose(look: CGPoint(x: 0.9, y: -0.35), blink: 1, mouth: 0.15)), "redde-blink")
        // Looking out at whoever watches, the mouth shut (between lines).
        try save(BotAvatar(face: .main, size: 300, pose: BotPose(look: CGPoint(x: 0, y: 0.2), mouth: 0.0)), "redde-look")
        try save(TinyPhone(), "redde-phone")
        // The two together, as the video puts them, to look at.
        try save(ZStack {
            BotAvatar(face: .main, size: 300, pose: BotPose(look: CGPoint(x: 0.9, y: -0.35), mouth: 0.7))
            TinyPhone().frame(width: 170, height: 170).rotationEffect(.degrees(14)).offset(x: 118, y: -26)
        }, "redde-calling", side: 420)
    }
}

/// A tiny phone held in a mitten: a graphite phone with an island, Redde's own face on its screen
/// above a green answer button, and a round hand of Redde's colour round its foot, its thumb over
/// the front.
private struct TinyPhone: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let skin = BotAvatar.colors(of: .main, theme: theme)
        let edge = skin.deep.mix(with: .black, by: 0.22)
        GeometryReader { geo in
            let u = geo.size.width / 100
            ZStack {
                // The hand behind the phone: the palm and fingers wrapped round it.
                Ellipse()
                    .fill(LinearGradient(colors: [skin.light, skin.deep], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Ellipse().strokeBorder(edge.opacity(0.55), lineWidth: 1.4 * u))
                    .frame(width: 44 * u, height: 34 * u)
                    .offset(x: 3 * u, y: 26 * u)
                // The phone.
                RoundedRectangle(cornerRadius: 9 * u, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.27, blue: 0.33), Color(red: 0.09, green: 0.1, blue: 0.13)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 9 * u, style: .continuous)
                        .strokeBorder(Color(red: 0.55, green: 0.6, blue: 0.68), lineWidth: 1.2 * u))
                    .frame(width: 40 * u, height: 76 * u)
                RoundedRectangle(cornerRadius: 6.5 * u, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.05, green: 0.07, blue: 0.12)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 34 * u, height: 70 * u)
                Capsule().fill(.black).frame(width: 11 * u, height: 3.4 * u).offset(y: -31 * u)
                BotAvatar(face: .main, size: 22 * u, pose: BotPose(look: CGPoint(x: 0, y: 0.3), mouth: 0.6)).offset(y: -12 * u)
                Circle()
                    .fill(Color(red: 0.2, green: 0.8, blue: 0.38))
                    .frame(width: 14 * u, height: 14 * u)
                    .overlay(Image(systemName: "phone.fill").font(.system(size: 7.5 * u, weight: .bold)).foregroundStyle(.white))
                    .offset(y: 13 * u)
                // The thumb over the front, the fingers' tips peeking round the other edge.
                Capsule()
                    .fill(LinearGradient(colors: [skin.light, skin.deep], startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().strokeBorder(edge.opacity(0.55), lineWidth: 1.4 * u))
                    .frame(width: 13 * u, height: 25 * u)
                    .rotationEffect(.degrees(-28))
                    .offset(x: -16 * u, y: 24 * u)
                ForEach(0 ..< 3) { i in
                    Ellipse()
                        .fill(skin.deep)
                        .overlay(Ellipse().strokeBorder(edge.opacity(0.55), lineWidth: 1.2 * u))
                        .frame(width: 9 * u, height: 7.5 * u)
                        .offset(x: 21 * u, y: (16 + Double(i) * 7) * u)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

import CarPlay
import Testing
import UIKit
@testable import Echo

/// The CarPlay artwork: its sizes, and how the voice card's pictures move. Set REDDE_ARTWORK_DIR
/// (passed to the test runner as TEST_RUNNER_REDDE_ARTWORK_DIR) to also write PNGs there for a
/// visual check: the buttons, every picture of each loop, and the backdrops.
@MainActor
struct CarPlayArtworkTests {
    typealias Art = CarPlayArtwork

    @Test func rendersTheButtonsAndVoiceStates() throws {
        let buttons = Art.Start.allCases.map { ("start-\($0)", Art.startIcon($0, size: CGSize(width: 80, height: 80))) }
        let states = Art.VoiceState.allCases.map { ("voice-\($0.rawValue)", Art.voiceStateImage($0)) }
        for (_, image) in buttons { #expect(image.size == CGSize(width: 80, height: 80)); #expect(image.scale == 3) }
        for (_, image) in states {
            #expect(image.size == CGSize(width: Art.voiceImageSide, height: Art.voiceImageSide))
            #expect(image.images == nil, "a picture nobody asked to move stands still")
        }
        // Outside a car the grid has no size to give; the button still has to come out a picture.
        #expect(Art.startIcon(.ask, size: .zero).size.width > 0)
        try write(buttons + states)
    }

    @Test func listeningThinkingAndSpeakingMove() throws {
        var pictures: [(String, UIImage)] = []
        for state in Art.VoiceState.allCases {
            let image = Art.voiceStateImage(state, movingAt: 2)
            #expect(image.size == CGSize(width: Art.voiceImageSide, height: Art.voiceImageSide), "\(state) is larger than the card takes")
            guard let loop = Art.loop(state) else {
                #expect(image.images == nil, "\(state) has nothing to move")
                continue
            }
            let frames = try #require(image.images, "\(state) stands still")
            #expect(frames.count == loop.frames)
            #expect(image.duration == loop.duration)
            // CarPlay plays a loop of 0.3 to 5 seconds.
            #expect((0.3 ... 5).contains(loop.duration))
            #expect(frames.allSatisfy { $0.scale == 2 }, "pictures at the car's scale, not three times its pixels")
            #expect(frames.first?.pngData() != frames[frames.count / 3].pngData(), "\(state) plays the same picture throughout")
            pictures += frames.enumerated().map { (String(format: "loop-\(state.rawValue)-%02d", $0.offset), $0.element) }
        }
        try write(pictures)
    }

    @Test func theLoopsCloseOnThemselves() {
        // The picture after the last is the first again: no jump where a loop starts over.
        for (heights, frames) in [(Art.listeningHeights, 29), (Art.speakingHeights, 32)] {
            let step = 1 / CGFloat(frames)
            let first = heights(0), wrapped = heights(1)
            for i in first.indices { #expect(abs(first[i] - wrapped[i]) < 0.001) }
            // The bars stay inside the disc, and never thinner than a dot.
            for f in 0 ..< frames {
                #expect(heights(CGFloat(f) * step).allSatisfy { (5.5 ... 60).contains($0) })
            }
        }
        // A quarter turn puts a four-pointed spark back as it was.
        #expect(Art.thinkingTurn(0) == 0)
        #expect(abs(Art.thinkingTurn(0.6) - .pi / 2) < 0.0001)
        #expect(abs(Art.thinkingTurn(0.95) - .pi / 2) < 0.0001)
    }

    @Test func theBackdropIsDarkAtNightAndLightByDay() throws {
        var pictures: [(String, UIImage)] = []
        for state in Art.VoiceState.allCases {
            let backdrop = Art.voiceBackdrop(state)
            let asset = try #require(backdrop.imageAsset)
            let dark = asset.image(with: UITraitCollection(userInterfaceStyle: .dark))
            let light = asset.image(with: UITraitCollection(userInterfaceStyle: .light))
            #expect(dark.size == Art.backdropSize && light.size == Art.backdropSize)
            // The card writes its words in the car's own colours: light on dark, dark on light.
            // They sit below the picture, so that is where the ground has to carry them.
            let under = CGPoint(x: 0.5, y: 0.72)
            #expect(try luminance(dark, at: under) < 0.2, "\(state): white words need a dark ground")
            #expect(try luminance(light, at: under) > 0.8, "\(state): dark words need a light ground")
            pictures += [("backdrop-\(state.rawValue)-dark", dark), ("backdrop-\(state.rawValue)-light", light)]
        }
        try write(pictures)
    }

    /// How bright a picture is at a point given in fractions of its size, 0 to 1.
    private func luminance(_ image: UIImage, at point: CGPoint) throws -> CGFloat {
        let cg = try #require(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let x = CGFloat(cg.width) * point.x, y = CGFloat(cg.height) * (1 - point.y)
        context.draw(cg, in: CGRect(x: -x, y: -y, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (0.2126 * CGFloat(pixel[0]) + 0.7152 * CGFloat(pixel[1]) + 0.0722 * CGFloat(pixel[2])) / 255
    }

    private func write(_ pictures: [(String, UIImage)]) throws {
        guard let dir = ProcessInfo.processInfo.environment["REDDE_ARTWORK_DIR"] else { return }
        for (name, image) in pictures {
            try image.pngData()?.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }
}

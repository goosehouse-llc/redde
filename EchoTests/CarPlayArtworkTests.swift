import CarPlay
import Testing
import UIKit
@testable import Echo

/// The CarPlay artwork: its sizes, and how the voice card's pictures move. Set REDDE_ARTWORK_DIR
/// (passed to the test runner as TEST_RUNNER_REDDE_ARTWORK_DIR) to also write PNGs there for a
/// visual check: the cards, every picture of each loop, and the backdrops.
@MainActor
struct CarPlayArtworkTests {
    typealias Art = CarPlayArtwork

    @Test func rendersTheCardsAndVoiceStates() throws {
        let buttons = Art.Start.allCases.map { ("start-\($0)", Art.startCard($0)) }
        let square = Art.Start.allCases.map { ("start-square-\($0)", Art.startCard($0, wide: false)) }
        let states = Art.VoiceState.allCases.map { ("voice-\($0.rawValue)", Art.voiceStateImage($0)) }
        for (_, image) in buttons {
            // The car makes a card in the shape of its picture, and squeezes any wide picture
            // that isn't 16 by 9 into that shape.
            #expect(abs(image.size.width / image.size.height - 16.0 / 9) < 0.01)
            #expect(image.scale == 3)
        }
        for (_, image) in square { #expect(image.size.width == image.size.height) }
        for (_, image) in states {
            #expect(image.size == CGSize(width: Art.voiceImageSide, height: Art.voiceImageSide))
            #expect(image.images == nil, "a picture nobody asked to move stands still")
        }
        try write(buttons + square + states)
    }

    /// The car writes a card's two lines over the bottom left of its picture, in white by day
    /// and by night: the colour there has to be deep enough to read them on.
    @Test func theCardsAreDeepWhereTheCarWritesOnThem() throws {
        for start in Art.Start.allCases {
            let image = Art.startCard(start)
            // Under the words: the lower third, as far across as the longer line reaches.
            for (x, y) in [(0.06, 0.92), (0.25, 0.80), (0.45, 0.90), (0.50, 0.74)] {
                let ground = try luminance(of: image, at: CGPoint(x: x, y: y))
                let contrast = 1.05 / (ground + 0.05)
                #expect(contrast >= 3.5, "\(start): white words at \(x), \(y) have a contrast of \(contrast)")
            }
            // And bright at the other corner, behind the symbol: a card is its colour.
            #expect(try luminance(of: image, at: CGPoint(x: 0.96, y: 0.06)) > 3 * luminance(of: image, at: CGPoint(x: 0.06, y: 0.92)))
        }
    }

    /// The relative luminance of a picture at a point given as fractions of its width and height.
    private func luminance(of image: UIImage, at point: CGPoint) throws -> Double {
        let cg = try #require(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // One pixel of the picture, drawn so that it lands on the context's only one.
        let x = (point.x * CGFloat(cg.width)).rounded(.down), y = (point.y * CGFloat(cg.height)).rounded(.down)
        context.draw(cg, in: CGRect(x: -x, y: -(CGFloat(cg.height) - 1 - y), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        func linear(_ c: UInt8) -> Double { let v = Double(c) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(pixel[0]) + 0.7152 * linear(pixel[1]) + 0.0722 * linear(pixel[2])
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

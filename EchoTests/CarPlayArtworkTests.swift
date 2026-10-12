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
                let ground = try relativeLuminance(of: image, at: CGPoint(x: x, y: y))
                let contrast = 1.05 / (ground + 0.05)
                #expect(contrast >= 3.5, "\(start): white words at \(x), \(y) have a contrast of \(contrast)")
            }
            // And bright at the other corner, behind the symbol: a card is its colour.
            #expect(try relativeLuminance(of: image, at: CGPoint(x: 0.96, y: 0.06)) > 3 * relativeLuminance(of: image, at: CGPoint(x: 0.06, y: 0.92)))
        }
    }

    /// The relative luminance of a picture (the measure contrast ratios are made of) at a point
    /// given as fractions of its width and height.
    private func relativeLuminance(of image: UIImage, at point: CGPoint) throws -> Double {
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
            // The columns move a light at a time: a picture that comes round again is the same
            // object, not another copy of it for the car to hold.
            if state != .thinking { #expect(Set(frames.map(ObjectIdentifier.init)).count < frames.count / 2) }
            pictures += frames.enumerated().map { (String(format: "loop-\(state.rawValue)-%02d", $0.offset), $0.element) }
        }
        try write(pictures)
    }

    @Test func theLoopsCloseOnThemselves() {
        // The picture after the last is the first again: no jump where a loop starts over.
        #expect(abs(Art.listeningLevel(0) - Art.listeningLevel(1)) < 0.001)
        #expect(abs(Art.speakingLevel(0) - Art.speakingLevel(1)) < 0.001)
        for (first, wrapped) in zip(Art.scanner(0), Art.scanner(1)) { #expect(abs(first - wrapped) < 0.001) }
    }

    /// Speaking has to look like speech and Listening must not: nothing on the car's screen
    /// can follow a voice, so a meter that leapt about while nobody spoke would be a lie.
    @Test func speakingRisesAndRestsAndListeningStaysLow() {
        let speaking = (0 ..< 300).map { Art.speakingLevel(CGFloat($0) / 300) }
        #expect(speaking.max()! >= 0.95, "a loud syllable lights the whole column")
        #expect(speaking.min()! <= 0.05, "the lights fall back to rest in a breath")
        // Syllables, not a hum: the level crosses its middle many times in a loop.
        let crossings = zip(speaking, speaking.dropFirst()).filter { ($0 < 0.4) != ($1 < 0.4) }.count
        #expect(crossings >= 12)
        let listening = (0 ..< 300).map { Art.listeningLevel(CGFloat($0) / 300) }
        #expect(listening.max()! <= 0.5)
        #expect(Set(listening.map { Art.columns(at: $0).centre }).count >= 3, "the columns stir while the mic is open")
        // At rest the middle light of each column is all that is lit; at full, every light.
        #expect(Art.columns(at: 0) == (0, 0))
        #expect(Art.columns(at: 1) == (Art.centreLights, Art.sideLights))
    }

    /// One light, running from one end of the row to the other and back, with lamps fading
    /// behind it.
    @Test func theScannersLightRunsToTheFarEndAndBack() {
        func brightest(_ p: CGFloat) -> Int { Art.scanner(p).enumerated().max { $0.element < $1.element }!.offset }
        #expect(brightest(0) == 0)
        #expect(brightest(0.25) == Art.scannerLamps / 2 || brightest(0.25) == Art.scannerLamps / 2 - 1)
        #expect(brightest(0.5) == Art.scannerLamps - 1)
        #expect(brightest(0.75) == Art.scannerLamps / 2 || brightest(0.75) == Art.scannerLamps / 2 - 1)
        for step in 0 ..< 60 {
            let lamps = Art.scanner(CGFloat(step) / 60)
            #expect(lamps.count == Art.scannerLamps)
            #expect(lamps.allSatisfy { (0 ... 1).contains($0) })
            #expect(lamps.max()! > 0.6, "the light never goes out between two lamps")
        }
        // On the way out the lamps it has passed still glow; those ahead are dark.
        let outward = Art.scanner(0.25)
        #expect(outward[brightest(0.25) - 1] > outward[brightest(0.25) + 2])
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

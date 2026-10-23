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
        // Every look of Settings → Appearance → CarPlay cards.
        let looks = CarPlayCardLook.allCases
        let buttons = looks.flatMap { look in Art.Start.allCases.map { ("start-\(look.rawValue)-\($0)", Art.startCard($0, look: look)) } }
        let square = looks.flatMap { look in Art.Start.allCases.map { ("start-square-\(look.rawValue)-\($0)", Art.startCard($0, look: look, wide: false)) } }
        // Eighteen pictures, no two alike.
        #expect(Set(buttons.compactMap { $0.1.pngData() }).count == buttons.count)
        // And every look of Settings → Appearance → CarPlay voice screen, standing still.
        let states = CarPlayVoiceLook.allCases.flatMap { look in
            Art.VoiceState.allCases.map { ("voice-\(look.rawValue)-\($0.rawValue)", Art.voiceStateImage($0, look: look)) }
        }
        // Twenty-five pictures, and one of them twice: the phone waited for is the same in lamps
        // as in solid bars.
        #expect(Set(states.compactMap { $0.1.pngData() }).count == states.count - 1)
        #expect(Art.voiceStateImage(.phone, look: .lamps).pngData() == Art.voiceStateImage(.phone, look: .bars).pngData())
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
    /// and by night: in every look the ground there has to be deep enough to read them on.
    @Test(arguments: CarPlayCardLook.allCases) func theCardsAreDeepWhereTheCarWritesOnThem(_ look: CarPlayCardLook) throws {
        for start in Art.Start.allCases {
            let image = Art.startCard(start, look: look)
            // Under the words: the lower third, as far across as the longer line reaches.
            for (x, y) in [(0.06, 0.92), (0.25, 0.80), (0.45, 0.90), (0.50, 0.74)] {
                let ground = try relativeLuminance(of: image, at: CGPoint(x: x, y: y))
                let contrast = 1.05 / (ground + 0.05)
                #expect(contrast >= 3.5, "\(look) \(start): white words at \(x), \(y) have a contrast of \(contrast)")
            }
            // The colour cards are bright at the other corner, behind the symbol: a card is its colour.
            guard look == .color else { continue }
            #expect(try relativeLuminance(of: image, at: CGPoint(x: 0.96, y: 0.06)) > 3 * relativeLuminance(of: image, at: CGPoint(x: 0.06, y: 0.92)))
        }
    }

    /// The Bots tab's cards likewise, in every look and mood, for a pale bot, a bright one and
    /// Redde's own (`CarPlayBotLook`).
    @Test(arguments: CarPlayBotLook.allCases) func theBotCardsAreDeepWhereTheCarWritesOnThem(_ look: CarPlayBotLook) throws {
        var white = BotFace(seed: "a")
        white.color = BotFace.white
        var lime = BotFace(seed: "b")
        lime.color = 10
        for face in [white, lime, BotFace.main] {
            for mood in Art.BotMood.allCases {
                let image = Art.botCard(face, named: "Scout", mood: mood, look: look)
                #expect(image.size == Art.botCardSize(look) && image.scale == 3)
                for (x, y) in [(0.06, 0.92), (0.25, 0.80), (0.45, 0.90), (0.50, 0.76)] {
                    let ground = try relativeLuminance(of: image, at: CGPoint(x: x, y: y))
                    let contrast = 1.05 / (ground + 0.05)
                    #expect(contrast >= 3.5, "\(look) \(mood) colour \(face.color): white words at \(x), \(y) have a contrast of \(contrast)")
                }
            }
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

    @Test(arguments: CarPlayVoiceLook.allCases) func listeningThinkingAndSpeakingMove(_ look: CarPlayVoiceLook) throws {
        var pictures: [(String, UIImage)] = []
        var kept = 0
        for state in Art.VoiceState.allCases {
            let image = Art.voiceStateImage(state, look: look, movingAt: 2)
            #expect(image.size == CGSize(width: Art.voiceImageSide, height: Art.voiceImageSide), "\(state) is larger than the card takes")
            guard let loop = Art.loop(state, look: look) else {
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
            // A picture that comes round again is the same object, not another copy of it for
            // the car to hold: the bars come back to where they have been, and the orb's rings
            // leave the spark twice a loop.
            let different = Set(frames.map(ObjectIdentifier.init)).count
            switch (look, state) {
            case (.orb, .speaking), (.redde, .speaking): #expect(different == frames.count / 2)
            case (.orb, _), (.redde, _), (_, .thinking): #expect(different == frames.count)
            default: #expect(different <= frames.count * 3 / 5)
            }
            kept += different
            pictures += frames.enumerated().map { (String(format: "loop-\(look.rawValue)-\(state.rawValue)-%02d", $0.offset), $0.element) }
        }
        // What the car holds while it is connected: 150 points square at two pixels a point is
        // 360 KB a picture, so this is some 40 MB.
        #expect(kept <= 115, "\(look) keeps \(kept) pictures")
        try write(pictures)
    }

    /// The picture that plays is the one Settings names, and a look that is no longer picked
    /// is let go.
    @Test func onlyThePickedLooksPicturesAreKept() {
        Art.forget()
        let bars = Art.voiceStateImage(.speaking, look: .bars, movingAt: 2), orb = Art.voiceStateImage(.speaking, look: .orb, movingAt: 2)
        #expect(Art.voiceStateImage(.speaking, look: .bars, movingAt: 2) === bars, "drawn once")
        Art.keepVoicePictures(only: .orb)
        #expect(Art.voiceStateImage(.speaking, look: .orb, movingAt: 2) === orb)
        #expect(Art.voiceStateImage(.speaking, look: .bars, movingAt: 2) !== bars, "the bars were let go, and are drawn again when asked for")
        // Settings draws its own, and none of those is kept.
        #expect(Art.voicePicture(.speaking, look: .orb, movingAt: 2) !== orb)
        Art.forget()
    }

    @Test func theLoopsCloseOnThemselves() {
        // The picture after the last is the first again: no jump where a loop starts over.
        #expect(Art.voiceBars(.listening, at: 0) == Art.voiceBars(.listening, at: 1))
        #expect(Art.voiceBars(.speaking, at: 0) == Art.voiceBars(.speaking, at: 1))
        #expect(abs(Art.glide(0) - Art.glide(1)) < 0.001)
        for (first, wrapped) in zip(Art.scanner(0), Art.scanner(1)) { #expect(abs(first - wrapped) < 0.001) }
        for state in [Art.VoiceState.listening, .thinking] {
            for angle in stride(from: 0, to: 2 * CGFloat.pi, by: 0.1) {
                #expect(abs(Art.ringLight(state, at: 0, angle: angle) - Art.ringLight(state, at: 1, angle: angle)) < 0.001)
            }
        }
        // The two rings change places: the picture is the same half a loop on, and a loop on.
        for p in [0, 0.2, 0.37] as [CGFloat] {
            let now = Art.ripples(at: p).sorted { $0.radius < $1.radius }, later = Art.ripples(at: p + 0.5).sorted { $0.radius < $1.radius }
            for (a, b) in zip(now, later) { #expect(abs(a.radius - b.radius) < 0.001 && abs(a.light - b.light) < 0.001) }
        }
    }

    /// The lights move slowly. The first loops leapt from three dashes to a full column within
    /// one picture, twelve times in three seconds, and the fast movement looked odd
    /// (2026-10-12). Now nothing moves far from one picture to the next.
    @Test func noLightJumpsFromOnePictureToTheNext() throws {
        for state in [Art.VoiceState.listening, .speaking] {
            let frames = try #require(Art.loop(state)).frames
            let looks = try (0 ... frames).map { try #require(Art.voiceBars(state, at: CGFloat($0) / CGFloat(frames))) }
            for (a, b) in zip(looks, looks.dropFirst()) {
                // An end of a bar moves by less than a twentieth of the picture.
                #expect(abs(a.centreHalf - b.centreHalf) < 5, "\(state): the centre bar jumps")
                #expect(abs(a.sidesHalf - b.sidesHalf) < 5, "\(state): the outer bars jump")
            }
        }
        // The thinking light likewise: under a twelfth of its slot a picture.
        let frames = try #require(Art.loop(.thinking)).frames
        for step in 0 ..< frames {
            #expect(abs(Art.glide(CGFloat(step + 1) / CGFloat(frames)) - Art.glide(CGFloat(step) / CGFloat(frames))) < 1.0 / 12, "the light jumps at \(step)")
        }
        // And every loop of bars and lamps lasts long enough to be calm: none comes round in
        // under two and a half seconds.
        for look in [CarPlayVoiceLook.bars, .lamps, .kitt] {
            for state in Art.VoiceState.allCases { if let loop = Art.loop(state, look: look) { #expect(loop.duration >= 2.5) } }
        }
    }

    /// The same for lamps: the lit part of a column grows by less than a lamp a picture, and
    /// the scanner's light moves by less than a lamp.
    @Test func noLampJumpsFromOnePictureToTheNext() throws {
        for state in [Art.VoiceState.listening, .speaking] {
            let frames = try #require(Art.loop(state, look: .lamps)).frames
            let looks = try (0 ... frames).map { try #require(Art.voiceBars(state, at: CGFloat($0) / CGFloat(frames))) }
            for (a, b) in zip(looks, looks.dropFirst()) {
                #expect(abs(a.centre - b.centre) * CGFloat(Art.centreLights) < 1, "\(state): the centre column jumps")
                #expect(abs(a.sides - b.sides) * CGFloat(Art.sideLights) < 1, "\(state): the outer columns jump")
            }
        }
        // The scanner's light, where the lamps' brightnesses balance.
        let frames = try #require(Art.loop(.thinking, look: .lamps)).frames
        func light(_ step: Int) -> CGFloat {
            let lamps = Art.scanner(CGFloat(step) / CGFloat(frames))
            return zip(lamps.indices, lamps).map { CGFloat($0) * $1 }.reduce(0, +) / lamps.reduce(0, +)
        }
        for step in 0 ..< frames { #expect(abs(light(step + 1) - light(step)) < 1, "the scanner jumps at \(step)") }
        // KITT is the same lamps in another colour: one set of loops for both.
        for state in Art.VoiceState.allCases { #expect(Art.loop(state, look: .kitt)?.frames == Art.loop(state, look: .lamps)?.frames) }
    }

    /// A column grows by a lamp fading in, not by one coming on.
    @Test func aLampFadesInAsTheColumnReachesIt() {
        for level in [0, 0.3, 1] as [CGFloat] { #expect(Art.glow(ofLamp: 0, of: Art.centreLights, at: level) == 1, "the middle lamp is always on") }
        // At rest only the middle lamp of a column is lit; at full, every lamp.
        #expect((1 ... Art.centreLights).allSatisfy { Art.glow(ofLamp: $0, of: Art.centreLights, at: 0) == 0 })
        #expect((1 ... Art.centreLights).allSatisfy { Art.glow(ofLamp: $0, of: Art.centreLights, at: 1) == 1 })
        // Half a lamp's worth of level lights the first lamp halfway, and leaves the second dark.
        #expect(abs(Art.glow(ofLamp: 1, of: Art.centreLights, at: 0.5 / 6) - 0.5) < 0.001)
        #expect(Art.glow(ofLamp: 2, of: Art.centreLights, at: 0.5 / 6) == 0)
        let rising = stride(from: 0, through: 1, by: 0.01).map { Art.glow(ofLamp: 3, of: Art.centreLights, at: CGFloat($0)) }
        #expect(zip(rising, rising.dropFirst()).allSatisfy { $0 <= $1 })
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

    /// The orb's ring: a glint that goes round once while you are heard, a comet with its tail
    /// behind it while Redde thinks, both clockwise from the top and neither in jumps.
    @Test func theOrbsLightGoesRoundTheRing() throws {
        let turn = 2 * CGFloat.pi
        func brightest(_ state: Art.VoiceState, _ p: CGFloat) -> CGFloat {
            stride(from: 0, to: turn, by: turn / 360).max { Art.ringLight(state, at: p, angle: $0) < Art.ringLight(state, at: p, angle: $1) }!
        }
        for state in [Art.VoiceState.listening, .thinking] {
            for (p, place) in [(0, 0), (0.25, turn / 4), (0.5, turn / 2), (0.75, turn * 3 / 4)] as [(CGFloat, CGFloat)] {
                #expect(abs(brightest(state, p) - place) < 0.04, "\(state) at \(p): the light is at \(brightest(state, p))")
            }
            // From one picture to the next the light moves on by a small part of the ring.
            let loop = try #require(Art.loop(state, look: .orb))
            #expect(360 / CGFloat(loop.frames) <= 10, "\(state): \(360 / CGFloat(loop.frames)) degrees a picture")
            for step in 0 ..< 720 {
                let light = Art.ringLight(state, at: 0.3, angle: turn * CGFloat(step) / 720)
                #expect((0.1 ... 1).contains(light), "the ring never goes out anywhere")
            }
        }
        // The glint is as bright a little way before it as after; the comet is dark ahead of
        // its head and fades out behind it.
        let at = turn * 0.3
        #expect(abs(Art.ringLight(.listening, at: 0.3, angle: at - 0.4) - Art.ringLight(.listening, at: 0.3, angle: at + 0.4)) < 0.001)
        #expect(Art.ringLight(.thinking, at: 0.3, angle: at + 0.4) < 0.15)
        #expect(Art.ringLight(.thinking, at: 0.3, angle: at - 0.4) > Art.ringLight(.thinking, at: 0.3, angle: at - 1.2))
        #expect(Art.ringLight(.thinking, at: 0.3, angle: at - 1.2) > Art.ringLight(.thinking, at: 0.3, angle: at - 2.4))
        // Speaking, paused and waiting, the ring is lit evenly and stands still.
        for state in [Art.VoiceState.speaking, .paused, .phone] {
            #expect(Art.ringLight(state, at: 0.1, angle: 1) == Art.ringLight(state, at: 0.7, angle: 4))
        }
    }

    /// Speaking, the orb sends rings out from the spark to the ring. None appears or goes out
    /// at a stroke, and none leaves the ring.
    @Test func theOrbsRingsSpreadFromTheSparkAndFadeAtTheRing() throws {
        let frames = try #require(Art.loop(.speaking, look: .orb)).frames
        var brightest: CGFloat = 0
        for step in 0 ..< frames {
            let now = Art.ripples(at: CGFloat(step) / CGFloat(frames)), next = Art.ripples(at: CGFloat(step + 1) / CGFloat(frames))
            #expect(now.count == 2)
            for (i, ripple) in now.enumerated() {
                #expect((14 ... Art.ringRadius).contains(ripple.radius))
                #expect((0 ... 0.75).contains(ripple.light))
                brightest = max(brightest, ripple.light)
                // The next picture has it a little farther out, or has it back at the spark, unlit.
                if next[i].radius > ripple.radius {
                    #expect(next[i].radius - ripple.radius < 1.5)
                    #expect(abs(next[i].light - ripple.light) < 0.2)
                } else {
                    #expect(ripple.light < 0.02 && next[i].light < 0.02, "a ring went out at a stroke")
                }
            }
        }
        #expect(brightest > 0.4, "the rings can be seen")
        // The ring stays on the disc, whose half-width is 50.
        #expect(Art.ringRadius + Art.ringLine / 2 < 50)
    }

    /// Speaking has to look like a voice and Listening must not: nothing on the car's screen
    /// can follow one, so lights that rose high while nobody spoke would be a lie.
    @Test func speakingSwellsAndListeningStaysLow() throws {
        let speaking = (0 ..< 300).map { Art.speakingLevel(CGFloat($0) / 300) }
        #expect(speaking.max()! >= 0.9, "a swell reaches the top of the housing")
        #expect(speaking.min()! <= 0.3 && speaking.min()! >= 0.1, "it sinks low between swells, and never goes out")
        // Swells, not syllables: the level crosses its middle a few times in a loop, not dozens.
        let crossings = zip(speaking, speaking.dropFirst()).filter { ($0 < 0.57) != ($1 < 0.57) }.count
        #expect((4 ... 8).contains(crossings))
        // The loop's second half is its first played backwards, so its pictures serve twice.
        for step in 1 ..< 30 { #expect(Art.voiceBars(.speaking, at: CGFloat(step) / 60) == Art.voiceBars(.speaking, at: CGFloat(60 - step) / 60)) }

        let listening = try (0 ..< 300).map { try #require(Art.voiceBars(.listening, at: CGFloat($0) / 300)) }
        #expect(listening.map(\.centre).max()! <= 0.45 && listening.map(\.sides).max()! <= 0.45)
        // The centre bar grows as the outer ones shrink, so the picture sways and doesn't pulse.
        let up = try #require(Art.voiceBars(.listening, at: 0.25)), down = try #require(Art.voiceBars(.listening, at: 0.75))
        #expect(up.centre > down.centre && up.sides < down.sides)
        #expect(Art.voiceBars(.thinking, at: 0.3) == nil && Art.voiceBars(.paused, at: 0.3) == nil)
    }

    /// The centre bar is the tallest at every moment, listening and speaking alike. With the
    /// outer bars above it the Listening picture looked wrong (2026-10-13).
    @Test func theOuterBarsNeverStandAsHighAsTheCentreOne() throws {
        for state in [Art.VoiceState.listening, .speaking] {
            for step in 0 ..< 600 {
                let bars = try #require(Art.voiceBars(state, at: CGFloat(step) / 600))
                #expect(bars.sidesHalf < bars.centreHalf, "\(state) at \(step): the outer bars reach \(bars.sidesHalf), the centre one \(bars.centreHalf)")
                // In lamps too: fewer of an outer column's are lit than of the centre one's.
                #expect(bars.sides * CGFloat(Art.sideLights) < bars.centre * CGFloat(Art.centreLights), "\(state) at \(step): the outer columns stand higher")
            }
        }
    }

    /// A bar is a dash at rest and fills its housing at full; the centre one's is the taller.
    @Test func aBarGrowsFromADashToItsHousing() {
        let rest = Art.VoiceBars(centre: 0, sides: 0), full = Art.VoiceBars(centre: 1, sides: 1)
        #expect(rest.centreHalf == Art.restReach && rest.sidesHalf == Art.restReach)
        #expect(abs(full.centreHalf - Art.centreReach) < 0.001 && abs(full.sidesHalf - Art.sideReach) < 0.001)
        #expect(Art.centreReach > Art.sideReach)
        // Everything stays on the disc: its half-width is 50, and a bar's corner is the farthest point.
        #expect((Art.centreReach * Art.centreReach + 6.5 * 6.5).squareRoot() < 50)
        #expect((Art.sideReach * Art.sideReach + 26 * 26).squareRoot() < 50)
    }

    /// One light, gliding from one end of its slot to the other and back, slowest where it turns.
    @Test func theThinkingLightGlidesToTheFarEndAndBack() {
        #expect(Art.glide(0) == 0)
        #expect(abs(Art.glide(0.25) - 0.5) < 0.001)
        #expect(abs(Art.glide(0.5) - 1) < 0.001)
        #expect(abs(Art.glide(0.75) - 0.5) < 0.001)
        for step in 0 ... 60 { #expect((0 ... 1).contains(Art.glide(CGFloat(step) / 60))) }
        // Slowest at the ends, fastest through the middle.
        #expect(Art.glide(0.02) - Art.glide(0) < Art.glide(0.26) - Art.glide(0.24))
    }

    @Test(arguments: [CarPlayVoiceLook.bars, .kitt]) func theBackdropIsDarkAtNightAndLightByDay(_ look: CarPlayVoiceLook) throws {
        var pictures: [(String, UIImage)] = []
        for state in Art.VoiceState.allCases {
            let backdrop = Art.voiceBackdrop(state, look: look)
            let asset = try #require(backdrop.imageAsset)
            let dark = asset.image(with: UITraitCollection(userInterfaceStyle: .dark))
            let light = asset.image(with: UITraitCollection(userInterfaceStyle: .light))
            #expect(dark.size == Art.backdropSize && light.size == Art.backdropSize)
            // The card writes its words in the car's own colours: light on dark, dark on light.
            // They sit below the picture, so that is where the ground has to carry them.
            let under = CGPoint(x: 0.5, y: 0.72)
            #expect(try luminance(dark, at: under) < 0.2, "\(state): white words need a dark ground")
            #expect(try luminance(light, at: under) > 0.8, "\(state): dark words need a light ground")
            pictures += [("backdrop-\(look.rawValue)-\(state.rawValue)-dark", dark), ("backdrop-\(look.rawValue)-\(state.rawValue)-light", light)]
        }
        // Lamps and the orb stand on the bars' graphite; KITT's dash has a ground of its own.
        #expect(Art.voiceBackdrop(.speaking, look: .lamps) === Art.voiceBackdrop(.speaking, look: .bars))
        #expect(Art.voiceBackdrop(.speaking, look: .orb) === Art.voiceBackdrop(.speaking, look: .bars))
        #expect(Art.voiceBackdrop(.speaking, look: .kitt) !== Art.voiceBackdrop(.speaking, look: .bars))
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

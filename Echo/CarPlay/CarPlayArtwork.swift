import CarPlay
import UIKit

/// Redde's CarPlay artwork. The Ask tab's cards are a colour each, to be told apart at a glance.
/// The voice card is in the app's own look: graphite discs, light waveform bars in the spark's
/// profile (centre tallest, each bar outward lower, like voice mode's Waveform orb) and the gold
/// spark. CarPlay owns layout and type, so these images are where the brand shows. Everything is
/// drawn in code so it stays sharp on any car display, and every picture carries its own ground
/// so it reads the same on CarPlay's light and dark appearances.
enum CarPlayArtwork {
    static let graphiteTop = UIColor(red: 0.231, green: 0.267, blue: 0.325, alpha: 1)      // #3B4453
    static let graphiteBottom = UIColor(red: 0.078, green: 0.102, blue: 0.149, alpha: 1)   // #141A26
    static let mist = UIColor(red: 0.863, green: 0.890, blue: 0.933, alpha: 1)             // #DCE3EE
    static let gold = UIColor(red: 0xE8 / 255.0, green: 0xB0 / 255.0, blue: 0x4B / 255.0, alpha: 1)

    /// The Ask tab's three cards: the ways to start talking.
    enum Start: CaseIterable { case ask, talk, newChat }
    /// The voice card's states. Five, the most a voice-control template takes.
    enum VoiceState: String, CaseIterable { case listening, thinking, speaking, muted, phone }

    /// Bar heights in the spark's profile, as fractions of the tallest (voice mode's weights).
    private static let sparkProfile: [CGFloat] = [0.13, 0.27, 0.51, 1.0, 0.51, 0.27, 0.13]

    // MARK: - The Ask tab

    /// A card on the Ask tab: its own colour from edge to edge and a plain white symbol. The
    /// picture is wide because a card made from a thumbnail takes its picture's shape and lets
    /// the picture fill it, and 16 by 9 is the widest the car draws: 146 points across on a
    /// 770-point screen, where a square picture set inside a card made one of 80. The car writes
    /// the card's two lines over the bottom left corner, in white whatever its appearance, so
    /// the colour is deep there and bright behind the symbol at the right. `wide: false` is the
    /// square picture for a card of the older kind (before iOS 26.4), its symbol in the middle.
    static func startCard(_ start: Start, wide: Bool = true) -> UIImage {
        render(wide ? wideCard : squareCard, opaque: true) { ctx, rect in
            let (deep, bright) = cardColours(start)
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [deep.cgColor, bright.cgColor] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
            }
            let centre = wide ? CGPoint(x: rect.width * 0.73, y: rect.height * 0.44) : CGPoint(x: rect.midX, y: rect.midY)
            let config = UIImage.SymbolConfiguration(pointSize: rect.height * (wide ? 0.50 : 0.37), weight: .semibold)
            guard let symbol = UIImage(systemName: cardSymbol(start), withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
            symbol.draw(at: CGPoint(x: centre.x - symbol.size.width / 2, y: centre.y - symbol.size.height / 2))
        }
    }

    /// The pictures' sizes in points; the car scales them to its card.
    static let wideCard = CGSize(width: 292, height: 164)
    static let squareCard = CGSize(width: 141, height: 141)

    /// Blue to ask, gold to talk, green for a new chat: the deep end and the bright end of each.
    static func cardColours(_ start: Start) -> (deep: UIColor, bright: UIColor) {
        func rgb(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return switch start {
        case .ask: (rgb(0x0A2E66), rgb(0x3D9BFF))
        case .talk: (rgb(0x6E4708), rgb(0xF0B850))
        case .newChat: (rgb(0x0A4A3C), rgb(0x3ECFA6))
        }
    }

    private static func cardSymbol(_ start: Start) -> String {
        switch start {
        case .ask: "mic.fill"
        case .talk: "waveform"
        case .newChat: "plus.bubble.fill"
        }
    }

    /// The mark beside the chat that is open, at the trailing edge of its row.
    static var openChatMark: UIImage? {
        UIImage(systemName: "checkmark")?.withTintColor(gold, renderingMode: .alwaysOriginal)
    }

    // MARK: - The voice card

    /// The largest image a voice-control state takes, in points (CarPlay's own limit).
    static let voiceImageSide: CGFloat = 150

    /// How a state's picture moves: how long one loop lasts and how many pictures it is made of.
    /// CarPlay plays a loop of 0.3 to 5 seconds. Muted and "needs your phone" stand still.
    static func loop(_ state: VoiceState) -> (duration: TimeInterval, frames: Int)? {
        switch state {
        case .listening: (2.4, 29)
        case .thinking: (2.4, 29)
        case .speaking: (2.0, 32)
        case .muted, .phone: nil
        }
    }

    /// The voice card's large image for each state: a graphite disc with light or gold marks.
    /// `movingAt` makes Listening, Thinking and Speaking a loop, drawn at that many pixels a
    /// point: the waveform swells while the mic is open, rises and falls in gold while Redde
    /// speaks, and the spark turns while it thinks. The card plays pictures made ahead of time,
    /// so the bars follow a rhythm of their own and not the level of anybody's voice, unlike the
    /// phone's.
    static func voiceStateImage(_ state: VoiceState, side: CGFloat = voiceImageSide, movingAt scale: CGFloat? = nil) -> UIImage {
        let key = "\(state.rawValue) \(side) \(scale ?? 0)"
        if let made = voicePictures[key] { return made }
        let size = CGSize(width: side, height: side)
        var picture = render(size) { ctx, rect in draw(state, at: nil, ctx, rect) }
        if let scale, let loop = loop(state) {
            var frames: [UIImage] = []
            for i in 0 ..< loop.frames {
                let p = CGFloat(i) / CGFloat(loop.frames)
                // The spark rests between turns: those pictures are the first one again.
                if state == .thinking, p >= thinkingTurnEnds, let first = frames.first {
                    frames.append(first)
                } else {
                    frames.append(render(size, scale: scale) { ctx, rect in draw(state, at: p, ctx, rect) })
                }
            }
            picture = UIImage.animatedImage(with: frames, duration: loop.duration) ?? picture
        }
        voicePictures[key] = picture
        return picture
    }

    /// The pictures already drawn, so that a card opens without drawing eighty of them first.
    private static var voicePictures: [String: UIImage] = [:]
    private static var backdrops: [Bool: UIImage] = [:]

    /// Lets go of the drawn pictures: the car is gone.
    static func forget() {
        voicePictures = [:]
        backdrops = [:]
    }

    /// One picture of a state. `p` is how far through its loop, 0 up to 1; nil is the picture
    /// that stands still.
    private static func draw(_ state: VoiceState, at p: CGFloat?, _ ctx: CGContext, _ rect: CGRect) {
        disc(ctx, rect)
        let u = rect.width / 100
        func waveform(_ heights: [CGFloat], _ colour: UIColor) {
            bars(ctx, centreX: 50 * u, centreY: 50 * u, heights: heights.map { $0 * u }, gap: 8.5 * u, width: 5.5 * u, colour: colour)
        }
        switch state {
        case .listening:
            // Your voice: light bars in the spark's profile.
            waveform(p.map(listeningHeights) ?? profile(tallest: 52, rest: 8), mist)
        case .thinking:
            spark(ctx, centre: CGPoint(x: 50 * u, y: 50 * u), radius: 22 * u, colour: gold, turned: p.map(thinkingTurn) ?? 0)
        case .speaking:
            // Redde's voice: the same bars in gold.
            waveform(p.map(speakingHeights) ?? profile(tallest: 52, rest: 8), gold)
        case .muted:
            // Nobody is being heard: the bars at rest, struck through.
            waveform(profile(tallest: 8, rest: 8), mist)
            line(ctx, from: CGPoint(x: 30 * u, y: 70 * u), to: CGPoint(x: 70 * u, y: 30 * u), width: 6 * u, colour: gold)
        case .phone:
            // The agent is waiting for an approval that only the phone can give: a phone outline.
            ctx.setLineJoin(.round); ctx.setLineWidth(6 * u); mist.setStroke()
            UIBezierPath(roundedRect: CGRect(x: 36 * u, y: 26 * u, width: 28 * u, height: 48 * u), cornerRadius: 6 * u).stroke()
            mist.setFill(); ctx.fillEllipse(in: CGRect(x: 47.5 * u, y: 64 * u, width: 5 * u, height: 5 * u))
        }
    }

    /// Listening: a swell that runs across the bars from left to right, never flat and never
    /// full. The mic is open and waiting. Heights are in the 100-unit square.
    static func listeningHeights(_ p: CGFloat) -> [CGFloat] {
        sparkProfile.indices.map { i in
            let swell = 0.5 + 0.5 * sin(2 * .pi * (p - CGFloat(i) * 0.085))
            return 8 + 44 * sparkProfile[i] * (0.30 + 0.45 * swell) + 5 * swell
        }
    }

    /// Speaking: the bars rise and fall together, as the phone's do with the loudness of the
    /// reply, on a rhythm like speech. The outer ones follow a moment after the centre.
    static func speakingHeights(_ p: CGFloat) -> [CGFloat] {
        sparkProfile.indices.map { i in
            let q = p - CGFloat(abs(i - 3)) * 0.012
            let loudness = 0.52 + 0.26 * sin(2 * .pi * 2 * q) + 0.17 * sin(2 * .pi * 5 * q + 0.9) + 0.09 * sin(2 * .pi * 3 * q + 2.1)
            return 8 + 44 * sparkProfile[i] * min(max(loudness, 0.06), 1)
        }
    }

    /// Thinking: the spark makes a quarter turn, which leaves a four-pointed spark as it was,
    /// then rests for the remainder of the loop.
    static func thinkingTurn(_ p: CGFloat) -> CGFloat {
        let x = min(p / thinkingTurnEnds, 1)
        return .pi / 2 * x * x * (3 - 2 * x)
    }

    private static let thinkingTurnEnds: CGFloat = 0.6

    /// What lies behind the voice card (iOS 27): graphite with a soft light where the picture
    /// sits, mist while you are heard and gold while Redde thinks and speaks. One image holding a
    /// dark and a light picture, since the card's own words follow the car's appearance and have
    /// to stay readable on either.
    static func voiceBackdrop(_ state: VoiceState) -> UIImage {
        let warm = state == .thinking || state == .speaking
        if let made = backdrops[warm] { return made }
        let light = backdrop(dark: false, warm: warm), dark = backdrop(dark: true, warm: warm)
        let both = UIImageAsset()
        both.register(light, with: UITraitCollection(userInterfaceStyle: .light))
        both.register(dark, with: UITraitCollection(userInterfaceStyle: .dark))
        let picture = both.image(with: UITraitCollection(userInterfaceStyle: .dark))
        backdrops[warm] = picture
        return picture
    }

    /// A car screen's shape. The picture is all gradients and is stretched to the screen, so
    /// one size does for every car. Drawn at one pixel a point, which is how an image asset
    /// keeps a picture registered for an appearance alone.
    static let backdropSize = CGSize(width: 960, height: 540)

    private static func backdrop(dark: Bool, warm: Bool) -> UIImage {
        render(backdropSize, scale: 1, opaque: true) { ctx, rect in
            let ground: [UIColor] = dark
                ? [UIColor(red: 0.165, green: 0.192, blue: 0.251, alpha: 1),    // #2A3140
                   UIColor(red: 0.075, green: 0.094, blue: 0.133, alpha: 1),    // #131822
                   UIColor(red: 0.027, green: 0.031, blue: 0.043, alpha: 1)]    // #07080B
                : [UIColor.white,
                   UIColor(red: 0.933, green: 0.945, blue: 0.965, alpha: 1),    // #EEF1F6
                   UIColor(red: 0.851, green: 0.875, blue: 0.910, alpha: 1)]    // #D9DFE8
            ground[2].setFill(); ctx.fill(rect)
            // Lightest a little above the middle, where the card puts its picture.
            let centre = CGPoint(x: rect.midX, y: rect.height * 0.38)
            radial(ctx, ground, at: [0, 0.46, 1], centre: centre, radii: CGSize(width: rect.width * 1.2, height: rect.height * 0.9))
            // A light backdrop is already as light as mist: only gold shows on it.
            guard dark || warm else { return }
            let glow = warm ? gold : mist
            let strength: CGFloat = warm ? 0.24 : 0.18
            radial(ctx, [glow.withAlphaComponent(strength), glow.withAlphaComponent(0)], at: [0, 1], centre: centre,
                   radii: CGSize(width: rect.height * 0.62, height: rect.height * 0.62))
        }
    }

    /// The bars' heights from the spark profile, each at least `rest` units tall.
    private static func profile(tallest: CGFloat, rest: CGFloat) -> [CGFloat] {
        sparkProfile.map { rest + (tallest - rest) * $0 }
    }

    // MARK: - Drawing

    private static func render(_ size: CGSize, scale: CGFloat = 3, opaque: Bool = false, _ draw: (CGContext, CGRect) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(context.cgContext, CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)   // keep the brand colours; don't let CarPlay tint them
    }

    private static func disc(_ ctx: CGContext, _ rect: CGRect) {
        ctx.saveGState()
        UIBezierPath(ovalIn: rect).addClip()
        gradient(ctx, rect)
        ctx.restoreGState()
    }

    /// The graphite ground, lighter at the top left.
    private static func gradient(_ ctx: CGContext, _ rect: CGRect) {
        let colours = [graphiteTop.cgColor, graphiteBottom.cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
    }

    /// A gradient out from a centre, on an ellipse of the given radii, carried on past its edge.
    private static func radial(_ ctx: CGContext, _ colours: [UIColor], at stops: [CGFloat], centre: CGPoint, radii: CGSize) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours.map(\.cgColor) as CFArray, locations: stops) else { return }
        ctx.saveGState()
        ctx.translateBy(x: centre.x, y: centre.y)
        ctx.scaleBy(x: radii.width, y: radii.height)
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Vertical rounded bars centred on a point.
    private static func bars(_ ctx: CGContext, centreX: CGFloat, centreY: CGFloat, heights: [CGFloat], gap: CGFloat, width: CGFloat, colour: UIColor) {
        ctx.saveGState()
        ctx.setLineCap(.round); ctx.setLineWidth(width); colour.setStroke()
        let start = centreX - gap * CGFloat(heights.count - 1) / 2
        for (i, h) in heights.enumerated() {
            let x = start + CGFloat(i) * gap
            ctx.move(to: CGPoint(x: x, y: centreY - h / 2 + width / 2))
            ctx.addLine(to: CGPoint(x: x, y: centreY + h / 2 - width / 2))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func line(_ ctx: CGContext, from: CGPoint, to: CGPoint, width: CGFloat, colour: UIColor) {
        ctx.saveGState()
        ctx.setLineCap(.round); ctx.setLineWidth(width); colour.setStroke()
        ctx.move(to: from); ctx.addLine(to: to)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The app icon's four-point spark: quadratic arms pulled in to the centre.
    private static func spark(_ ctx: CGContext, centre c: CGPoint, radius r: CGFloat, colour: UIColor, turned: CGFloat = 0) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: -r))
        path.addQuadCurve(to: CGPoint(x: r, y: 0), controlPoint: .zero)
        path.addQuadCurve(to: CGPoint(x: 0, y: r), controlPoint: .zero)
        path.addQuadCurve(to: CGPoint(x: -r, y: 0), controlPoint: .zero)
        path.addQuadCurve(to: CGPoint(x: 0, y: -r), controlPoint: .zero)
        path.close()
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: turned)
        colour.setFill(); path.fill()
        ctx.restoreGState()
    }
}

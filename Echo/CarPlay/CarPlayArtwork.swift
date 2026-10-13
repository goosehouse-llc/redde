import CarPlay
import UIKit

/// Redde's CarPlay artwork. The Ask tab's cards come in six looks (`CarPlayCardLook`, picked in
/// Settings), a colour each unless another is chosen, to be told apart at a glance.
/// The voice card's pictures are graphite discs with lights on them, after the dashboard of KITT,
/// the talking car in Knight Rider: three columns of lights that rise and fall with a voice, in
/// mist while you are heard and in gold while Redde speaks, and a scanner whose light runs to and
/// fro while it thinks. CarPlay owns layout and type, so these images are where the brand shows.
/// Everything is drawn in code so it stays sharp on any car display, and every picture carries
/// its own ground so it reads the same on CarPlay's light and dark appearances.
enum CarPlayArtwork {
    static let graphiteTop = UIColor(red: 0.231, green: 0.267, blue: 0.325, alpha: 1)      // #3B4453
    static let graphiteBottom = UIColor(red: 0.078, green: 0.102, blue: 0.149, alpha: 1)   // #141A26
    static let mist = UIColor(red: 0.863, green: 0.890, blue: 0.933, alpha: 1)             // #DCE3EE
    static let gold = UIColor(red: 0xE8 / 255.0, green: 0xB0 / 255.0, blue: 0x4B / 255.0, alpha: 1)

    /// The Ask tab's three cards: the ways to start talking.
    enum Start: CaseIterable { case ask, talk, newChat }
    /// The voice card's states. Five, the most a voice-control template takes.
    enum VoiceState: String, CaseIterable { case listening, thinking, speaking, paused, phone }

    // MARK: - The Ask tab

    /// A card on the Ask tab, in the look Settings names. The picture is wide because a card made
    /// from a thumbnail takes its picture's shape and lets the picture fill it, and 16 by 9 is
    /// the widest the car draws: 146 points across on a 770-point screen, where a square picture
    /// set inside a card made one of 80. The car writes the card's two lines over the bottom left
    /// corner, in white whatever its appearance, so every look is dark there and keeps its mark
    /// to the right. `wide: false` is the square picture for a card of the older kind (before
    /// iOS 26.4), its mark in the middle.
    static func startCard(_ start: Start, look: CarPlayCardLook = .color, wide: Bool = true) -> UIImage {
        let key = "\(start) \(look.rawValue) \(wide)"
        if let made = cardPictures[key] { return made }
        let picture = render(wide ? wideCard : squareCard, opaque: true) { ctx, rect in
            // Where the mark goes, and how tall it is.
            let centre = wide ? CGPoint(x: rect.width * 0.73, y: rect.height * 0.44) : CGPoint(x: rect.midX, y: rect.midY)
            let height = rect.height * (wide ? 0.62 : 0.46)
            let light = cardLight(start)
            switch look {
            case .color:
                // Deep at the corner where the words lie, bright behind the symbol.
                let (deep, bright) = cardColours(start)
                diagonal(ctx, rect, from: deep, to: bright)
                symbol(cardSymbol(start), height: height * 0.80, colour: .white, centre: centre)
            case .glow:
                // Nearly black, with a light in the card's colour behind its symbol.
                diagonal(ctx, rect, from: rgb(0x07090D), to: rgb(0x161B26))
                radial(ctx, [light.withAlphaComponent(0.55), light.withAlphaComponent(0.16), light.withAlphaComponent(0)], at: [0, 0.55, 1],
                       centre: centre, radii: CGSize(width: height * 1.25, height: height * 1.25))
                symbol(cardSymbol(start), height: height * 0.78, colour: .white, centre: centre)
            case .orb:
                // The phone's voice orb: a dark glass disc in a ring of the card's colour.
                diagonal(ctx, rect, from: rgb(0x06080B), to: rgb(0x11151D))
                let r = height * 0.60
                radial(ctx, [light.withAlphaComponent(0.34), light.withAlphaComponent(0)], at: [0.55, 1], centre: centre,
                       radii: CGSize(width: r * 1.55, height: r * 1.55))
                let face = CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)
                ctx.saveGState()
                UIBezierPath(ovalIn: face).addClip()
                gradient(ctx, face, from: rgb(0x343D4D), to: rgb(0x0D1118))
                radial(ctx, [UIColor.white.withAlphaComponent(0.16), UIColor.white.withAlphaComponent(0)], at: [0, 1],
                       centre: CGPoint(x: centre.x - r * 0.35, y: centre.y - r * 0.45), radii: CGSize(width: r * 0.9, height: r * 0.9))
                ctx.restoreGState()
                ctx.setLineWidth(max(2.5, r * 0.07)); light.setStroke()
                ctx.strokeEllipse(in: face)
                if start == .newChat {
                    symbol("plus", height: r * 0.72, weight: .bold, colour: mist, centre: centre)
                } else {
                    mark(start, ctx, centre: centre, height: r * 0.86)
                }
            case .gold:
                gradient(ctx, rect, from: rgb(0x2B3240), to: rgb(0x0C1017))
                symbol(cardSymbol(start), height: height * 0.80, colour: gold, centre: centre)
            case .graphite:
                gradient(ctx, rect)
                symbol(cardSymbol(start), height: height * 0.80, colour: mist, centre: centre)
            case .marks:
                gradient(ctx, rect)
                mark(start, ctx, centre: centre, height: height)
            }
        }
        cardPictures[key] = picture
        return picture
    }

    /// The pictures' sizes in points; the car scales them to its card.
    static let wideCard = CGSize(width: 292, height: 164)
    static let squareCard = CGSize(width: 141, height: 141)

    /// Blue to ask, gold to talk, green for a new chat: the deep end and the bright end of each.
    static func cardColours(_ start: Start) -> (deep: UIColor, bright: UIColor) {
        switch start {
        case .ask: (rgb(0x0A2E66), rgb(0x3D9BFF))
        case .talk: (rgb(0x6E4708), rgb(0xF0B850))
        case .newChat: (rgb(0x0A4A3C), rgb(0x3ECFA6))
        }
    }

    /// The same three colours as light: a glow, or an orb's ring.
    private static func cardLight(_ start: Start) -> UIColor {
        switch start {
        case .ask: rgb(0x2E8BF5)
        case .talk: gold
        case .newChat: rgb(0x38C29E)
        }
    }

    private static func cardSymbol(_ start: Start) -> String {
        switch start {
        case .ask: "mic.fill"
        case .talk: "waveform"
        case .newChat: "plus.bubble.fill"
        }
    }

    /// Redde's own marks, as the cards first had them: one voice waiting to be heard, a voice
    /// running into the spark that answers, and the spark by itself, about to be asked something.
    private static func mark(_ start: Start, _ ctx: CGContext, centre c: CGPoint, height: CGFloat) {
        let u = height / 50
        switch start {
        case .ask:
            bars(ctx, centre: c, heights: [19, 31, 50, 31, 19].map { $0 * u }, gap: 10.5 * u, width: 6 * u, colour: mist)
        case .talk:
            bars(ctx, centre: CGPoint(x: c.x - 17 * u, y: c.y), heights: [18, 32, 48, 27].map { $0 * u }, gap: 10 * u, width: 6 * u, colour: mist)
            spark(ctx, centre: CGPoint(x: c.x + 24 * u, y: c.y), radius: 17 * u, colour: gold)
        case .newChat:
            spark(ctx, centre: c, radius: 25 * u, colour: gold)
        }
    }

    /// Beside "Take a Note" on the Ask tab: a pencil in Redde's gold, on its own graphite so it
    /// reads on the car's light appearance as on its dark one.
    static let noteMark: UIImage = render(CGSize(width: 44, height: 44), opaque: false) { ctx, rect in
        ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 10).cgPath)
        ctx.clip()
        gradient(ctx, rect)
        symbol("square.and.pencil", height: 22, colour: gold, centre: CGPoint(x: rect.midX + 1, y: rect.midY - 1))
    }

    /// The mark beside the chat that is open, at the trailing edge of its row.
    static var openChatMark: UIImage? {
        UIImage(systemName: "checkmark")?.withTintColor(gold, renderingMode: .alwaysOriginal)
    }

    // MARK: - The voice card

    /// The largest image a voice-control state takes, in points (CarPlay's own limit).
    static let voiceImageSide: CGFloat = 150

    /// How a state's picture moves: how long one loop lasts and how many pictures it is made of.
    /// CarPlay plays a loop of 0.3 to 5 seconds. Paused and "needs your phone" stand still.
    static func loop(_ state: VoiceState) -> (duration: TimeInterval, frames: Int)? {
        switch state {
        case .listening: (2.4, 30)
        case .thinking: (2.0, 30)
        case .speaking: (3.0, 42)
        case .paused, .phone: nil
        }
    }

    /// The voice card's large image for each state: a graphite disc with lights in mist or gold.
    /// `movingAt` makes Listening, Thinking and Speaking a loop, drawn at that many pixels a
    /// point: the columns stir while the mic is open, rise and fall in gold on the rhythm of
    /// speech while Redde speaks, and the scanner's light runs to and fro while it thinks. The
    /// card plays pictures made ahead of time, so the lights follow a rhythm of their own and not
    /// the level of anybody's voice, unlike the phone's waveform.
    static func voiceStateImage(_ state: VoiceState, side: CGFloat = voiceImageSide, movingAt scale: CGFloat? = nil) -> UIImage {
        let key = "\(state.rawValue) \(side) \(scale ?? 0)"
        if let made = voicePictures[key] { return made }
        let size = CGSize(width: side, height: side)
        var picture = render(size) { ctx, rect in draw(state, at: nil, ctx, rect) }
        if let scale, let loop = loop(state) {
            var frames: [UIImage] = []
            // The columns move a light at a time, so most pictures of their loops are one that
            // has been drawn already: it is used again.
            var drawn: [String: UIImage] = [:]
            for i in 0 ..< loop.frames {
                let p = CGFloat(i) / CGFloat(loop.frames)
                let look = level(state, at: p).map { "\(columns(at: $0))" }
                if let look, let same = drawn[look] {
                    frames.append(same)
                } else {
                    let frame = render(size, scale: scale) { ctx, rect in draw(state, at: p, ctx, rect) }
                    if let look { drawn[look] = frame }
                    frames.append(frame)
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
    /// And the Ask tab's cards, which are asked for again whenever the tab is brought up to date.
    private static var cardPictures: [String: UIImage] = [:]

    /// Lets go of the drawn pictures: the car is gone.
    static func forget() {
        voicePictures = [:]
        backdrops = [:]
        cardPictures = [:]
    }

    /// One picture of a state. `p` is how far through its loop, 0 up to 1; nil is the picture
    /// that stands still.
    private static func draw(_ state: VoiceState, at p: CGFloat?, _ ctx: CGContext, _ rect: CGRect) {
        disc(ctx, rect)
        let u = rect.width / 100
        switch state {
        case .listening:
            // The mic is open: the columns in mist, low.
            columns(ctx, u, lit: columns(at: level(state, at: p) ?? 0.34), colour: mist)
        case .thinking:
            // Standing still, the light is on the lamp just past the middle, on its way out.
            scanner(ctx, u, lamps: scanner(p ?? 0.273), colour: gold)
        case .speaking:
            // Redde's voice: the same columns in gold, as loud as the syllable.
            columns(ctx, u, lit: columns(at: level(state, at: p) ?? 0.75), colour: gold)
        case .paused:
            // Held: the columns at rest, struck through, as they were for Muted.
            columns(ctx, u, lit: columns(at: 0), colour: mist)
            line(ctx, from: CGPoint(x: 30 * u, y: 70 * u), to: CGPoint(x: 70 * u, y: 30 * u), width: 6 * u, colour: gold)
        case .phone:
            // The agent is waiting for an approval that only the phone can give: a phone outline.
            ctx.setLineJoin(.round); ctx.setLineWidth(6 * u); mist.setStroke()
            UIBezierPath(roundedRect: CGRect(x: 36 * u, y: 26 * u, width: 28 * u, height: 48 * u), cornerRadius: 6 * u).stroke()
            mist.setFill(); ctx.fillEllipse(in: CGRect(x: 47.5 * u, y: 64 * u, width: 5 * u, height: 5 * u))
        }
    }

    // MARK: The columns

    /// How many lights a column has above its middle one, and as many below: the centre column
    /// and the two beside it, which are shorter.
    static let centreLights = 6, sideLights = 4

    /// What the columns show at a loudness of 0 to 1: the lights lit above the middle one of the
    /// centre column and of the side ones. At rest only the middle ones are lit, three dashes,
    /// and whenever more are, the centre column stands above the other two.
    static func columns(at level: CGFloat) -> (centre: Int, sides: Int) {
        let level = min(max(level, 0), 1)
        return (Int((level * CGFloat(centreLights)).rounded()), Int(level * CGFloat(sideLights)))
    }

    /// How loud the columns' state is at `p` of its loop. Nil for a state that has no columns,
    /// or no moment.
    private static func level(_ state: VoiceState, at p: CGFloat?) -> CGFloat? {
        guard let p else { return nil }
        switch state {
        case .listening: return listeningLevel(p)
        case .speaking: return speakingLevel(p)
        case .thinking, .paused, .phone: return nil
        }
    }

    /// Listening: low and restless, like a meter on an open mic in a quiet car. Never still for
    /// long and never high: it is nobody's speech, and must not look as if it followed yours.
    static func listeningLevel(_ p: CGFloat) -> CGFloat {
        let stir = 0.20 + 0.11 * sin(2 * .pi * 2 * p + 0.6) + 0.09 * sin(2 * .pi * 5 * p + 1.9) + 0.07 * sin(2 * .pi * 7 * p + 4.0)
        return min(max(stir, 0), 1)
    }

    /// The syllables of the Speaking loop: when each is loudest, as a fraction of the loop, and
    /// how loud. Three phrases with a breath between them, about four syllables a second.
    private static let syllables: [(at: CGFloat, peak: CGFloat)] = [
        (0.040, 0.75), (0.113, 1.00), (0.173, 0.60), (0.260, 0.90), (0.327, 0.55),
        (0.473, 0.85), (0.533, 0.65), (0.607, 1.00), (0.687, 0.70),
        (0.813, 0.90), (0.873, 0.60), (0.940, 0.80),
    ]

    /// Speaking: each syllable comes up at once and dies away more slowly, as a voice does, and
    /// the lights fall back to rest in the breaths.
    static func speakingLevel(_ p: CGFloat) -> CGFloat {
        syllables.map { syllable in
            // How far past the syllable's peak, in loops: the loop is a circle.
            var since = (p - syllable.at).truncatingRemainder(dividingBy: 1)
            if since > 0.5 { since -= 1 } else if since < -0.5 { since += 1 }
            return syllable.peak * (since < 0 ? max(0, 1 + since / 0.013) : exp(-since / 0.037))
        }.max() ?? 0
    }

    /// Three columns of lights, each a stack about its middle one, the centre column taller.
    /// `lit` is how many are lit above the middle one, and as many below it; the others show
    /// faintly, as lamps that are off.
    private static func columns(_ ctx: CGContext, _ u: CGFloat, lit: (centre: Int, sides: Int), colour: UIColor) {
        let width: CGFloat = 13, across: CGFloat = 19.5, height: CGFloat = 3.4, up: CGFloat = 5.2
        for (column, (lights, lit)) in [(sideLights, lit.sides), (centreLights, lit.centre), (sideLights, lit.sides)].enumerated() {
            let x = 50 + CGFloat(column - 1) * across
            for light in -lights ... lights {
                let lamp = CGRect(x: (x - width / 2) * u, y: (50 + CGFloat(light) * up - height / 2) * u, width: width * u, height: height * u)
                colour.withAlphaComponent(abs(light) <= lit ? 1 : offLamp).setFill()
                UIBezierPath(roundedRect: lamp, cornerRadius: 1.3 * u).fill()
            }
        }
    }

    /// How much of its colour a lamp that is off still shows.
    private static let offLamp: CGFloat = 0.14

    // MARK: The scanner

    static let scannerLamps = 8

    /// Thinking: how bright each lamp of the scanner is, 0 to 1, at `p` of the loop. One light
    /// runs to the far end and back, slowing as it turns, and the lamps behind it fade out.
    static func scanner(_ p: CGFloat) -> [CGFloat] {
        func light(_ p: CGFloat) -> CGFloat { CGFloat(scannerLamps - 1) * (0.5 - 0.5 * cos(2 * .pi * p)) }
        return (0 ..< scannerLamps).map { lamp in
            // The light itself, and what is left of it where it was a moment ago.
            (0 ..< 12).map { ago in
                max(0, 1 - abs(CGFloat(lamp) - light(p - CGFloat(ago) * 0.012)) / 1.25) * pow(0.8, CGFloat(ago))
            }.max() ?? 0
        }
    }

    /// A row of lamps across the middle of the disc, each as bright as `lamps` says.
    private static func scanner(_ ctx: CGContext, _ u: CGFloat, lamps: [CGFloat], colour: UIColor) {
        let width: CGFloat = 7.4, across: CGFloat = 9.6, height: CGFloat = 16
        for (i, brightness) in lamps.enumerated() {
            let x = 50 + (CGFloat(i) - CGFloat(lamps.count - 1) / 2) * across
            colour.withAlphaComponent(offLamp + (1 - offLamp) * brightness).setFill()
            UIBezierPath(roundedRect: CGRect(x: (x - width / 2) * u, y: (50 - height / 2) * u, width: width * u, height: height * u),
                         cornerRadius: 1.6 * u).fill()
        }
    }

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

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// A ground lighter at the top left: the graphite one, unless other colours are given.
    private static func gradient(_ ctx: CGContext, _ rect: CGRect, from: UIColor = graphiteTop, to: UIColor = graphiteBottom) {
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [from.cgColor, to.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
    }

    /// A ground that runs from the bottom left corner, where a card's words lie, to the top right.
    private static func diagonal(_ ctx: CGContext, _ rect: CGRect, from: UIColor, to: UIColor) {
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [from.cgColor, to.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        }
    }

    /// A system symbol of that height, centred on a point.
    private static func symbol(_ name: String, height: CGFloat, weight: UIImage.SymbolWeight = .semibold, colour: UIColor, centre: CGPoint) {
        let config = UIImage.SymbolConfiguration(pointSize: height, weight: weight)
        guard let symbol = UIImage(systemName: name, withConfiguration: config)?.withTintColor(colour, renderingMode: .alwaysOriginal) else { return }
        symbol.draw(at: CGPoint(x: centre.x - symbol.size.width / 2, y: centre.y - symbol.size.height / 2))
    }

    /// Vertical rounded bars centred on a point.
    private static func bars(_ ctx: CGContext, centre: CGPoint, heights: [CGFloat], gap: CGFloat, width: CGFloat, colour: UIColor) {
        ctx.saveGState()
        ctx.setLineCap(.round); ctx.setLineWidth(width); colour.setStroke()
        let start = centre.x - gap * CGFloat(heights.count - 1) / 2
        for (i, h) in heights.enumerated() {
            let x = start + CGFloat(i) * gap
            ctx.move(to: CGPoint(x: x, y: centre.y - h / 2 + width / 2))
            ctx.addLine(to: CGPoint(x: x, y: centre.y + h / 2 - width / 2))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The app icon's four-point spark: quadratic arms pulled in to the centre.
    private static func spark(_ ctx: CGContext, centre c: CGPoint, radius r: CGFloat, colour: UIColor) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: -r))
        path.addQuadCurve(to: CGPoint(x: r, y: 0), controlPoint: .zero)
        path.addQuadCurve(to: CGPoint(x: 0, y: r), controlPoint: .zero)
        path.addQuadCurve(to: CGPoint(x: -r, y: 0), controlPoint: .zero)
        path.addQuadCurve(to: CGPoint(x: 0, y: -r), controlPoint: .zero)
        path.close()
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        colour.setFill(); path.fill()
        ctx.restoreGState()
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

    private static func line(_ ctx: CGContext, from: CGPoint, to: CGPoint, width: CGFloat, colour: UIColor) {
        ctx.saveGState()
        ctx.setLineCap(.round); ctx.setLineWidth(width); colour.setStroke()
        ctx.move(to: from); ctx.addLine(to: to)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

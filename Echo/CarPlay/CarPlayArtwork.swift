import CarPlay
import UIKit

/// Redde's CarPlay artwork. The Ask tab's cards come in six looks (`CarPlayCardLook`, picked in
/// Settings), a colour each unless another is chosen, to be told apart at a glance.
/// The voice card's pictures are discs with lights on them, in four looks (`CarPlayVoiceLook`,
/// picked in Settings too). Three are after the dashboard of KITT, the talking car in Knight
/// Rider: three bars of light, low while you are heard and swelling while Redde speaks, and one
/// light going to and fro while it thinks. Solid bars in mist and gold, the same as stacks of
/// small lamps, and the lamps in the car's own red on black. The fourth is a ring of light
/// around Redde's marks. They move slowly and in one piece: nothing here can follow a real
/// voice, and lights that leapt about as if they did looked odd. CarPlay owns layout and type,
/// so these images are where the brand shows.
/// Everything is drawn in code so it stays sharp on any car display, and every picture carries
/// its own ground so it reads the same on CarPlay's light and dark appearances.
enum CarPlayArtwork {
    static let graphiteTop = UIColor(red: 0.231, green: 0.267, blue: 0.325, alpha: 1)      // #3B4453
    static let graphiteBottom = UIColor(red: 0.078, green: 0.102, blue: 0.149, alpha: 1)   // #141A26
    static let mist = UIColor(red: 0.863, green: 0.890, blue: 0.933, alpha: 1)             // #DCE3EE
    static let gold = UIColor(red: 0xE8 / 255.0, green: 0xB0 / 255.0, blue: 0x4B / 255.0, alpha: 1)
    /// The KITT look: every light red, on a dash that is nearly black.
    static let red = UIColor(red: 1, green: 0x3B / 255.0, blue: 0x2F / 255.0, alpha: 1)       // #FF3B2F
    static let dashTop = UIColor(red: 0.110, green: 0.114, blue: 0.133, alpha: 1)             // #1C1D22
    static let dashBottom = UIColor(red: 0.020, green: 0.020, blue: 0.024, alpha: 1)          // #050506

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

    /// Beside "Short Answers" on the Ask tab, in the manner of the pencil.
    static let brevityMark: UIImage = render(CGSize(width: 44, height: 44), opaque: false) { ctx, rect in
        ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 10).cgPath)
        ctx.clip()
        gradient(ctx, rect)
        symbol("text.badge.minus", height: 21, colour: gold, centre: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// The end of the Short Answers row: a switch, as iOS draws one. CarPlay's lists have none
    /// of their own, only a picture at the end of a row. Green with the knob to the right is on.
    static func switchMark(on: Bool) -> UIImage { on ? switchOn : switchOff }

    private static let switchOn = drawnSwitch(on: true), switchOff = drawnSwitch(on: false)

    /// No more than 44 points either way (`CPListItem.maximumImageSize`). A picture at the end
    /// of a row that is any larger is made to fit by CarPlay, which then takes its pixels for
    /// points: a switch 46 points wide came out 132 wide in a row twice the height (drawn with
    /// CarPlay's own views, 2026-10-13).
    static let switchSize = CGSize(width: 42, height: 26)

    private static func drawnSwitch(on: Bool) -> UIImage {
        render(switchSize, opaque: false) { ctx, rect in
            // The grey shows on the car's light appearance as on its dark one.
            (on ? rgb(0x34C759) : rgb(0x8E8E93).withAlphaComponent(0.6)).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).fill()
            let knob = rect.height - 4
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2 * abs(ctx.ctm.a), color: UIColor.black.withAlphaComponent(0.25).cgColor)
            UIColor.white.setFill()
            ctx.fillEllipse(in: CGRect(x: on ? rect.maxX - knob - 2 : 2, y: 2, width: knob, height: knob))
        }
    }

    /// The mark beside the chat that is open, at the trailing edge of its row.
    static var openChatMark: UIImage? {
        UIImage(systemName: "checkmark")?.withTintColor(gold, renderingMode: .alwaysOriginal)
    }

    // MARK: - The voice card

    /// The largest image a voice-control state takes, in points (CarPlay's own limit).
    static let voiceImageSide: CGFloat = 150

    /// How a state's picture moves in a look: how long one loop lasts and how many pictures it
    /// is made of. CarPlay plays a loop of 0.3 to 5 seconds. Paused and "needs your phone" stand
    /// still.
    static func loop(_ state: VoiceState, look: CarPlayVoiceLook = .bars) -> (duration: TimeInterval, frames: Int)? {
        switch (state, look) {
        case (.paused, _), (.phone, _): nil
        case (.listening, .orb): (4.8, 58)
        case (.thinking, .orb): (1.8, 36)
        case (.speaking, .orb): (2.4, 36)
        case (.listening, _): (3.6, 44)
        case (.thinking, _): (2.8, 42)
        case (.speaking, _): (4.0, 60)
        }
    }

    /// The voice card's large image for each state, in the look Settings names: a disc with
    /// lights on it. `movingAt` makes Listening, Thinking and Speaking a loop, drawn at that
    /// many pixels a point. The card plays pictures made ahead of time, so the lights keep a
    /// rhythm of their own and not the level of anybody's voice, unlike the phone's waveform.
    /// That is why they are slow: see `speakingLevel`.
    static func voiceStateImage(_ state: VoiceState, look: CarPlayVoiceLook = .bars, side: CGFloat = voiceImageSide,
                                movingAt scale: CGFloat? = nil) -> UIImage {
        let key = "\(look.rawValue) \(state.rawValue) \(side) \(scale ?? 0)"
        if let made = voicePictures[key] { return made }
        let picture = voicePicture(state, look: look, side: side, movingAt: scale)
        voicePictures[key] = picture
        return picture
    }

    /// The same picture drawn afresh and not kept: for Settings, which plays a look's loops only
    /// while its row is open.
    static func voicePicture(_ state: VoiceState, look: CarPlayVoiceLook, side: CGFloat = voiceImageSide, movingAt scale: CGFloat? = nil) -> UIImage {
        let size = CGSize(width: side, height: side)
        guard let scale, let loop = loop(state, look: look) else {
            return render(size) { ctx, rect in draw(state, look, at: nil, ctx, rect) }
        }
        var frames: [UIImage] = []
        // A picture that looks just like one drawn already is that one again: the bars come down
        // the way they went up, which halves what the car has to hold.
        var drawn: [Twin: UIImage] = [:]
        for i in 0 ..< loop.frames {
            let twin = twin(state, look, picture: i, of: loop.frames)
            if let twin, let same = drawn[twin] {
                frames.append(same)
            } else {
                let frame = render(size, scale: scale) { ctx, rect in draw(state, look, at: CGFloat(i) / CGFloat(loop.frames), ctx, rect) }
                if let twin { drawn[twin] = frame }
                frames.append(frame)
            }
        }
        return UIImage.animatedImage(with: frames, duration: loop.duration) ?? frames[0]
    }

    /// What a picture of a loop shares with every other that looks just the same: where its
    /// bars stand, or how far it is through half a loop.
    private enum Twin: Hashable { case bars(VoiceBars), half(Int) }

    /// Nil: the picture is the only one of its kind in the loop.
    private static func twin(_ state: VoiceState, _ look: CarPlayVoiceLook, picture i: Int, of frames: Int) -> Twin? {
        switch look {
        case .bars, .lamps, .kitt:
            voiceBars(state, at: CGFloat(i) / CGFloat(frames)).map { .bars($0) }
        case .orb:
            // Speaking sends out two rings half a loop apart: its second half is its first again.
            state == .speaking ? .half(i % (frames / 2)) : nil
        }
    }

    /// The pictures already drawn, so that a card opens without drawing a hundred of them first.
    private static var voicePictures: [String: UIImage] = [:]
    private static var backdrops: [String: UIImage] = [:]
    /// And the Ask tab's cards, which are asked for again whenever the tab is brought up to date.
    private static var cardPictures: [String: UIImage] = [:]

    /// Lets go of the drawn pictures: the car is gone.
    static func forget() {
        voicePictures = [:]
        backdrops = [:]
        cardPictures = [:]
    }

    /// Lets go of the voice card's pictures in every look but one: another was picked.
    static func keepVoicePictures(only look: CarPlayVoiceLook) {
        voicePictures = voicePictures.filter { $0.key.hasPrefix("\(look.rawValue) ") }
    }

    /// One picture of a state in a look. `p` is how far through its loop, 0 up to 1; nil is the
    /// picture that stands still.
    private static func draw(_ state: VoiceState, _ look: CarPlayVoiceLook, at p: CGFloat?, _ ctx: CGContext, _ rect: CGRect) {
        let u = rect.width / 100
        // Mist is you and what waits on you, gold is Redde. KITT gives that up for the car's
        // red: there the height of the lights and the scanner tell the states apart.
        let colour = look == .kitt ? red : state == .thinking || state == .speaking ? gold : mist
        if look == .kitt { disc(ctx, rect, from: dashTop, to: dashBottom) } else { disc(ctx, rect) }
        switch (look, state) {
        case (.orb, _):
            orb(ctx, u, state, at: p, colour: colour)
        case (_, .phone):
            phone(ctx, u, colour: colour)
        case (.bars, .listening), (.bars, .speaking):
            // The mic is open: the bars low. Redde's voice: the same bars, tall.
            let still = state == .listening ? VoiceBars(centre: 0.3, sides: 0.1) : VoiceBars(centre: 0.85, sides: 0.8)
            voiceBars(ctx, u, lit: p.flatMap { voiceBars(state, at: $0) } ?? still, colour: colour)
        case (.bars, .thinking):
            // Standing still, the light is just past the middle of its slot, on its way out.
            glider(ctx, u, at: p ?? 0.273, colour: colour)
        case (.bars, .paused):
            // Held: two bars, the sign on any pause button. Nothing moves.
            for x in [38.5, 61.5] as [CGFloat] { bar(ctx, u, x: x, half: sideReach, most: nil, colour: colour) }
        case (_, .listening), (_, .speaking):
            // Standing still, the columns end on a whole lamp.
            let still = state == .listening ? VoiceBars(centre: 1 / 3, sides: 1 / 4) : VoiceBars(centre: 5 / 6, sides: 3 / 4)
            columns(ctx, u, lit: p.flatMap { voiceBars(state, at: $0) } ?? still, colour: colour, shine: look == .kitt ? 3 : 2.2)
        case (_, .thinking):
            scanner(ctx, u, lamps: scanner(p ?? 0.273), colour: colour, shine: look == .kitt ? 3 : 2.2)
        case (_, .paused):
            for x in [38.5, 61.5] as [CGFloat] {
                for light in -sideLights ... sideLights { lamp(ctx, u, x: x, light: light, colour: colour, lit: 1, shine: 1.2) }
            }
        }
    }

    /// The agent is waiting for an approval that only the phone can give: a phone outline.
    private static func phone(_ ctx: CGContext, _ u: CGFloat, colour: UIColor) {
        let outline = UIBezierPath(roundedRect: CGRect(x: 36 * u, y: 26 * u, width: 28 * u, height: 48 * u), cornerRadius: 6 * u)
        // (A path strokes at its own width, not the context's.)
        outline.lineWidth = 4 * u
        colour.setStroke(); outline.stroke()
        colour.setFill(); ctx.fillEllipse(in: CGRect(x: 47.5 * u, y: 63 * u, width: 5 * u, height: 5 * u))
    }

    // MARK: The bars

    /// How far a bar reaches above its middle, and as far below, in hundredths of the picture:
    /// at rest, and at its fullest for the centre bar and for the two beside it, which are
    /// shorter.
    static let restReach: CGFloat = 1.7, centreReach: CGFloat = 32.9, sideReach: CGFloat = 22.5

    /// What the three bars show: how far the centre one and the two beside it have grown, 0 to
    /// 1. At 0 each is a dash; at 1 each fills its housing. The same for the columns of lamps:
    /// at 0 only the middle lamp of each is lit, at 1 every lamp.
    struct VoiceBars: Hashable {
        var centre: CGFloat
        var sides: CGFloat

        /// How far each reaches from its middle, in hundredths of the picture.
        var centreHalf: CGFloat { CarPlayArtwork.restReach + (CarPlayArtwork.centreReach - CarPlayArtwork.restReach) * centre }
        var sidesHalf: CGFloat { CarPlayArtwork.restReach + (CarPlayArtwork.sideReach - CarPlayArtwork.restReach) * sides }
    }

    /// The bars at `p` of a state's loop, solid or made of lamps. Nil for a state that has no
    /// bars.
    static func voiceBars(_ state: VoiceState, at p: CGFloat) -> VoiceBars? {
        // In steps too small to see, so that a picture met again is the same picture.
        func step(_ level: CGFloat) -> CGFloat { (level * 240).rounded() / 240 }
        switch state {
        case .listening:
            // Low, and swaying: the centre bar grows as the outer ones shrink, and back, so the
            // picture never pulses as a whole. The outer bars never stand as high as the centre
            // one, at any moment (asked 2026-10-13: with them above it the picture looked
            // wrong). And never high: it is nobody's speech, and must not look as if it
            // followed yours.
            let sway = sin(2 * .pi * p)
            return VoiceBars(centre: step(0.28 + 0.12 * sway), sides: step(0.10 - 0.06 * sway))
        case .speaking:
            let level = step(speakingLevel(p))
            return VoiceBars(centre: level, sides: step(level * 0.94))
        case .thinking, .paused, .phone:
            return nil
        }
    }

    /// Speaking: a slow swell, three to a loop and not all the same height, never down to rest,
    /// like a meter with a heavy needle on a voice. The first version leapt with every syllable,
    /// twelve of them in three seconds, each a jump from three dashes to the full height within
    /// one picture: fast, and to a rhythm that was not the voice's, which looked odd
    /// (2026-10-12). The second half of the loop is the first played backwards, so every
    /// picture serves twice.
    static func speakingLevel(_ p: CGFloat) -> CGFloat {
        let swell = 0.57 + 0.27 * cos(2 * .pi * 2 * p) - 0.14 * cos(2 * .pi * 3 * p) - 0.05 * cos(2 * .pi * 5 * p)
        return min(max(swell, 0.1), 1)
    }

    /// Three bars growing out of their middles, the centre one taller, each in a faint housing
    /// that shows how far it can go.
    private static func voiceBars(_ ctx: CGContext, _ u: CGFloat, lit: VoiceBars, colour: UIColor) {
        bar(ctx, u, x: 50 - 19.5, half: lit.sidesHalf, most: sideReach, colour: colour)
        bar(ctx, u, x: 50, half: lit.centreHalf, most: centreReach, colour: colour)
        bar(ctx, u, x: 50 + 19.5, half: lit.sidesHalf, most: sideReach, colour: colour)
    }

    /// One bar centred on `x`, reaching `half` above and below the middle of the picture, with
    /// a little light around it. `most`: how far its housing goes, if it has one.
    private static func bar(_ ctx: CGContext, _ u: CGFloat, x: CGFloat, half: CGFloat, most: CGFloat?, colour: UIColor) {
        let width: CGFloat = 13
        func shape(_ reach: CGFloat) -> UIBezierPath {
            UIBezierPath(roundedRect: CGRect(x: (x - width / 2) * u, y: (50 - reach) * u, width: width * u, height: 2 * reach * u),
                         cornerRadius: min(2.4, reach) * u)
        }
        if let most {
            colour.withAlphaComponent(housing).setFill()
            shape(most).fill()
        }
        glowing(ctx, u, colour: colour) { shape(half).fill() }
    }

    /// Fills what `shape` draws in `colour`, with the light it throws around it.
    private static func glowing(_ ctx: CGContext, _ u: CGFloat, colour: UIColor, alpha: CGFloat = 1, _ shape: () -> Void) {
        ctx.saveGState()
        // (A shadow's blur is in pixels, whatever the picture's scale.)
        if alpha > 0.5 { ctx.setShadow(offset: .zero, blur: 2.6 * u * abs(ctx.ctm.a), color: colour.withAlphaComponent(0.7 * alpha).cgColor) }
        colour.withAlphaComponent(alpha).setFill()
        shape()
        ctx.restoreGState()
    }

    /// How much of its colour a housing shows: where a bar can grow to, and the slot the
    /// thinking light runs in.
    private static let housing: CGFloat = 0.10

    // MARK: The glider

    /// Thinking: where the light is in its slot at `p` of the loop, 0 at one end and 1 at the
    /// other. It runs to the far end and back, slowing as it turns.
    static func glide(_ p: CGFloat) -> CGFloat { 0.5 - 0.5 * cos(2 * .pi * p) }

    /// A slot across the middle of the disc with one light in it, and what is left of the
    /// light where it was up to a third of a second ago.
    private static func glider(_ ctx: CGContext, _ u: CGFloat, at p: CGFloat, colour: UIColor) {
        let slot = CGRect(x: 12, y: 42, width: 76, height: 16), light: CGFloat = 11
        func shape(_ x: CGFloat, _ width: CGFloat) -> UIBezierPath {
            UIBezierPath(roundedRect: CGRect(x: x * u, y: slot.minY * u, width: width * u, height: slot.height * u), cornerRadius: 3 * u)
        }
        colour.withAlphaComponent(housing).setFill()
        shape(slot.minX, slot.width).fill()
        for ago in stride(from: 12, through: 0, by: -1) {
            let x = slot.minX + (slot.width - light) * glide(p - CGFloat(ago) * 0.010)
            glowing(ctx, u, colour: colour, alpha: pow(0.74, CGFloat(ago))) { shape(x, light).fill() }
        }
    }

    // MARK: The lamps

    /// How many lamps a column has above its middle one, and as many below: the centre column
    /// and the two beside it, which are shorter.
    static let centreLights = 6, sideLights = 4

    /// How brightly a lamp is lit, 0 to 1: the lamp `place` steps from the middle one, in a
    /// column of `lights` each way that is lit as far as `level`. The middle lamp is always on.
    /// The lamp at the edge of the lit part is partly on, so a column grows and shrinks by
    /// fading and not by a lamp at a time.
    static func glow(ofLamp place: Int, of lights: Int, at level: CGFloat) -> CGFloat {
        guard place > 0 else { return 1 }
        let x = min(max(level * CGFloat(lights) - CGFloat(place - 1), 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Three columns of lamps, each a stack about its middle one, the centre column taller.
    private static func columns(_ ctx: CGContext, _ u: CGFloat, lit: VoiceBars, colour: UIColor, shine: CGFloat) {
        for (column, (lights, level)) in [(sideLights, lit.sides), (centreLights, lit.centre), (sideLights, lit.sides)].enumerated() {
            for light in -lights ... lights {
                lamp(ctx, u, x: 50 + CGFloat(column - 1) * 19.5, light: light, colour: colour, lit: glow(ofLamp: abs(light), of: lights, at: level), shine: shine)
            }
        }
    }

    /// One lamp of a column centred on `x`, `light` places above or below the middle.
    private static func lamp(_ ctx: CGContext, _ u: CGFloat, x: CGFloat, light: Int, colour: UIColor, lit: CGFloat, shine: CGFloat) {
        let width: CGFloat = 13, height: CGFloat = 3.4, up: CGFloat = 5.2
        let shape = CGRect(x: (x - width / 2) * u, y: (50 + CGFloat(light) * up - height / 2) * u, width: width * u, height: height * u)
        lamplit(ctx, u, colour: colour, lit: lit, shine: shine) { UIBezierPath(roundedRect: shape, cornerRadius: 1.3 * u).fill() }
    }

    /// Fills what `shape` draws as a lamp lit that much: one that is off still shows faintly,
    /// one that is on throws light `shine` hundredths of the picture around it.
    private static func lamplit(_ ctx: CGContext, _ u: CGFloat, colour: UIColor, lit: CGFloat, shine: CGFloat, _ shape: () -> Void) {
        ctx.saveGState()
        if lit > 0.05 { ctx.setShadow(offset: .zero, blur: shine * u * abs(ctx.ctm.a), color: colour.withAlphaComponent(0.75 * lit).cgColor) }
        colour.withAlphaComponent(offLamp + (1 - offLamp) * lit).setFill()
        shape()
        ctx.restoreGState()
    }

    /// How much of its colour a lamp that is off still shows.
    private static let offLamp: CGFloat = 0.14

    static let scannerLamps = 8

    /// Thinking, in lamps: how bright each lamp of the scanner is, 0 to 1, at `p` of the loop.
    /// One light runs to the far end and back, slowing as it turns, and the lamps behind it
    /// fade out.
    static func scanner(_ p: CGFloat) -> [CGFloat] {
        func light(_ p: CGFloat) -> CGFloat { CGFloat(scannerLamps - 1) * glide(p) }
        return (0 ..< scannerLamps).map { lamp in
            // The light itself, and what is left of it where it was up to a third of a second ago.
            (0 ..< 14).map { ago in
                max(0, 1 - abs(CGFloat(lamp) - light(p - CGFloat(ago) * 0.0086)) / 1.25) * pow(0.8, CGFloat(ago))
            }.max() ?? 0
        }
    }

    /// A row of lamps across the middle of the disc, each as bright as `lamps` says.
    private static func scanner(_ ctx: CGContext, _ u: CGFloat, lamps: [CGFloat], colour: UIColor, shine: CGFloat) {
        let width: CGFloat = 7.4, across: CGFloat = 9.6, height: CGFloat = 16
        for (i, brightness) in lamps.enumerated() {
            let x = 50 + (CGFloat(i) - CGFloat(lamps.count - 1) / 2) * across
            lamplit(ctx, u, colour: colour, lit: brightness, shine: shine) {
                UIBezierPath(roundedRect: CGRect(x: (x - width / 2) * u, y: (50 - height / 2) * u, width: width * u, height: height * u),
                             cornerRadius: 1.6 * u).fill()
            }
        }
    }

    // MARK: The orb

    /// The ring of the Orb look: how far out it runs and how thick its line is, in hundredths
    /// of the picture.
    static let ringRadius: CGFloat = 39, ringLine: CGFloat = 2.6

    /// Orb: how brightly the ring is lit, 0 to 1, at `angle` round it (radians, clockwise from
    /// the top) at `p` of a state's loop. A glint goes round while you are heard and a comet,
    /// its tail a third of the ring long, while Redde thinks; the rest of the time the ring is
    /// lit evenly. Standing still, the light is an eighth of the way round.
    static func ringLight(_ state: VoiceState, at p: CGFloat?, angle: CGFloat) -> CGFloat {
        let turn = 2 * CGFloat.pi, head = turn * (p ?? 0.125)
        /// How far round it is from `a` on to `b`, going clockwise.
        func on(from a: CGFloat, to b: CGFloat) -> CGFloat {
            let d = (b - a).truncatingRemainder(dividingBy: turn)
            return d < 0 ? d + turn : d
        }
        switch state {
        case .listening:
            let away = min(on(from: angle, to: head), on(from: head, to: angle))
            return 0.22 + 0.78 * exp(-pow(away / 0.55, 2))
        case .thinking:
            return 0.14 + 0.86 * pow(max(0, 1 - on(from: angle, to: head) / 2.2), 1.5)
        case .speaking:
            return 0.5
        case .paused, .phone:
            return 0.45
        }
    }

    /// Orb, speaking: the rings spreading from the spark at `p` of the loop, how far out each
    /// is and how bright. Two of them, half a loop apart; each leaves the spark with no light
    /// and has none again when it comes to the ring, so none appears or goes out at a stroke.
    static func ripples(at p: CGFloat) -> [(radius: CGFloat, light: CGFloat)] {
        (0 ..< 2).map { i in
            let q = (p + CGFloat(i) / 2).truncatingRemainder(dividingBy: 1)
            let rise = min(q * 6, 1)
            return (14 + (ringRadius - 14) * q, 0.75 * pow(1 - q, 1.4) * rise * rise * (3 - 2 * rise))
        }
    }

    /// The Orb look: the ring, and inside it Redde's marks, a voice in mist while you are
    /// heard and the gold spark while Redde thinks and speaks.
    private static func orb(_ ctx: CGContext, _ u: CGFloat, _ state: VoiceState, at p: CGFloat?, colour: UIColor) {
        let centre = CGPoint(x: 50 * u, y: 50 * u)
        func circle(_ radius: CGFloat, line: CGFloat, light: CGFloat) {
            ctx.setLineWidth(line * u); colour.withAlphaComponent(light).setStroke()
            ctx.strokeEllipse(in: CGRect(x: (50 - radius) * u, y: (50 - radius) * u, width: 2 * radius * u, height: 2 * radius * u))
        }
        if state == .speaking {
            for ripple in ripples(at: p ?? 0.3) { circle(ripple.radius, line: 2.2, light: ripple.light) }
        }
        if state == .listening || state == .thinking {
            ring(ctx, u, colour: colour) { ringLight(state, at: p, angle: $0) }
            if state == .thinking {
                // The comet's head is round, like the end of a line.
                let angle = 2 * .pi * (p ?? 0.125)
                let head = CGPoint(x: centre.x + ringRadius * u * sin(angle), y: centre.y - ringRadius * u * cos(angle))
                colour.setFill()
                ctx.fillEllipse(in: CGRect(x: head.x - ringLine / 2 * u, y: head.y - ringLine / 2 * u, width: ringLine * u, height: ringLine * u))
            }
        } else {
            circle(ringRadius, line: ringLine, light: ringLight(state, at: p, angle: 0))
        }
        switch state {
        case .listening:
            bars(ctx, centre: centre, heights: [12, 20, 32, 20, 12].map { $0 * u }, gap: 7 * u, width: 4 * u, colour: colour)
        case .thinking, .speaking:
            glowing(ctx, u, colour: colour) { spark(ctx, centre: centre, radius: (state == .thinking ? 17 : 15) * u, colour: colour) }
        case .paused:
            bars(ctx, centre: centre, heights: [28, 28].map { $0 * u }, gap: 15 * u, width: 7 * u, colour: colour)
        case .phone:
            // The same outline as the other looks, small enough to stand inside the ring.
            ctx.saveGState()
            ctx.translateBy(x: centre.x, y: centre.y); ctx.scaleBy(x: 0.78, y: 0.78); ctx.translateBy(x: -centre.x, y: -centre.y)
            phone(ctx, u, colour: colour)
            ctx.restoreGState()
        }
    }

    /// The ring, lit differently all the way round: `light` says how brightly at an angle
    /// (radians, clockwise from the top). Worked out a pixel at a time and laid on as a mask.
    /// Drawn as arcs or wedges side by side it showed a tick wherever two met, by overlapping
    /// or by leaving a gap, and on a ring this faint the ticks were plain to see.
    private static func ring(_ ctx: CGContext, _ u: CGFloat, colour: UIColor, light: (CGFloat) -> CGFloat) {
        let pixel = u * abs(ctx.ctm.a)   // pixels to a hundredth of the picture
        let side = Int((100 * pixel).rounded())
        guard side > 0, let mask = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = mask.data else { return }
        let shades = data.bindMemory(to: UInt8.self, capacity: mask.bytesPerRow * side)
        let middle = CGFloat(side) / 2, radius = ringRadius * pixel, half = ringLine / 2 * pixel
        // Only pixels this far from the middle can be on the line.
        let nearest = pow(max(radius - half - 1, 0), 2), farthest = pow(radius + half + 1, 2)
        for row in 0 ..< side {
            for column in 0 ..< side {
                let x = CGFloat(column) + 0.5 - middle, y = CGFloat(row) + 0.5 - middle, away = x * x + y * y
                var shade: CGFloat = 0
                if away > nearest, away < farthest {
                    // How much of the pixel the line covers: all of it, but for those on its edges.
                    let covered = min(half + 0.5 - abs(away.squareRoot() - radius), 1)
                    if covered > 0 {
                        let angle = atan2(x, -y)
                        shade = covered * min(max(light(angle < 0 ? angle + 2 * .pi : angle), 0), 1)
                    }
                }
                shades[row * mask.bytesPerRow + column] = UInt8((shade * 255).rounded())
            }
        }
        guard let image = mask.makeImage() else { return }
        ctx.saveGState()
        // A mask is laid on bottom row first; turned over, its first row is the picture's top.
        ctx.translateBy(x: 0, y: 100 * u); ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: CGRect(x: 0, y: 0, width: 100 * u, height: 100 * u), mask: image)
        colour.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 100 * u, height: 100 * u))
        ctx.restoreGState()
    }

    /// What lies behind the voice card (iOS 27): graphite with a soft light where the picture
    /// sits, gold while Redde thinks and speaks and mist the rest of the time; behind KITT's
    /// lights, black with their red. One image holding a dark and a light picture, since the
    /// card's own words follow the car's appearance and have to stay readable on either.
    static func voiceBackdrop(_ state: VoiceState, look: CarPlayVoiceLook = .bars) -> UIImage {
        let warm = state == .thinking || state == .speaking, kitt = look == .kitt
        let key = kitt ? "kitt" : warm ? "warm" : "cool"
        if let made = backdrops[key] { return made }
        let glow: UIColor = kitt ? red : warm ? gold : mist
        let light = backdrop(dark: false, glow: glow, black: kitt), dark = backdrop(dark: true, glow: glow, black: kitt)
        let both = UIImageAsset()
        both.register(light, with: UITraitCollection(userInterfaceStyle: .light))
        both.register(dark, with: UITraitCollection(userInterfaceStyle: .dark))
        let picture = both.image(with: UITraitCollection(userInterfaceStyle: .dark))
        backdrops[key] = picture
        return picture
    }

    /// A car screen's shape. The picture is all gradients and is stretched to the screen, so
    /// one size does for every car. Drawn at one pixel a point, which is how an image asset
    /// keeps a picture registered for an appearance alone.
    static let backdropSize = CGSize(width: 960, height: 540)

    private static func backdrop(dark: Bool, glow: UIColor, black: Bool) -> UIImage {
        render(backdropSize, scale: 1, opaque: true) { ctx, rect in
            let ground: [UIColor] = !dark
                ? [UIColor.white,
                   UIColor(red: 0.933, green: 0.945, blue: 0.965, alpha: 1),    // #EEF1F6
                   UIColor(red: 0.851, green: 0.875, blue: 0.910, alpha: 1)]    // #D9DFE8
                : black
                ? [dashTop, rgb(0x0C0C0F), dashBottom]
                : [UIColor(red: 0.165, green: 0.192, blue: 0.251, alpha: 1),    // #2A3140
                   UIColor(red: 0.075, green: 0.094, blue: 0.133, alpha: 1),    // #131822
                   UIColor(red: 0.027, green: 0.031, blue: 0.043, alpha: 1)]    // #07080B
            ground[2].setFill(); ctx.fill(rect)
            // Lightest a little above the middle, where the card puts its picture.
            let centre = CGPoint(x: rect.midX, y: rect.height * 0.38)
            radial(ctx, ground, at: [0, 0.46, 1], centre: centre, radii: CGSize(width: rect.width * 1.2, height: rect.height * 0.9))
            // A light backdrop is already as light as mist: only gold and red show on it.
            guard dark || glow != mist else { return }
            let strength: CGFloat = glow == mist ? 0.18 : 0.24
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

    private static func disc(_ ctx: CGContext, _ rect: CGRect, from: UIColor = graphiteTop, to: UIColor = graphiteBottom) {
        ctx.saveGState()
        UIBezierPath(ovalIn: rect).addClip()
        gradient(ctx, rect, from: from, to: to)
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
}

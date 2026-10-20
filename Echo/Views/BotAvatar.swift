import SwiftUI

/// A bot's picture: a little creature, a speech bubble at heart (the corner nearest its bottom
/// left drawn sharp, as a message bubble's is, for its tail), in a colour of its own, with white
/// eyes glancing somewhere, and on some a small mouth or a mark of its own. Shape, eyes, mouth, mark
/// and colour come from the bot's profile name, so a bot keeps its creature when it is renamed in
/// Hermes Desktop, and `BotFace.faces(for:picked:)` gives every bot on a server one no other has
/// there (a shape and a colour of its own too, while there are some left), unless the person picked
/// one for it (`HermesBot.face`, kept on the server). The main agent is Redde itself: the app's own
/// message bubble, in the Code theme's pale sky whatever the theme.
nonisolated struct BotFace: Equatable, Hashable, Sendable {
    enum Shape: String, CaseIterable, Sendable {
        case round, egg, pill, capsule, burst, pick, hex, diamond
        /// Redde's own: the message bubble, its tucked corner on the left. No other bot gets it.
        case bubble
        /// Shapes only picked, never given by a name (adding them to what a name gives would
        /// change every bot's creature): a ghost, a rounded square, a star, a blob.
        case ghost, square, star, blob

        /// The shapes a bot can be picked to have.
        static let given = allCases.filter { $0 != .bubble }
        /// The shapes a name gives, in their first order: never to change.
        static let seeded: [Shape] = [.round, .egg, .pill, .capsule, .burst, .pick, .hex, .diamond]
    }
    enum Eyes: String, CaseIterable, Sendable { case round, mismatched, sleepy, happy, sparkle }
    enum Mouth: String, CaseIterable, Sendable { case none, smile, oh, grin }
    enum Mark: String, CaseIterable, Sendable { case none, antenna, spark, freckles, blush }

    var shape: Shape
    var eyes: Eyes
    var mouth: Mouth
    var mark: Mark
    /// Which way its pupils look: 0…3.
    var glance: Int
    /// A slight lean, in degrees.
    var tilt: Double
    var color: Int

    /// Each colour as a gradient, light to deep.
    static let palette: [(light: Color, deep: Color)] = [
        (Color(red: 0.66, green: 0.83, blue: 1.00), Color(red: 0.30, green: 0.55, blue: 0.96)),   // blue
        (Color(red: 1.00, green: 0.89, blue: 0.54), Color(red: 0.96, green: 0.68, blue: 0.22)),   // amber
        (Color(red: 1.00, green: 0.70, blue: 0.85), Color(red: 0.91, green: 0.34, blue: 0.62)),   // pink
        (Color(red: 0.68, green: 0.73, blue: 1.00), Color(red: 0.36, green: 0.42, blue: 0.94)),   // indigo
        (Color(red: 0.58, green: 0.94, blue: 0.87), Color(red: 0.13, green: 0.69, blue: 0.60)),   // teal
        (Color(red: 0.82, green: 0.74, blue: 1.00), Color(red: 0.54, green: 0.40, blue: 0.94)),   // violet
        (Color(red: 0.78, green: 0.96, blue: 0.66), Color(red: 0.34, green: 0.76, blue: 0.40)),   // green
        (Color(red: 1.00, green: 0.78, blue: 0.57), Color(red: 0.94, green: 0.50, blue: 0.22)),   // orange
        (Color(red: 0.66, green: 0.91, blue: 1.00), Color(red: 0.18, green: 0.68, blue: 0.90)),   // sky
        (Color(red: 1.00, green: 0.73, blue: 0.66), Color(red: 0.93, green: 0.42, blue: 0.37)),   // coral
        (Color(red: 0.92, green: 0.97, blue: 0.63), Color(red: 0.70, green: 0.80, blue: 0.17)),   // lime
        // For picking only, after `seededColors`.
        (Color(white: 1.0), Color(white: 0.86)),   // white
        (Color(white: 0.34), Color(white: 0.07)),  // black
    ]
    /// What a name gives is one of the first eleven colours, so no bot's colour changes when
    /// colours are added for picking (as with `Shape.seeded`).
    static let seededColors = 11
    /// The white one: drawn with a faint outline, or it would vanish on a white page.
    static let white = 11

    /// Every face a name can give (colour, glance and lean aside), in a fixed order.
    private static let all: [BotFace] = Shape.seeded.flatMap { shape in
        Eyes.allCases.flatMap { eyes in
            Mouth.allCases.flatMap { mouth in
                Mark.allCases.map { BotFace(shape: shape, eyes: eyes, mouth: mouth, mark: $0, glance: 0, tilt: 0, color: 0) }
            }
        }
    }

    /// The main agent's, whatever its profile is called, unless one was picked for it: Redde's own
    /// bubble, the shape of a message in the app with its tucked corner on the left (a reply's
    /// side), in the Code theme's pale sky in every theme (asked 2026-10-20). Its colour
    /// number only keeps the other bots off blue, the colour of the standard theme.
    static let main = BotFace(shape: .bubble, eyes: .round, mouth: .none, mark: .none, glance: 1, tilt: -3, color: 0)

    /// The face a name gives, on its own. The main profile's is always Redde's (`main`).
    init(seed: String) {
        guard seed != "default" else { self = Self.main; return }
        let hash = Self.hash(seed)
        self = Self.all[Int(hash % UInt64(Self.all.count))]
        color = Int((hash >> 20) % UInt64(Self.seededColors))
        glance = Int((hash >> 28) % 4)
        tilt = Double(Int((hash >> 32) % 13) - 6)
    }

    init(shape: Shape, eyes: Eyes, mouth: Mouth, mark: Mark, glance: Int, tilt: Double, color: Int) {
        self.shape = shape
        self.eyes = eyes
        self.mouth = mouth
        self.mark = mark
        self.glance = glance
        self.tilt = tilt
        self.color = color
    }

    /// How a picked face is kept on the server (the profile's `ui_meta.redde.face`): every part by
    /// name, so a part this version doesn't know leaves the face unread rather than wrong.
    var code: String { "1:\(shape.rawValue):\(eyes.rawValue):\(mouth.rawValue):\(mark.rawValue):\(color):\(glance):\(Int(tilt))" }

    init?(code: String) {
        let parts = code.split(separator: ":").map(String.init)
        guard parts.count == 8, parts[0] == "1", let shape = Shape(rawValue: parts[1]),
              let eyes = Eyes(rawValue: parts[2]), let mouth = Mouth(rawValue: parts[3]), let mark = Mark(rawValue: parts[4]),
              let color = Int(parts[5]), let glance = Int(parts[6]), let tilt = Int(parts[7]) else { return nil }
        self.init(shape: shape, eyes: eyes, mouth: mouth, mark: mark, glance: ((glance % 4) + 4) % 4,
                  tilt: Double(max(-8, min(8, tilt))), color: ((color % Self.palette.count) + Self.palette.count) % Self.palette.count)
    }

    /// A face for each name, no two alike: the ones the person picked as they are, then each
    /// other takes the face its name gives unless one before it (in name order) has it, then the
    /// next free one; its shape one of those used least so far, and a colour of its own while
    /// there are colours no one has yet. The main profile's is Redde's, or the one picked for it;
    /// Redde's bubble is never another bot's, picked or not.
    static func faces(for names: [String], picked: [String: BotFace] = [:]) -> [String: BotFace] {
        var taken: [BotFace] = []
        var out: [String: BotFace] = [:]
        let picked = picked.filter { $0.key == "default" || $0.value.shape != .bubble }
        // The main profile first: the others go round its face.
        if names.contains("default") {
            let face = picked["default"] ?? main
            taken.append(face)
            out["default"] = face
        }
        for name in Set(names).subtracting(["default"]).sorted() {
            guard let face = picked[name] else { continue }   // (the main profile's is in already)
            taken.append(face)
            out[name] = face
        }
        for name in Set(names).subtracting(["default"]).subtracting(picked.keys).sorted() {
            let given = BotFace(seed: name)
            let start = all.firstIndex { $0.sameFeatures(as: given) } ?? 0
            // The shapes used least so far are the ones open to it: every shape once before any twice.
            let uses = Dictionary(grouping: taken, by: \.shape).mapValues(\.count)
            let fewest = Shape.seeded.map { uses[$0] ?? 0 }.min() ?? 0
            var face = given
            for step in 0 ..< all.count {
                var candidate = all[(start + step) % all.count]
                (candidate.color, candidate.glance, candidate.tilt) = (given.color, given.glance, given.tilt)
                guard !taken.contains(where: { $0.sameFeatures(as: candidate) }), (uses[candidate.shape] ?? 0) == fewest else { continue }
                face = candidate
                break
            }
            if taken.count < seededColors {
                while taken.contains(where: { $0.color == face.color }) { face.color = (face.color + 1) % seededColors }
            }
            taken.append(face)
            out[name] = face
        }
        return out
    }

    private func sameFeatures(as other: BotFace) -> Bool {
        shape == other.shape && eyes == other.eyes && mouth == other.mouth && mark == other.mark
    }

    /// FNV-1a over the name's bytes: the same on every launch, unlike `hashValue`.
    private static func hash(_ seed: String) -> UInt64 {
        seed.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

/// A moment of a face that moves (Redde's in voice mode): where it looks, how far its eyes are
/// shut, how wide its mouth is open. What is nil stays the face's own.
nonisolated struct BotPose: Equatable, Sendable {
    /// -1…1 each way: right and down are positive.
    var look: CGPoint?
    /// 0 open … 1 shut.
    var blink: CGFloat = 0
    /// 0 … 1: a mouth that talks. Nil keeps the face's own mouth (Redde's has none).
    var mouth: CGFloat?
    var tilt: Double?
}

struct BotAvatar: View {
    var face: BotFace
    var size: CGFloat = 32
    var pose: BotPose? = nil
    /// Redde's bubble takes its colour and corners from the theme, as a message does.
    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { context, canvas in draw(in: &context, size: canvas.width) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// The face as a picture, for what isn't SwiftUI (CarPlay's voice card), in the theme the app
    /// is in.
    static func picture(of face: BotFace, side: CGFloat, pose: BotPose? = nil, scale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: BotAvatar(face: face, size: side, pose: pose).environment(\.theme, Settings.shared.resolvedTheme))
        renderer.scale = scale
        return renderer.uiImage
    }

    /// Where each shape's body is, its eyes and its top, in a 100-point box.
    private struct Layout {
        var body: Path
        var eyeY: CGFloat
        var eyeGap: CGFloat
        var top: CGPoint
    }

    /// The tail's corner: the radius of the one corner drawn sharp.
    private static let tailCorner: CGFloat = 6.5

    private func layout(_ shape: BotFace.Shape) -> Layout {
        func rounded(_ points: [CGPoint], softness: CGFloat = 0.22, sharp: Int = -1, sharpness: CGFloat = 0.05) -> Path {
            // A polygon with soft corners: each corner cut by a curve through it; the tail's, less.
            var path = Path()
            let n = points.count
            for i in 0 ..< n {
                let p = points[i], next = points[(i + 1) % n], prev = points[(i + n - 1) % n]
                let soft = i == sharp ? sharpness : softness
                let a = CGPoint(x: p.x + (prev.x - p.x) * soft, y: p.y + (prev.y - p.y) * soft)
                let b = CGPoint(x: p.x + (next.x - p.x) * soft, y: p.y + (next.y - p.y) * soft)
                if i == 0 { path.move(to: a) } else { path.addLine(to: a) }
                path.addQuadCurve(to: b, control: p)
            }
            path.closeSubpath()
            return path
        }
        func ring(_ count: Int, center c: CGPoint, outer: CGFloat, inner: CGFloat, turn: Double = -90) -> [CGPoint] {
            (0 ..< count * 2).map { i in
                let r = i.isMultiple(of: 2) ? outer : inner
                let a = (turn + Double(i) * 180 / Double(count)) * .pi / 180
                return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            }
        }
        /// The corner nearest the bottom left: the tail.
        func nearestBottomLeft(_ points: [CGPoint], outerOnly: Bool = false) -> Int {
            points.indices.filter { !outerOnly || $0.isMultiple(of: 2) }
                .min { hypot(points[$0].x, 100 - points[$0].y) < hypot(points[$1].x, 100 - points[$1].y) } ?? 0
        }
        /// A rounded box whose bottom left corner is the tail.
        func tucked(_ rect: CGRect, radius: CGFloat) -> Path {
            UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: Self.tailCorner, bottomTrailingRadius: radius,
                                   topTrailingRadius: radius, style: .circular).path(in: rect)
        }
        /// Round above and on the right, and at the bottom left a corner, the tail, where a
        /// quarter of it would be: an oval (`left`…`right`, `top`…`bottom`, widest at `middle`).
        func cornered(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat, middle: CGFloat) -> Path {
            let k: CGFloat = 0.5523, cx = (left + right) / 2, rx = (right - left) / 2, t = Self.tailCorner
            var p = Path()
            p.move(to: CGPoint(x: cx, y: top))
            p.addCurve(to: CGPoint(x: right, y: middle), control1: CGPoint(x: cx + rx * k, y: top), control2: CGPoint(x: right, y: middle - (middle - top) * k))
            p.addCurve(to: CGPoint(x: cx, y: bottom), control1: CGPoint(x: right, y: middle + (bottom - middle) * k), control2: CGPoint(x: cx + rx * k, y: bottom))
            p.addLine(to: CGPoint(x: left + t, y: bottom))
            p.addQuadCurve(to: CGPoint(x: left, y: bottom - t), control: CGPoint(x: left, y: bottom))
            p.addLine(to: CGPoint(x: left, y: middle))
            p.addCurve(to: CGPoint(x: cx, y: top), control1: CGPoint(x: left, y: middle - (middle - top) * k), control2: CGPoint(x: cx - rx * k, y: top))
            p.closeSubpath()
            return p
        }
        switch shape {
        case .round:
            return Layout(body: cornered(left: 17, right: 85, top: 14, bottom: 80, middle: 47), eyeY: 44, eyeGap: 11, top: CGPoint(x: 51, y: 14))
        case .egg:
            // Narrower above than below.
            var p = Path()
            let t = Self.tailCorner
            p.move(to: CGPoint(x: 51, y: 10))
            p.addCurve(to: CGPoint(x: 84, y: 55), control1: CGPoint(x: 70, y: 10), control2: CGPoint(x: 84, y: 33))
            p.addCurve(to: CGPoint(x: 51, y: 86), control1: CGPoint(x: 84, y: 75), control2: CGPoint(x: 70, y: 86))
            p.addLine(to: CGPoint(x: 19 + t, y: 86))
            p.addQuadCurve(to: CGPoint(x: 19, y: 86 - t), control: CGPoint(x: 19, y: 86))
            p.addLine(to: CGPoint(x: 19, y: 55))
            p.addCurve(to: CGPoint(x: 51, y: 10), control1: CGPoint(x: 19, y: 33), control2: CGPoint(x: 32, y: 10))
            p.closeSubpath()
            return Layout(body: p, eyeY: 47, eyeGap: 11, top: CGPoint(x: 51, y: 10))
        case .pill:
            return Layout(body: tucked(CGRect(x: 10, y: 24, width: 82, height: 50), radius: 25), eyeY: 47, eyeGap: 13, top: CGPoint(x: 51, y: 24))
        case .capsule:
            return Layout(body: tucked(CGRect(x: 27, y: 9, width: 50, height: 76), radius: 25), eyeY: 36, eyeGap: 10, top: CGPoint(x: 52, y: 9))
        case .burst:
            // Its bottom-left point a little longer, and sharp.
            var points = ring(11, center: CGPoint(x: 51, y: 47), outer: 38, inner: 31)
            let tip = nearestBottomLeft(points, outerOnly: true)
            points[tip] = CGPoint(x: 51 + (points[tip].x - 51) * 1.14, y: 47 + (points[tip].y - 47) * 1.14)
            return Layout(body: rounded(points, sharp: tip, sharpness: 0.04), eyeY: 45, eyeGap: 11, top: CGPoint(x: 51, y: 10))
        case .pick:
            // A rounded triangle, its point down and to the left: a plectrum.
            return Layout(body: rounded([CGPoint(x: 8, y: 14), CGPoint(x: 94, y: 14), CGPoint(x: 32, y: 93)], softness: 0.36, sharp: 2, sharpness: 0.08),
                          eyeY: 38, eyeGap: 11, top: CGPoint(x: 51, y: 18))
        case .hex:
            let points = ring(3, center: CGPoint(x: 51, y: 47), outer: 39, inner: 39, turn: -90)
            return Layout(body: rounded(points, sharp: nearestBottomLeft(points)), eyeY: 45, eyeGap: 11, top: CGPoint(x: 51, y: 8))
        case .diamond:
            return Layout(body: rounded([CGPoint(x: 51, y: 7), CGPoint(x: 91, y: 47), CGPoint(x: 45, y: 88), CGPoint(x: 11, y: 47)], sharp: 2, sharpness: 0.06),
                          eyeY: 46, eyeGap: 11, top: CGPoint(x: 51, y: 9))
        case .ghost:
            // A dome above, straight sides, and a hem of three scallops whose left end is the tail.
            var p = Path()
            p.move(to: CGPoint(x: 18, y: 50))
            p.addCurve(to: CGPoint(x: 51, y: 11), control1: CGPoint(x: 18, y: 28), control2: CGPoint(x: 32, y: 11))
            p.addCurve(to: CGPoint(x: 84, y: 50), control1: CGPoint(x: 70, y: 11), control2: CGPoint(x: 84, y: 28))
            p.addLine(to: CGPoint(x: 84, y: 82))
            p.addQuadCurve(to: CGPoint(x: 73, y: 82), control: CGPoint(x: 78.5, y: 91))
            p.addQuadCurve(to: CGPoint(x: 62, y: 82), control: CGPoint(x: 67.5, y: 74))
            p.addQuadCurve(to: CGPoint(x: 51, y: 82), control: CGPoint(x: 56.5, y: 91))
            p.addQuadCurve(to: CGPoint(x: 40, y: 82), control: CGPoint(x: 45.5, y: 74))
            p.addQuadCurve(to: CGPoint(x: 29, y: 82), control: CGPoint(x: 34.5, y: 91))
            p.addQuadCurve(to: CGPoint(x: 18, y: 90), control: CGPoint(x: 23, y: 76))
            p.closeSubpath()
            return Layout(body: p, eyeY: 43, eyeGap: 11, top: CGPoint(x: 51, y: 11))
        case .square:
            // A square with gently rounded corners; the bottom left one the tail.
            return Layout(body: tucked(CGRect(x: 14, y: 12, width: 74, height: 74), radius: 13), eyeY: 45, eyeGap: 12, top: CGPoint(x: 51, y: 12))
        case .star:
            // Five soft points; the one at the bottom left a little sharper.
            let points = ring(5, center: CGPoint(x: 51, y: 52), outer: 45, inner: 27)
            return Layout(body: rounded(points, softness: 0.3, sharp: nearestBottomLeft(points, outerOnly: true), sharpness: 0.12),
                          eyeY: 50, eyeGap: 9.5, top: CGPoint(x: 51, y: 9))
        case .blob:
            // Seven lumps of no two sizes, run smooth, and a corner at the bottom left.
            let radii: [CGFloat] = [37, 33, 39, 34, 38, 41, 35]
            let points = radii.indices.map { i -> CGPoint in
                let a = (-90 + Double(i) * 360 / Double(radii.count)) * .pi / 180
                return CGPoint(x: 51 + radii[i] * cos(a), y: 49 + radii[i] * sin(a))
            }
            return Layout(body: rounded(points, softness: 0.5, sharp: nearestBottomLeft(points), sharpness: 0.12),
                          eyeY: 46, eyeGap: 11, top: CGPoint(x: 51, y: 12))
        case .bubble:
            // Nearly square, its corners the theme's, scaled up, the bottom left one tucked in as the
            // bottom right of your own messages is (`userBubbleShape`).
            let scale: CGFloat = 1.45
            let radius = min(theme.bubbleRadius * scale, 29), tucked = min(5, theme.bubbleRadius) * scale
            let bubble = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: tucked,
                                                bottomTrailingRadius: radius, topTrailingRadius: radius)
            return Layout(body: bubble.path(in: CGRect(x: 12, y: 13, width: 78, height: 74)), eyeY: 45, eyeGap: 12,
                          top: CGPoint(x: 51, y: 13))
        }
    }

    /// Redde's colour: the Code theme's bubble (#CBF0FF), whichever theme is on, and whatever
    /// colour was picked for that theme's bubbles.
    private var bubbleColor: Color { Theme.claudeCode.userBubble }

    private func draw(in context: inout GraphicsContext, size s: CGFloat) {
        let colors = face.shape == .bubble ? (light: bubbleColor.mix(with: .white, by: 0.14), deep: bubbleColor)
                                           : BotFace.palette[face.color % BotFace.palette.count]
        let ink = Color(red: 0.09, green: 0.09, blue: 0.13)
        // On a body nearly white (a theme's pale bubble) the white of the eyes gets a rim, or it'd vanish.
        let skin = colors.deep.resolve(in: context.environment)
        let lightness = 0.2126 * skin.linearRed + 0.7152 * skin.linearGreen + 0.0722 * skin.linearBlue
        let pale = lightness > 0.62
        // On a black body the mouth and freckles are drawn light, or they'd vanish.
        let dark = lightness < 0.03
        let features = dark ? Color.white.opacity(0.9) : ink
        let shape = layout(face.shape)
        let u = s / 100
        context.scaleBy(x: u, y: u)
        // An antenna stands above the body: the whole creature a little smaller, so it fits.
        if face.mark == .antenna {
            context.translateBy(x: 50, y: 62)
            context.scaleBy(x: 0.86, y: 0.86)
            context.translateBy(x: -50, y: -62)
        }
        // A slight lean, about the middle.
        context.translateBy(x: 50, y: 50)
        context.rotate(by: .degrees(pose?.tilt ?? face.tilt))
        context.translateBy(x: -50, y: -50)

        let body = shape.body
        let fill = GraphicsContext.Shading.linearGradient(Gradient(colors: [colors.light, colors.deep]),
                                                           startPoint: CGPoint(x: 18, y: 12), endPoint: CGPoint(x: 84, y: 90))

        // A mark that stands up from it goes behind the body's edge.
        if face.mark == .antenna {
            var stalk = Path()
            stalk.move(to: CGPoint(x: shape.top.x + 4, y: shape.top.y + 4))
            stalk.addQuadCurve(to: CGPoint(x: shape.top.x + 9, y: shape.top.y - 9), control: CGPoint(x: shape.top.x + 9, y: shape.top.y - 1))
            context.stroke(stalk, with: .color(colors.deep), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: shape.top.x + 4.5, y: shape.top.y - 15, width: 9, height: 9)), with: .color(colors.deep))
        }
        context.fill(body, with: fill)
        if face.shape != .bubble, face.color == BotFace.white {
            context.stroke(body, with: .color(ink.opacity(0.2)), lineWidth: 1.6)
        }
        if face.mark == .spark {
            // A small four-pointed sparkle by its top right.
            let c = CGPoint(x: 74, y: shape.top.y + 12)
            var star = Path()
            for i in 0 ..< 8 {
                let r: CGFloat = i.isMultiple(of: 2) ? 7.5 : 2.2
                let a = Double(i) * .pi / 4 - .pi / 2
                let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
            }
            star.closeSubpath()
            context.fill(star, with: .color(pale ? ink.opacity(0.4) : .white.opacity(0.92)))
        }

        // A little gloss on its top left.
        var gloss = context
        gloss.clip(to: body)
        gloss.translateBy(x: shape.top.x - 17, y: shape.top.y + 13)
        gloss.rotate(by: .degrees(-28))
        gloss.fill(Path(ellipseIn: CGRect(x: -9, y: -5, width: 18, height: 10)), with: .color(.white.opacity(0.28)))

        // The eyes: white, with pupils looking its way (or where the pose says), open as far as it says.
        let glanced = [CGPoint(x: -1.8, y: 0.6), CGPoint(x: 1.8, y: 0.6), CGPoint(x: -1.4, y: -1.2), CGPoint(x: 1.4, y: -1.2)][face.glance % 4]
        let look = pose?.look.map { CGPoint(x: max(-1, min(1, $0.x)) * 1.9, y: max(-1, min(1, $0.y)) * 1.4) } ?? glanced
        let open = 1 - max(0, min(1, pose?.blink ?? 0)) * 0.9
        let left = CGPoint(x: 51 - shape.eyeGap, y: shape.eyeY), right = CGPoint(x: 51 + shape.eyeGap, y: shape.eyeY)
        func eye(_ c: CGPoint, white r: CGFloat, pupil p: CGFloat, sparkle: Bool = false) {
            let white = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 1.06 * open, width: r * 2, height: r * 2.12 * open))
            context.fill(white, with: .color(.white))
            if pale { context.stroke(white, with: .color(ink.opacity(0.32)), lineWidth: 1.4) }
            var inside = context
            inside.clip(to: white)
            let pc = CGPoint(x: c.x + look.x * r / 7, y: c.y + look.y * r / 7)
            inside.fill(Path(ellipseIn: CGRect(x: pc.x - p, y: pc.y - p, width: p * 2, height: p * 2)), with: .color(ink))
            if sparkle {
                inside.fill(Path(ellipseIn: CGRect(x: pc.x + p * 0.15, y: pc.y - p * 0.75, width: p * 0.7, height: p * 0.7)), with: .color(.white))
            }
        }
        switch face.eyes {
        case .round:
            eye(left, white: 7.4, pupil: 3.8)
            eye(right, white: 7.4, pupil: 3.8)
        case .mismatched:
            eye(left, white: 8.6, pupil: 4.4)
            eye(CGPoint(x: right.x + 1, y: right.y + 1), white: 6, pupil: 3.2)
        case .sleepy:
            for c in [left, right] {
                eye(c, white: 7.2, pupil: 3.6)
                // The lid: the top of the eye in the body's colour, its edge a line.
                var lid = context
                lid.clip(to: Path(ellipseIn: CGRect(x: c.x - 7.4, y: c.y - 7.8, width: 14.8, height: 15.6)))
                lid.fill(Path(CGRect(x: c.x - 8, y: c.y - 9, width: 16, height: 8.4)), with: .color(colors.deep))
                var edge = Path()
                edge.move(to: CGPoint(x: c.x - 7, y: c.y - 0.6))
                edge.addLine(to: CGPoint(x: c.x + 7, y: c.y - 0.6))
                context.stroke(edge, with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
        case .happy:
            for c in [left, right] {
                var arc = Path()
                arc.move(to: CGPoint(x: c.x - 6, y: c.y + 2.5))
                arc.addQuadCurve(to: CGPoint(x: c.x + 6, y: c.y + 2.5), control: CGPoint(x: c.x, y: c.y - 7))
                context.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
            }
        case .sparkle:
            eye(left, white: 7.8, pupil: 4.6, sparkle: true)
            eye(right, white: 7.8, pupil: 4.6, sparkle: true)
        }

        // The mark below the eyes.
        let cheekY = shape.eyeY + 10
        switch face.mark {
        case .freckles:
            for base in [left.x, right.x] {
                for (dx, dy) in [(-3.0, 0.0), (0.5, 2.2), (3.6, -0.4)] {
                    context.fill(Path(ellipseIn: CGRect(x: base + dx - 0.9, y: cheekY + dy - 0.9, width: 1.8, height: 1.8)),
                                 with: .color(dark ? .white.opacity(0.55) : colors.deep.opacity(0.9)))
                }
            }
        case .blush:
            for base in [left.x - 3, right.x + 3] {
                context.fill(Path(ellipseIn: CGRect(x: base - 5, y: cheekY - 2.4, width: 10, height: 4.8)), with: .color(Color(red: 1, green: 0.45, blue: 0.55).opacity(0.45)))
            }
        default:
            break
        }

        // The mouth: one that talks, when the pose has one; else the face's own, on some.
        let mouthY = shape.eyeY + (face.mark == .freckles || face.mark == .blush ? 15 : 13)
        if let talking = pose?.mouth {
            let open = max(0, min(1, talking))
            if open > 0.03 {
                let w = 7 + open * 3, h = 1.6 + open * 8
                context.fill(Path(roundedRect: CGRect(x: 51 - w / 2, y: mouthY - 1, width: w, height: h), cornerRadius: min(w, h) / 2), with: .color(features))
            }
            return
        }
        switch face.mouth {
        case .none:
            break
        case .smile:
            var smile = Path()
            smile.move(to: CGPoint(x: 51 - 5, y: mouthY))
            smile.addQuadCurve(to: CGPoint(x: 51 + 5, y: mouthY), control: CGPoint(x: 51, y: mouthY + 5))
            context.stroke(smile, with: .color(features), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        case .oh:
            context.fill(Path(ellipseIn: CGRect(x: 51 - 2.6, y: mouthY - 1.5, width: 5.2, height: 6)), with: .color(features))
        case .grin:
            var grin = Path()
            grin.move(to: CGPoint(x: 51 - 6, y: mouthY - 1))
            grin.addQuadCurve(to: CGPoint(x: 51, y: mouthY), control: CGPoint(x: 51 - 3, y: mouthY + 4))
            grin.addQuadCurve(to: CGPoint(x: 51 + 6, y: mouthY - 1), control: CGPoint(x: 51 + 3, y: mouthY + 4))
            context.stroke(grin, with: .color(features), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }
    }
}

#if DEBUG
/// Every creature a roster of names gives, large and small, on dark and light (`-echo.screen botGallery`).
struct BotGallery: View {
    private static let names = ["default", "scout", "writer", "fixit", "atlas", "echo", "sage", "ember", "nimbus", "pip", "rook", "juniper"]
    private let faces = BotFace.faces(for: names)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 18) {
                ForEach(Self.names, id: \.self) { name in
                    VStack(spacing: 6) {
                        BotAvatar(face: faces[name] ?? BotFace(seed: name), size: 96)
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            // The shapes only picked, never given by a name.
            HStack(spacing: 14) {
                ForEach(Array([BotFace.Shape.ghost, .square, .star, .blob].enumerated()), id: \.offset) { i, shape in
                    BotAvatar(face: BotFace(shape: shape, eyes: [.round, .happy, .sparkle, .mismatched][i], mouth: [.smile, .none, .grin, .oh][i],
                                            mark: [.none, .blush, .spark, .freckles][i], glance: i, tilt: Double(i * 2 - 3), color: [8, 4, 1, 5][i]), size: 72)
                }
            }
            .padding(.vertical, 8)
            // The colours only picked, white and black, on white and on black.
            HStack(spacing: 14) {
                ForEach(Array([(BotFace.Shape.round, BotFace.Mark.spark, BotFace.Mouth.smile), (.egg, .freckles, .grin)].enumerated()), id: \.offset) { i, part in
                    ForEach([BotFace.white, BotFace.white + 1], id: \.self) { color in
                        BotAvatar(face: BotFace(shape: part.0, eyes: .round, mouth: part.2, mark: part.1, glance: i, tilt: 0, color: color), size: 56)
                            .padding(6)
                            .background(i == 0 ? Color.white : Color.black, in: .rect(cornerRadius: 10))
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(Self.names, id: \.self) { BotAvatar(face: faces[$0] ?? BotFace(seed: $0), size: 26) }
            }
            .padding(10)
            .background(Color.white, in: .rect(cornerRadius: 12))
            // Redde in every theme, on that theme's page.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                ForEach(Theme.allCases) { theme in
                    let resolved = theme.resolved(with: nil)
                    VStack(spacing: 4) {
                        BotAvatar(face: .main, size: 56)
                        Text(theme.rawValue).font(.caption2).foregroundStyle(resolved.textColor).lineLimit(1)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(resolved.pageColor, in: .rect(cornerRadius: 12))
                    .environment(\.theme, resolved)
                }
            }
            .padding()
        }
        .background(Color(white: 0.08))
    }
}
#endif

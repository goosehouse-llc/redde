import SwiftUI

/// A bot's picture: a little creature, a speech bubble at heart (each has a bubble's tail), in a
/// colour of its own, with white eyes glancing somewhere, and on some a small mouth or a mark of its
/// own. Shape, eyes, mouth, mark and colour come from the bot's profile name, so a bot keeps its
/// creature when it is renamed in Hermes Desktop, and `BotFace.faces(for:)` gives every bot on a
/// server one no other has there (a shape and a colour of its own too, while there are some left).
nonisolated struct BotFace: Equatable, Hashable, Sendable {
    enum Shape: CaseIterable, Sendable { case round, squircle, pill, capsule, burst, pick, hex, diamond }
    enum Eyes: CaseIterable, Sendable { case round, mismatched, sleepy, happy, sparkle }
    enum Mouth: CaseIterable, Sendable { case none, smile, oh, grin }
    enum Mark: CaseIterable, Sendable { case none, antenna, spark, freckles, blush }

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
    ]

    /// Every face there is (colour, glance and lean aside), in a fixed order.
    private static let all: [BotFace] = Shape.allCases.flatMap { shape in
        Eyes.allCases.flatMap { eyes in
            Mouth.allCases.flatMap { mouth in
                Mark.allCases.map { BotFace(shape: shape, eyes: eyes, mouth: mouth, mark: $0, glance: 0, tilt: 0, color: 0) }
            }
        }
    }

    /// The main agent's: Redde's own blue speech bubble, whatever its profile is called.
    static let main = BotFace(shape: .round, eyes: .round, mouth: .none, mark: .none, glance: 1, tilt: -4, color: 0)

    /// The face a name gives, on its own. The main profile's is always Redde's (`main`).
    init(seed: String) {
        guard seed != "default" else { self = Self.main; return }
        let hash = Self.hash(seed)
        self = Self.all[Int(hash % UInt64(Self.all.count))]
        color = Int((hash >> 20) % UInt64(Self.palette.count))
        glance = Int((hash >> 28) % 4)
        tilt = Double(Int((hash >> 32) % 13) - 6)
    }

    private init(shape: Shape, eyes: Eyes, mouth: Mouth, mark: Mark, glance: Int, tilt: Double, color: Int) {
        self.shape = shape
        self.eyes = eyes
        self.mouth = mouth
        self.mark = mark
        self.glance = glance
        self.tilt = tilt
        self.color = color
    }

    /// A face for each name, no two alike: each takes the face its name gives unless one before it
    /// (in name order) has it, then the next free one; its shape one of those used least so far, and
    /// a colour of its own while there are colours no one has yet.
    static func faces(for names: [String]) -> [String: BotFace] {
        var taken: [BotFace] = []
        var out: [String: BotFace] = [:]
        // The main profile first: Redde's bubble is its own, and the others go round it.
        if names.contains("default") {
            taken.append(main)
            out["default"] = main
        }
        for name in Set(names).subtracting(["default"]).sorted() {
            let given = BotFace(seed: name)
            let start = all.firstIndex { $0.sameFeatures(as: given) } ?? 0
            // The shapes used least so far are the ones open to it: every shape once before any twice.
            let uses = Dictionary(grouping: taken, by: \.shape).mapValues(\.count)
            let fewest = Shape.allCases.map { uses[$0] ?? 0 }.min() ?? 0
            var face = given
            for step in 0 ..< all.count {
                var candidate = all[(start + step) % all.count]
                (candidate.color, candidate.glance, candidate.tilt) = (given.color, given.glance, given.tilt)
                guard !taken.contains(where: { $0.sameFeatures(as: candidate) }), (uses[candidate.shape] ?? 0) == fewest else { continue }
                face = candidate
                break
            }
            if taken.count < palette.count {
                while taken.contains(where: { $0.color == face.color }) { face.color = (face.color + 1) % palette.count }
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

struct BotAvatar: View {
    var face: BotFace
    var size: CGFloat = 32

    var body: some View {
        Canvas { context, canvas in draw(in: &context, size: canvas.width) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// Where each shape's body is, its eyes, and where its tail leaves it, in a 100-point box.
    private struct Layout {
        var body: Path
        var eyeY: CGFloat
        var eyeGap: CGFloat
        var tail: CGPoint
        var top: CGPoint
    }

    private func layout(_ shape: BotFace.Shape) -> Layout {
        func rounded(_ points: [CGPoint], softness: CGFloat = 0.22) -> Path {
            // A polygon with soft corners: each corner cut by a curve through it.
            var path = Path()
            let n = points.count
            for i in 0 ..< n {
                let p = points[i], next = points[(i + 1) % n], prev = points[(i + n - 1) % n]
                let a = CGPoint(x: p.x + (prev.x - p.x) * softness, y: p.y + (prev.y - p.y) * softness)
                let b = CGPoint(x: p.x + (next.x - p.x) * softness, y: p.y + (next.y - p.y) * softness)
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
        switch shape {
        case .round:
            return Layout(body: Path(ellipseIn: CGRect(x: 17, y: 14, width: 68, height: 66)), eyeY: 44, eyeGap: 11, tail: CGPoint(x: 30, y: 72), top: CGPoint(x: 51, y: 14))
        case .squircle:
            return Layout(body: Path(roundedRect: CGRect(x: 17, y: 16, width: 68, height: 62), cornerRadius: 23), eyeY: 44, eyeGap: 11, tail: CGPoint(x: 29, y: 72), top: CGPoint(x: 51, y: 16))
        case .pill:
            return Layout(body: Path(roundedRect: CGRect(x: 10, y: 24, width: 82, height: 50), cornerRadius: 25), eyeY: 47, eyeGap: 13, tail: CGPoint(x: 26, y: 70), top: CGPoint(x: 51, y: 24))
        case .capsule:
            return Layout(body: Path(roundedRect: CGRect(x: 27, y: 9, width: 50, height: 76), cornerRadius: 25), eyeY: 36, eyeGap: 10, tail: CGPoint(x: 34, y: 80), top: CGPoint(x: 52, y: 9))
        case .burst:
            return Layout(body: rounded(ring(11, center: CGPoint(x: 51, y: 47), outer: 38, inner: 31)), eyeY: 45, eyeGap: 11, tail: CGPoint(x: 31, y: 72), top: CGPoint(x: 51, y: 10))
        case .pick:
            // A rounded triangle, its point down: a plectrum.
            return Layout(body: rounded([CGPoint(x: 8, y: 14), CGPoint(x: 94, y: 14), CGPoint(x: 51, y: 94)], softness: 0.36),
                          eyeY: 38, eyeGap: 11, tail: CGPoint(x: 35, y: 62), top: CGPoint(x: 51, y: 18))
        case .hex:
            return Layout(body: rounded(ring(3, center: CGPoint(x: 51, y: 47), outer: 39, inner: 39, turn: -90)), eyeY: 45, eyeGap: 11, tail: CGPoint(x: 29, y: 70), top: CGPoint(x: 51, y: 8))
        case .diamond:
            return Layout(body: rounded([CGPoint(x: 51, y: 7), CGPoint(x: 91, y: 47), CGPoint(x: 51, y: 87), CGPoint(x: 11, y: 47)]),
                          eyeY: 46, eyeGap: 11, tail: CGPoint(x: 36, y: 72), top: CGPoint(x: 51, y: 9))
        }
    }

    private func draw(in context: inout GraphicsContext, size s: CGFloat) {
        let colors = BotFace.palette[face.color % BotFace.palette.count]
        let ink = Color(red: 0.09, green: 0.09, blue: 0.13)
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
        context.rotate(by: .degrees(face.tilt))
        context.translateBy(x: -50, y: -50)

        // The body and its tail: a speech bubble. Filled one after the other: as one path, where they
        // overlap the winding cancels and leaves a hole.
        let body = shape.body
        let t = shape.tail
        var tail = Path()
        tail.move(to: CGPoint(x: t.x - 3, y: t.y - 6))
        tail.addQuadCurve(to: CGPoint(x: t.x - 13, y: t.y + 16), control: CGPoint(x: t.x - 4, y: t.y + 9))
        tail.addQuadCurve(to: CGPoint(x: t.x + 12, y: t.y + 1), control: CGPoint(x: t.x + 3, y: t.y + 13))
        tail.closeSubpath()
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
        context.fill(tail, with: fill)
        context.fill(body, with: fill)
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
            context.fill(star, with: .color(.white.opacity(0.92)))
        }

        // A little gloss on its top left.
        var gloss = context
        gloss.clip(to: body)
        gloss.translateBy(x: shape.top.x - 17, y: shape.top.y + 13)
        gloss.rotate(by: .degrees(-28))
        gloss.fill(Path(ellipseIn: CGRect(x: -9, y: -5, width: 18, height: 10)), with: .color(.white.opacity(0.28)))

        // The eyes: white, with pupils looking its way.
        let look = [CGPoint(x: -1.8, y: 0.6), CGPoint(x: 1.8, y: 0.6), CGPoint(x: -1.4, y: -1.2), CGPoint(x: 1.4, y: -1.2)][face.glance % 4]
        let left = CGPoint(x: 51 - shape.eyeGap, y: shape.eyeY), right = CGPoint(x: 51 + shape.eyeGap, y: shape.eyeY)
        func eye(_ c: CGPoint, white r: CGFloat, pupil p: CGFloat, sparkle: Bool = false) {
            context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 1.06, width: r * 2, height: r * 2.12)), with: .color(.white))
            let pc = CGPoint(x: c.x + look.x * r / 7, y: c.y + look.y * r / 7)
            context.fill(Path(ellipseIn: CGRect(x: pc.x - p, y: pc.y - p, width: p * 2, height: p * 2)), with: .color(ink))
            if sparkle {
                context.fill(Path(ellipseIn: CGRect(x: pc.x + p * 0.15, y: pc.y - p * 0.75, width: p * 0.7, height: p * 0.7)), with: .color(.white))
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
                    context.fill(Path(ellipseIn: CGRect(x: base + dx - 0.9, y: cheekY + dy - 0.9, width: 1.8, height: 1.8)), with: .color(colors.deep.opacity(0.9)))
                }
            }
        case .blush:
            for base in [left.x - 3, right.x + 3] {
                context.fill(Path(ellipseIn: CGRect(x: base - 5, y: cheekY - 2.4, width: 10, height: 4.8)), with: .color(Color(red: 1, green: 0.45, blue: 0.55).opacity(0.45)))
            }
        default:
            break
        }

        // The mouth, on some.
        let mouthY = shape.eyeY + (face.mark == .freckles || face.mark == .blush ? 15 : 13)
        switch face.mouth {
        case .none:
            break
        case .smile:
            var smile = Path()
            smile.move(to: CGPoint(x: 51 - 5, y: mouthY))
            smile.addQuadCurve(to: CGPoint(x: 51 + 5, y: mouthY), control: CGPoint(x: 51, y: mouthY + 5))
            context.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        case .oh:
            context.fill(Path(ellipseIn: CGRect(x: 51 - 2.6, y: mouthY - 1.5, width: 5.2, height: 6)), with: .color(ink))
        case .grin:
            var grin = Path()
            grin.move(to: CGPoint(x: 51 - 6, y: mouthY - 1))
            grin.addQuadCurve(to: CGPoint(x: 51, y: mouthY), control: CGPoint(x: 51 - 3, y: mouthY + 4))
            grin.addQuadCurve(to: CGPoint(x: 51 + 6, y: mouthY - 1), control: CGPoint(x: 51 + 3, y: mouthY + 4))
            context.stroke(grin, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
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
            HStack(spacing: 10) {
                ForEach(Self.names, id: \.self) { BotAvatar(face: faces[$0] ?? BotFace(seed: $0), size: 26) }
            }
            .padding(10)
            .background(Color.white, in: .rect(cornerRadius: 12))
        }
        .background(Color(white: 0.08))
    }
}
#endif

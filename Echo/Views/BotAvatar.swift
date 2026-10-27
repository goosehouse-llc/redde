import SwiftUI

struct BotAvatar: View {
    var face: BotFace
    /// Whose it is, as the bot is shown: with Settings → Appearance → Bot faces off, it is drawn
    /// as its initial on a circle of its colour instead. Without one, the face is always drawn
    /// (where a face is picked, and voice mode's, which shows the orb instead).
    var name: String? = nil
    var size: CGFloat = 32
    var pose: BotPose? = nil
    /// Redde's bubble takes its colour and corners from the theme, as a message does.
    @Environment(\.theme) private var theme

    var body: some View {
        if let picture = shownPicture {
            // Its picture from Hermes Desktop: a rounded square, as an app's icon is, a little inside
            // the face's square so it stands as large as a creature beside it.
            Image(uiImage: picture)
                .resizable()
                .scaledToFill()
                .frame(width: size * 0.9, height: size * 0.9)
                .clipShape(.rect(cornerRadius: size * 0.24, style: .continuous))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            let initial = name.flatMap { Settings.shared.botFaces ? nil : Self.initial(of: $0) }
            Canvas { context, canvas in
                if let initial { monogram(initial, in: &context, size: canvas.width) } else { draw(in: &context, size: canvas.width) }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task(id: face.picture) {
                if let profile = face.picture, Settings.shared.botPictures { await BotPictures.shared.load(profile) }
            }
        }
    }

    /// The bot's picture from Hermes Desktop, once fetched, with Pictures from Hermes on.
    private var shownPicture: UIImage? {
        guard let profile = face.picture, Settings.shared.botPictures else { return nil }
        return BotPictures.shared.image(for: profile)
    }

    /// The face as a picture, for what isn't SwiftUI (CarPlay's voice card), in the theme the app
    /// is in.
    static func picture(of face: BotFace, named name: String? = nil, side: CGFloat, pose: BotPose? = nil, scale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: BotAvatar(face: face, name: name, size: side, pose: pose).environment(\.theme, Settings.shared.resolvedTheme))
        renderer.scale = scale
        return renderer.uiImage
    }

    /// What stands for a name with Bot faces off: its first letter or digit as a capital
    /// ("@scout" is S), or its first character if it has neither (an emoji); none for no name.
    static func initial(of name: String) -> String {
        let first = name.first { $0.isLetter || $0.isNumber } ?? name.first { !$0.isWhitespace && !$0.isPunctuation }
        return first.map { String($0).uppercased() } ?? ""
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
        case .house:
            // The square's walls under a big pointed roof: a sharp peak, rounder eaves, the bottom
            // left corner the tail. Its top stands about where the square's does, the roof at 37°
            // (asked 2026-10-24: less steep than the 46° and 41° first tried).
            var p = Path()
            let peak = CGPoint(x: 51, y: 12), left = CGPoint(x: 14, y: 40), right = CGPoint(x: 88, y: 40)
            p.move(to: CGPoint(x: 51, y: 88))
            p.addArc(tangent1End: CGPoint(x: 14, y: 88), tangent2End: left, radius: Self.tailCorner)
            p.addArc(tangent1End: left, tangent2End: peak, radius: 14)
            p.addArc(tangent1End: peak, tangent2End: right, radius: 9)
            p.addArc(tangent1End: right, tangent2End: CGPoint(x: 88, y: 88), radius: 14)
            p.addArc(tangent1End: CGPoint(x: 88, y: 88), tangent2End: CGPoint(x: 14, y: 88), radius: 13)
            p.closeSubpath()
            return Layout(body: p, eyeY: 53, eyeGap: 12, top: CGPoint(x: 51, y: 15))
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

    /// The face's colour as a gradient, light to deep. Redde's own two: the colour of a message
    /// bubble in this theme (the prompt line's in a theme without bubbles), or the Code theme's.
    private var colors: (light: Color, deep: Color) { Self.colors(of: face, theme: theme) }

    /// A face's colour as a gradient, light to deep, in a theme: for what draws beside a face in
    /// its colour (CarPlay's bot cards).
    static func colors(of face: BotFace, theme: ResolvedTheme) -> (light: Color, deep: Color) {
        let own: Color
        switch face.color {
        case BotFace.themed: own = theme.promptPrefix != nil ? theme.promptColor : theme.userBubble
        case BotFace.codeBlue: own = Theme.claudeCode.userBubble
        default: return BotFace.pair(face.color)
        }
        return (own.mix(with: .white, by: 0.14), own)
    }

    /// With Bot faces off: a circle in the face's colour, the initial on it in white, or in ink
    /// on a light colour (amber, lime, white, a pale theme's bubble), the white one outlined.
    private func monogram(_ initial: String, in context: inout GraphicsContext, size s: CGFloat) {
        let deep = colors.deep
        let ink = Color(red: 0.09, green: 0.09, blue: 0.13)
        let skin = deep.resolve(in: context.environment)
        let lightness = 0.2126 * skin.linearRed + 0.7152 * skin.linearGreen + 0.0722 * skin.linearBlue
        let disc = Path(ellipseIn: CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.04, dy: s * 0.04))
        context.fill(disc, with: .linearGradient(Gradient(colors: [deep.mix(with: .white, by: 0.18), deep]),
                                                 startPoint: CGPoint(x: s * 0.2, y: 0), endPoint: CGPoint(x: s * 0.8, y: s)))
        if lightness > 0.62 { context.stroke(disc, with: .color(ink.opacity(0.2)), lineWidth: max(1, s / 60)) }
        guard !initial.isEmpty else { return }
        context.draw(Text(initial).font(.system(size: s * 0.46, weight: .semibold, design: .rounded))
                        .foregroundStyle(lightness > 0.45 ? ink : .white),
                     at: CGPoint(x: s / 2, y: s / 2))
    }

    private func draw(in context: inout GraphicsContext, size s: CGFloat) {
        let colors = colors
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
            // White with a thin dark edge, so it shows on any body and any ground: where it stands
            // past the body's edge it was drawn dark on a pale body (and vanished on a dark ground)
            // and white on the others (and vanished on a light one).
            context.fill(star, with: .color(.white.opacity(0.95)))
            context.stroke(star, with: .color(ink.opacity(pale ? 0.45 : 0.3)), style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
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
            // The house beside the square it is drawn from, then with each mark, as large as a
            // creature in the picker and as small as one in the list: its peak takes the antenna,
            // the spark stands by its roof.
            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    ForEach([BotFace.Shape.square, .house], id: \.self) { shape in
                        BotAvatar(face: BotFace(shape: shape, eyes: .round, mouth: .smile, mark: .none, glance: 1, tilt: 0, color: 9), size: 96)
                    }
                }
                ForEach([56, 26] as [CGFloat], id: \.self) { size in
                    HStack(spacing: 10) {
                        ForEach(Array(BotFace.Mark.allCases.enumerated()), id: \.offset) { i, mark in
                            BotAvatar(face: BotFace(shape: .house, eyes: BotFace.Eyes.allCases[i], mouth: BotFace.Mouth.allCases[(i + 1) % 4], mark: mark,
                                                    glance: i % 4, tilt: Double(i * 2 - 4), color: [6, 2, 0, 16, 12][i]), size: size)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.white, in: .rect(cornerRadius: 12))
            // The later colours with a spark, on black and on white: a spark past a pale body's
            // edge was drawn dark, and vanished on a dark ground.
            ForEach([Color.black, Color.white], id: \.self) { ground in
                HStack(spacing: 10) {
                    ForEach(Array([BotFace.Shape.round, .square, .star, .blob].enumerated()), id: \.offset) { i, shape in
                        BotAvatar(face: BotFace(shape: shape, eyes: .round, mouth: .smile, mark: .spark, glance: i, tilt: 0,
                                                color: [BotFace.yellow, BotFace.gold, BotFace.softPink, BotFace.gold][i]), size: 56)
                    }
                }
                .padding(8)
                .background(ground, in: .rect(cornerRadius: 10))
            }
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
                ForEach(Array([BotFace.Shape.ghost, .square, .house, .star, .blob].enumerated()), id: \.offset) { i, shape in
                    BotAvatar(face: BotFace(shape: shape, eyes: [.round, .happy, .round, .sparkle, .mismatched][i], mouth: [.smile, .none, .smile, .grin, .oh][i],
                                            mark: [.none, .blush, .antenna, .spark, .freckles][i], glance: i, tilt: Double(i * 2 - 4), color: [8, 4, 9, 1, 5][i]), size: 60)
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
            // The same by name, as initials with Bot faces off (`-botFaces NO`), on white and black.
            ForEach([Color.white, .black], id: \.self) { page in
                HStack(spacing: 6) {
                    ForEach(Self.names, id: \.self) { BotAvatar(face: faces[$0] ?? BotFace(seed: $0), name: $0, size: 26) }
                }
                .padding(10)
                .background(page, in: .rect(cornerRadius: 12))
            }
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

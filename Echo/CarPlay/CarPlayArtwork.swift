import CarPlay
import UIKit

/// Redde's CarPlay artwork, drawn in the app's current look instead of generic SF Symbols:
/// graphite tiles and discs, light waveform bars in the spark's profile (centre tallest, each bar
/// outward lower, like voice mode's Waveform orb) and the gold spark. CarPlay owns layout, type and
/// backgrounds, so these images are where the brand shows. Everything is drawn in code at a
/// generous scale so it stays sharp on any car display, and every image carries its own graphite
/// ground so it reads the same on CarPlay's light and dark appearances.
enum CarPlayArtwork {
    static let graphiteTop = UIColor(red: 0.231, green: 0.267, blue: 0.325, alpha: 1)      // #3B4453
    static let graphiteBottom = UIColor(red: 0.078, green: 0.102, blue: 0.149, alpha: 1)   // #141A26
    static let mist = UIColor(red: 0.863, green: 0.890, blue: 0.933, alpha: 1)             // #DCE3EE
    static let gold = UIColor(red: 0xE8 / 255.0, green: 0xB0 / 255.0, blue: 0x4B / 255.0, alpha: 1)

    enum Row { case ask, talk }
    enum VoiceState: String, CaseIterable { case listening, thinking, speaking, idle, error, phone }

    /// Bar heights in the spark's profile, as fractions of the tallest (voice mode's weights).
    private static let sparkProfile: [CGFloat] = [0.13, 0.27, 0.51, 1.0, 0.51, 0.27, 0.13]

    /// A list row's leading image: a small graphite tile like the app icon.
    static func rowIcon(_ row: Row, size: CGSize = CPListItem.maximumImageSize) -> UIImage {
        let side = min(size.width, size.height)
        return render(CGSize(width: side, height: side)) { ctx, rect in
            tile(ctx, rect, radius: side * 0.24)
            let u = side / 100   // draw in a 100-unit square
            switch row {
            case .ask:
                // One voice, waiting to be heard.
                bars(ctx, centreX: 50 * u, centreY: 50 * u, heights: profile(tallest: 60, rest: 10, count: 5).map { $0 * u },
                     gap: 12 * u, width: 7 * u, colour: mist)
            case .talk:
                // A conversation: your voice running into the spark that answers.
                bars(ctx, centreX: 34 * u, centreY: 50 * u, heights: [18, 32, 48, 28].map { $0 * u }, gap: 10 * u, width: 6.5 * u, colour: mist)
                spark(ctx, centre: CGPoint(x: 72 * u, y: 50 * u), radius: 17 * u, colour: gold)
            }
        }
    }

    /// The voice card's large image for each state: a graphite disc with light or gold marks.
    static func voiceStateImage(_ state: VoiceState, side: CGFloat = 160) -> UIImage {
        render(CGSize(width: side, height: side)) { ctx, rect in
            disc(ctx, rect)
            let u = side / 100
            switch state {
            case .listening:
                // Your voice: light bars in the spark's profile.
                bars(ctx, centreX: 50 * u, centreY: 50 * u, heights: profile(tallest: 52, rest: 8, count: 7).map { $0 * u },
                     gap: 8.5 * u, width: 5.5 * u, colour: mist)
            case .thinking:
                spark(ctx, centre: CGPoint(x: 50 * u, y: 50 * u), radius: 22 * u, colour: gold)
            case .speaking:
                // Redde's voice: the same bars in gold.
                bars(ctx, centreX: 50 * u, centreY: 50 * u, heights: profile(tallest: 52, rest: 8, count: 7).map { $0 * u },
                     gap: 8.5 * u, width: 5.5 * u, colour: gold)
            case .idle:
                ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(8 * u); mist.setStroke()
                ctx.move(to: CGPoint(x: 34 * u, y: 51 * u)); ctx.addLine(to: CGPoint(x: 45 * u, y: 62 * u)); ctx.addLine(to: CGPoint(x: 67 * u, y: 39 * u))
                ctx.strokePath()
            case .error:
                ctx.setLineCap(.round); ctx.setLineWidth(8 * u); gold.setStroke()
                ctx.move(to: CGPoint(x: 50 * u, y: 32 * u)); ctx.addLine(to: CGPoint(x: 50 * u, y: 56 * u)); ctx.strokePath()
                mist.setFill(); ctx.fillEllipse(in: CGRect(x: 45 * u, y: 64 * u, width: 10 * u, height: 10 * u))
            case .phone:
                // The agent is waiting for an approval that only the phone can give: a phone outline.
                ctx.setLineJoin(.round); ctx.setLineWidth(6 * u); mist.setStroke()
                UIBezierPath(roundedRect: CGRect(x: 36 * u, y: 26 * u, width: 28 * u, height: 48 * u), cornerRadius: 6 * u).stroke()
                mist.setFill(); ctx.fillEllipse(in: CGRect(x: 47.5 * u, y: 64 * u, width: 5 * u, height: 5 * u))
            }
        }
    }

    /// `count` bar heights (5 or 7) from the spark profile, each at least `rest` units tall.
    private static func profile(tallest: CGFloat, rest: CGFloat, count: Int) -> [CGFloat] {
        let weights = count == 5 ? Array(sparkProfile[1...5]) : sparkProfile
        return weights.map { rest + (tallest - rest) * $0 }
    }

    // MARK: - Drawing

    private static func render(_ size: CGSize, _ draw: (CGContext, CGRect) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(context.cgContext, CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)   // keep the brand colours; don't let CarPlay tint them
    }

    private static func tile(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat) {
        ctx.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
        gradient(ctx, rect)
        ctx.restoreGState()
    }

    private static func disc(_ ctx: CGContext, _ rect: CGRect) {
        ctx.saveGState()
        UIBezierPath(ovalIn: rect).addClip()
        gradient(ctx, rect)
        ctx.restoreGState()
    }

    private static func gradient(_ ctx: CGContext, _ rect: CGRect) {
        let colours = [graphiteTop.cgColor, graphiteBottom.cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
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

    /// The app icon's four-point spark: quadratic arms pulled in to the centre.
    private static func spark(_ ctx: CGContext, centre c: CGPoint, radius r: CGFloat, colour: UIColor) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), controlPoint: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), controlPoint: c)
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), controlPoint: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), controlPoint: c)
        path.close()
        ctx.saveGState(); colour.setFill(); path.fill(); ctx.restoreGState()
    }
}

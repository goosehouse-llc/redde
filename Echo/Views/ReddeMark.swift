import SwiftUI

/// The four-point spark from the app icon, on the Thinking tag.
struct SparkShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: rect.maxY), control: c)
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: rect.minY), control: c)
        p.closeSubpath()
        return p
    }
}

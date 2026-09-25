import Cocoa
// Redde "Return" icon: return arrow whose tail is a waveform. Full-bleed 1024×1024 (iOS masks it).
let size = 1024.0, s = size / 100.0
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: srgb, components: [r, g, b, a])! }
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: s, y: -s)   // 100-unit space, y down
// background gradient: slate blue-grey, lighter top-left → deep at bottom-right
// The chosen swatch: #29497F. Kept nearly flat: +6% at the top-left, -8% at the bottom-right.
let colors = [c(0.175, 0.305, 0.525, 1), c(0.148, 0.268, 0.470, 1)] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100), options: [])
// soft highlight for depth
ctx.saveGState()
let hl = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    colors: [c(1, 1, 1, 0.03), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(hl, startCenter: CGPoint(x: 30, y: 20), startRadius: 0, endCenter: CGPoint(x: 30, y: 20), endRadius: 80, options: [])
ctx.restoreGState()
// glyph, recentred: composition centre ≈ (50, 52)
let dx = -6.0, dy = -4.0
func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
ctx.setStrokeColor(c(1, 1, 1, 1))
ctx.setLineCap(.round); ctx.setLineJoin(.round)
// arrow head
ctx.setLineWidth(9.5)
ctx.move(to: P(62, 30)); ctx.addLine(to: P(74, 42)); ctx.addLine(to: P(62, 54)); ctx.strokePath()
// shaft curving back down
ctx.move(to: P(74, 42)); ctx.addLine(to: P(48, 42))
ctx.addCurve(to: P(28, 60), control1: P(36, 42), control2: P(28, 50))
ctx.addCurve(to: P(42, 74), control1: P(28, 68), control2: P(34, 74))
ctx.strokePath()
// waveform tail
ctx.setLineWidth(7.2)
for (x, y0, y1) in [(50.0, 66.0, 82.0), (60.0, 70.0, 78.0), (70.0, 63.0, 85.0), (80.0, 69.0, 79.0)] {
    ctx.move(to: P(x, y0)); ctx.addLine(to: P(x, y1)); ctx.strokePath()
}
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote", CommandLine.arguments[1])

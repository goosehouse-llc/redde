import Cocoa
// Redde app icon ("Orbit"): ring from 12:00 clockwise to 10:15; right triangle on the ring's inner
// edge at 9:30 pointing at the centre dot. Usage: swift redde-orbit.swift out.png [back angle offset ringEnd]
// Chosen values: 16 195 4 217.5
let size = 1024.0, s = size / 100.0
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: srgb, components: [r, g, b, a])! }
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!   // opaque: App Store rejects icons with alpha
ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: s, y: -s)
let grad = CGGradient(colorsSpace: srgb, colors: [c(0.175, 0.305, 0.525), c(0.148, 0.268, 0.470)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100), options: [])
ctx.setStrokeColor(c(1, 1, 1)); ctx.setFillColor(c(1, 1, 1))
ctx.setLineCap(.round)
let center = CGPoint(x: 50, y: 50), r = 30.0, w = 8.0
// ring: 12:00 (-90°) clockwise to 10:00 (210°) — increasing angle is clockwise in this y-down space
ctx.setLineWidth(w)
let ringEnd = CommandLine.arguments.count > 5 ? Double(CommandLine.arguments[5])! : 217.5   // 10:15
ctx.addArc(center: center, radius: r, startAngle: -90 * .pi / 180, endAngle: ringEnd * .pi / 180, clockwise: false)
ctx.strokePath()
// right triangle on the ring at a clock position, pointing at the centre. Args: back length,
// clock angle in degrees (9:00 = 180, 9:30 = 195), and the back's offset from the ring's
// centreline (0 = on the stroke's centre, +4 = inner edge, -4 = outer edge).
let back = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 16
let angle = (CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 195) * .pi / 180
let offset = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4])! : 4
let h = back / 2
let inward = angle + .pi                                   // from the ring toward the centre
func along(_ p: CGPoint, _ a: Double, _ d: Double) -> CGPoint { CGPoint(x: p.x + d * cos(a), y: p.y + d * sin(a)) }
let onRing = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
let backMid = along(onRing, inward, offset)
ctx.move(to: along(backMid, inward + .pi / 2, back / 2))
ctx.addLine(to: along(backMid, inward, h))                 // apex: right angle, aimed at the centre
ctx.addLine(to: along(backMid, inward - .pi / 2, back / 2))
ctx.closePath(); ctx.fillPath()
// centre dot
ctx.addEllipse(in: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)); ctx.fillPath()
let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

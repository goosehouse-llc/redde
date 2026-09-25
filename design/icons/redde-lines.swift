import Cocoa
// Redde app icon ("Cursor", B7): a lowercase r opening the first of three rounded mist-blue lines
// of text (two full, one short) and a tall gold cursor waiting at the end of the last line — the
// beginning of what was typed, zoomed to fill the navy tile with equal margins left and right.
// Usage: swift redde-lines.swift out.png
let size = 1024.0
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: srgb, components: [r, g, b, a])! }

// B7 geometry, authored on a 64-unit tile and scaled up; the r sits on line one's baseline.
let k = size / 64.0
let lineWidth = 7 * k
let lines: [(Double, Double, Double)] = [(23.5, 52.5, 17.85), (11.9, 52.5, 31.85), (11.9, 33, 45.85)]
let cursor = CGRect(x: 40 * k, y: 38.85 * k, width: 7 * k, height: 14 * k)
let rBaseline = CGPoint(x: 8 * k, y: 21.3 * k)
let rFont = NSFont.systemFont(ofSize: 19.5 * k, weight: .heavy)

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!   // opaque: App Store rejects icons with alpha
ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)
let ground = CGGradient(colorsSpace: srgb, colors: [c(0.175, 0.305, 0.525), c(0.148, 0.268, 0.470)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(ground, start: .zero, end: CGPoint(x: size, y: size), options: [])
let mist = c(0xB9 / 255.0, 0xCB / 255.0, 0xE6 / 255.0)
ctx.setStrokeColor(mist); ctx.setLineWidth(lineWidth); ctx.setLineCap(.round)
for (x1, x2, y) in lines { ctx.move(to: CGPoint(x: x1 * k, y: y * k)); ctx.addLine(to: CGPoint(x: x2 * k, y: y * k)); ctx.strokePath() }
ctx.setFillColor(c(0xE8 / 255.0, 0xB0 / 255.0, 0x4B / 255.0))
ctx.addPath(CGPath(roundedRect: cursor, cornerWidth: 1.8 * k, cornerHeight: 1.8 * k, transform: nil)); ctx.fillPath()
// The r, drawn on its baseline; the context is flipped, so unflip for text.
ctx.setFillColor(mist)
let attrs: [NSAttributedString.Key: Any] = [.font: rFont,
    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
let rLine = CTLineCreateWithAttributedString(NSAttributedString(string: "r", attributes: attrs))
ctx.saveGState(); ctx.translateBy(x: rBaseline.x, y: rBaseline.y); ctx.scaleBy(x: 1, y: -1)
ctx.textPosition = .zero; CTLineDraw(rLine, ctx); ctx.restoreGState()
let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")

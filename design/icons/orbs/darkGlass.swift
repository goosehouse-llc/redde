import Cocoa
// Dark Glass voice orb: the picker's picture. The orb itself is drawn in code (GlassOrb in
// Views/VoiceView.swift), so this is that drawing frozen at the Nebula light's first frame, with
// the bars in their raised shape. Same 48-unit space as the SVG orbs beside it (disc radius 23
// at 32,32), 480 px, transparent outside the disc. Usage: swift darkGlass.swift out.png
let px = 480.0, s = px / 48.0
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r / 255, g / 255, b / 255, a])!
}
let ctx = CGContext(data: nil, width: Int(px), height: Int(px), bitsPerComponent: 8, bytesPerRow: 0,
                    space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: px); ctx.scaleBy(x: s, y: -s); ctx.translateBy(x: -8, y: -8)

let centre = CGPoint(x: 32, y: 32), radius = 23.0
let k = 2 * radius / 190   // the face is 190 pt across in the app
let disc = CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
ctx.addEllipse(in: disc); ctx.clip()
ctx.setFillColor(c(26, 34, 48)); ctx.fill(disc)

// A faint rim at the edge, under the light. (The blue ring is worn outside the face in the app
// and only while something is happening, so the picture has none.)
ctx.setStrokeColor(c(255, 255, 255, 0.16)); ctx.setLineWidth(1.5 * k)
ctx.strokeEllipse(in: disc.insetBy(dx: 0.75 * k, dy: 0.75 * k))

// A patch of light: centre offset from the face's centre, its box size and scale (all in the
// app's points), colour, and the opacity at the centre and halfway out; gone at 70%.
func patch(_ dx: Double, _ dy: Double, size: Double, scale: Double, _ r: Double, _ g: Double, _ b: Double, _ a0: Double, _ a1: Double) {
    let p = CGPoint(x: centre.x + dx * k, y: centre.y + dy * k)
    let reach = size / 2 * 2.0.squareRoot() * scale * k
    let gradient = CGGradient(colorsSpace: srgb, colors: [c(r, g, b, a0), c(r, g, b, a1), c(r, g, b, 0)] as CFArray, locations: [0, 0.5, 0.7])!
    ctx.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: reach, options: [])
}
patch(-30, -22, size: 170, scale: 1, 46, 139, 245, 0.85, 0.45)
patch(38, 24, size: 140, scale: 1.15, 150, 200, 255, 0.7, 0.35)
patch(4, 30, size: 130, scale: 0.9, 140, 90, 230, 0.75, 0.4)

// The bars, raised.
ctx.setFillColor(c(233, 241, 255))
for (i, h) in [22.0, 34, 56, 88, 56, 34, 22].enumerated() {
    let x = centre.x + (Double(i) - 3) * 15.5 * k
    let bar = CGRect(x: x - 5 * k, y: centre.y - h * k / 2, width: 10 * k, height: h * k)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 5 * k, cornerHeight: 5 * k, transform: nil))
    ctx.fillPath()
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "darkGlass.png")
let destination = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
CGImageDestinationFinalize(destination)

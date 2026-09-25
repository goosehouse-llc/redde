import Cocoa
// Flattens a rendered icon onto an opaque sRGB canvas: the App Store rejects icons with alpha.
// The "Matte Graphite" icon (redde-graphite.svg: a matte graphite speech bubble with a soft shadow on a pale tile,
// an r and one gold spark) is rendered by WebKit, which draws its blurs:
//   qlmanage -t -s 1024 -o /tmp redde-graphite.svg
//   swift flatten-icon.swift /tmp/redde-graphite.svg.png ../../Echo/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
// The previous icon (the r and three lines, B7) lives on as AppIconClassic; redde-lines.swift regenerates it.
let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: swift flatten-icon.swift in.png out.png"); exit(1)
}
let size = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(colorSpace: srgb, components: [1, 1, 1, 1])!)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.interpolationQuality = .high
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")

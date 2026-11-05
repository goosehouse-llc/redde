import Foundation
import SwiftUI

/// Company and product logos for plugins and MCP servers (asked 2026-11-03: "those are not the actual
/// icons for the company. example nvda"): Simple Icons' marks (simpleicons.org, CC0), only the ones
/// Hermes's plugin catalog and the usual MCP servers name, in `BrandIcons.json` (written by a script
/// from Simple Icons 16.34.0: each brand's title, colour and one 24×24 path; which catalog plugin is
/// whose, matched by name and checked by eye; and the name words that mean a brand). The logos are
/// their owners' trademarks and only say which service a plugin or server is for.
nonisolated struct BrandIcon: Equatable, Sendable {
    let slug: String
    let title: String
    /// "76B900".
    let hex: String
    let path: String

    var color: Color {
        let value = UInt32(hex, radix: 16) ?? 0
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// White on the brand's colour, unless the colour is too light to carry it ("FFFFFF", a pale
    /// yellow): then the mark in its colour on a dark tile.
    var wantsDarkTile: Bool { BrandIcons.contrastWithWhite(hex: hex) < 1.6 }
}

nonisolated enum BrandIcons {
    private struct File: Decodable {
        struct Icon: Decodable { let t: String; let h: String; let p: String }
        let icons: [String: Icon]
        let plugins: [String: String]
        let words: [String: String]
    }

    private static let file: File? = {
        guard let url = Bundle.main.url(forResource: "BrandIcons", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }()

    static func icon(_ slug: String) -> BrandIcon? {
        guard let icon = file?.icons[slug] else { return nil }
        return BrandIcon(slug: slug, title: icon.t, hex: icon.h, path: icon.p)
    }

    /// A catalog plugin by its catalog name; else, as for a server, by the words in its name.
    static func forPlugin(_ name: String) -> BrandIcon? {
        if let slug = file?.plugins[name] { return icon(slug) }
        return forName(name)
    }

    /// An MCP server (or a plugin the catalog doesn't have) by the words in its name: "github",
    /// "home-assistant", "google_calendar". Whole words only, from a short list of brands.
    static func forName(_ name: String) -> BrandIcon? {
        slug(forName: name, words: file?.words ?? [:]).flatMap(icon)
    }

    static func slug(forName name: String, words: [String: String]) -> String? {
        let tokens = name.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        for size in stride(from: min(3, tokens.count), through: 1, by: -1) {
            for start in 0...(tokens.count - size) {
                if let slug = words[tokens[start..<start + size].joined()] { return slug }
            }
        }
        return nil
    }

    static func contrastWithWhite(hex: String) -> Double {
        let value = UInt32(hex, radix: 16) ?? 0
        func channel(_ shift: UInt32) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        return 1.05 / (luminance + 0.05)
    }

    // MARK: Paths

    private static let cache = PathCache()

    /// The brand's mark in a 24×24 box, parsed once.
    static func shape(_ icon: BrandIcon) -> Path {
        cache.path(icon.slug) { SVGPath.parse(icon.path) }
    }
}

private nonisolated final class PathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String: Path] = [:]

    func path(_ key: String, make: () -> Path) -> Path {
        lock.lock()
        defer { lock.unlock() }
        if let kept = paths[key] { return kept }
        let made = make()
        paths[key] = made
        return made
    }
}

/// SVG path data ("M8.948 8.798v-1.43a6.7 6.7 0 0 1 .424-.018…") as a SwiftUI path: every command,
/// absolute and relative, with arcs as Béziers. Simple Icons' paths are minified, so numbers run
/// together ("-.5.5" is two) and an arc's flags may too ("a1 1 0 01-1 1").
nonisolated enum SVGPath {
    static func parse(_ data: String) -> Path {
        var scanner = Scanner(Array(data.utf8))
        var path = Path()
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: UInt8 = 0
        var command: UInt8 = 0

        while true {
            scanner.skipSeparators()
            guard let byte = scanner.peek() else { break }
            if Scanner.isCommand(byte) {
                command = byte
                scanner.advance()
            } else if command == 0 {
                break
            } else if command == UInt8(ascii: "M") {
                command = UInt8(ascii: "L")
            } else if command == UInt8(ascii: "m") {
                command = UInt8(ascii: "l")
            } else if command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                break
            }
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            var control: CGPoint?
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p); current = p; start = p
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p); current = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: origin.x + x, y: current.y); path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: origin.y + y); path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; control = c2
            case UInt8(ascii: "s"):
                let c1 = reflect(lastControl, about: current, if: [UInt8(ascii: "c"), UInt8(ascii: "s")].contains(lastCommand | 0x20))
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; control = c2
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c); current = p; control = c
            case UInt8(ascii: "t"):
                let c = reflect(lastControl, about: current, if: [UInt8(ascii: "q"), UInt8(ascii: "t")].contains(lastCommand | 0x20))
                guard let p = point() else { return path }
                path.addQuadCurve(to: p, control: c); current = p; control = c
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = point() else { return path }
                addArc(to: &path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath(); current = start
            default:
                return path
            }
            lastControl = control
            lastCommand = command
        }
        return path
    }

    private static func reflect(_ control: CGPoint?, about point: CGPoint, if previousWasCurve: Bool) -> CGPoint {
        guard previousWasCurve, let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// SVG's endpoint arc (F.6.5 of the SVG spec) as up to four cubic Béziers.
    static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint, rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { return path.addLine(to: p1) }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        var factor = (numerator / (rx * rx * y1 * y1 + ry * ry * x1 * x1)).squareRoot()
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi } else if sweep, delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func onEllipse(_ t: Double) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func derivative(_ t: Double) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        var t = theta1
        for i in 0..<segments {
            let next = t + step
            let a = onEllipse(t), b = i == segments - 1 ? p1 : onEllipse(next)
            let da = derivative(t), db = derivative(next)
            path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y), control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t = next
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        static func isCommand(_ byte: UInt8) -> Bool { "MmLlHhVvCcSsQqTtAaZz".utf8.contains(byte) }

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func advance() { index += 1 }

        mutating func skipSeparators() {
            while let byte = peek(), byte == 0x20 || byte == 0x2C || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
        }

        /// An arc flag: one "0" or "1", which may have the next number right after it.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard let byte = peek(), byte == UInt8(ascii: "0") || byte == UInt8(ascii: "1") else { return nil }
            index += 1
            return byte == UInt8(ascii: "1")
        }

        mutating func number() -> Double? {
            skipSeparators()
            let begin = index
            if let byte = peek(), byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") { index += 1 }
            var digits = false, dot = false
            while let byte = peek() {
                if byte >= 0x30, byte <= 0x39 { digits = true; index += 1 }
                else if byte == UInt8(ascii: "."), !dot { dot = true; index += 1 }
                else { break }
            }
            if digits, let byte = peek(), byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                let mark = index
                index += 1
                if let sign = peek(), sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") { index += 1 }
                var exponent = false
                while let byte = peek(), byte >= 0x30, byte <= 0x39 { exponent = true; index += 1 }
                if !exponent { index = mark }
            }
            guard digits else { index = begin; return nil }
            return Double(String(decoding: bytes[begin..<index], as: UTF8.self))
        }
    }
}

/// A brand's mark scaled into whatever box it is given, kept square.
nonisolated struct BrandMark: Shape {
    let icon: BrandIcon

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 24
        let transform = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2).scaledBy(x: scale, y: scale)
        return BrandIcons.shape(icon).applying(transform)
    }
}

/// The logo on a tile: white on the brand's colour, or the colour on a dark tile when it is too light.
struct BrandTile: View {
    let icon: BrandIcon
    var size: CGFloat = 30

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
        ZStack {
            if icon.wantsDarkTile {
                Color(white: 0.11)
                BrandMark(icon: icon).fill(icon.color).padding(size * 0.2)
            } else {
                icon.color
                BrandMark(icon: icon).fill(.white).padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

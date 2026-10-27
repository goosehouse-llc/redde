import SwiftUI

/// A bot's picture: a little creature, a speech bubble at heart (the corner nearest its bottom
/// left drawn sharp, as a message bubble's is, for its tail), in a colour of its own, with white
/// eyes glancing somewhere, and on some a small mouth or a mark of its own. Shape, eyes, mouth, mark
/// and colour come from the bot's profile name, so a bot keeps its creature when it is renamed in
/// Hermes Desktop, and `BotFace.faces(for:picked:)` gives every bot on a server one no other has
/// there (a shape and a colour of its own too, while there are some left), unless the person picked
/// one for it (`HermesBot.face`, kept on the server). The main agent is Redde itself: the app's own
/// message bubble, in the theme's bubble colour, or the Code theme's pale sky if that is picked.
nonisolated struct BotFace: Equatable, Hashable, Sendable {
    enum Shape: String, CaseIterable, Sendable {
        case round, egg, pill, capsule, burst, pick, hex, diamond
        /// Redde's own: the message bubble, its tucked corner on the left. No other bot gets it.
        case bubble
        /// Shapes only picked, never given by a name (adding them to what a name gives would
        /// change every bot's creature): a ghost, a rounded square, a house (the square with a
        /// peaked roof, asked 2026-10-24), a star, a blob.
        case ghost, square, house, star, blob

        /// The shapes a bot can be picked to have.
        static let given = allCases.filter { $0 != .bubble }
        /// The shapes a name gives, in their first order: never to change.
        static let seeded: [Shape] = [.round, .egg, .pill, .capsule, .burst, .pick, .hex, .diamond]
    }
    enum Eyes: String, CaseIterable, Sendable { case round, mismatched, sleepy, happy, sparkle }
    enum Mouth: String, CaseIterable, Sendable { case none, smile, oh, grin }
    enum Mark: String, CaseIterable, Sendable { case none, antenna, spark, freckles, blush }

    var shape: Shape
    var eyes: Eyes
    var mouth: Mouth
    var mark: Mark
    /// Which way its pupils look: 0…3.
    var glance: Int
    /// A slight lean, in degrees.
    var tilt: Double
    var color: Int
    /// The profile whose picture from Hermes Desktop stands for this face, when it has one and
    /// Settings → Appearance → Pictures from Hermes is on (`BotPictures`). Never kept on the server
    /// with the face (`code`).
    var picture: String?

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
        // For picking only, after `seededColors`.
        (Color(white: 1.0), Color(white: 0.86)),   // white
        (Color(white: 0.34), Color(white: 0.07)),  // black
    ]
    /// What a name gives is one of the first eleven colours, so no bot's colour changes when
    /// colours are added for picking (as with `Shape.seeded`).
    static let seededColors = 11
    /// The white one: drawn with a faint outline, or it would vanish on a white page.
    static let white = 11
    /// Redde's own two, past the palette: the theme's bubble colour, which follows the theme (its
    /// face's unless another is picked), and the Code theme's pale sky (#CBF0FF) in every theme.
    /// Asked 2026-10-21, after a day of the Code blue everywhere: the theme's, with the Code blue
    /// still to be had.
    static let themed = 13
    static let codeBlue = 14
    /// Colours added for picking after Redde's own two, from `laterColors` on, so no colour kept on
    /// a server changes: a soft pink, then a yellow, lemon rather than amber (both asked 2026-10-22),
    /// then a gold, Redde's own, deeper and browner than amber (asked 2026-10-23).
    static let laterPalette: [(light: Color, deep: Color)] = [
        (Color(red: 1.00, green: 0.87, blue: 0.93), Color(red: 0.96, green: 0.64, blue: 0.80)),   // soft pink
        (Color(red: 1.00, green: 0.96, blue: 0.58), Color(red: 0.98, green: 0.83, blue: 0.10)),   // yellow
        (Color(red: 0.99, green: 0.86, blue: 0.50), Color(red: 0.80, green: 0.59, blue: 0.16)),   // gold
    ]
    static let laterColors = 15
    static let softPink = 15
    static let yellow = 16
    static let gold = 17
    /// Every colour a face can be: the palette's, Redde's two, then the later ones.
    static let colorCount = 18
    /// The colours any bot can be picked to have, in the order they are offered: round the colour
    /// wheel from red to pink, Soft Pink by Pink, then white and black (asked 2026-10-22, "list
    /// the colors in an order that makes sense").
    static let pickable: [Int] = [9, 7, 1, gold, yellow, 10, 6, 4, 8, 0, 3, 5, 2, softPink, white, white + 1]
    // (coral, orange, amber, gold, yellow, lime, green, teal, sky, blue, indigo, violet, pink, soft pink, white, black)

    /// A colour's gradient, light to deep (any but Redde's two, which follow the theme).
    static func pair(_ color: Int) -> (light: Color, deep: Color) {
        color >= laterColors && color - laterColors < laterPalette.count ? laterPalette[color - laterColors] : palette[color % palette.count]
    }

    /// Every face a name can give (colour, glance and lean aside), in a fixed order.
    private static let all: [BotFace] = Shape.seeded.flatMap { shape in
        Eyes.allCases.flatMap { eyes in
            Mouth.allCases.flatMap { mouth in
                Mark.allCases.map { BotFace(shape: shape, eyes: eyes, mouth: mouth, mark: $0, glance: 0, tilt: 0, color: 0) }
            }
        }
    }

    /// The colours a chat with this bot takes with Settings → Appearance → Bot colors on, as the
    /// reader's own colour picks would: your bubbles and the accent in the deep end of its colour
    /// (white and black colour the bubbles alone: an accent in either would vanish on one of the
    /// pages), the Code blue as the Code theme has it. None for a face in the theme's colour,
    /// which is the theme's already.
    var chatColors: ThemeColors? {
        switch color {
        case Self.themed:
            return nil
        case Self.codeBlue:
            // #CBF0FF, the Code theme's accent and bubble.
            let blue = ThemeColors.RGB(red: 0.796, green: 0.941, blue: 1.0)
            return ThemeColors(accent: blue, bubble: blue)
        case Self.white:
            return ThemeColors(accent: nil, bubble: ThemeColors.RGB(Self.palette[color].light))
        case Self.white + 1:
            return ThemeColors(accent: nil, bubble: ThemeColors.RGB(Self.palette[color].deep))
        default:
            let own = ThemeColors.RGB(Self.pair(color).deep)
            return ThemeColors(accent: own, bubble: own)
        }
    }

    /// The main agent's, whatever its profile is called, unless one was picked for it: Redde's own
    /// bubble, the shape of a message in the app with its tucked corner on the left (a reply's
    /// side), in the theme's bubble colour. The other bots keep off blue, the standard theme's.
    static let main = BotFace(shape: .bubble, eyes: .round, mouth: .none, mark: .none, glance: 1, tilt: -3, color: themed)

    /// The face a name gives, on its own. The main profile's is always Redde's (`main`).
    init(seed: String) {
        guard seed != "default" else { self = Self.main; return }
        let hash = Self.hash(seed)
        self = Self.all[Int(hash % UInt64(Self.all.count))]
        color = Int((hash >> 20) % UInt64(Self.seededColors))
        glance = Int((hash >> 28) % 4)
        tilt = Double(Int((hash >> 32) % 13) - 6)
    }

    init(shape: Shape, eyes: Eyes, mouth: Mouth, mark: Mark, glance: Int, tilt: Double, color: Int) {
        self.shape = shape
        self.eyes = eyes
        self.mouth = mouth
        self.mark = mark
        self.glance = glance
        self.tilt = tilt
        self.color = color
    }

    /// How a picked face is kept on the server (the profile's `ui_meta.redde.face`): every part by
    /// name, so a part this version doesn't know leaves the face unread rather than wrong.
    var code: String { "1:\(shape.rawValue):\(eyes.rawValue):\(mouth.rawValue):\(mark.rawValue):\(color):\(glance):\(Int(tilt))" }

    init?(code: String) {
        let parts = code.split(separator: ":").map(String.init)
        guard parts.count == 8, parts[0] == "1", let shape = Shape(rawValue: parts[1]),
              let eyes = Eyes(rawValue: parts[2]), let mouth = Mouth(rawValue: parts[3]), let mark = Mark(rawValue: parts[4]),
              let color = Int(parts[5]), let glance = Int(parts[6]), let tilt = Int(parts[7]) else { return nil }
        self.init(shape: shape, eyes: eyes, mouth: mouth, mark: mark, glance: ((glance % 4) + 4) % 4,
                  tilt: Double(max(-8, min(8, tilt))), color: ((color % Self.colorCount) + Self.colorCount) % Self.colorCount)
    }

    /// A face for each name, no two alike: the ones the person picked as they are, then each
    /// other takes the face its name gives unless one before it (in name order) has it, then the
    /// next free one; its shape one of those used least so far, and a colour of its own while
    /// there are colours no one has yet. The main profile's is Redde's, or the one picked for it;
    /// Redde's bubble is never another bot's, picked or not.
    static func faces(for names: [String], picked: [String: BotFace] = [:]) -> [String: BotFace] {
        var taken: [BotFace] = []
        var out: [String: BotFace] = [:]
        let picked = picked.filter { $0.key == "default" || $0.value.shape != .bubble }
        // The main profile first: the others go round its face.
        if names.contains("default") {
            let face = picked["default"] ?? main
            // In a colour of its own (the theme's, the Code blue), it keeps the others off blue.
            var held = face
            if held.color == themed || held.color == codeBlue { held.color = 0 }
            taken.append(held)
            out["default"] = face
        }
        for name in Set(names).subtracting(["default"]).sorted() {
            guard let face = picked[name] else { continue }   // (the main profile's is in already)
            taken.append(face)
            out[name] = face
        }
        for name in Set(names).subtracting(["default"]).subtracting(picked.keys).sorted() {
            let given = BotFace(seed: name)
            let start = all.firstIndex { $0.sameFeatures(as: given) } ?? 0
            // The shapes used least so far are the ones open to it: every shape once before any twice.
            let uses = Dictionary(grouping: taken, by: \.shape).mapValues(\.count)
            let fewest = Shape.seeded.map { uses[$0] ?? 0 }.min() ?? 0
            var face = given
            for step in 0 ..< all.count {
                var candidate = all[(start + step) % all.count]
                (candidate.color, candidate.glance, candidate.tilt) = (given.color, given.glance, given.tilt)
                guard !taken.contains(where: { $0.sameFeatures(as: candidate) }), (uses[candidate.shape] ?? 0) == fewest else { continue }
                face = candidate
                break
            }
            if taken.count < seededColors {
                while taken.contains(where: { $0.color == face.color }) { face.color = (face.color + 1) % seededColors }
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

/// A moment of a face that moves (Redde's in voice mode): where it looks, how far its eyes are
/// shut, how wide its mouth is open. What is nil stays the face's own.
nonisolated struct BotPose: Equatable, Sendable {
    /// -1…1 each way: right and down are positive.
    var look: CGPoint?
    /// 0 open … 1 shut.
    var blink: CGFloat = 0
    /// 0 … 1: a mouth that talks. Nil keeps the face's own mouth (Redde's has none).
    var mouth: CGFloat?
    var tilt: Double?
}

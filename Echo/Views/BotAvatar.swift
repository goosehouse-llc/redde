import SwiftUI

/// A bot's picture: the first letter of its name on a colour of its own. The colour comes from
/// its profile's name, so a bot keeps it when it's renamed.
struct BotAvatar: View {
    var name: String
    var seed: String
    var size: CGFloat = 32

    private static let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red, .cyan, .mint]

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .circle)
            .accessibilityHidden(true)
    }

    private var color: Color {
        // Not `hashValue`: it changes from one launch to the next.
        // djb2 over the name's bytes.
        let hash = seed.utf8.reduce(UInt32(5381)) { $0 &* 33 &+ UInt32($1) }
        return Self.colors[Int(hash % UInt32(Self.colors.count))]
    }
}

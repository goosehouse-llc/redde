import SwiftUI
import WidgetKit
#if WIDGET_VIEWS_IN_TESTS
@testable import Echo
#endif

// What the Home Screen widgets share (revamped 2026-11-24): their small capitals header, an
// agent's face as the app drew it, a calendar's colour.

/// "UP NEXT", in the widget's tint, above what it shows.
struct WidgetHeader: View {
    let title: String
    var symbol: String?
    var trailing: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(title).textCase(.uppercase)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).foregroundStyle(.secondary) }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.tint)
        .lineLimit(1)
        .widgetAccentable()
    }
}

/// An agent's face, as the app drew it into the app group (`WidgetImages`); the first letter of
/// its name on a disc where there is none yet.
struct WidgetFace: View {
    let file: String?
    let name: String
    var size: CGFloat = 28

    var body: some View {
        if let image = WidgetImages.image(file) {
            Image(uiImage: image)
                .resizable()
                .widgetAccentedRenderingMode(.accentedDesaturated)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Circle().fill(.tint.opacity(0.25))
                .overlay { Text(name.prefix(1).uppercased()).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.tint) }
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// A tick in a circle: filled when done.
struct WidgetTick: View {
    let done: Bool
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .widgetAccentable(done)
            .contentTransition(.symbolEffect(.replace))
    }
}

extension Color {
    /// "#RRGGBB", as the app writes a calendar's colour.
    init?(widgetHex hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

extension Date {
    /// "2:00 PM".
    var widgetTime: String { formatted(date: .omitted, time: .shortened) }

    /// "2:00", or "14:00": the time without its AM or PM, for a round Lock Screen widget.
    var widgetClock: String {
        var time = widgetTime
        for symbol in [Calendar.current.amSymbol, Calendar.current.pmSymbol] { time = time.replacingOccurrences(of: symbol, with: "") }
        return time.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{202F}\u{00A0}")))
    }
}

/// A weather symbol that reads on a light widget as on a dark one: grey clouds, a yellow sun or
/// moon, blue rain and snow (multicolor's clouds are white).
struct WidgetWeatherIcon: View {
    let symbol: String

    var body: some View {
        let wet = ["rain", "drizzle", "snow", "sleet", "bolt"].contains { symbol.contains($0) }
        if symbol.hasPrefix("cloud") {
            Image(systemName: symbol).symbolRenderingMode(.palette).foregroundStyle(Color.gray, wet ? Color.cyan : Color.yellow)
        } else if symbol.hasPrefix("moon") {
            Image(systemName: symbol).symbolRenderingMode(.palette).foregroundStyle(Color.yellow, Color.gray)
        } else {
            Image(systemName: symbol).foregroundStyle(Color.yellow)
        }
    }
}

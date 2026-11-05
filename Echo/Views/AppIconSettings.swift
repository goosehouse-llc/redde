import SwiftUI
import UIKit

/// The Home Screen icons Redde ships besides its bot face (`BotIcon`, whose blue bubble,
/// `AppIconFaceMist`, is the primary): Matte Graphite (the primary before it), the glass Graphite
/// (`AppIcon`) and the rest, alternates listed in ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES. Each
/// has a small copy under IconPreviews/ because app icon sets can't be loaded as images. The glass
/// orbs first, their matte partners and the matte-only colors, then Classic.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case graphite = "AppIcon"
    case graphiteBlock = "AppIconGraphiteBlock"
    case steelBlock = "AppIconSteelBlock"
    case mist = "AppIconMist"
    case graphiteFlat = "AppIconGraphiteFlat"
    case graphiteBlockFlat = "AppIconGraphiteBlockFlat"
    case steelFlat = "AppIconSteelFlat"
    case mistFlat = "AppIconMistFlat"
    case navyBlock = "AppIconNavyBlock"
    case ink = "AppIconInk"
    case paperNavy = "AppIconPaperNavy"
    case gold = "AppIconGold"
    case classic = "AppIconClassic"

    var id: String { rawValue }

    /// The name `setAlternateIconName` takes (none of these is the primary).
    var alternateName: String? { rawValue }

    var label: String {
        switch self {
        case .graphite: String(localized: "Graphite")
        case .graphiteBlock: String(localized: "Graphite Block", comment: "An app icon's name")
        case .steelBlock: String(localized: "Steel", comment: "An app icon's name")
        case .mist: String(localized: "Mist", comment: "An app icon's name")
        case .graphiteFlat: String(localized: "Matte Graphite", comment: "An app icon's name")
        case .graphiteBlockFlat: String(localized: "Matte Graphite Block", comment: "An app icon's name")
        case .steelFlat: String(localized: "Matte Steel", comment: "An app icon's name")
        case .mistFlat: String(localized: "Matte Mist", comment: "An app icon's name")
        case .navyBlock: String(localized: "Navy", comment: "An app icon's name")
        case .ink: String(localized: "Ink", comment: "An app icon's name")
        case .paperNavy: String(localized: "Paper Navy", comment: "An app icon's name")
        case .gold: String(localized: "Gold")
        case .classic: String(localized: "Classic", comment: "An app icon's name: the original icon")
        }
    }

}

/// Redde's bot face as the app icon: a shape and a colour (asked 2026-11-04). iOS switches only
/// between icons built into the app, so each pair is its own (design/icons/make-face-icons.py
/// draws them); this names the one a pair is. Blue bubble is the primary, AppIconFaceMist, and blue
/// star keeps the name it had as Redde Star.
struct BotIcon: Equatable {
    enum Shape: String, CaseIterable, Identifiable {
        case bubble = "Bubble", star = "Star", ghost = "Ghost"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bubble: String(localized: "Bubble", comment: "An app icon's shape: Redde's message-bubble face")
            case .star: String(localized: "Star", comment: "An app icon's shape")
            case .ghost: String(localized: "Ghost", comment: "An app icon's shape")
            }
        }
    }
    enum Tint: String, CaseIterable, Identifiable {
        case blue = "Blue", green = "Green", purple = "Purple", orange = "Orange", pink = "Pink"
        case graphite = "Graphite", yellow = "Yellow", gold = "Gold"
        var id: String { rawValue }
        /// The dot: the icon's deep colour.
        var color: Color {
            switch self {
            case .blue: Color(red: 0.14, green: 0.45, blue: 0.89)
            case .green: Color(red: 0.34, green: 0.76, blue: 0.40)
            case .purple: Color(red: 0.54, green: 0.40, blue: 0.94)
            case .orange: Color(red: 0.94, green: 0.50, blue: 0.22)
            case .pink: Color(red: 0.91, green: 0.34, blue: 0.62)
            case .graphite: Color(red: 0.23, green: 0.25, blue: 0.29)
            case .yellow: Color(red: 0.98, green: 0.83, blue: 0.10)
            case .gold: Color(red: 0.80, green: 0.59, blue: 0.16)
            }
        }
        var label: String {
            switch self {
            case .blue: String(localized: "Blue")
            case .green: String(localized: "Green")
            case .purple: String(localized: "Purple")
            case .orange: String(localized: "Orange")
            case .pink: String(localized: "Pink")
            case .graphite: String(localized: "Graphite")
            case .yellow: String(localized: "Yellow")
            case .gold: String(localized: "Gold")
            }
        }
    }

    var shape: Shape
    var tint: Tint

    static let primary = BotIcon(shape: .bubble, tint: .blue)
    static let primaryName = "AppIconFaceMist"

    /// The icon's name in the app: what `setAlternateIconName` and IconPreviews/ go by.
    var name: String {
        switch (shape, tint) {
        case (.bubble, .blue): Self.primaryName
        case (.star, .blue): "AppIconStarMist"
        default: "AppIcon\(shape.rawValue)\(tint.rawValue)"
        }
    }

    var alternateName: String? { self == Self.primary ? nil : name }

    var label: String {
        String(localized: "\(tint.label) \(shape.label)", comment: "An app icon's name: its colour, then its shape, e.g. Pink Ghost")
    }

    init(shape: Shape, tint: Tint) {
        self.shape = shape
        self.tint = tint
    }

    /// The bot icon of that name; nil for one of the other icons.
    init?(name: String) {
        guard let found = Shape.allCases.lazy.flatMap({ shape in Tint.allCases.map { BotIcon(shape: shape, tint: $0) } })
                .first(where: { $0.name == name }) else { return nil }
        self = found
    }
}

/// The icon in use: one of the bot faces, or one of the others.
enum AppIconPick: Equatable {
    case bot(BotIcon)
    case other(AppIconChoice)

    static var current: AppIconPick {
        guard let name = UIApplication.shared.alternateIconName else { return .bot(.primary) }
        if let bot = BotIcon(name: name) { return .bot(bot) }
        return AppIconChoice(rawValue: name).map(AppIconPick.other) ?? .bot(.primary)
    }

    var name: String {
        switch self {
        case .bot(let icon): icon.name
        case .other(let icon): icon.rawValue
        }
    }
    var alternateName: String? {
        switch self {
        case .bot(let icon): icon.alternateName
        case .other(let icon): icon.alternateName
        }
    }
    var label: String {
        switch self {
        case .bot(let icon): icon.label
        case .other(let icon): icon.label
        }
    }
}

/// The App icon row of the Appearance section: collapsed to the current icon, expands to the grid.
struct AppIconSettings: View {
    @State private var selected = AppIconPick.current
    @State private var failure: String?
    /// The shape and colour the rows show: the bot icon in use, or the last one looked at.
    @State private var botIcon: BotIcon = { if case .bot(let icon) = AppIconPick.current { icon } else { .primary } }()
    // Dev hook: `-echo.expandAppIcons` opens the grid (the "Make it yours" store screenshot).
    #if DEBUG
    @State private var expanded = DevHooks.expandAppIcons
    #else
    @State private var expanded = false
    #endif

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 12, alignment: .top)]

    var body: some View {
        if UIApplication.shared.supportsAlternateIcons {
            DisclosureGroup(isExpanded: $expanded) {
                botFaceRows
                Text("More Icons", comment: "Settings: the app icons that aren't Redde's bot face")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AppIconChoice.allCases) { icon in
                        tile(.other(icon), label: icon.label)
                    }
                }
                .padding(.vertical, 6)
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                }
            } label: {
                DisclosureSummary(title: String(localized: "App icon")) {
                    HStack(spacing: 8) {
                        Text(selected.label)
                        Image("IconPreviews/\(selected.name)")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5.4, style: .continuous))
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// Redde's face: its shapes in the colour picked, then the colours as dots.
    private var botFaceRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ForEach(BotIcon.Shape.allCases) { shape in
                    let icon = BotIcon(shape: shape, tint: botIcon.tint)
                    tile(.bot(icon), label: shape.label)
                }
            }
            HStack(spacing: 0) {
                ForEach(BotIcon.Tint.allCases) { tint in
                    let isOn = botIcon.tint == tint
                    Button { choose(.bot(BotIcon(shape: botIcon.shape, tint: tint))) } label: {
                        Circle()
                            .fill(tint.color)
                            .frame(width: 26, height: 26)
                            .padding(3)
                            .overlay { Circle().strokeBorder(.tint, lineWidth: isOn ? 2.5 : 0) }
                            .frame(maxWidth: .infinity)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tint.label)
                    .accessibilityAddTraits(isOn && selected == .bot(botIcon) ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func tile(_ icon: AppIconPick, label: String) -> some View {
        Button { choose(icon) } label: {
            VStack(spacing: 6) {
                Image("IconPreviews/\(icon.name)")
                    .resizable()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 13.4, style: .continuous))
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.tint, lineWidth: selected == icon ? 2.5 : 0)
                    }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(selected == icon ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon.label)
        .accessibilityAddTraits(selected == icon ? .isSelected : [])
    }

    private func choose(_ icon: AppIconPick) {
        if case .bot(let bot) = icon { botIcon = bot }
        guard icon != selected else { return }
        let previous = selected
        selected = icon
        failure = nil
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(icon.alternateName)
            } catch {
                selected = previous
                if case .bot(let bot) = previous { botIcon = bot }
                failure = String(localized: "Couldn't change the icon: \(error.localizedDescription)")
            }
        }
    }
}

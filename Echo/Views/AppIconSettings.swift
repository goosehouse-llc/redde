import SwiftUI
import UIKit

/// The Home Screen icons Redde ships. `AppIconFaceMist` (Redde Face: Redde's bot face on the Matte
/// Mist tile) is the primary; the rest, Matte Graphite (the primary before it) and the glass Graphite
/// (`AppIcon`) included, are alternates listed in ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES. Each
/// has a small copy under IconPreviews/ because app icon sets can't be loaded as images. The primary
/// first, then the glass orbs, their matte partners and the matte-only colors, then Classic.
enum AppIconChoice: String, CaseIterable, Identifiable {
    /// Redde's own bot face (`BotFace.main`) on the Matte Mist tile: design/icons/picker/redde-face-mist.svg.
    case faceMist = "AppIconFaceMist"
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

    /// The primary icon: what a fresh install shows, and what nil puts back.
    static let primary = AppIconChoice.faceMist

    /// The name `setAlternateIconName` takes: nil puts the primary icon back.
    var alternateName: String? { self == Self.primary ? nil : rawValue }

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
        case .faceMist: String(localized: "Redde Face", comment: "An app icon's name: Redde's bot face")
        case .navyBlock: String(localized: "Navy", comment: "An app icon's name")
        case .ink: String(localized: "Ink", comment: "An app icon's name")
        case .paperNavy: String(localized: "Paper Navy", comment: "An app icon's name")
        case .gold: String(localized: "Gold")
        case .classic: String(localized: "Classic", comment: "An app icon's name: the original icon")
        }
    }

    static var current: AppIconChoice {
        // Someone who picked Redde Face before it became the primary still has that name set; it
        // maps to the same choice. Matte Graphite, the primary before, is an alternate again.
        UIApplication.shared.alternateIconName.flatMap(AppIconChoice.init(rawValue:)) ?? primary
    }
}

/// The App icon row of the Appearance section: collapsed to the current icon, expands to the grid.
struct AppIconSettings: View {
    @State private var selected = AppIconChoice.current
    @State private var failure: String?
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
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AppIconChoice.allCases) { icon in
                        Button { choose(icon) } label: {
                            VStack(spacing: 6) {
                                Image("IconPreviews/\(icon.rawValue)")
                                    .resizable()
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 13.4, style: .continuous))
                                    .padding(3)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .strokeBorder(.tint, lineWidth: selected == icon ? 2.5 : 0)
                                    }
                                Text(icon.label)
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
                }
                .padding(.vertical, 6)
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                }
            } label: {
                DisclosureSummary(title: String(localized: "App icon")) {
                    HStack(spacing: 8) {
                        Text(selected.label)
                        Image("IconPreviews/\(selected.rawValue)")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5.4, style: .continuous))
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func choose(_ icon: AppIconChoice) {
        guard icon != selected else { return }
        let previous = selected
        selected = icon
        failure = nil
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(icon.alternateName)
            } catch {
                selected = previous
                failure = String(localized: "Couldn't change the icon: \(error.localizedDescription)")
            }
        }
    }
}

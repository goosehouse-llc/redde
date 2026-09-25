import SwiftUI
import UIKit

/// The Home Screen icons Redde ships. `AppIcon` (Graphite) is the primary; the rest are alternates listed in
/// ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES. Each has a small copy under IconPreviews/ because
/// app icon sets can't be loaded as images. Glass orbs first, then their matte partners and the
/// matte-only colors, then Classic.
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

    /// The name `setAlternateIconName` takes: nil puts the primary icon back.
    var alternateName: String? { self == .graphite ? nil : rawValue }

    var label: String {
        switch self {
        case .graphite: "Graphite"
        case .graphiteBlock: "Graphite Block"
        case .steelBlock: "Steel"
        case .mist: "Mist"
        case .graphiteFlat: "Matte Graphite"
        case .graphiteBlockFlat: "Matte Graphite Block"
        case .steelFlat: "Matte Steel"
        case .mistFlat: "Matte Mist"
        case .navyBlock: "Navy"
        case .ink: "Ink"
        case .paperNavy: "Paper Navy"
        case .gold: "Gold"
        case .classic: "Classic"
        }
    }

    static var current: AppIconChoice {
        UIApplication.shared.alternateIconName.flatMap(AppIconChoice.init(rawValue:)) ?? .graphite
    }
}

/// The App icon row of the Appearance section: collapsed to the current icon, expands to the grid.
struct AppIconSettings: View {
    @State private var selected = AppIconChoice.current
    @State private var failure: String?
    // Dev hook: `-echo.expandAppIcons` opens the grid (the "Make it yours" store screenshot).
    #if DEBUG
    @State private var expanded = CommandLine.arguments.contains("-echo.expandAppIcons")
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
                DisclosureSummary(title: "App icon") {
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
                failure = "Couldn't change the icon: \(error.localizedDescription)"
            }
        }
    }
}

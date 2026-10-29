import MapKit
import SwiftUI

/// Maps for addresses (asked 2026-10-29: "I want maps to be included in messages with addresses
/// like this heads up"): a street address in a finished reply, or a heads-up's place, gets a map
/// under it, when the agent sent no map of its own. Found on the phone by the system's address
/// detector; the map is a picture drawn once and kept (a live map for every such reply would cost
/// the transcript its smoothness), opened in Apple Maps with a tap, with directions from where
/// the person is by the way they get about (Settings → Agent → Heads-Ups → Getting There).
@MainActor
enum AddressMaps {
    nonisolated struct Found: Equatable, Hashable, Sendable {
        /// What the pin is called: the place's name where it is known, else the street line.
        var name: String
        /// The address as written, on one line.
        var address: String

        var place: ReplyCard.Place { ReplyCard.Place(name: name, address: address) }
    }

    private static var cache: [String: Found?] = [:]

    /// The first street address in `text`, read once per text. Nil when there's none, or for a
    /// text too long to be worth reading.
    static func first(in text: String) -> Found? {
        if let known = cache[text] { return known }
        let found = find(in: text)
        if cache.count > 400 { cache.removeAll() }
        cache[text] = found
        return found
    }

    /// The map a reply should get: its first address, when it shows no map or places of its own.
    static func forReply(_ message: Message) -> Found? {
        guard Settings.shared.addressMaps, message.role == .assistant, !message.text.isEmpty else { return nil }
        let hasMap = (message.cards ?? []).contains { card in
            switch card {
            case .map, .places: true
            default: false
            }
        }
        return hasMap ? nil : first(in: message.text)
    }

    nonisolated static func find(in text: String) -> Found? {
        // A street address has a number in it; most replies have none, and are passed over at once.
        guard text.count < 12_000, text.contains(where: \.isNumber) else { return nil }
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue) else { return nil }
        let range = NSRange(plain.startIndex..., in: plain)
        for match in detector.matches(in: plain, range: range) {
            guard let span = Range(match.range, in: plain) else { continue }
            let parts = match.addressComponents ?? [:]
            // A street with a number, not a city or a state alone ("in Winter Park, FL").
            guard let street = parts[.street], street.contains(where: \.isNumber) else { continue }
            let written = plain[span].split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: ", ")
            return Found(name: parts[.name] ?? street, address: written)
        }
        return nil
    }

    /// Directions in Apple Maps from where the phone is, by the way the person gets about.
    static func directions(to found: Found) {
        guard let item = PlaceLookup.shared.mapItem(found.place) else { return }
        let mode = switch LeaveTime.mode() {
        case .walking: MKLaunchOptionsDirectionsModeWalking
        case .transit: MKLaunchOptionsDirectionsModeTransit
        default: MKLaunchOptionsDirectionsModeDriving
        }
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode])
    }
}

/// The map for an address: a picture of the streets around it with a pin, its name and address,
/// and Directions.
struct AddressMapCard: View {
    let found: AddressMaps.Found
    @State private var lookup = PlaceLookup.shared
    @State private var picture: Image?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    private static let height: CGFloat = 150
    private static var pictures: [String: Image] = [:]

    var body: some View {
        CardBox {
            // The picture lies over a frame of the card's width, so its own size never widens the row.
            Rectangle().fill(.quaternary)
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .overlay {
                    if let picture {
                        picture.resizable().scaledToFill()
                    } else if lookup.coordinate(of: found.place) == nil {
                        ProgressView().controlSize(.small)
                    }
                }
                .overlay {
                    if picture != nil {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
            .contentShape(.rect)
            .onTapGesture { lookup.mapItem(found.place)?.openInMaps() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Map of \(found.address)"))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(String(localized: "Opens it in Maps"))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(found.name).chatFont(.footnote, weight: .semibold).lineLimit(1)
                    if found.address != found.name {
                        Text(found.address).chatFont(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Button("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill") { AddressMaps.directions(to: found) }
                    .chatFont(.footnote, weight: .semibold).buttonStyle(.borderless)
                    .disabled(lookup.coordinate(of: found.place) == nil)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .task(id: "\(found.address)|\(scheme == .dark)") { await draw() }
    }

    /// The picture, drawn once per address and appearance and kept for the rest of the run.
    private func draw() async {
        let dark = scheme == .dark
        await lookup.look(up: [found.place])
        guard let at = lookup.coordinate(of: found.place) else { return }
        let key = "\(at.latitude),\(at.longitude),\(dark)"
        if let kept = Self.pictures[key] { picture = kept; return }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: at, latitudinalMeters: 700, longitudinalMeters: 700)
        options.size = CGSize(width: 520, height: Self.height)
        options.pointOfInterestFilter = .includingAll
        #if canImport(UIKit)
        options.scale = displayScale
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        #else
        options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        #endif
        guard let shot = try? await MKMapSnapshotter(options: options).start() else { return }
        #if canImport(UIKit)
        let drawn = Image(uiImage: shot.image)
        #else
        let drawn = Image(nsImage: shot.image)
        #endif
        if Self.pictures.count > 60 { Self.pictures.removeAll() }
        Self.pictures[key] = drawn
        picture = drawn
    }
}

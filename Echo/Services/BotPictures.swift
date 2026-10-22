import Observation
import UIKit

/// The pictures bots were given in Hermes Desktop (`profiles.get_asset`), drawn in place of their
/// faces (`BotAvatar`, `BotFace.picture`); asked on Reddit 2026-10-22. Each is fetched once a
/// launch through the Dashboard, made small, and kept on this phone per server, so a list shows
/// it at once on the next launch and the server is asked again in the background.
@MainActor
@Observable
final class BotPictures {
    static let shared = BotPictures()

    /// By server and profile ("<server id>/<profile>").
    private var images: [String: UIImage] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let folder: URL

    /// The side, in pixels, a picture is kept at: the largest a face is drawn (voice mode's) at 3×.
    nonisolated static let side: CGFloat = 384

    init(folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "BotPictures")) {
        self.folder = folder
        // The ones kept from before, at once: a list must not show faces first and pictures after.
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: folder.path())) ?? []
        for file in files where file.hasSuffix(".png") {
            if let image = UIImage(contentsOfFile: folder.appending(path: file).path()) {
                images[String(file.dropLast(4))] = image
            }
        }
    }

    /// The picture for a profile on the server in use, if it has been fetched.
    func image(for profile: String) -> UIImage? { images[Self.key(profile)] }

    /// Fetches a profile's picture, once a launch; one it no longer has is forgotten.
    func load(_ profile: String) async {
        let key = Self.key(profile)
        guard asked.insert(key).inserted else { return }
        do {
            guard let data = try await HermesServeClient.shared.botPicture(profile) else {
                images[key] = nil
                try? FileManager.default.removeItem(at: file(key))
                return
            }
            guard let small = await Self.small(data) else { return }
            images[key] = small
            let target = file(key)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? small.pngData()?.write(to: target, options: .atomic)
        } catch {
            asked.remove(key)   // not reachable now: ask again next time it is drawn
        }
    }

    #if DEBUG
    /// `-echo.demoPicture`: a picture as if fetched, for a look without a server.
    func seed(_ profile: String, _ image: UIImage) {
        let key = Self.key(profile)
        asked.insert(key)
        images[key] = image
    }

    static var demoPicture: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240)).image { context in
            let colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 240, y: 240), options: [])
            }
            let symbol = UIImage(systemName: "binoculars.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 110, weight: .semibold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 50, y: 60, width: 140, height: 120))
        }
    }
    #endif

    private static func key(_ profile: String) -> String { "\(Settings.shared.activeServerID.uuidString)/\(profile)" }

    private func file(_ key: String) -> URL { folder.appending(path: key + ".png") }

    /// Decoded off the main thread at the size it is drawn, never the 2 MB it may arrive as.
    @concurrent private static func small(_ data: Data) async -> UIImage? {
        ImageThumbnail.decode(data, maxPixel: side)
    }
}

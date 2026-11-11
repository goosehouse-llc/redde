import ImageIO
import Observation
#if canImport(UIKit)
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#else
import AppKit
#endif

/// The pictures bots were given in Hermes Desktop (`profiles.get_asset`), drawn in place of their
/// faces (`BotAvatar`, `BotFace.picture`); asked on Reddit 2026-10-22. Each is fetched once a
/// launch through the Dashboard, made small, and kept on this phone per server, so a list shows
/// it at once on the next launch and the server is asked again in the background.
@MainActor
@Observable
final class BotPictures {
    static let shared = BotPictures()

    /// By server and profile ("<server id>/<profile>").
    private var images: [String: PlatformImage] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let folder: URL

    /// The side, in pixels, a picture is kept at: the largest a face is drawn (voice mode's) at 3×.
    nonisolated static let side: CGFloat = 384

    init(folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "BotPictures")) {
        self.folder = folder
        // The ones kept from before, at once: a list must not show faces first and pictures after.
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: folder.path())) ?? []
        for file in files where file.hasSuffix(".png") {
            if let image = PlatformImage(contentsOfFile: folder.appending(path: file).path()) {
                images[String(file.dropLast(4))] = image
            }
        }
    }

    /// The picture for a profile on the server in use, if it has been fetched.
    func image(for profile: String) -> PlatformImage? { images[Self.key(profile)] }

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

    /// A picture given on this phone (`BotFacePicker`), or taken away (nil): shown at once, without
    /// waiting for the server to be asked again.
    func set(_ profile: String, _ jpeg: Data?) async {
        let key = Self.key(profile)
        asked.insert(key)
        guard let jpeg, let small = await Self.small(jpeg) else {
            images[key] = nil
            try? FileManager.default.removeItem(at: file(key))
            return
        }
        images[key] = small
        let target = file(key)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? small.pngData()?.write(to: target, options: .atomic)
    }

    /// The side, in pixels, of a picture sent from this phone: twice what is kept, for Hermes
    /// Desktop's larger faces.
    nonisolated static let sentSide = 768

    /// A photo made ready to send as a bot's picture: the middle square, `sentSide` across, upright,
    /// as a JPEG well under Hermes's 2 MB, with nothing of the original's metadata (where it was
    /// taken, the camera): only the pixels are drawn again. Nil when it can't be read as an image.
    @concurrent static func prepare(_ data: Data) async -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Decoded at little more than needed: the shorter side about `sentSide` once cropped.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: sentSide * 3,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let short = min(image.width, image.height)
        let square = CGRect(x: (image.width - short) / 2, y: (image.height - short) / 2, width: short, height: short)
        guard let cropped = image.cropping(to: square) else { return nil }
        let side = min(sentSide, short)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let drawn = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, drawn, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    #if DEBUG && canImport(UIKit)
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
    @concurrent private static func small(_ data: Data) async -> PlatformImage? {
        ImageThumbnail.decode(data, maxPixel: side)
    }
}

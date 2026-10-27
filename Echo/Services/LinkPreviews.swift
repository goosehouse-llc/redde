import Foundation
import LinkPresentation
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
import UniformTypeIdentifiers
import os

/// A web page as its card under a message shows it: its title, its site and a small picture
/// (Settings → Appearance → Link previews, asked for on Reddit, 2026-10-23).
nonisolated struct LinkPreview: Codable, Equatable, Sendable {
    var url: URL
    var title: String?
    var site: String
    /// A JPEG of the page's picture, or its icon, no more than 240 pixels across.
    var image: Data?
}

/// The cards' pages, fetched by the phone itself (LinkPresentation), once each: kept in memory
/// and in Caches by address. Off until turned on, because the site sees the visit, where Redde
/// otherwise only ever talks to the servers it is set up with. A page that can't be read isn't
/// asked again for a while.
@MainActor @Observable
final class LinkPreviews {
    static let shared = LinkPreviews()

    /// What has been fetched, as it arrives: the cards are drawn from it.
    private(set) var known: [URL: LinkPreview] = [:]
    @ObservationIgnored private var failedAt: [URL: Date] = [:]
    @ObservationIgnored private var fetching: Set<URL> = []
    @ObservationIgnored private let folder: URL?
    /// How a page is read. Tests and the demo give their own.
    @ObservationIgnored var fetch: @Sendable (URL) async -> LinkPreview? = { await LinkPreviews.fromSite($0) }
    /// How long a page that couldn't be read is left alone.
    static let retryAfter: TimeInterval = 15 * 60

    init(folder: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "link-previews")) {
        #if DEBUG
        // Made-up pages are kept nowhere, so they never stand in for real ones later.
        let demo = DevHooks.has("-echo.demoLinkPreview")
        self.folder = demo ? nil : folder
        #if canImport(UIKit)
        if demo { fetch = { await LinkPreviews.demo($0) } }
        #endif
        #else
        self.folder = folder
        #endif
    }

    /// The page's card if it is known, in memory or on disk; nil while it isn't.
    func preview(for url: URL) -> LinkPreview? { known[url] }

    /// Fetches the page unless it is known, on its way, or failed lately. One kept on disk
    /// comes back at once.
    func request(_ url: URL, now: Date = .now) async {
        guard known[url] == nil, !fetching.contains(url) else { return }
        if let kept = fromDisk(url) { known[url] = kept; return }
        if let failed = failedAt[url], now.timeIntervalSince(failed) < Self.retryAfter { return }
        fetching.insert(url)
        defer { fetching.remove(url) }
        guard let preview = await fetch(url) else { failedAt[url] = now; return }
        known[url] = preview
        toDisk(preview)
    }

    // MARK: Kept on disk

    private func file(for url: URL) -> URL? {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 { hash ^= UInt64(byte); hash &*= 0x0000_0100_0000_01b3 }
        return folder?.appending(path: String(hash, radix: 36) + ".json")
    }

    private func fromDisk(_ url: URL) -> LinkPreview? {
        guard let file = file(for: url), let data = try? Data(contentsOf: file),
              let preview = try? JSONDecoder().decode(LinkPreview.self, from: data), preview.url == url else { return nil }
        return preview
    }

    private func toDisk(_ preview: LinkPreview) {
        guard let folder, let file = file(for: preview.url), let data = try? JSONEncoder().encode(preview) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Part of "Erase everything".
    func clear() {
        known = [:]
        failedAt = [:]
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Reading the page

    /// The page read by LinkPresentation, as Messages reads it: its title, and its picture (or
    /// failing that its icon) made small.
    @concurrent nonisolated static func fromSite(_ url: URL) async -> LinkPreview? {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else {
            Logger(subsystem: "com.goosehouse.echo", category: "links").info("no preview for \(url.host() ?? "?", privacy: .public)")
            return nil
        }
        var image: Data?
        for item in [metadata.imageProvider, metadata.iconProvider].compactMap({ $0 }) where image == nil {
            image = await thumbnail(from: item)
        }
        let site = (metadata.url ?? url).host(percentEncoded: false) ?? url.absoluteString
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LinkPreview(url: url, title: title?.isEmpty == false ? title : nil, site: Self.site(site), image: image)
    }

    /// "www.example.com" reads as "example.com".
    nonisolated static func site(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    @concurrent private nonisolated static func thumbnail(from item: NSItemProvider) async -> Data? {
        let data: Data? = await withCheckedContinuation { done in
            _ = item.loadDataRepresentation(for: .image) { data, _ in done.resume(returning: data) }
        }
        #if canImport(UIKit)
        guard let data, let image = UIImage(data: data) else { return nil }
        let side: CGFloat = 240
        let scale = min(1, side / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return (image.preparingThumbnail(of: size) ?? image).jpegData(compressionQuality: 0.8)
        #else
        guard let data else { return nil }
        return ImageThumbnail.decode(data, maxPixel: 240)?.jpegData(compressionQuality: 0.8)
        #endif
    }

    #if DEBUG && canImport(UIKit)
    /// `-echo.demoLinkPreview`: made-up pages, at once, with no network (screenshots, UI tests).
    nonisolated static func demo(_ url: URL) async -> LinkPreview? {
        try? await Task.sleep(for: .milliseconds(300))
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { ctx in
            UIColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }
        return LinkPreview(url: url, title: "Falls Loop trail: conditions and parking", site: site(url.host() ?? "example.com"),
                           image: picture.jpegData(compressionQuality: 0.8))
    }
    #endif
}

/// Which link of a message gets a card.
nonisolated enum LinkPreviewLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The first web address a message gives, written out or as a Markdown link: not one in code,
    /// not a picture, and only http or https.
    static func first(in text: String) -> URL? {
        guard text.contains("http"), let detector else { return nil }
        let prose = withoutCodeOrPictures(text)
        let range = NSRange(prose.startIndex..., in: prose)
        for match in detector.matches(in: prose, range: range) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.host() != nil else { continue }
            return url
        }
        return nil
    }

    /// The text with fenced code, inline code and Markdown pictures taken out.
    static func withoutCodeOrPictures(_ text: String) -> String {
        var out = text
        for pattern in [#"```[\s\S]*?(```|$)"#, #"`[^`\n]*`"#, #"!\[[^\]]*\]\([^)]*\)"#] {
            out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return out
    }
}

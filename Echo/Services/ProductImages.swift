import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Products' pictures on a purchase card (`PurchaseCard`, asked 2026-10-30), fetched by the phone
/// from the store's own servers, which see the visit: only with Settings → Appearance → Link
/// previews on, for the same reason as a link's card (`LinkPreviews`). Made small for the card
/// (`side` pixels across at most) off the main actor, kept in memory for the run of the app, and a
/// picture that couldn't be had isn't asked again. No cookies go with the request, and none are kept.
@MainActor
final class ProductImages {
    static let shared = ProductImages()

    /// The largest a card draws one (96 pt), at 3×.
    nonisolated static let side: CGFloat = 288
    /// A picture larger than this is left alone.
    nonisolated static let largest = 8 << 20

    private let cache = NSCache<NSURL, UIImage>()
    private var loading: [URL: Task<UIImage?, Never>] = [:]
    private var failed: Set<URL> = []
    /// How a picture is fetched. Tests and the demo give their own.
    var fetch: @Sendable (URL) async -> Data? = { await ProductImages.download($0) }

    init() {
        cache.countLimit = 60
        #if DEBUG && canImport(UIKit)
        // The demo's products are drawn here, and nothing is fetched (`-echo.demoCards purchase`).
        if DevHooks.has("-echo.demoCards") { fetch = { await ProductImages.demo($0) } }
        #endif
    }

    /// The picture to fetch for a product: its address with Link previews on; else none, and the
    /// card draws what it is instead.
    static func allowed(_ url: URL?, settings: Settings = .shared) -> URL? {
        settings.linkPreviews ? url : nil
    }

    /// The picture, if it has come already: a card drawn again shows it at once.
    func cached(_ url: URL?) -> UIImage? {
        url.flatMap { cache.object(forKey: $0 as NSURL) }
    }

    /// The picture, fetched once however many cards ask for it; nil if it can't be had.
    func image(_ url: URL) async -> UIImage? {
        if let known = cached(url) { return known }
        guard !failed.contains(url) else { return nil }
        if let running = loading[url] { return await running.value }
        let fetch = self.fetch
        let task = Task { () -> UIImage? in
            guard let data = await fetch(url) else { return nil }
            return await Self.shrink(data)
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) } else { failed.insert(url) }
        return image
    }

    /// Part of "Erase everything", and for tests.
    func clear() {
        cache.removeAllObjects()
        failed = []
    }

    @concurrent private nonisolated static func shrink(_ data: Data) async -> UIImage? {
        ImageThumbnail.decode(data, maxPixel: side)
    }

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    /// The store's picture, https only, as an image and not too large.
    @concurrent nonisolated static func download(_ url: URL) async -> Data? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              http.mimeType?.hasPrefix("image/") == true, data.count <= largest else { return nil }
        return data
    }

    #if DEBUG && canImport(UIKit)
    /// `-echo.demoCards purchase`: each product drawn as a picture of its own, from its address
    /// (its colour), with no network.
    nonisolated static func demo(_ url: URL) async -> Data? {
        try? await Task.sleep(for: .milliseconds(250))
        let colours: [UIColor] = [UIColor(white: 0.16, alpha: 1), UIColor(red: 0.62, green: 0.66, blue: 0.70, alpha: 1),
                                  UIColor(red: 0.20, green: 0.27, blue: 0.45, alpha: 1), UIColor(red: 0.80, green: 0.72, blue: 0.60, alpha: 1)]
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let colour = colours[Int(hash % UInt64(colours.count))]
        let size = CGSize(width: 300, height: 300)
        let picture = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let symbol = UIImage(systemName: url.lastPathComponent.contains("bud") ? "earbuds" : "headphones",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 170, weight: .regular))?
                .withTintColor(colour, renderingMode: .alwaysOriginal)
            if let symbol {
                let fit = symbol.size
                symbol.draw(in: CGRect(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2, width: fit.width, height: fit.height))
            }
        }
        return picture.pngData()
    }
    #endif
}

import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Products' pictures on a purchase card (`PurchaseCard`, asked 2026-10-30), and from 2026-10-31 a
/// recipe's picture and a film's poster (`RecipeCard`, `ShowCard`), fetched by the phone from the
/// site's own servers, which see the visit: only with Settings → Appearance → Link previews on, for
/// the same reason as a link's card (`LinkPreviews`). Made small for the card (`side` pixels across
/// at most, or what the card asks for) off the main actor, kept in memory for the run of the app,
/// and a picture that couldn't be had isn't asked again. No cookies go with the request, and none
/// are kept. The one way a card's picture comes: `CardPicture` draws them all.
@MainActor
final class ProductImages {
    static let shared = ProductImages()

    /// The largest a card draws one (96 pt), at 3×.
    nonisolated static let side: CGFloat = 288
    /// A picture larger than this is left alone.
    nonisolated static let largest = 8 << 20

    /// By the picture's address and its size (`key`).
    private let cache = NSCache<NSString, UIImage>()
    private var loading: [String: Task<UIImage?, Never>] = [:]
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
    func cached(_ url: URL?, side: CGFloat = ProductImages.side) -> UIImage? {
        url.flatMap { cache.object(forKey: Self.key($0, side) as NSString) }
    }

    private static func key(_ url: URL, _ side: CGFloat) -> String { "\(Int(side))|" + url.absoluteString }

    /// The picture, `side` pixels across at most, fetched once however many cards ask for it; nil
    /// if it can't be had.
    func image(_ url: URL, side: CGFloat = ProductImages.side) async -> UIImage? {
        if let known = cached(url, side: side) { return known }
        guard !failed.contains(url) else { return nil }
        let key = Self.key(url, side)
        if let running = loading[key] { return await running.value }
        let fetch = self.fetch
        let task = Task { () -> UIImage? in
            guard let data = await fetch(url) else { return nil }
            return await Self.shrink(data, side: side)
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) } else { failed.insert(url) }
        return image
    }

    /// Part of "Erase everything", and for tests.
    func clear() {
        cache.removeAllObjects()
        failed = []
    }

    @concurrent private nonisolated static func shrink(_ data: Data, side: CGFloat) async -> UIImage? {
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
        // `-echo.demoCards recipe` and `show`: a dish and posters, drawn the same way.
        if url.path.contains("/recipes/") { return demoDish() }
        if url.path.contains("/posters/") { return demoPoster(url.deletingPathExtension().lastPathComponent) }
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

    /// A bowl of pasta from above, on a table: a recipe's picture in the demo.
    nonisolated static func demoDish() -> Data? {
        let size = CGSize(width: 900, height: 600)
        var seed: UInt64 = 42
        func random() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let wood = [UIColor(red: 0.45, green: 0.30, blue: 0.20, alpha: 1).cgColor, UIColor(red: 0.30, green: 0.19, blue: 0.12, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: nil, colors: wood as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            for row in 0 ..< 12 {   // the table's boards
                UIColor(white: 0, alpha: 0.08).setFill()
                UIBezierPath(rect: CGRect(x: 0, y: CGFloat(row) * 50, width: size.width, height: 2)).fill()
            }
            let centre = CGPoint(x: size.width * 0.5, y: size.height * 0.52)
            cg.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: UIColor(white: 0, alpha: 0.45).cgColor)
            UIColor(white: 0.97, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: centre.x - 250, y: centre.y - 250, width: 500, height: 500)).fill()
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor(white: 0.90, alpha: 1).setStroke()
            let rim = UIBezierPath(ovalIn: CGRect(x: centre.x - 200, y: centre.y - 200, width: 400, height: 400))
            rim.lineWidth = 3
            rim.stroke()
            // Spaghetti in a tomato sauce: strands as arcs, then the sauce over them.
            for _ in 0 ..< 70 {
                let r = 40 + random() * 120, start = random() * .pi * 2
                let strand = UIBezierPath(arcCenter: CGPoint(x: centre.x + (random() - 0.5) * 40, y: centre.y + (random() - 0.5) * 40),
                                          radius: r, startAngle: start, endAngle: start + 1.2 + random() * 1.5, clockwise: true)
                strand.lineWidth = 7
                UIColor(red: 0.96, green: 0.80 + random() * 0.08, blue: 0.45, alpha: 1).setStroke()
                strand.stroke()
            }
            for _ in 0 ..< 14 {
                let x = centre.x + (random() - 0.5) * 220, y = centre.y + (random() - 0.5) * 200, r = 18 + random() * 26
                UIColor(red: 0.78, green: 0.16 + random() * 0.08, blue: 0.10, alpha: 0.88).setFill()
                UIBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 1.6)).fill()
            }
            // Basil and cheese.
            for _ in 0 ..< 7 {
                cg.saveGState()
                cg.translateBy(x: centre.x + (random() - 0.5) * 230, y: centre.y + (random() - 0.5) * 210)
                cg.rotate(by: random() * .pi)
                UIColor(red: 0.18, green: 0.52 + random() * 0.1, blue: 0.20, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: -26, y: -11, width: 52, height: 22)).fill()
                cg.restoreGState()
            }
            UIColor(white: 1, alpha: 0.9).setFill()
            for _ in 0 ..< 40 {
                let x = centre.x + (random() - 0.5) * 260, y = centre.y + (random() - 0.5) * 240
                UIBezierPath(rect: CGRect(x: x, y: y, width: 5, height: 3)).fill()
            }
            // A fork beside it.
            UIColor(white: 0.82, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: centre.x + 290, y: centre.y - 160, width: 16, height: 330), cornerRadius: 8).fill()
        }.jpegData(compressionQuality: 0.85)
    }

    /// A film's poster in the demo: a sky in two colours from its name, a mark, its name.
    nonisolated static func demoPoster(_ slug: String) -> Data? {
        let size = CGSize(width: 400, height: 600)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in slug.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let skies: [(UIColor, UIColor, String)] = [
            (UIColor(red: 0.05, green: 0.10, blue: 0.22, alpha: 1), UIColor(red: 0.20, green: 0.55, blue: 0.62, alpha: 1), "building.2"),
            (UIColor(red: 0.20, green: 0.05, blue: 0.20, alpha: 1), UIColor(red: 0.90, green: 0.45, blue: 0.30, alpha: 1), "sun.horizon"),
            (UIColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 1), UIColor(red: 0.30, green: 0.20, blue: 0.55, alpha: 1), "moon.stars"),
            (UIColor(red: 0.10, green: 0.18, blue: 0.10, alpha: 1), UIColor(red: 0.62, green: 0.70, blue: 0.40, alpha: 1), "mountain.2"),
        ]
        let (top, bottom, mark) = skies[Int(hash % UInt64(skies.count))]
        let name = slug.split(separator: "-").map { $0.capitalized }.joined(separator: " ").uppercased()
        return UIGraphicsImageRenderer(size: size).image { context in
            if let gradient = CGGradient(colorsSpace: nil, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            if let symbol = UIImage(systemName: mark, withConfiguration: UIImage.SymbolConfiguration(pointSize: 150, weight: .ultraLight))?
                .withTintColor(UIColor(white: 1, alpha: 0.85), renderingMode: .alwaysOriginal) {
                symbol.draw(in: CGRect(x: (size.width - symbol.size.width) / 2, y: 150, width: symbol.size.width, height: symbol.size.height))
            }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let title = NSAttributedString(string: name, attributes: [.font: UIFont.systemFont(ofSize: 40, weight: .heavy), .foregroundColor: UIColor.white,
                                                                      .paragraphStyle: style, .kern: 3])
            title.draw(in: CGRect(x: 20, y: 440, width: size.width - 40, height: 110))
            let line = NSAttributedString(string: "A REDDE DEMO PICTURE", attributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                                                                                       .foregroundColor: UIColor(white: 1, alpha: 0.7), .paragraphStyle: style, .kern: 2])
            line.draw(in: CGRect(x: 20, y: 40, width: size.width - 40, height: 20))
        }.jpegData(compressionQuality: 0.85)
    }
    #endif
}

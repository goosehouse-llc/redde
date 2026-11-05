import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Icons for plugins, toolsets, MCP servers and skill groups (asked 2026-11-03: "Plugins in settings,
/// can we add icons to each? … Also for any other pages it would be appropriate"). A catalog plugin's
/// own picture when it has one (`CatalogPlugin.image`, a file in its repository pinned to a commit),
/// fetched only while its row is on screen, shrunk with ImageIO and kept in Caches; otherwise an SF
/// Symbol for its kind, or its first letter on a tile of a colour its name gives. No logos ship in
/// the app.
nonisolated enum ItemIcon {
    /// What a catalog category is drawn as (the catalog's vocabulary: tools, desktop, memory, models,
    /// general, automation, web, platform, voice).
    static func symbol(category: String) -> String {
        switch category.lowercased() {
        case "tools": "wrench.and.screwdriver"
        case "desktop": "macwindow"
        case "memory": "brain"
        case "models": "cpu"
        case "automation": "gearshape.2"
        case "web": "globe"
        case "platform": "bubble.left.and.bubble.right"
        case "voice": "waveform"
        default: "puzzlepiece.extension"
        }
    }

    /// A Hermes toolset by its name (`toolsets.py`), the messaging platforms' ("hermes-slack") as one.
    static func symbol(toolset name: String) -> String {
        let name = name.lowercased()
        if name.hasPrefix("hermes-") { return name == "hermes-cron" ? "clock" : name == "hermes-email" ? "envelope" : "bubble.left.and.bubble.right" }
        switch name {
        case "web", "search": return "globe"
        case "x_search": return "magnifyingglass"
        case "vision": return "eye"
        case "video", "video_gen": return "film"
        case "image_gen": return "photo"
        case "computer_use", "desktop_ui": return "desktopcomputer"
        case "terminal", "code_execution", "coding": return "apple.terminal"
        case "skills": return "sparkles"
        case "browser": return "safari"
        case "cronjob": return "clock"
        case "file": return "doc"
        case "tts": return "speaker.wave.2"
        case "todo": return "checklist"
        case "memory", "context_engine": return "brain"
        case "session_search": return "text.magnifyingglass"
        case "connections": return "link"
        case "project": return "folder"
        case "bot_room": return "person.3"
        case "onboarding": return "hand.wave"
        case "catalog": return "books.vertical"
        case "clarify": return "questionmark.bubble"
        case "delegation": return "arrow.triangle.branch"
        case "kanban": return "square.grid.3x2"
        case "homeassistant": return "house"
        case "mcp": return "puzzlepiece"
        case "debugging": return "ladybug"
        case "safe": return "lock.shield"
        default:
            if name.contains("discord") || name.contains("feishu") || name.contains("yuanbao") { return "bubble.left.and.bubble.right" }
            return "wrench.adjustable"
        }
    }

    /// An MCP server by the words in its name; nothing fetched.
    static func symbol(mcpServer name: String) -> String {
        let name = name.lowercased()
        let table: [(words: [String], symbol: String)] = [
            (["github", "gitlab", "git"], "chevron.left.forwardslash.chevron.right"),
            (["slack", "discord", "telegram", "matrix", "chat"], "bubble.left.and.bubble.right"),
            (["gmail", "mail", "imap", "outlook", "proton"], "envelope"),
            (["calendar", "caldav"], "calendar"),
            (["notion", "obsidian", "note", "memory", "wiki"], "note.text"),
            (["file", "fs", "drive", "dropbox", "storage"], "folder"),
            (["home", "hass", "homeassistant"], "house"),
            (["browser", "playwright", "puppeteer", "chrome", "web", "fetch", "search"], "globe"),
            (["sql", "postgres", "sqlite", "mysql", "db", "database"], "cylinder.split.1x2"),
            (["spotify", "music", "audio"], "music.note"),
            (["map", "location", "geo"], "map"),
            (["weather"], "cloud.sun"),
        ]
        for row in table where row.words.contains(where: { name.contains($0) }) { return row.symbol }
        return "server.rack"
    }

    /// A skill category (the folders under Hermes's `skills/`).
    static func symbol(skillCategory: String) -> String {
        switch skillCategory.lowercased() {
        case "apple": "apple.logo"
        case "autonomous-ai-agents": "person.2.wave.2"
        case "creative": "paintbrush"
        case "devops": "server.rack"
        case "email": "envelope"
        case "media": "play.rectangle"
        case "note-taking": "note.text"
        case "productivity": "checklist"
        case "research": "magnifyingglass"
        case "social-media": "person.2"
        case "software-development": "chevron.left.forwardslash.chevron.right"
        case "web": "globe"
        default: "sparkles"
        }
    }

    /// The fallback tile's colour: the same for a name every time, on every device.
    static let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .green, .teal]
    static func paletteIndex(for name: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Int(hash % UInt32(palette.count))
    }
    static func tint(for name: String) -> Color { palette[paletteIndex(for: name)] }

    /// A plugin with no catalog entry (one that comes with Hermes), by the words in its name; nil:
    /// its initial.
    static func symbol(pluginNamed name: String) -> String? {
        let symbol = self.symbol(mcpServer: name)
        return symbol == "server.rack" ? nil : symbol
    }

    /// A catalog plugin: what its name says first ("spotify" is music, though the catalog files it
    /// under tools), else its category.
    static func symbol(plugin name: String, category: String) -> String {
        symbol(pluginNamed: name) ?? symbol(category: category)
    }

    /// "telegram-business" → "T".
    static func initial(of name: String) -> String {
        name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
    }
}

/// A picture fetched once per address, kept small, on disk and in memory.
nonisolated final class FetchedPicture: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
    /// Width over height: about 1 is an icon; a catalog's 1200×600 picture is a banner.
    var aspect: Double { Double(image.width) / Double(max(1, image.height)) }
    var isIconShaped: Bool { (0.8...1.25).contains(aspect) }
}

actor RemotePictures {
    static let shared = RemotePictures()

    /// Bigger than this is not an icon: left unloaded.
    nonisolated static let maxBytes = 512 * 1024

    private let folder: URL
    private let memory = NSCache<NSString, FetchedPicture>()
    private var inFlight: [String: Task<FetchedPicture?, Never>] = [:]
    /// Addresses that failed this run (not found, too big, not a picture): not asked again until relaunch.
    private var failed = Set<String>()

    init(folder: URL = URL.cachesDirectory.appending(path: "ItemIcons")) {
        self.folder = folder
        memory.countLimit = 120
    }

    /// Only https, and only a picture's address.
    nonisolated static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return false }
        return url.pathExtension.lowercased() != "svg"
    }

    nonisolated static func cacheKey(_ url: URL, pixels: Int) -> String {
        SHA256.hash(data: Data("\(url.absoluteString)@\(pixels)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func acceptable(byteCount: Int) -> Bool { byteCount > 0 && byteCount <= maxBytes }

    /// The picture at most `pixels` on its long side, the first frame of a GIF; nil for anything
    /// ImageIO can't read (SVG among them). Never decodes the full size.
    nonisolated static func decode(_ data: Data, pixels: Int) -> CGImage? {
        guard acceptable(byteCount: data.count),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, type != UTType.svg.identifier
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(8, pixels),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func picture(_ url: URL, pixels: Int) async -> FetchedPicture? {
        guard Self.allows(url) else { return nil }
        let key = Self.cacheKey(url, pixels: pixels)
        if let kept = memory.object(forKey: key as NSString) { return kept }
        if failed.contains(url.absoluteString) { return nil }
        if let running = inFlight[key] { return await running.value }
        let file = folder.appending(path: key + ".png")
        let task = Task<FetchedPicture?, Never> { [folder] in
            if let data = try? Data(contentsOf: file), let image = Self.decode(data, pixels: pixels) { return FetchedPicture(image) }
            guard let data = await Self.download(url), let image = Self.decode(data, pixels: pixels) else { return nil }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Self.writePNG(image, to: file)
            return FetchedPicture(image)
        }
        inFlight[key] = task
        let picture = await task.value
        inFlight[key] = nil
        if let picture { memory.setObject(picture, forKey: key as NSString) } else if !Task.isCancelled { failed.insert(url.absoluteString) }
        return picture
    }

    nonisolated private static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, acceptable(byteCount: data.count)
        else { return nil }
        return data
    }

    nonisolated private static func writePNG(_ image: CGImage, to file: URL) {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// A row's icon: a fixed square with rounded corners and a hairline edge, the fetched picture when
/// it is icon-shaped, else the symbol (or the initial) on a tile of the name's colour. Decorative.
struct ItemIconView: View {
    /// A company's or product's logo (`BrandIcons`): before the picture and the symbol.
    var brand: BrandIcon? = nil
    var picture: URL? = nil
    var symbol: String?
    let name: String
    var size: CGFloat = 30

    @Environment(\.displayScale) private var scale
    @State private var fetched: FetchedPicture?

    var body: some View {
        if let brand {
            BrandTile(icon: brand, size: size)
        } else {
            drawn
        }
    }

    private var drawn: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
        return ZStack {
            if let fetched, fetched.isIconShaped {
                Image(decorative: fetched.image, scale: scale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                let tint = ItemIcon.tint(for: name)
                tint.opacity(0.16)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.5, weight: .medium))
                        .foregroundStyle(tint)
                } else {
                    Text(ItemIcon.initial(of: name))
                        .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
        // Tied to the row being on screen: SwiftUI cancels it when the row goes.
        .task(id: picture) {
            guard let picture, RemotePictures.allows(picture) else { return }
            fetched = await RemotePictures.shared.picture(picture, pixels: Int((size * scale).rounded(.up)))
        }
    }
}

/// A catalog picture that is a banner (1200×600 on Nous's official plugins), across a plugin's page;
/// nothing at all while it loads or when there is none.
struct PluginBanner: View {
    let picture: URL?
    @Environment(\.displayScale) private var scale
    @State private var fetched: FetchedPicture?

    var body: some View {
        Group {
            if let fetched, !fetched.isIconShaped {
                Image(decorative: fetched.image, scale: scale)
                    .resizable()
                    .aspectRatio(fetched.aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
            }
        }
        .task(id: picture) {
            guard let picture, RemotePictures.allows(picture) else { return }
            fetched = await RemotePictures.shared.picture(picture, pixels: Int(800 * min(scale, 2)))
        }
    }
}

/// The catalog's pictures and categories by plugin name, for rows that show installed plugins (which
/// carry only the catalog's name): read once from the copy `PluginCatalogStore` keeps, off the main actor.
@MainActor @Observable
final class PluginCatalogIndex {
    static let shared = PluginCatalogIndex()

    struct Entry: Equatable, Sendable { var picture: URL?; var category: String }
    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var loading: Task<Void, Never>?

    func entry(_ name: String) -> Entry? { entries[name] }

    func prepare() async {
        if let loading { return await loading.value }
        #if DEBUG
        if PluginsDemo.on {
            entries = Dictionary(PluginsDemo.catalog.plugins.map { ($0.name, Entry(picture: $0.image, category: $0.category)) }, uniquingKeysWith: { a, _ in a })
            loading = Task {}
            return
        }
        #endif
        let task = Task {
            let catalog = await Task.detached(priority: .utility) { try? await PluginCatalogStore.load() }.value
            guard let catalog else { return }
            entries = Dictionary(catalog.plugins.map { ($0.name, Entry(picture: $0.image, category: $0.category)) }, uniquingKeysWith: { a, _ in a })
        }
        loading = task
        await task.value
    }
}

/// An installed plugin's icon: its catalog entry's picture or category, else by the words in its name.
struct PluginIcon: View {
    let name: String
    var catalogName: String?
    var size: CGFloat = 30

    var body: some View {
        let entry = PluginCatalogIndex.shared.entry(catalogName ?? name)
        ItemIconView(brand: BrandIcons.forPlugin(catalogName ?? name), picture: entry?.picture,
                     symbol: entry.map { ItemIcon.symbol(plugin: name, category: $0.category) } ?? ItemIcon.symbol(pluginNamed: name),
                     name: name, size: size)
            .task { await PluginCatalogIndex.shared.prepare() }
    }
}

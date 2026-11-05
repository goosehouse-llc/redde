import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Echo

/// Icons for plugins, toolsets, MCP servers and skill groups (asked 2026-11-03): only https
/// pictures, small ones, shrunk on decode, one cache entry per address and size; otherwise a symbol
/// by kind, or the initial on a tile whose colour the name decides.
struct PluginIconTests {
    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func onlyHttpsPicturesAreFetched() {
        #expect(RemotePictures.allows(URL(string: "https://raw.githubusercontent.com/a/b/abc/assets/icon.png")))
        #expect(!RemotePictures.allows(URL(string: "http://example.com/icon.png")), "no plain http")
        #expect(!RemotePictures.allows(URL(string: "file:///etc/passwd")))
        #expect(!RemotePictures.allows(URL(string: "https://example.com/logo.svg")), "SVG isn't drawn: the fallback is")
        #expect(!RemotePictures.allows(nil))
    }

    @Test func bigFilesAreLeftAlone() {
        #expect(RemotePictures.acceptable(byteCount: 200_000))
        #expect(RemotePictures.acceptable(byteCount: RemotePictures.maxBytes))
        #expect(!RemotePictures.acceptable(byteCount: RemotePictures.maxBytes + 1))
        #expect(!RemotePictures.acceptable(byteCount: 0))
        #expect(RemotePictures.decode(Data(count: RemotePictures.maxBytes + 1), pixels: 96) == nil)
    }

    @Test func oneCacheEntryPerAddressAndSize() throws {
        let url = try #require(URL(string: "https://raw.githubusercontent.com/a/b/abc/assets/icon.png"))
        let other = try #require(URL(string: "https://raw.githubusercontent.com/a/b/def/assets/icon.png"))
        #expect(RemotePictures.cacheKey(url, pixels: 96) == RemotePictures.cacheKey(url, pixels: 96))
        #expect(RemotePictures.cacheKey(url, pixels: 96) != RemotePictures.cacheKey(url, pixels: 120))
        #expect(RemotePictures.cacheKey(url, pixels: 96) != RemotePictures.cacheKey(other, pixels: 96), "a new commit is a new picture")
        #expect(RemotePictures.cacheKey(url, pixels: 96).count == 64)
    }

    @Test func picturesAreShrunkAsTheyAreRead() throws {
        let square = try #require(RemotePictures.decode(try png(width: 1024, height: 1024), pixels: 96))
        #expect(max(square.width, square.height) <= 96)
        #expect(FetchedPicture(square).isIconShaped)
        // Nous's official plugins carry 1200×600 banners: drawn on the plugin's page, not as an icon.
        let banner = try #require(RemotePictures.decode(try png(width: 1200, height: 600), pixels: 96))
        #expect(banner.width == 96 && banner.height == 48)
        #expect(!FetchedPicture(banner).isIconShaped)
        #expect(RemotePictures.decode(Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8), pixels: 96) == nil)
        #expect(RemotePictures.decode(Data("not a picture".utf8), pixels: 96) == nil)
    }

    @Test func eachKindHasASymbol() {
        #expect(ItemIcon.symbol(category: "voice") == "waveform")
        #expect(ItemIcon.symbol(category: "memory") == "brain")
        #expect(ItemIcon.symbol(category: "Something new") == "puzzlepiece.extension")
        #expect(ItemIcon.symbol(toolset: "browser") == "safari")
        #expect(ItemIcon.symbol(toolset: "terminal") == "apple.terminal")
        #expect(ItemIcon.symbol(toolset: "hermes-slack") == "bubble.left.and.bubble.right")
        #expect(ItemIcon.symbol(toolset: "brand_new_toolset") == "wrench.adjustable")
        #expect(ItemIcon.symbol(mcpServer: "github") == "chevron.left.forwardslash.chevron.right")
        #expect(ItemIcon.symbol(mcpServer: "calendar") == "calendar")
        #expect(ItemIcon.symbol(mcpServer: "acme-internal") == "server.rack")
        #expect(ItemIcon.symbol(pluginNamed: "spotify-desktop") == "music.note")
        #expect(ItemIcon.symbol(pluginNamed: "redde-push") == nil, "no known word: its initial")
        #expect(ItemIcon.symbol(plugin: "spotify", category: "tools") == "music.note")
        #expect(ItemIcon.symbol(plugin: "homeassistant", category: "platform") == "house")
        #expect(ItemIcon.symbol(plugin: "langfuse", category: "general") == "puzzlepiece.extension")
        #expect(ItemIcon.symbol(skillCategory: "software-development") == "chevron.left.forwardslash.chevron.right")
    }

    @Test func theFallbackTileIsTheSameForANameEveryTime() {
        #expect(ItemIcon.paletteIndex(for: "redde-push") == ItemIcon.paletteIndex(for: "redde-push"))
        #expect(ItemIcon.paletteIndex(for: "Redde-Push") == ItemIcon.paletteIndex(for: "redde-push"))
        // FNV-1a over the name's bytes: fixed, not Swift's per-launch hashValue.
        #expect(ItemIcon.paletteIndex(for: "a") == Int((((2_166_136_261 as UInt32) ^ 97) &* 16_777_619) % 8))
        let spread = Set(["spotify", "markifact", "mermail", "langfuse", "blender", "snyk", "redde-push", "homeassistant"].map(ItemIcon.paletteIndex(for:)))
        #expect(spread.count > 3)
        #expect(ItemIcon.initial(of: "telegram-business") == "T")
        #expect(ItemIcon.initial(of: "-x") == "X")
        #expect(ItemIcon.initial(of: "") == "?")
    }

    // MARK: Brand logos (Simple Icons, 2026-11-03: "those are not the actual icons for the company")

    @Test func brandsAreMatchedByWholeNamesOnly() {
        #expect(BrandIcons.forPlugin("nvidia-app")?.slug == "nvidia")
        #expect(BrandIcons.forPlugin("nvidia-broadcast")?.slug == "nvidia")
        #expect(BrandIcons.forPlugin("spotify")?.slug == "spotify")
        #expect(BrandIcons.forPlugin("homeassistant")?.slug == "homeassistant")
        #expect(BrandIcons.forName("NVIDIA App")?.slug == "nvidia")
        #expect(BrandIcons.forName("github")?.slug == "github")
        #expect(BrandIcons.forName("home-assistant")?.slug == "homeassistant")
        #expect(BrandIcons.forName("google_calendar")?.slug == "googlecalendar")
        for generic in ["memory", "basic-memory", "web-search", "files", "redde-push", "terminal", "agentvault", "abstract-provider", "my-calendar-app"] {
            #expect(BrandIcons.forPlugin(generic) == nil, "\(generic)")
        }
        #expect(BrandIcons.slug(forName: "githubber", words: ["github": "github"]) == nil, "part of a word isn't the word")
    }

    @Test func everyBundledMarkParsesInsideItsBox() throws {
        for slug in ["nvidia", "spotify", "github", "homeassistant", "notion", "telegram", "discord", "obsidian", "linear", "google"] {
            let icon = try #require(BrandIcons.icon(slug), "\(slug) is bundled")
            let box = SVGPath.parse(icon.path).boundingRect
            #expect(box.width > 12 && box.height > 6, "\(slug): \(box)")
            #expect(box.minX >= -0.5 && box.minY >= -0.5 && box.maxX <= 24.5 && box.maxY <= 24.5, "\(slug): \(box)")
        }
    }

    @Test func svgPathsReadTheMinifiedForms() {
        // Numbers run together, relative commands, an arc whose flags touch the next number.
        let line = SVGPath.parse("M1-.5.5.5h2v3H0V0z").boundingRect
        #expect(line == CGRect(x: 0, y: -0.5, width: 2.5, height: 4), "M1,-.5 then a line to .5,.5: \(line)")
        let arc = SVGPath.parse("M0 12a12 12 0 0124 0").boundingRect
        #expect(abs(arc.minX) < 0.01 && abs(arc.maxX - 24) < 0.01 && abs(arc.minY) < 0.05 && abs(arc.maxY - 12) < 0.01, "a half circle over the top: \(arc)")
        let curves = SVGPath.parse("M0 0c4 0 4 8 8 8s4-8 8-8q4 0 4 4t4 4").boundingRect
        #expect(abs(curves.maxX - 24) < 0.01 && curves.maxY > 7)
        #expect(SVGPath.parse("").isEmpty)
        #expect(SVGPath.parse("garbage").isEmpty)
    }

    @Test func lightBrandsGoOnADarkTile() {
        #expect(BrandIcon(slug: "a", title: "A", hex: "FFFFFF", path: "").wantsDarkTile)
        #expect(BrandIcon(slug: "a", title: "A", hex: "FFDD00", path: "").wantsDarkTile)
        #expect(!BrandIcon(slug: "a", title: "A", hex: "181717", path: "").wantsDarkTile)
        #expect(!BrandIcon(slug: "a", title: "A", hex: "1DB954", path: "").wantsDarkTile)
    }
}

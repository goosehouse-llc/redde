import Foundation
import Testing
@testable import Echo

/// Link previews (Settings → Appearance → Link previews, asked for on Reddit 2026-10-23): which
/// link of a message gets a card, and how its page is read once and kept.
@MainActor
struct LinkPreviewTests {
    @Test func theFirstWebLinkGetsTheCard() {
        #expect(LinkPreviewLinks.first(in: "See https://example.com/a and https://example.org/b")?.absoluteString == "https://example.com/a")
        #expect(LinkPreviewLinks.first(in: "Details are in the [shared plan](https://example.com/kitchen).")?.absoluteString == "https://example.com/kitchen")
        #expect(LinkPreviewLinks.first(in: "No link here, just words.") == nil)
    }

    @Test func notInCodeNotAPictureNotAnotherKindOfAddress() {
        #expect(LinkPreviewLinks.first(in: "Run `curl https://example.com/install.sh` first") == nil, "inline code")
        #expect(LinkPreviewLinks.first(in: "```\nfetch('https://example.com/api')\n```") == nil, "a code block")
        #expect(LinkPreviewLinks.first(in: "![a chart](https://example.com/chart.png)") == nil, "a picture")
        #expect(LinkPreviewLinks.first(in: "Write to mailto:someone@example.com or ftp://example.com/file") == nil)
        #expect(LinkPreviewLinks.first(in: "![chart](https://example.com/c.png) and the [page](https://example.com/page)")?.path() == "/page",
                "the picture is passed over, the page after it is the one")
    }

    @Test func aPageIsReadOnceAndKeptOnDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "link-previews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try #require(URL(string: "https://example.com/trail"))
        let reads = Counter()
        let store = LinkPreviews(folder: folder)
        store.fetch = { url in
            await reads.add()
            return LinkPreview(url: url, title: "The trail", site: "example.com", image: nil)
        }
        await store.request(url)
        await store.request(url)
        #expect(store.preview(for: url)?.title == "The trail")
        #expect(await reads.value == 1, "read once")

        // Another launch: from disk, without reading the page again.
        let again = LinkPreviews(folder: folder)
        again.fetch = { _ in await reads.add(); return nil }
        await again.request(url)
        #expect(again.preview(for: url)?.title == "The trail")
        #expect(await reads.value == 1)
    }

    @Test func aPageThatCantBeReadIsLeftAloneForAWhile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "link-previews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try #require(URL(string: "https://example.com/gone"))
        let reads = Counter()
        let store = LinkPreviews(folder: folder)
        store.fetch = { _ in await reads.add(); return nil }
        let now = Date.now
        await store.request(url, now: now)
        await store.request(url, now: now.addingTimeInterval(60))
        #expect(await reads.value == 1, "not asked again within a quarter of an hour")
        await store.request(url, now: now.addingTimeInterval(LinkPreviews.retryAfter + 1))
        #expect(await reads.value == 2)
        #expect(store.preview(for: url) == nil)
    }

    @Test func theSiteReadsWithoutWww() {
        #expect(LinkPreviews.site("www.example.com") == "example.com")
        #expect(LinkPreviews.site("trails.example.com") == "trails.example.com")
    }

    @Test func offUntilTurnedOnAndSynced() {
        let settings = Settings(defaults: UserDefaults(suiteName: "link-previews-\(UUID().uuidString)")!)
        #expect(settings.linkPreviews == false)
        #expect(Settings.syncedKeys.contains("linkPreviews"))
    }
}

private actor Counter {
    private(set) var value = 0
    func add() { value += 1 }
}

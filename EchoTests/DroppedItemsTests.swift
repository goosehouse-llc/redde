import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Echo

/// A drop on the chat, sorted into attachments and text.
@MainActor
struct DroppedItemsTests {
    // MARK: - What a provider holds

    @Test func picturesAreAttachedWhateverElseComesWithThem() {
        // A picture dragged from a web page brings its address along.
        #expect(DroppedItems.kind(of: [.png, .url], fileBacked: false, readsAsText: false) == .image)
        #expect(DroppedItems.kind(of: [.heic], fileBacked: true, readsAsText: false) == .image)
    }

    /// The same types, a file behind one of them: that is the difference between a document
    /// out of Files and a sentence dragged out of a page.
    @Test func aTextFileIsAFileAndASelectionIsText() {
        #expect(DroppedItems.kind(of: [.plainText], fileBacked: true, readsAsText: true) == .file(.plainText))
        #expect(DroppedItems.kind(of: [.utf8PlainText], fileBacked: false, readsAsText: true) == .text)
        #expect(DroppedItems.kind(of: [.webArchive, .rtf, .utf8PlainText], fileBacked: false, readsAsText: true) == .text)
        #expect(DroppedItems.kind(of: [.json, .fileURL], fileBacked: false, readsAsText: true) == .file(.json))
    }

    @Test func aLinkIsALinkNotItsText() {
        #expect(DroppedItems.kind(of: [.url, .utf8PlainText], fileBacked: false, readsAsText: true) == .link)
    }

    @Test func dataWithNothingToReadItAsIsAFile() {
        #expect(DroppedItems.kind(of: [.pdf], fileBacked: false, readsAsText: false) == .file(.pdf))
        #expect(DroppedItems.kind(of: [.pdf], fileBacked: true, readsAsText: false) == .file(.pdf))
        #expect(DroppedItems.kind(of: [], fileBacked: false, readsAsText: false) == .nothing)
    }

    @Test func aSuggestedNameGetsTheFilesExtension() {
        let file = URL(fileURLWithPath: "/tmp/E3F1.jpeg")
        #expect(DroppedItems.named("Kitchen plan", like: file) == "Kitchen plan.jpeg")
        #expect(DroppedItems.named("plan.png", like: file) == "plan.png")
        #expect(DroppedItems.named(nil, like: file) == "E3F1.jpeg")
    }

    // MARK: - Loading real providers

    private func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
    }

    /// A provider with a file behind it, as Files hands one over.
    private func file(named name: String, type: UTType, bytes: Data) throws -> NSItemProvider {
        let directory = FileManager.default.temporaryDirectory.appending(path: "drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try bytes.write(to: url)
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(for: type, visibility: .all, openInPlace: true) { completion in
            completion(url, true, nil)
            return nil
        }
        return provider
    }

    @Test func aDroppedPictureBecomesAnAttachment() async {
        let dropped = await DroppedItems.load([NSItemProvider(object: picture())])
        #expect(dropped.attachments.count == 1)
        #expect(dropped.attachments.first?.kind == .image)
        #expect(dropped.text.isEmpty)
        #expect(dropped.problems.isEmpty)
    }

    @Test func aDroppedFileBecomesAnAttachmentWithItsName() async throws {
        let notes = try file(named: "notes.md", type: .plainText, bytes: Data("# Plan\n\nCabinets on the 18th.".utf8))
        let dropped = await DroppedItems.load([notes])
        let attachment = try #require(dropped.attachments.first)
        #expect(attachment.filename == "notes.md")
        #expect(attachment.kind == .text)
        #expect(attachment.inlineText?.contains("Cabinets on the 18th") == true)
        #expect(dropped.text.isEmpty, "a text file is attached, not poured into the draft")
    }

    @Test func aFileOverTheLimitIsRefusedByName() async throws {
        let big = try file(named: "video.bin", type: .data, bytes: Data(count: Attachment.maxFileBytes + 1))
        let dropped = await DroppedItems.load([big])
        #expect(dropped.attachments.isEmpty)
        #expect(dropped.problems == ["video.bin is over the 8 MB attachment limit."])
    }

    @Test func linksAndTextGoToTheDraft() async {
        let link = NSItemProvider(object: URL(string: "https://example.com/plan?week=2")! as NSURL)
        let sentence = NSItemProvider(object: "  The crew starts Monday.\n" as NSString)
        let dropped = await DroppedItems.load([link, sentence])
        #expect(dropped.attachments.isEmpty)
        #expect(dropped.text == ["https://example.com/plan?week=2", "The crew starts Monday."])
    }

    @Test func aDropOfMixedThingsKeepsTheirOrder() async throws {
        let notes = try file(named: "a.txt", type: .plainText, bytes: Data("a".utf8))
        let dropped = await DroppedItems.load([NSItemProvider(object: picture()), notes, NSItemProvider(object: "and this" as NSString)])
        #expect(dropped.attachments.map(\.kind) == [.image, .text])
        #expect(dropped.text == ["and this"])
    }

    @Test func noMoreThanAHandfulAtOnce() async {
        let many = (0 ... DroppedItems.maximumAttachments).map { _ in NSItemProvider(object: picture()) }
        let dropped = await DroppedItems.load(many)
        #expect(dropped.attachments.count == DroppedItems.maximumAttachments)
        #expect(dropped.problems == ["Only the first \(DroppedItems.maximumAttachments) items were attached."])
    }
}

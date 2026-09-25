import Foundation
import Testing
import UIKit
@testable import Echo

struct AttachmentTests {
    private func sampleImage() -> Echo.Attachment {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000))
        let image = renderer.image { ctx in UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000)) }
        return Attachment.image(image)!
    }

    @Test func imagesAreDownscaledToJPEG() {
        let att = sampleImage()
        #expect(att.kind == .image)
        #expect(att.mimeType == "image/jpeg")
        let decoded = UIImage(data: att.data)!
        #expect(max(decoded.size.width, decoded.size.height) <= Attachment.maxImageEdge + 1)
    }

    @Test func sessionsInputBecomesPartsWithImages() throws {
        let input = try HermesSessionsTransport.makeInput(text: "what is this", attachments: [sampleImage()])
        let parts = input.array!
        #expect(parts.count == 2)
        #expect(parts[0]["type"]?.string == "input_text")
        #expect(parts[1]["type"]?.string == "input_image")
        #expect(parts[1]["image_url"]?.string?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(try HermesSessionsTransport.makeInput(text: "plain", attachments: []) == .string("plain"))
    }

    @Test func textFilesAreInlinedAndPDFsRefusedOnAPI() throws {
        let txt = Echo.Attachment(kind: .text, filename: "notes.txt", mimeType: "text/plain", data: Data("hello".utf8))
        let input = try HermesSessionsTransport.makeInput(text: "summarize", attachments: [txt])
        #expect(input.array?.first?["text"]?.string?.contains("--- notes.txt ---\nhello") == true)
        let pdf = Echo.Attachment(kind: .pdf, filename: "a.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]))
        #expect(throws: AttachmentError.self) { try HermesSessionsTransport.makeInput(text: "", attachments: [pdf]) }
        #expect(throws: AttachmentError.self) { try ChatCompletionsTransport.makeContent(text: "", attachments: [pdf]) }
    }

    @Test func messagesRoundTripAttachmentsViaDisk() throws {
        var m = Message(role: .user, text: "look")
        m.attachments = [Echo.Attachment(kind: .text, filename: "a.txt", mimeType: "text/plain", data: Data("x".utf8))]
        m.attachments[0].persistToStore()   // the store's save path does this before encoding
        let data = try JSONEncoder().encode(m)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"data\""), "bytes should not be inline in transcript JSON")
        let back = try JSONDecoder().decode(Message.self, from: data)
        #expect(back.attachments.count == 1 && back.attachments[0].filename == "a.txt")
        #expect(back.attachments[0].data == Data("x".utf8), "bytes come back from the attachment store")
        AttachmentFiles.delete(id: m.attachments[0].id)
    }

    // A 1×1 red pixel; valid JPEG bytes matter because extraction decodes the base64.
    private static let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        .jpegData(withCompressionQuality: 1) { ctx in UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        .base64EncodedString()

    @Test func inlineDataImagesBecomePhotoAttachments() {
        let (text, atts) = InlineImages.extract(from: "Here it is ![image](data:image/jpeg;base64,\(Self.pixel)) — front door.")
        #expect(text == "Here it is  — front door.")
        #expect(atts.count == 1)
        #expect(atts[0].kind == .image && atts[0].mimeType == "image/jpeg" && atts[0].filename == "photo.jpg")
        #expect(UIImage(data: atts[0].data) != nil)
    }

    @Test func imageOnlyReplyKeepsNoText() {
        let (text, atts) = InlineImages.extract(from: "![front door](data:image/png;base64,\(Self.pixel))")
        #expect(text.isEmpty)
        #expect(atts.count == 1 && atts[0].filename == "front door.png")
    }

    @Test func remoteAndMalformedImagesStayInTheText() {
        let remote = "See ![diagram](https://example.com/a.png)"
        #expect(InlineImages.extract(from: remote) == (remote, []))
        let bad = "x ![i](data:image/jpeg;base64,@@not-base64@@) y"
        #expect(InlineImages.extract(from: bad) == (bad, []))
    }

    @Test func serveMediaFindsEveryPathShape() {
        let text = """
        Here you go: MEDIA:/tmp/snap_front_door.jpg
        Also ![front](/home/hermes/cam.png) and ![f2](file:///var/cache/x.webp)
        I saved it. [IMAGE: /tmp/snap2.jpeg]
        Documents too: MEDIA:/tmp/report.pdf ![doc](/tmp/notes.txt)
        Not fetchable: MEDIA:/tmp/tool.bin https://example.com/pic.jpg
        """
        let found = ServeMedia.candidates(in: text)
        #expect(found.map(\.path) == ["/tmp/snap_front_door.jpg", "/tmp/report.pdf",
                                      "/home/hermes/cam.png", "/var/cache/x.webp", "/tmp/notes.txt",
                                      "/tmp/snap2.jpeg"])
        #expect(found[0].whole == "MEDIA:/tmp/snap_front_door.jpg")
        #expect(found[2].whole == "![front](/home/hermes/cam.png)")
        #expect(found[5].whole == "[IMAGE: /tmp/snap2.jpeg]")
        #expect(found[0].filename == "snap_front_door.jpg")
    }

    @Test func serveMediaIgnoresRemoteAndPlainText() {
        #expect(ServeMedia.candidates(in: "see ![a](https://example.com/a.png) at /tmp or ~/pics").isEmpty)
    }

    /// A fetched file's kind follows its mime type: photos stay photos, the rest become
    /// document chips (PDF, text) that QuickLook can open.
    @Test func fetchedFilesBecomeTypedAttachments() {
        let pdf = ServeMedia.attachment(dataURL: "data:application/pdf;base64,\(Data("%PDF-1.4".utf8).base64EncodedString())", name: "report.pdf")
        #expect(pdf?.kind == .pdf && pdf?.filename == "report.pdf" && pdf?.mimeType == "application/pdf")
        let txt = ServeMedia.attachment(dataURL: "data:text/plain;base64,\(Data("hello".utf8).base64EncodedString())", name: "notes.txt")
        #expect(txt?.kind == .text && txt?.inlineText == "hello")
        let img = ServeMedia.attachment(dataURL: "data:image/png;base64,\(Data([1, 2, 3]).base64EncodedString())", name: "cam")
        #expect(img?.kind == .image && img?.filename == "cam.png")
        #expect(InlineImages.attachment(dataURL: "data:application/pdf;base64,AAAA", name: "x") == nil,
                "the inline extractor stays image-only")
    }

    @Test func shareInboxKeepsBytesInline() throws {
        let att = Echo.Attachment(kind: .text, filename: "b.txt", mimeType: "text/plain", data: Data("yy".utf8))
        let encoder = JSONEncoder()
        encoder.userInfo[.inlineAttachmentData] = true
        let data = try encoder.encode(att)
        #expect(String(decoding: data, as: UTF8.self).contains("\"data\""))
        let back = try JSONDecoder().decode(Echo.Attachment.self, from: data)
        #expect(back.data == Data("yy".utf8))
    }
}


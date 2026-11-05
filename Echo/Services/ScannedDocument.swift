import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A document scanned in the composer (Add → Scan Document), as it goes to the agent: one PDF of
/// its pages where the chat takes files (the Dashboard, or the Hermes API with the Dashboard's
/// login, which puts it on the server), its pages as pictures where it takes only pictures (the
/// Hermes API alone, an OpenAI-compatible server).
///
/// Each page is a JPEG at most `maxEdge` pixels on its long side; the PDF carries those JPEGs as
/// they are (a CGImage made from JPEG data goes into a PDF still compressed), at 200 dpi.
nonisolated enum ScannedDocument {
    static let maxEdge = 2000
    static let quality: CGFloat = 0.7
    /// As pictures, a scan this long is cut short: past it, a run gets too big to send.
    static let pictureLimit = 10
    /// Smaller and rougher, in turn, until the PDF fits under the attachment limit.
    static let steps: [(edge: Int, quality: CGFloat)] = [(maxEdge, quality), (maxEdge, 0.5), (1600, 0.5), (1200, 0.45)]

    /// The PDF, made small enough to attach; throws `tooLarge` when even the smallest step isn't.
    static func pdfAttachment(pages: [CGImage], date: Date = .now, limit: Int = Attachment.maxFileBytes) throws -> Attachment {
        let name = filename(date, ext: "pdf")
        for step in steps {
            guard let data = pdf(pages: pages, title: name, maxEdge: step.edge, quality: step.quality) else { break }
            if data.count <= limit { return Attachment(kind: .pdf, filename: name, mimeType: "application/pdf", data: data) }
        }
        throw AttachmentError.tooLarge(name)
    }

    /// The pages as pictures, at most `pictureLimit` of them, named after the scan and its page.
    static func pictureAttachments(pages: [CGImage], date: Date = .now) -> [Attachment] {
        pages.prefix(pictureLimit).enumerated().compactMap { index, page in
            guard let data = jpeg(page, maxEdge: maxEdge, quality: 0.8) else { return nil }
            let name = filename(date, ext: "jpg", page: pages.count > 1 ? index + 1 : nil)
            return Attachment(kind: .image, filename: name, mimeType: "image/jpeg", data: data)
        }
    }

    /// One PDF page per scanned page, each the page's JPEG at 200 dpi.
    static func pdf(pages: [CGImage], title: String, maxEdge: Int = maxEdge, quality: CGFloat = quality) -> Data? {
        guard !pages.isEmpty else { return nil }
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else { return nil }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Redde"] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &box, info) else { return nil }
        for page in pages {
            guard let data = jpeg(page, maxEdge: maxEdge, quality: quality),
                  let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { return nil }
            var media = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / 200, height: CGFloat(image.height) * 72 / 200)
            context.beginPage(mediaBox: &media)
            context.draw(image, in: media)
            context.endPage()
        }
        context.closePDF()
        return out as Data
    }

    /// A page as a JPEG, its long side at most `maxEdge` pixels (never made larger).
    static func jpeg(_ image: CGImage, maxEdge: Int, quality: CGFloat) -> Data? {
        let longest = max(image.width, image.height)
        let scale = min(1, CGFloat(maxEdge) / CGFloat(max(longest, 1)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        var page = image
        if scale < 1 {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            page = scaled
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, page, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// "Scan 2026-11-02 21.14.pdf", "Scan 2026-11-02 21.14 p2.jpg". Digits and dots only in the
    /// date: no slash or colon, whatever the language, so it is a file name on any server.
    static func filename(_ date: Date, ext: String, page: Int? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let word = String(localized: "Scan", comment: "A scanned document's file name, before its date: Scan 2026-11-02 21.14.pdf")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let pageSuffix = page.map { " p\($0)" } ?? ""
        return "\(word) \(formatter.string(from: date))\(pageSuffix).\(ext)"
    }
}

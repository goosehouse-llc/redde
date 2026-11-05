import CoreGraphics
import Foundation
import ImageIO
import PencilKit
import Testing
import UIKit
@testable import Echo

/// Add → Scan Document and Add → Drawing: the scan's PDF (pages kept as JPEG, made smaller until
/// it fits), its pages as pictures, and a drawing cut to what was drawn on a solid ground.
@MainActor
struct ScanAndDrawTests {
    /// A page of noise, so JPEG can't squeeze it to nothing and the size steps get exercised.
    private func page(width: Int, height: Int, seed: UInt64 = 7) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var state = seed
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0 ..< context.bytesPerRow * height {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
        return context.makeImage()!
    }

    private func flat(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private let date = Date(timeIntervalSince1970: 1_793_653_440)   // 2026-11-02, any time zone's day

    /// The top-left pixel, as RGBA, whatever layout the image came in.
    private func corner(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        out.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // The image's top-left pixel lands on the 1 × 1 context.
            context.draw(image, in: CGRect(x: 0, y: -CGFloat(image.height - 1), width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return out
    }

    @Test func aScanIsOnePDFWithAPagePerScannedPageAt200dpi() throws {
        let pdf = try ScannedDocument.pdfAttachment(pages: [flat(width: 3000, height: 4000), flat(width: 2480, height: 3508)], date: date)
        #expect(pdf.kind == .pdf)
        #expect(pdf.mimeType == "application/pdf")
        #expect(pdf.filename.hasPrefix("Scan 2026-11-0"))
        #expect(pdf.filename.hasSuffix(".pdf"))
        let document = try #require(CGPDFDocument(CGDataProvider(data: pdf.data as CFData)!))
        #expect(document.numberOfPages == 2)
        // The first page was cut to 2000 px on its long side: 2000 px at 200 dpi is 720 pt.
        let first = try #require(document.page(at: 1)).getBoxRect(.mediaBox)
        #expect(abs(first.height - 720) < 1)
        #expect(abs(first.width - 540) < 1)
    }

    @Test func pagesStayJPEGInsideThePDF() throws {
        let pdf = try ScannedDocument.pdfAttachment(pages: [page(width: 1200, height: 1600)], date: date)
        // A page kept as JPEG is DCT-encoded in the file, not inflated to raw pixels.
        let text = String(decoding: pdf.data, as: UTF8.self)
        #expect(text.contains("DCTDecode"))
        #expect(pdf.data.count < 1200 * 1600 * 3 / 2)
    }

    @Test func aScanTooBigForTheLimitIsMadeSmallerAndThenRefused() throws {
        let pages = [page(width: 1800, height: 2200)]
        let big = try #require(ScannedDocument.pdf(pages: pages, title: "x"))
        // Under a limit the first step passes, a smaller step is taken and fits.
        let smaller = try ScannedDocument.pdfAttachment(pages: pages, date: date, limit: big.count - 1)
        #expect(smaller.data.count < big.count)
        // Under a limit no step can meet, it is refused as too large.
        #expect(throws: AttachmentError.self) { try ScannedDocument.pdfAttachment(pages: pages, date: date, limit: 10_000) }
    }

    @Test func asPicturesAScanIsItsPagesNamedByPageAndCutShort() {
        let pages = (0 ..< 12).map { _ in flat(width: 3000, height: 4000) }
        let pictures = ScannedDocument.pictureAttachments(pages: pages, date: date)
        #expect(pictures.count == ScannedDocument.pictureLimit)
        #expect(pictures.allSatisfy { $0.kind == .image && $0.mimeType == "image/jpeg" })
        #expect(pictures[1].filename.hasSuffix(" p2.jpg"))
        let source = CGImageSourceCreateWithData(pictures[0].data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 2000)
        // One page has no page number.
        #expect(ScannedDocument.pictureAttachments(pages: [flat(width: 100, height: 100)], date: date)[0].filename.hasSuffix(".jpg"))
        #expect(!ScannedDocument.pictureAttachments(pages: [flat(width: 100, height: 100)], date: date)[0].filename.contains(" p1"))
    }

    @Test func aFileNameHasNoSlashOrColon() {
        let name = ScannedDocument.filename(date, ext: "pdf")
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!DrawingExport.filename(date).contains(":"))
    }

    @Test func aDrawingIsCutToItsStrokesAndAMargin() {
        #expect(DrawingExport.cropRect(CGRect(x: 100.4, y: 50, width: 200, height: 80)) == CGRect(x: 76, y: 26, width: 249, height: 128))
        // The screen's scale, less when that would pass the longest edge allowed.
        #expect(DrawingExport.scale(for: CGRect(x: 0, y: 0, width: 300, height: 200), screenScale: 3) == 3)
        #expect(DrawingExport.scale(for: CGRect(x: 0, y: 0, width: 1280, height: 200), screenScale: 3) == 2)
    }

    private func stroke(from a: CGPoint, to b: CGPoint) -> PKStroke {
        let points = (0 ... 10).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 10
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: Double(i) / 60,
                                 size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))
    }

    @Test func aDrawingIsAnOpaquePNGOfWhatWasDrawn() throws {
        let drawing = PKDrawing(strokes: [stroke(from: CGPoint(x: 200, y: 300), to: CGPoint(x: 400, y: 340))])
        let attachment = try #require(DrawingExport.attachment(drawing, dark: false, screenScale: 2, date: date))
        #expect(attachment.kind == .image)
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.filename.hasSuffix(".png"))
        let image = try #require(UIImage(data: attachment.data)?.cgImage)
        // The strokes' bounds and the margin, at twice the points: about 250 × 90 pt, not the screen.
        #expect(image.width < 600 && image.width > 450)
        #expect(image.height < 250)
        // On a solid ground: a corner (in the margin) is white, not transparent.
        let rgba = corner(image)
        #expect(rgba[0] > 240 && rgba[1] > 240 && rgba[2] > 240 && rgba[3] == 255)
        // Nothing drawn, nothing attached.
        #expect(DrawingExport.attachment(PKDrawing(), dark: false, screenScale: 2) == nil)
    }

    @Test func aDarkDrawingIsOnADarkGround() throws {
        let drawing = PKDrawing(strokes: [stroke(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 60))])
        let data = try #require(DrawingExport.png(drawing, dark: true, screenScale: 1))
        let image = try #require(UIImage(data: data)?.cgImage)
        let rgba = corner(image)
        #expect(rgba[0] < 40 && rgba[1] < 40 && rgba[2] < 40 && rgba[3] == 255)
    }

    @Test func aMarkedUpPhotoKeepsItsSizeAndName() throws {
        let photo = UIImage(cgImage: flat(width: 1200, height: 900))
        let drawing = PKDrawing(strokes: [stroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 150))])
        let marked = try #require(DrawingExport.markedUp(photo, drawing: drawing, imageFrame: CGRect(x: 0, y: 100, width: 400, height: 300),
                                                         filename: "IMG_0412.jpg"))
        #expect(marked.filename == "IMG_0412.jpg")
        let image = try #require(UIImage(data: marked.data)?.cgImage)
        #expect(image.width == 1200 && image.height == 900)
    }
}

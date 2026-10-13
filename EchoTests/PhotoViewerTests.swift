import SwiftUI
import Testing
import UIKit
@testable import Echo

/// How a message's pictures are set out together, and the sums of the viewer's zoom.
struct PhotoViewerTests {
    @Test func picturesAreSetOutByHowManyThereAre() {
        #expect(PhotoCollage.tiles(for: 0).isEmpty && PhotoCollage.tiles(for: 1).isEmpty, "one picture is shown at its own shape")
        #expect(PhotoCollage.tiles(for: 2).count == 2)
        #expect(PhotoCollage.tiles(for: 3).count == 3)
        for count in [4, 5, 9, 40] { #expect(PhotoCollage.tiles(for: count).count == 4, "\(count) pictures have four tiles") }
        #expect(PhotoCollage.hidden(4) == 0 && PhotoCollage.hidden(5) == 1 && PhotoCollage.hidden(12) == 8)

        for count in 2 ... 6 {
            let tiles = PhotoCollage.tiles(for: count)
            // The tiles fill the collage and none lies over another.
            #expect(abs(tiles.map { $0.width * $0.height }.reduce(0, +) - 1) < 0.0001, "\(count) pictures don't fill the collage")
            for (i, a) in tiles.enumerated() {
                #expect(a.minX >= 0 && a.minY >= 0 && a.maxX <= 1.0001 && a.maxY <= 1.0001)
                for b in tiles.dropFirst(i + 1) { #expect(a.intersection(b).width * a.intersection(b).height < 0.0001) }
            }
        }
        // Three: the first is the large one, the whole height.
        let three = PhotoCollage.tiles(for: 3)
        #expect(three[0].height == 1 && three[0].width > three[1].width)
        // Two stand side by side in a collage wider than it is tall; four make a square.
        #expect(PhotoCollage.shape(for: 2) > 1 && PhotoCollage.shape(for: 4) == 1 && PhotoCollage.shape(for: 7) == 1)
    }

    @Test func aPictureIsFittedToTheScreenAndCanBeLookedInto() {
        let screen = CGSize(width: 440, height: 956)
        // A landscape photo is as wide as the screen; a portrait one of the screen's own shape or
        // narrower is as tall.
        let wide = PhotoZoom.fitted(CGSize(width: 1600, height: 1200), in: screen), tall = PhotoZoom.fitted(CGSize(width: 600, height: 2400), in: screen)
        #expect(abs(wide.width - 440) < 0.001 && abs(wide.height - 330) < 0.001)
        #expect(abs(tall.width - 239) < 0.001 && abs(tall.height - 956) < 0.001)
        #expect(PhotoZoom.fitted(.zero, in: screen) == .zero)

        // In as far as twice its own pixels: 1600 across on a 440-point screen at 3x is 1.2 of
        // its pixels fitted, so 2.4, but never less than four times what fits, nor more than twelve.
        #expect(PhotoZoom.most(pixels: CGSize(width: 1600, height: 1200), fitted: CGSize(width: 440, height: 330), screenScale: 3) == 4)
        #expect(abs(PhotoZoom.most(pixels: CGSize(width: 4032, height: 3024), fitted: CGSize(width: 440, height: 330), screenScale: 3) - 6.109) < 0.01)
        #expect(PhotoZoom.most(pixels: CGSize(width: 20000, height: 15000), fitted: CGSize(width: 440, height: 330), screenScale: 3) == 12)
        #expect(PhotoZoom.step(most: 4) == 2.5 && PhotoZoom.step(most: 2) == 2)
    }

    @Test func aDoubleTapZoomsInOnTheSpotTapped() {
        let screen = CGSize(width: 440, height: 956)
        let part = PhotoZoom.target(around: CGPoint(x: 300, y: 100), scale: 2.5, room: screen)
        #expect(abs(part.midX - 300) < 0.001 && abs(part.midY - 100) < 0.001)
        #expect(abs(part.width - 176) < 0.001 && abs(part.height - 382.4) < 0.001, "what fills the screen at two and a half times")
    }

    @Test func aPictureSmallerThanTheScreenStaysInTheMiddle() {
        let screen = CGSize(width: 440, height: 956)
        let fitted = PhotoZoom.margins(content: CGSize(width: 440, height: 330), room: screen)
        #expect(fitted.top == 313 && fitted.bottom == 313 && fitted.left == 0 && fitted.right == 0)
        // Zoomed past the screen both ways, it needs none.
        #expect(PhotoZoom.margins(content: CGSize(width: 1100, height: 1200), room: screen) == .zero)
    }

    /// The viewer is given an attachment's picture at full size, not the thumbnail of its tile.
    @MainActor @Test func anAttachmentIsOpenedAtFullSize() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: format).jpegData(withCompressionQuality: 0.7) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        }
        let attachment = Echo.Attachment(kind: .image, filename: "photo-1.jpg", mimeType: "image/jpeg", data: jpeg)
        let photo = ViewerPhoto(attachment)
        // Its file name is what VoiceOver calls it, and is not written under the picture.
        #expect(photo.id == attachment.id.uuidString && photo.name == "photo-1.jpg" && photo.caption.isEmpty)
        // A picture from a reply's text keeps the words the reply gave it.
        let named = ViewerPhoto(id: "image", caption: "The floor plan", image: UIImage())
        #expect(named.caption == "The floor plan" && named.name == "The floor plan")
        #expect(ViewerPhoto(id: "image", image: UIImage()).name == "Photo")
        let image = try #require(await photo.load())
        #expect(image.size.width * image.scale == 1600)
        // Something that is not a picture gives none, and the page says so.
        #expect(await ViewerPhoto(Echo.Attachment(kind: .image, filename: "broken.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3]))).load() == nil)
    }
}

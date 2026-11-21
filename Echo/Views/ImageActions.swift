import Photos
import SwiftUI

/// What can be done with a picture in the chat, in its hold menu and in the viewer: copy it, save
/// it to Photos, share it (an App Store review, 2026-11-17: "i create a image with gpt there is no
/// download option on image just copy, i just send it to tailscale"). Share's sheet has Save
/// Image, Files and AirDrop too.
struct ImageActions: View {
    let image: UIImage?
    /// The picture as it came (a PNG stays one in Photos); nil to save `image` as a PNG.
    var data: Data? = nil
    @Environment(Toaster.self) private var toaster: Toaster?

    var body: some View {
        if let image {
            Button("Copy image", systemImage: "doc.on.doc") { UIPasteboard.general.image = image }
            Button {
                Task { toaster?.show(await SavedPictures.save(image, data: data)) }
            } label: {
                Label { Text("Save to Photos", comment: "A picture's menu: saves it to the Photos library") } icon: { Image(systemName: "square.and.arrow.down") }
            }
            ShareLink(item: Image(uiImage: image), preview: SharePreview(Text("Image", comment: "Sharing a picture: its name in the share sheet"), image: Image(uiImage: image))) {
                Label { Text("Share…", comment: "A picture's menu: the share sheet (Save Image, AirDrop, Files)") } icon: { Image(systemName: "square.and.arrow.up") }
            }
        }
    }
}

/// Pictures saved to the Photos library, asking only to add to it.
enum SavedPictures {
    /// Saves it, and says how that went, for a toast.
    static func save(_ image: UIImage, data: Data?) async -> String {
        let allowed = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard allowed == .authorized || allowed == .limited else {
            return String(localized: "Redde may not add to Photos. Allow it in Settings › Redde › Photos.", comment: "Saving a picture: Photos access was refused")
        }
        guard let bytes = data ?? image.pngData() else {
            return String(localized: "That picture couldn't be saved.", comment: "Saving a picture failed")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: bytes, options: nil)
            }
            return String(localized: "Saved to Photos", comment: "Saving a picture: done")
        } catch {
            return String(localized: "That picture couldn't be saved.", comment: "Saving a picture failed")
        }
    }
}

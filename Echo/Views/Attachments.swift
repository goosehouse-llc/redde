import AVFoundation
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Pending attachments above the composer: thumbnails for images, chips for files, each removable.
struct AttachmentStrip: View {
    let attachments: [Attachment]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    ZStack(alignment: .topTrailing) {
                        AttachmentTile(attachment: att, size: 64)
                        Button { remove(att.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("Remove \(att.filename)")
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}

/// Attachments shown with a message. A lone image displays as a photo bubble, like a received
/// picture message; several show as tiles. Images open full screen on tap, out of the thumbnail
/// that was tapped and back into it.
struct AttachmentGallery: View {
    let attachments: [Attachment]
    @State private var viewing: Attachment?
    @State private var previewingDoc: Attachment?
    @Namespace private var zoom

    var body: some View {
        Group {
            if attachments.count == 1, attachments[0].kind == .image {
                PhotoBubble(attachment: attachments[0]) { viewing = attachments[0] }
                    .matchedTransitionSource(id: attachments[0].id, in: zoom) { $0.clipShape(.rect(cornerRadius: 14)) }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { att in
                            AttachmentTile(attachment: att, size: 120)
                                .matchedTransitionSource(id: att.id, in: zoom) { $0.clipShape(.rect(cornerRadius: 12)) }
                                .onTapGesture {
                                    if att.kind == .image { viewing = att } else { previewingDoc = att }
                                }
                        }
                    }
                }
            }
        }
        .fullScreenCover(item: $viewing) { att in
            if let image = UIImage(data: att.data) {
                ZoomableImage(image: image, caption: att.filename)
                    .navigationTransition(.zoom(sourceID: att.id, in: zoom))
            }
        }
        .sheet(item: $previewingDoc) { DocumentPreview(attachment: $0).ignoresSafeArea() }
    }
}

/// QuickLook for a document attachment; the bytes go to a temp file so QL can render them,
/// and its share button covers saving to Files.
struct DocumentPreview: UIViewControllerRepresentable {
    let attachment: Attachment

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(attachment: Attachment) {
            let dir = FileManager.default.temporaryDirectory.appending(path: "previews")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appending(path: attachment.filename)
            try? attachment.data.write(to: url)
        }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }

    func makeCoordinator() -> Coordinator { Coordinator(attachment: attachment) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
}

/// The system camera for one photo. PhotosPicker can't take pictures, so this wraps
/// UIImagePickerController; `onCapture` gets the shot, or nothing if you cancel.
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCapture(nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
}

/// One image, shown big: scaled to fit, tap for the zoomable viewer.
/// ImageIO thumbnailing: decodes only what's needed for `maxPixel` instead of the full image.
nonisolated enum ImageThumbnail {
    static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The one attachment-thumbnail loader: decodes off the main actor, once per attachment
/// (attachment bytes may live on disk, so the read stays inside the detached task), and hands
/// the image to `content`; `placeholder` shows until it lands.
struct ThumbnailImage<Content: View, Placeholder: View>: View {
    let attachment: Attachment
    let maxPixel: CGFloat
    @ViewBuilder let content: (UIImage) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var thumb: UIImage?

    var body: some View {
        Group {
            if let thumb { content(thumb) } else { placeholder() }
        }
        .task(id: attachment.id) {
            guard thumb == nil else { return }
            let att = attachment, px = maxPixel
            thumb = await Task.detached(priority: .utility) { ImageThumbnail.decode(att.data, maxPixel: px) }.value
        }
    }
}

struct PhotoBubble: View {
    let attachment: Attachment
    let open: () -> Void

    var body: some View {
        ThumbnailImage(attachment: attachment, maxPixel: 1200) { image in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 300, maxHeight: 340, alignment: .leading)
                .clipShape(.rect(cornerRadius: 14))
                .onTapGesture(perform: open)
                .contextMenu {
                    Button("Copy image", systemImage: "doc.on.doc") { UIPasteboard.general.image = UIImage(data: attachment.data) }
                }
        } placeholder: {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 220, height: 160)
                .overlay(ProgressView())
        }
        .accessibilityLabel(attachment.filename)
        .accessibilityAddTraits(.isImage)
    }
}

/// A video's first frame, for its tile. Made once per attachment, from a copy of its bytes in
/// the temporary folder (the frame is read from a file, and by its extension), and kept for
/// this run.
nonisolated enum VideoPoster {
    // NSCache is thread-safe by contract; the annotation just tells Swift so.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static func image(for attachment: Attachment, maxPixel: CGFloat) async -> UIImage? {
        let key = attachment.id.uuidString as NSString
        if let kept = cache.object(forKey: key) { return kept }
        guard let made = await make(from: attachment.data, filename: attachment.filename, maxPixel: maxPixel) else { return nil }
        cache.setObject(made, forKey: key)
        return made
    }

    static func make(from data: Data, filename: String, maxPixel: CGFloat) async -> UIImage? {
        let kind = (filename as NSString).pathExtension
        let url = FileManager.default.temporaryDirectory.appending(path: "poster-\(UUID().uuidString).\(kind.isEmpty ? "mp4" : kind)")
        guard (try? data.write(to: url)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true   // upright, however the phone was held
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        guard let frame = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: frame)
    }
}

/// A video attachment: its first frame under a play mark, or the mark alone when no frame can
/// be read from it.
struct VideoTile: View {
    let attachment: Attachment
    let size: CGFloat
    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            if let poster {
                Image(uiImage: poster).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.06)
            }
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.2))
                .foregroundStyle(.white)
                .padding(size * 0.12)
                .background(.black.opacity(0.45), in: .circle)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 12))
        .task(id: attachment.id) {
            guard poster == nil else { return }
            let att = attachment, px = size * 3
            poster = await Task.detached(priority: .utility) { await VideoPoster.image(for: att, maxPixel: px) }.value
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video: \(attachment.filename), \(attachment.sizeLabel)")
    }
}

struct AttachmentTile: View {
    let attachment: Attachment
    let size: CGFloat

    var body: some View {
        if attachment.isVideo {
            VideoTile(attachment: attachment, size: size)
        } else if attachment.kind == .image {
            ThumbnailImage(attachment: attachment, maxPixel: size * 3) { image in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel(attachment.filename)
            } placeholder: {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: size, height: size)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "doc.text")
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename).font(.caption.weight(.medium)).lineLimit(1)
                    Text(attachment.sizeLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: size * 0.7)
            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 12))
        }
    }
}

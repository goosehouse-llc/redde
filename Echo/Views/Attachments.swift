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
/// picture message; several show as tiles. Images open full screen on tap.
struct AttachmentGallery: View {
    let attachments: [Attachment]
    @State private var viewing: Attachment?
    @State private var previewingDoc: Attachment?

    var body: some View {
        Group {
            if attachments.count == 1, attachments[0].kind == .image {
                PhotoBubble(attachment: attachments[0]) { viewing = attachments[0] }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { att in
                            AttachmentTile(attachment: att, size: 120)
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

struct AttachmentTile: View {
    let attachment: Attachment
    let size: CGFloat

    var body: some View {
        if attachment.kind == .image {
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

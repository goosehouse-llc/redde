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

/// Attachments shown with a message. Pictures are set out together, as Messages sets out photos
/// sent at once (`PhotoGroup`), and open full screen on a tap, out of the picture that was
/// tapped and back into it. Files and videos are tiles under them. Sound is played where it
/// stands, each file on a bar of its own above the rest.
struct AttachmentGallery: View {
    let attachments: [Attachment]

    var body: some View {
        let sound = attachments.filter(\.isAudio)
        let rest = attachments.filter { !$0.isAudio }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sound) { AudioBubble(attachment: $0) }
            if !rest.isEmpty { AttachmentTiles(attachments: rest) }
        }
    }
}

/// A sound attachment as a player: play or pause, where it has got to, how long it is. A file
/// this phone can't decode is offered as a file instead, to open or share.
struct AudioBubble: View {
    let attachment: Attachment
    @State private var audio = AttachmentAudio.shared
    /// Nil until the file has been looked at; 0 when it can't be played.
    @State private var duration: TimeInterval?
    @State private var previewing = false

    private var isCurrent: Bool { audio.current == attachment.id }
    private var isPlaying: Bool { isCurrent && audio.isPlaying }

    var body: some View {
        Group {
            if duration == 0 {
                AttachmentTile(attachment: attachment, size: 64)
                    .onTapGesture { previewing = true }
                    .sheet(isPresented: $previewing) { DocumentPreview(attachment: attachment).ignoresSafeArea() }
            } else {
                player
            }
        }
        .task(id: attachment.id) {
            guard duration == nil else { return }
            let att = attachment
            duration = await Task.detached(priority: .utility) { AttachmentAudio.duration(of: att) }.value ?? 0
        }
    }

    private var player: some View {
        HStack(spacing: 10) {
            Button { audio.toggle(attachment) } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.16), in: .circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(duration == nil)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            // The clock only runs while this one is playing; at rest the bar costs nothing.
            TimelineView(.periodic(from: .now, by: isPlaying ? 0.1 : 3600)) { _ in
                let length = max(duration ?? 0, 0.01)
                let at = min(audio.position(of: attachment.id), length)
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { at }, set: { audio.seek(attachment, to: $0) }), in: 0 ... length)
                        .accessibilityLabel("Position")
                        .accessibilityValue(Self.clock(at))
                    Text(isCurrent ? Self.clock(at) : Self.clock(duration ?? 0))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(maxWidth: 300)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 22))
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.square") { previewing = true }
        }
        .sheet(isPresented: $previewing) { DocumentPreview(attachment: attachment).ignoresSafeArea() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio: \(attachment.filename)")
    }

    /// "0:07", "12:40".
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// Everything but sound: the pictures together, then a tile for each file and video.
private struct AttachmentTiles: View {
    let attachments: [Attachment]
    @State private var previewingDoc: Attachment?

    var body: some View {
        let pictures = attachments.filter { $0.kind == .image }
        let files = attachments.filter { $0.kind != .image }
        VStack(alignment: .leading, spacing: 8) {
            if !pictures.isEmpty { PhotoGroup(pictures: pictures) }
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(files) { att in
                            AttachmentTile(attachment: att, size: 120)
                                .onTapGesture { previewingDoc = att }
                        }
                    }
                }
            }
        }
        .sheet(item: $previewingDoc) { DocumentPreview(attachment: $0).ignoresSafeArea() }
    }
}

/// How a message's pictures are set out together: two side by side, three as one large and two
/// small, four as a square of four. From five on the fourth tile says how many more there are,
/// and every one of them is in the viewer.
nonisolated enum PhotoCollage {
    /// How many pictures get a tile.
    static let most = 4

    /// The tiles as parts of the whole: where each starts and how much of the width and the
    /// height it takes. One picture is not a collage (`PhotoBubble` shows it at its own shape).
    static func tiles(for count: Int) -> [CGRect] {
        switch count {
        case ...1: []
        case 2: [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case 3: [CGRect(x: 0, y: 0, width: 0.6, height: 1), CGRect(x: 0.6, y: 0, width: 0.4, height: 0.5), CGRect(x: 0.6, y: 0.5, width: 0.4, height: 0.5)]
        default: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                  CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        }
    }

    /// The whole collage's width for a height of one.
    static func shape(for count: Int) -> CGFloat {
        switch count {
        case 2: 1.5
        case 3: 4.0 / 3
        default: 1
        }
    }

    /// The pictures that have no tile of their own.
    static func hidden(_ count: Int) -> Int { max(0, count - most) }
}

/// A message's pictures: one at its own shape, several as a collage. A tap opens the viewer on
/// the picture tapped, with the others a swipe away.
struct PhotoGroup: View {
    let pictures: [Attachment]
    @State private var open = false
    @State private var showing: String?
    @Namespace private var zoom

    private static let width: CGFloat = 300
    private static let gap: CGFloat = 3

    var body: some View {
        Group {
            if pictures.count == 1 {
                PhotoBubble(attachment: pictures[0]) { show(pictures[0]) }
                    .matchedTransitionSource(id: pictures[0].id.uuidString, in: zoom) { $0.clipShape(.rect(cornerRadius: 14)) }
            } else {
                collage
            }
        }
        .fullScreenCover(isPresented: $open) {
            PhotoViewer(photos: pictures.map { ViewerPhoto($0) }, showing: $showing)
                .navigationTransition(.zoom(sourceID: source, in: zoom))
        }
    }

    private func show(_ picture: Attachment) {
        showing = picture.id.uuidString
        open = true
    }

    /// The tile the viewer closes back into: the showing picture's own, or the last tile for a
    /// picture that has none.
    private var source: String {
        let tiled = pictures.prefix(PhotoCollage.most).map(\.id.uuidString)
        return showing.flatMap { tiled.contains($0) ? $0 : nil } ?? tiled.last ?? ""
    }

    private var collage: some View {
        let tiles = PhotoCollage.tiles(for: pictures.count), hidden = PhotoCollage.hidden(pictures.count)
        return Color.clear
            .aspectRatio(PhotoCollage.shape(for: pictures.count), contentMode: .fit)
            .frame(maxWidth: Self.width)
            .overlay {
                GeometryReader { room in
                    ForEach(Array(zip(pictures, tiles).enumerated()), id: \.element.0.id) { index, pair in
                        let (picture, tile) = pair
                        let frame = CGRect(x: tile.minX * room.size.width, y: tile.minY * room.size.height,
                                           width: tile.width * room.size.width, height: tile.height * room.size.height)
                            .insetBy(dx: Self.gap / 2, dy: Self.gap / 2)
                        ThumbnailImage(attachment: picture, maxPixel: 720) { image in
                            Image(uiImage: image).resizable().scaledToFill()
                        } placeholder: {
                            Color.primary.opacity(0.06)
                        }
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(.rect(cornerRadius: 4))
                        .overlay {
                            // The last tile stands for the pictures that have none.
                            if hidden > 0, index == tiles.count - 1 {
                                ZStack {
                                    Color.black.opacity(0.5)
                                    Text("+\(hidden)").font(.title.weight(.semibold)).foregroundStyle(.white)
                                }
                                .clipShape(.rect(cornerRadius: 4))
                            }
                        }
                        .contentShape(.rect)
                        .matchedTransitionSource(id: picture.id.uuidString, in: zoom) { $0.clipShape(.rect(cornerRadius: 4)) }
                        .onTapGesture { show(picture) }
                        .contextMenu {
                            Button("Copy image", systemImage: "doc.on.doc") { UIPasteboard.general.image = UIImage(data: picture.data) }
                        }
                        .position(x: frame.midX, y: frame.midY)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(hidden > 0 && index == tiles.count - 1
                            ? "Photo \(index + 1) of \(pictures.count), and \(hidden) more"
                            : "Photo \(index + 1) of \(pictures.count)")
                        .accessibilityAddTraits([.isImage, .isButton])
                        .accessibilityIdentifier("photo-tile-\(index + 1)")
                    }
                }
            }
            // The outer corners are the bubble's; the gaps between tiles show the page.
            .clipShape(.rect(cornerRadius: 14))
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
                Image(systemName: attachment.isAudio ? "waveform" : attachment.kind == .pdf ? "doc.richtext" : "doc.text")
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

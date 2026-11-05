#if os(iOS)
import AVFoundation
import PencilKit
import SwiftUI
import VisionKit

/// The system's document camera (Add → Scan Document): edges found, pages straightened, as many
/// as you like. `onFinish` gets the pages, or nothing if you cancel. Not on the simulator or a Mac
/// (`isAvailable`).
struct DocumentScanner: UIViewControllerRepresentable {
    var onFinish: ([UIImage]?) -> Void

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]?) -> Void
        init(onFinish: @escaping ([UIImage]?) -> Void) { self.onFinish = onFinish }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0 ..< scan.pageCount).map { scan.imageOfPage(at: $0) })
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onFinish(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { onFinish(nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
}

/// A drawing as it is attached: a PNG of what was drawn and a margin round it, on a solid
/// background in the look it was drawn in (black ink on white, or PencilKit's light ink on dark),
/// so a model never gets ink on a transparent ground it can't see. A marked-up photo is the photo
/// with the drawing over it, at the photo's own size.
enum DrawingExport {
    static let margin: CGFloat = 24
    static let maxEdge: CGFloat = 2560
    static let darkGround = UIColor(white: 0.11, alpha: 1)

    /// What is cut out: the strokes' bounds and the margin, on whole points.
    static func cropRect(_ bounds: CGRect, margin: CGFloat = margin) -> CGRect {
        bounds.insetBy(dx: -margin, dy: -margin).integral
    }

    /// The scale it is drawn at: the screen's, less when that would pass `maxEdge` pixels.
    static func scale(for rect: CGRect, screenScale: CGFloat, maxEdge: CGFloat = maxEdge) -> CGFloat {
        let longest = max(rect.width, rect.height, 1)
        return min(screenScale, maxEdge / longest)
    }

    /// The drawing as a PNG, or nil when nothing was drawn.
    static func png(_ drawing: PKDrawing, dark: Bool, screenScale: CGFloat) -> Data? {
        guard !drawing.strokes.isEmpty, !drawing.bounds.isEmpty else { return nil }
        let rect = cropRect(drawing.bounds)
        let scale = scale(for: rect, screenScale: screenScale)
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
            ink = drawing.image(from: rect, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            (dark ? darkGround : .white).setFill()
            context.fill(CGRect(origin: .zero, size: rect.size))
            ink.draw(in: CGRect(origin: .zero, size: rect.size))
        }
        return image.pngData()
    }

    static func attachment(_ drawing: PKDrawing, dark: Bool, screenScale: CGFloat, date: Date = .now) -> Attachment? {
        guard let data = png(drawing, dark: dark, screenScale: screenScale) else { return nil }
        return Attachment(kind: .image, filename: filename(date), mimeType: "image/png", data: data)
    }

    /// The photo with the drawing over it. `imageFrame` is where the photo was shown on the
    /// canvas, in the drawing's points.
    static func markedUp(_ photo: UIImage, drawing: PKDrawing, imageFrame: CGRect, filename: String) -> Attachment? {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        let size = photo.size
        let longest = max(size.width, size.height, 1)
        let fit = min(1, maxEdge / longest)
        let target = CGSize(width: size.width * fit, height: size.height * fit)
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: imageFrame, scale: target.width / imageFrame.width)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            photo.draw(in: CGRect(origin: .zero, size: target))
            ink.draw(in: CGRect(origin: .zero, size: target))
        }
        return Attachment.image(image, filename: filename)
    }

    /// "Drawing 2026-11-02 21.14.png", in the scan's way of naming (`ScannedDocument.filename`).
    static func filename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let word = String(localized: "Drawing", comment: "A drawing's file name, before its date: Drawing 2026-11-02 21.14.png")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(word) \(formatter.string(from: date)).png"
    }
}

/// Draw something to attach (Add → Drawing), or draw over an attached photo (Mark Up): full
/// screen, finger or Apple Pencil, the system's tool picker (floating on an iPad). Done attaches
/// it; Cancel leaves nothing.
struct DrawingSheet: View {
    /// The photo being marked up; nil for a drawing of its own.
    var photo: UIImage? = nil
    /// The marked-up photo's name, kept.
    var photoName: String = "photo.jpg"
    var onFinish: (Attachment?) -> Void

    @State private var canvas = DrawingCanvasModel()
    @State private var hasStrokes = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        NavigationStack {
            DrawingCanvas(model: canvas, photo: photo) { hasStrokes = $0 }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(photo == nil ? String(localized: "Drawing") : String(localized: "Mark Up"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onFinish(nil) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onFinish(export()) }
                            .disabled(!hasStrokes)
                    }
                }
        }
    }

    private func export() -> Attachment? {
        let drawing = canvas.drawing
        if let photo {
            return DrawingExport.markedUp(photo, drawing: drawing, imageFrame: canvas.imageFrame, filename: photoName)
        }
        return DrawingExport.attachment(drawing, dark: scheme == .dark, screenScale: displayScale)
    }
}

/// What the drawing view hands back: the drawing, and where a photo under it sits.
@MainActor final class DrawingCanvasModel {
    weak var host: DrawingCanvasHost?
    var drawing: PKDrawing { host?.canvas.drawing ?? PKDrawing() }
    var imageFrame: CGRect { host?.imageFrame ?? .zero }
}

/// A PencilKit canvas over an optional photo, with the tool picker shown while it is on screen.
struct DrawingCanvas: UIViewRepresentable {
    let model: DrawingCanvasModel
    var photo: UIImage?
    var changed: (Bool) -> Void

    func makeUIView(context: Context) -> DrawingCanvasHost {
        let host = DrawingCanvasHost(photo: photo)
        host.canvas.delegate = context.coordinator
        model.host = host
        return host
    }
    func updateUIView(_ host: DrawingCanvasHost, context: Context) { context.coordinator.changed = changed }
    func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var changed: (Bool) -> Void
        init(changed: @escaping (Bool) -> Void) { self.changed = changed }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { changed(!canvasView.drawing.strokes.isEmpty) }
    }
}

final class DrawingCanvasHost: UIView {
    let canvas = PKCanvasView()
    private let photoView = UIImageView()
    private let toolPicker = PKToolPicker()
    private let photo: UIImage?

    init(photo: UIImage?) {
        self.photo = photo
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        if let photo {
            photoView.image = photo
            photoView.contentMode = .scaleAspectFit
            addSubview(photoView)
            // On a photo, ink is drawn as it will be sent: PencilKit's dark-mode ink swap is off.
            canvas.overrideUserInterfaceStyle = .light
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
        } else {
            canvas.backgroundColor = .systemBackground
        }
        canvas.drawingPolicy = .anyInput   // a finger draws too, not only Apple Pencil
        canvas.alwaysBounceVertical = false
        addSubview(canvas)
        toolPicker.addObserver(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Where the photo is shown, in the canvas's points (the drawing's).
    var imageFrame: CGRect {
        guard let photo else { return .zero }
        return AVMakeRect(aspectRatio: photo.size, insideRect: bounds)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        photoView.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }
}
#endif

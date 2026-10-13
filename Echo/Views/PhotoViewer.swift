import SwiftUI
import UIKit

/// A picture as the full-screen viewer takes it: its place among the others, what to call it,
/// and how to get it at full size (off the main actor: it may be read from disk and decoded).
struct ViewerPhoto: Identifiable {
    let id: String
    /// Words shown under the picture: what a reply called it. Empty for a photo, whose file
    /// name says nothing worth reading.
    var caption: String = ""
    /// What VoiceOver calls it.
    var name: String = "Photo"
    let load: @Sendable () async -> UIImage?

    /// A picture that is in memory already.
    init(id: String, caption: String = "", image: UIImage) {
        self.id = id
        self.caption = caption
        if !caption.isEmpty { name = caption }
        load = { image }
    }

    /// An image attachment, decoded when its page is first shown.
    init(_ attachment: Attachment) {
        id = attachment.id.uuidString
        name = attachment.filename
        load = { ImageThumbnail.decode(attachment.data, maxPixel: 4096) }
    }
}

/// Pictures full screen, as Messages and Photos show them: swipe sideways from one to the next,
/// pinch or double-tap to zoom, drag a zoomed picture about, tap to clear the screen of
/// everything but the picture. Closing is the Close button, or the system's own gestures for a
/// view that opened out of a thumbnail (drag it down, or pinch it shut).
///
/// `showing` is the picture on screen, so whoever presents the viewer can have it close back
/// into that picture's thumbnail.
struct PhotoViewer: View {
    let photos: [ViewerPhoto]
    @Binding var showing: String?
    @Environment(\.dismiss) private var dismiss
    @State private var bare = false

    private var place: Int? { photos.firstIndex { $0.id == showing } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PhotoPager(photos: photos, showing: $showing) { bare.toggle() }
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) { if !bare { bar } }
        .overlay(alignment: .bottom) {
            if !bare, let caption = place.map({ photos[$0].caption }), !caption.isEmpty {
                Text(caption).font(.footnote).foregroundStyle(.white).lineLimit(2)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.5), in: .capsule).padding()
            }
        }
        .animation(.easeOut(duration: 0.18), value: bare)
        .statusBarHidden(bare)
        .onAppear { if showing == nil { showing = photos.first?.id } }
    }

    /// Which picture of how many, and the way out.
    private var bar: some View {
        ZStack {
            if photos.count > 1, let place {
                Text("\(place + 1) of \(photos.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: .capsule)
                    .accessibilityLabel("Photo \(place + 1) of \(photos.count)")
                    .accessibilityIdentifier("photo-count")
            }
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.9))
                }
                .accessibilityLabel("Close")
            }
        }
        .padding()
        .transition(.opacity)
    }
}

/// The pages, one picture each, turned by a swipe. See `PhotoPagerController`.
private struct PhotoPager: UIViewControllerRepresentable {
    let photos: [ViewerPhoto]
    @Binding var showing: String?
    let tapped: () -> Void

    func makeUIViewController(context: Context) -> PhotoPagerController {
        let pager = PhotoPagerController(photos: photos, start: photos.firstIndex { $0.id == showing } ?? 0)
        update(pager)
        return pager
    }

    func updateUIViewController(_ pager: PhotoPagerController, context: Context) { update(pager) }

    private func update(_ pager: PhotoPagerController) {
        pager.tapped = tapped
        pager.turned = { index in if photos.indices.contains(index) { showing = photos[index].id } }
    }
}

/// A row of pages in a scroll view that stops on each, with the pictures of the page showing
/// and the ones beside it in memory and no others. Written out, not UIKit's page view
/// controller or a SwiftUI scroll view, because of two things found with the UI test:
///
/// - a SwiftUI scroll view that pages opened on the first picture whichever it was told to show;
/// - the system closes a view that opened out of a thumbnail on a swipe back (a drag to the
///   right) unless a scroll view under the finger still has somewhere to go that way. The page
///   view controller keeps one page in its scroll view until a drag is under way, so it never
///   has: going to the picture before closed the viewer or did nothing. Here every page has its
///   place in the row from the start, so the system can see there is one before. On the first
///   picture a swipe back closes the viewer, as it does anywhere else in iOS.
final class PhotoPagerController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let photos: [ViewerPhoto]
    private(set) var index: Int
    var tapped: (() -> Void)?
    /// The page showing is another one.
    var turned: ((Int) -> Void)?

    private let row = UIScrollView()
    private var pages: [Int: PhotoPageView] = [:]
    private var laidOutFor = CGSize.zero
    /// The dark between two pictures while a page turns.
    private static let gap: CGFloat = 16

    init(photos: [ViewerPhoto], start: Int) {
        self.photos = photos
        index = min(max(start, 0), max(photos.count - 1, 0))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("made in code") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        row.isPagingEnabled = true
        row.showsHorizontalScrollIndicator = false
        row.showsVerticalScrollIndicator = false
        row.contentInsetAdjustmentBehavior = .never
        row.alwaysBounceHorizontal = photos.count > 1
        row.delegate = self
        view.addSubview(row)

        // While a picture is zoomed in, a drag moves about in it and must not close the
        // viewer when it comes to the picture's edge. This takes every drag for as long as
        // the picture is zoomed and does nothing with it; the system's gestures for closing
        // have to wait for it to fail, which it does at once when the picture is whole.
        let held = UIPanGestureRecognizer(target: self, action: #selector(heldWhileZoomed))
        held.delegate = self
        held.cancelsTouchesInView = false
        view.addGestureRecognizer(held)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != laidOutFor, view.bounds.width > 0 else { return }
        laidOutFor = view.bounds.size
        // The row is wider than the screen by the gap, half of it off each side, so that a
        // page is the screen plus the gap and the gap is only seen while a page turns.
        row.delegate = nil
        row.frame = view.bounds.insetBy(dx: -Self.gap / 2, dy: 0)
        row.contentSize = CGSize(width: row.bounds.width * CGFloat(photos.count), height: row.bounds.height)
        row.contentOffset = CGPoint(x: row.bounds.width * CGFloat(index), y: 0)
        row.delegate = self
        place()
    }

    /// Puts the page showing and its neighbors where they belong, and lets the others go.
    private func place() {
        guard !photos.isEmpty else { return }
        let wanted = max(index - 1, 0) ... min(index + 1, photos.count - 1)
        for (at, page) in pages where !wanted.contains(at) {
            page.removeFromSuperview()
            pages[at] = nil
        }
        for at in wanted {
            let page = pages[at] ?? {
                let made = PhotoPageView(photo: photos[at]) { [weak self] in self?.tapped?() }
                row.addSubview(made)
                pages[at] = made
                return made
            }()
            page.frame = CGRect(x: row.bounds.width * CGFloat(at) + Self.gap / 2, y: 0, width: view.bounds.width, height: view.bounds.height)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard row.bounds.width > 0 else { return }
        let now = min(max(Int((row.contentOffset.x / row.bounds.width).rounded()), 0), photos.count - 1)
        guard now != index else { return }
        // Paged away from, a picture is whole again when it comes back.
        pages[index]?.picture.setZoomScale(1, animated: false)
        index = now
        place()
        turned?(now)
    }

    @objc private func heldWhileZoomed() {}

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (pages[index]?.picture.zoomScale ?? 1) > 1.01
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // The system's gestures for closing the viewer sit on the view that presents it. Not
        // the scroll views (the row, a zoomed picture), not taps, and not the window's own.
        guard let on = other.view, !(on is UIScrollView), !(on is UIWindow) else { return false }
        return !(other is UITapGestureRecognizer) && !(other is UILongPressGestureRecognizer)
    }
}

/// One page of the viewer: the picture once it has been read, a spinner until then.
final class PhotoPageView: UIView {
    let picture = ZoomingPictureView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var reading: Task<Void, Never>?

    init(photo: ViewerPhoto, tapped: @escaping () -> Void) {
        super.init(frame: .zero)
        backgroundColor = .black
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        picture.tapped = tapped
        addSubview(picture)
        spinner.color = .white
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        spinner.startAnimating()
        addSubview(spinner)
        reading = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { await photo.load() }.value
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimating()
            if let image { self.picture.show(image, name: photo.name) } else { self.sayItFailed() }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("made in code") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if picture.frame != bounds { picture.frame = bounds }
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func removeFromSuperview() {
        reading?.cancel()
        super.removeFromSuperview()
    }

    private func sayItFailed() {
        let words = UILabel()
        words.text = "This picture couldn't be opened"
        words.textColor = UIColor.white.withAlphaComponent(0.7)
        words.font = .preferredFont(forTextStyle: .body)
        words.sizeToFit()
        words.center = CGPoint(x: bounds.midX, y: bounds.midY)
        words.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        addSubview(words)
    }
}

/// The sums of the zooming picture, apart from the views so they can be checked.
nonisolated enum PhotoZoom {
    /// A picture of `picture` points made as large as fits `room`, keeping its shape.
    static func fitted(_ picture: CGSize, in room: CGSize) -> CGSize {
        guard picture.width > 0, picture.height > 0, room.width > 0, room.height > 0 else { return .zero }
        let scale = min(room.width / picture.width, room.height / picture.height)
        return CGSize(width: picture.width * scale, height: picture.height * scale)
    }

    /// How far in the picture goes: to twice its own pixels, and never less than four times
    /// what fits, so a small picture can still be looked into.
    static func most(pixels: CGSize, fitted: CGSize, screenScale: CGFloat) -> CGFloat {
        guard fitted.width > 0 else { return 4 }
        let ownSize = pixels.width / (fitted.width * max(screenScale, 1))
        return min(max(4, ownSize * 2), 12)
    }

    /// What a double tap zooms to: two and a half times, or all the way if that is less.
    static func step(most: CGFloat) -> CGFloat { min(2.5, most) }

    /// The part of the picture to show after a double tap at `point` (in the picture's own
    /// coordinates), so that the spot tapped ends up in the middle.
    static func target(around point: CGPoint, scale: CGFloat, room: CGSize) -> CGRect {
        let size = CGSize(width: room.width / scale, height: room.height / scale)
        return CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
    }

    /// The margins that keep a picture smaller than the room in the middle of it.
    static func margins(content: CGSize, room: CGSize) -> UIEdgeInsets {
        let across = max(0, (room.width - content.width) / 2), down = max(0, (room.height - content.height) / 2)
        return UIEdgeInsets(top: down, left: across, bottom: down, right: across)
    }
}

/// A picture that zooms and pans, in a scroll view of UIKit's. Not a SwiftUI gesture: the
/// system's gesture for closing a view that opened out of a thumbnail (pinch it shut) takes a
/// pinch away from one, so the picture never zoomed. It gives way to a scroll view that can
/// zoom, and a scroll view also gets the rest right, from the bounce at the limits to passing
/// a sideways drag on to the pager when there is nothing left to pan.
final class ZoomingPictureView: UIScrollView, UIScrollViewDelegate {
    private let picture = UIImageView()
    private var laidOutFor = CGSize.zero
    var tapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        // With nothing to pan there is nothing to bounce: a drag is the pager's, or the
        // system's for closing the viewer.
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        picture.contentMode = .scaleAspectFit
        picture.isAccessibilityElement = true
        picture.accessibilityTraits = .image
        picture.accessibilityIdentifier = "photo"
        addSubview(picture)

        let twice = UITapGestureRecognizer(target: self, action: #selector(tappedTwice))
        twice.numberOfTapsRequired = 2
        addGestureRecognizer(twice)
        let once = UITapGestureRecognizer(target: self, action: #selector(tappedOnce))
        once.require(toFail: twice)
        addGestureRecognizer(once)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("made in code") }

    func show(_ image: UIImage, name: String) {
        picture.accessibilityLabel = name
        guard picture.image !== image else { return }
        picture.image = image
        laidOutFor = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A new picture, or a new shape of screen: start again from the whole picture.
        guard bounds.size != laidOutFor, let image = picture.image, bounds.width > 0, bounds.height > 0 else { return }
        laidOutFor = bounds.size
        minimumZoomScale = 1
        maximumZoomScale = 1
        zoomScale = 1
        let fitted = PhotoZoom.fitted(image.size, in: bounds.size)
        picture.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        maximumZoomScale = PhotoZoom.most(pixels: pixels, fitted: fitted, screenScale: traitCollection.displayScale)
        settle()
    }

    private func settle() {
        contentInset = PhotoZoom.margins(content: contentSize, room: bounds.size)
        let zoomed = zoomScale > 1.01
        picture.accessibilityValue = zoomed ? "Zoomed in, \(Int((zoomScale * 100).rounded())) percent" : ""
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { settle() }

    @objc private func tappedOnce() { tapped?() }

    @objc private func tappedTwice(_ tap: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            zoom(to: PhotoZoom.target(around: tap.location(in: picture), scale: PhotoZoom.step(most: maximumZoomScale), room: bounds.size), animated: true)
        }
    }
}

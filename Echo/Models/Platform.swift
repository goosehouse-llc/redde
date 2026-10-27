import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The platform's own image and colour types, for the code the iPhone and the Mac share
/// (`ReddeMac`): UIKit's on the iPhone, AppKit's on the Mac.
#if canImport(UIKit)
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#else
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#endif

#if !canImport(UIKit)
/// The few UIImage ways the shared code uses, on the Mac's NSImage.
extension NSImage {
    nonisolated convenience init(cgImage: CGImage) { self.init(cgImage: cgImage, size: .zero) }

    nonisolated var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }

    nonisolated func pngData() -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    nonisolated func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
#endif

/// Whether Redde is the app in front: on the iPhone, active (not in the background, not behind
/// Control Centre); on the Mac, the active app.
@MainActor
enum AppState {
    static var isActive: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        NSApplication.shared.isActive
        #endif
    }

    /// The device's files can be read: the iPhone is unlocked (or has been since it started).
    /// A Mac app runs only while its person is signed in, so on the Mac always.
    static var isProtectedDataAvailable: Bool {
        #if canImport(UIKit)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }

    /// Asks Apple's push service for this device's token; it arrives at the app's delegate.
    static func registerForRemoteNotifications() {
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// The device's name, as its person knows it ("Sam's iPhone", the Mac's computer name).
    static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}

// MARK: - The conversation's fonts

extension Font {
    /// A text style as SwiftUI's own constant (`.caption`), with a weight and a design if given:
    /// the font a conversation view always had.
    nonisolated static func chat(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        let base: Font = if let design { .system(style, design: design) } else {
            switch style {
            case .largeTitle: .largeTitle
            case .title: .title
            case .title2: .title2
            case .title3: .title3
            case .headline: .headline
            case .subheadline: .subheadline
            case .callout: .callout
            case .footnote: .footnote
            case .caption: .caption
            case .caption2: .caption2
            default: .body
            }
        }
        return weight.map { base.weight($0) } ?? base
    }
}

extension View {
    /// A font in the conversation: on the iPhone exactly `.font(.caption)` and the like; on the
    /// Mac, at its text zoom (`TextZoom`), which a Mac's text styles don't follow by themselves.
    func chatFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        #if os(macOS)
        modifier(ZoomedFont(style: style, weight: weight, design: design, size: nil))
        #else
        font(.chat(style, weight: weight, design: design))
        #endif
    }

    /// The same for a font of a set size (a card's big figures).
    func chatFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        #if os(macOS)
        modifier(ZoomedFont(style: .body, weight: weight, design: design, size: size))
        #else
        font(.system(size: size, weight: weight, design: design))
        #endif
    }
}

#if os(macOS)
/// `chatFont` on the Mac: the style's size on a Mac (or the set size), times the theme's text
/// zoom; at Actual Size the font it always was.
private struct ZoomedFont: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design?
    let size: CGFloat?
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let scale = theme.textScale
        if let size {
            content.font(.system(size: size * scale, weight: weight ?? .regular, design: design ?? .default))
        } else if scale == 1 {
            content.font(.chat(style, weight: weight, design: design))
        } else {
            content.font(.system(size: TextZoom.points(Self.appKit(style)) * scale, weight: weight ?? Self.weight(style), design: design ?? .default))
        }
    }

    /// The headline is the Mac's bold body.
    private static func weight(_ style: Font.TextStyle) -> Font.Weight { style == .headline ? .bold : .regular }

    private static func appKit(_ style: Font.TextStyle) -> NSFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
#endif

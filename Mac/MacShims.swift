import SwiftUI

// The iPhone's view modifiers that the Mac doesn't have, under the same names, so the views the
// two share compile here unchanged: each does nothing on the Mac, or the Mac's own nearest thing.
// SwiftUI's own are unavailable on macOS, so these are the ones picked.

/// `.navigationBarTitleDisplayMode(.inline)`: a Mac window's title has one size.
enum MacTitleDisplayMode { case automatic, inline, large }

/// `.textInputAutocapitalization(.never)`: a Mac's keyboard capitalizes as its person types.
struct MacAutocapitalization {
    static let never = MacAutocapitalization(), words = MacAutocapitalization(), sentences = MacAutocapitalization(),
               characters = MacAutocapitalization()
}

/// `.keyboardType(.URL)`: a Mac has one keyboard.
enum MacKeyboardType { case `default`, URL, numberPad, decimalPad, asciiCapable, emailAddress, phonePad }

extension View {
    func navigationBarTitleDisplayMode(_ mode: MacTitleDisplayMode) -> some View { self }
    func textInputAutocapitalization(_ style: MacAutocapitalization?) -> some View { self }
    func keyboardType(_ type: MacKeyboardType) -> some View { self }
    func statusBarHidden(_ hidden: Bool = true) -> some View { self }

    /// The iPhone's full-screen cover is a sheet in a Mac window.
    func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }

    func fullScreenCover<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                            @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss, content: content)
    }
}

extension ToolbarItemPlacement {
    /// The iPhone's top bar, leading: the Mac window's toolbar, at its leading edge.
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    /// The iPhone's top bar, trailing: the Mac window's toolbar, at its trailing edge.
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    /// The iPhone's bar along the bottom: the Mac window's toolbar.
    static var bottomBar: ToolbarItemPlacement { .automatic }
}

extension ListStyle where Self == InsetListStyle {
    /// The iPhone's grouped settings list: the Mac's inset list.
    static var insetGrouped: InsetListStyle { .inset }
}

// MARK: - UIKit's names for the AppKit things the shared views use

/// The iPhone's picture type is the Mac's: `NSImage` (sizes in points, as on the iPhone at 1×).
typealias UIImage = NSImage

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

/// The system's backgrounds, by the iPhone's names, in the Mac's own colours.
extension NSColor {
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemBackground: NSColor { .underPageBackgroundColor }
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
}

/// The iPhone's pasteboard, on the Mac's general one: copying text, a link or a picture, and
/// whether a picture is there to paste.
final class UIPasteboard {
    static let general = UIPasteboard()
    private var board: NSPasteboard { .general }

    var string: String? {
        get { board.string(forType: .string) }
        set { board.clearContents(); if let newValue { board.setString(newValue, forType: .string) } }
    }

    var url: URL? {
        get { board.string(forType: .URL).flatMap(URL.init(string:)) }
        set { board.clearContents(); if let newValue { board.writeObjects([newValue as NSURL]) } }
    }

    var image: NSImage? {
        get { NSImage(pasteboard: board) }
        set { board.clearContents(); if let newValue { board.writeObjects([newValue]) } }
    }

    var hasStrings: Bool { board.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.string.rawValue]) }
    var hasImages: Bool { board.canReadObject(forClasses: [NSImage.self], options: nil) }

    struct OptionsKey: Hashable { static let expirationDate = OptionsKey(), localOnly = OptionsKey() }

    /// Items given as type and value: the text among them. (A Mac's pasteboard doesn't expire.)
    func setItems(_ items: [[String: Any]], options: [OptionsKey: Any] = [:]) {
        board.clearContents()
        if let text = items.lazy.compactMap({ $0.values.first { $0 is String } as? String }).first {
            board.setString(text, forType: .string)
        }
    }

    var itemProviders: [NSItemProvider] {
        (board.pasteboardItems ?? []).map { item in
            let provider = NSItemProvider()
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { done in
                    done(data, nil)
                    return nil
                }
            }
            return provider
        }
    }
}

/// `EditButton` is the iPhone's: a Mac list deletes with the Delete key and the context menu.
struct EditButton: View {
    var body: some View { EmptyView() }
}

/// The Mac has no watch to tell what changed.
@MainActor final class WatchLink {
    static let shared = WatchLink()
    func push() {}
    func botsChanged() {}
}

/// What the shared views ask the iPhone about itself, answered for a Mac.
@MainActor final class UIDevice {
    enum Idiom { case phone, pad, mac }
    static let current = UIDevice()
    let userInterfaceIdiom = Idiom.mac
    var name: String { Host.current().localizedName ?? "Mac" }
}

/// What the shared code asks of the iPhone's application, answered by the Mac's.
@MainActor final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    /// The Settings link the iPhone opens for a permission: the Mac's Privacy & Security.
    static let openSettingsURLString = "x-apple.systempreferences:com.apple.preference.security"

    var applicationState: State { NSApplication.shared.isActive ? .active : .background }
    /// A Mac app runs only while its person is signed in: its files can always be read.
    var isProtectedDataAvailable: Bool { true }

    /// A Mac doesn't suspend an app in the background: nothing to ask for, nothing to end.
    func beginBackgroundTask(withName name: String? = nil, expirationHandler: (() -> Void)? = nil) -> Int { 0 }
    func endBackgroundTask(_ task: Int) {}

    /// Kept awake (voice mode): the display doesn't sleep while it is set.
    var isIdleTimerDisabled = false {
        didSet {
            guard isIdleTimerDisabled != oldValue else { return }
            if isIdleTimerDisabled {
                awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Redde's voice mode")
            } else if let awake {
                ProcessInfo.processInfo.endActivity(awake)
                self.awake = nil
            }
        }
    }
    private var awake: NSObjectProtocol?

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func registerForRemoteNotifications() { NSApplication.shared.registerForRemoteNotifications() }
}

/// A Mac has no car to be connected to.
enum CarPlaySceneDelegate {
    static var isConnected: Bool { false }
}

extension NSColor {
    /// The iPhone's hairline colour: the Mac's.
    static var separator: NSColor { .separatorColor }
}

/// The wake listener's holds, by the iPhone's names (`holdsWakePhrases`).
enum WakeHold { case settings, voicePicker, handoff, dictation }

/// A Mac's VoiceOver, by the iPhone's name.
enum UIAccessibility {
    static var isVoiceOverRunning: Bool { NSWorkspace.shared.isVoiceOverEnabled }
}

/// The iPhone's taps you feel: a Mac has nothing to tap with, so these do nothing.
@MainActor final class UINotificationFeedbackGenerator {
    enum FeedbackType { case success, warning, error }
    func notificationOccurred(_ type: FeedbackType) {}
    func prepare() {}
}

@MainActor final class UIImpactFeedbackGenerator {
    enum FeedbackStyle { case light, medium, heavy, soft, rigid }
    init(style: FeedbackStyle = .medium) {}
    func impactOccurred() {}
    func impactOccurred(intensity: CGFloat) {}
    func prepare() {}
}

extension ImageRenderer {
    /// The iPhone's picture of the view: the Mac's.
    var uiImage: NSImage? { nsImage }
}

extension NavigationTransition where Self == AutomaticNavigationTransition {
    /// The iPhone's zoom from a picture into its viewer: a Mac sheet opens as sheets do.
    static func zoom(sourceID: some Hashable, in namespace: Namespace.ID) -> AutomaticNavigationTransition { .automatic }
}

extension ToolbarPlacement {
    /// The iPhone's navigation bar: the Mac window's toolbar.
    static var navigationBar: ToolbarPlacement { .windowToolbar }
}

extension EnvironmentValues {
    /// The iPhone's side panel slid away (`SidePanel`): a Mac's sidebar never is.
    @Entry var sidePanelParked = false
}

extension Animation {
    /// The iPhone side panel's slide (`SidePanel`): the Mac's sidebar keeps its own.
    static var sidePanel: Animation { .snappy }
}

/// The iPhone's edit mode, which shows a list's selection circles: a Mac list selects with
/// clicks as it is, so the mode is only kept.
enum EditMode { case active, inactive, transient }

extension EnvironmentValues {
    @Entry var editMode: Binding<EditMode>? = nil
}

/// How the iPhone keeps its search field under the bar (`navigationBarDrawer(displayMode:)`).
enum MacSearchDrawerMode { case always, automatic }

extension SearchFieldPlacement {
    /// The iPhone's search field under the bar: a Mac sidebar's own.
    static func navigationBarDrawer(displayMode: MacSearchDrawerMode) -> SearchFieldPlacement { .sidebar }
}

/// A form as the iPhone lays it out, grouped, a row's label and its control together: the
/// Mac's own puts the labels in a column of their own and cuts their words short. (Declared
/// here, it is the `Form` every shared view builds on the Mac, sheets included.)
struct Form<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        SwiftUI.Form { content }
            .formStyle(.grouped)
    }
}

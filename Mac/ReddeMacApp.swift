import os
import SwiftUI

/// Redde for the Mac: a native SwiftUI app on the iPhone app's models, services and views, laid
/// out as the iPad lays them out (the conversations in the sidebar, the chat beside them), in a
/// Mac window. What the iPhone has that the Mac doesn't (calls, CarPlay, Live Activities, the
/// watch) is the iPhone's alone (`project.yml`, `MacShims`).
@main
struct ReddeMacApp: App {
    @State private var conversation: Conversation
    @State private var voiceSession: VoiceSession
    @State private var settings = Settings.shared
    @State private var lock = AppLock.shared
    @State private var zoom = TextZoom.shared
    @Environment(\.scenePhase) private var scenePhase

    /// The theme, made again as the text zoom changes: its fonts take the zoom (`TextZoom`).
    private var theme: ResolvedTheme {
        _ = zoom.step
        return settings.resolvedTheme
    }

    init() {
        let conversation = Conversation()
        _conversation = State(initialValue: conversation)
        let voice = VoiceSession(conversation: conversation)
        _voiceSession = State(initialValue: voice)
        VoiceSession.current = voice
        Conversation.current = conversation   // Siri's intents send through it
        CloudSync.shared.start()   // with Sync with iCloud on, what other devices changed meanwhile
        Notifier.shared.attach(conversation: conversation)
        #if DEBUG
        if DevHooks.has("-echo.hitches") { FrameMonitor.shared.start() }
        // `-echo.keychainProbe`: a throwaway secret written, read back and removed, the result in
        // the log, category keychain (whether this build's Keychain keeps what it is given).
        // `-echo.syncProbe`: whether Sync with iCloud is on here, and the servers' addresses, here
        // and in iCloud, in the log (category sync). Addresses only; keys stay in the Keychain.
        if DevHooks.has("-echo.syncProbe") {
            let log = Logger(subsystem: "com.goosehouse.echo", category: "sync")
            log.notice("probe: sync on \(CloudSync.shared.isOn), fast lane \(Settings.shared.fastLaneURL, privacy: .public) \(Settings.shared.fastLaneModel, privacy: .public)")
            for server in Settings.shared.servers {
                log.notice("probe: here \(server.name, privacy: .public) \(server.transport.rawValue, privacy: .public) \(server.gatewayURL, privacy: .public) \(server.serveURL, privacy: .public)")
            }
            let cloud = NSUbiquitousKeyValueStore.default
            cloud.synchronize()
            for (key, value) in cloud.dictionaryRepresentation where key.hasPrefix(CloudSync.serverPrefix) || key == "setting.fastLaneURL" {
                let text = (value as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
                log.notice("probe: icloud \(key, privacy: .public) \(text.prefix(400), privacy: .public)")
            }
        }
        if DevHooks.has("-echo.keychainProbe") {
            let account = "probe@keychain-test"
            let wrote = Keychain.write(account: account, value: "probe")
            Keychain.forgetCache()
            let read = Keychain.read(account: account)
            let removed = Keychain.delete(account: account)
            Logger(subsystem: "com.goosehouse.echo", category: "keychain")
                .notice("probe: wrote \(wrote), read \(read ?? "nothing", privacy: .public), removed \(removed)")
        }
        #endif
    }

    private static func controlSize(_ scale: CGFloat) -> ControlSize {
        switch scale {
        case ..<0.95: .small
        case ..<1.15: .regular
        case ..<1.6: .large
        default: .extraLarge
        }
    }

    var body: some Scene {
        WindowGroup("Redde") {
            ZStack {
                ContentView()
                    .accessibilityHidden(lock.isLocked || lock.isCovered)
                ReplyDrawingWarmUp()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                if lock.isLocked || lock.isCovered {
                    LockScreenView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.2), value: lock.isLocked || lock.isCovered)
            // The text zoom for whatever sets no font of its own (labels, list rows): the Mac's
            // body size, scaled. The sidebar and the chat's own views set theirs with `chatFont`.
            .chatFont(.body)
            // And the controls the system draws (the sidebar's switch, search, buttons), a size up
            // as the text grows.
            .controlSize(Self.controlSize(zoom.scale))
            // The iPad's layout: the conversations in a sidebar, the chat beside them.
            .environment(\.horizontalSizeClass, .regular)
            .environment(conversation)
            .environment(voiceSession)
            .environment(\.theme, theme)
            .tint(theme.accent)
            .preferredColorScheme(settings.effectiveColorScheme)
            .frame(minWidth: 760, minHeight: 520)
            // One title: the chat's own, in the middle of the toolbar (its name and its model),
            // not the window's beside it too.
            .toolbar(removing: .title)
            // Menus as the iPhone draws them: the symbol alone, no bezel and no arrow.
            .menuStyle(PlainMenu())
            .disclosureGroupStyle(WholeRowDisclosure())
            .onAppear {
                #if DEBUG
                // The store's pictures (design/screenshots/mac.py): `-echo.windowSize 1440x900`
                // sizes the window, whatever size it was left at. (Never brings it forward: that took the
                // keyboard from whatever the person was typing in, 2026-10-29.)
                if let size = UserDefaults.standard.string(forKey: "echo.windowSize")?.split(separator: "x").compactMap({ Double($0) }),
                   size.count == 2 {
                    DispatchQueue.main.async {
                        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
                        window.setContentSize(NSSize(width: size[0], height: size[1]))
                        window.center()
                    }
                }
                #endif
                lock.appDidLaunch()
                Settings.shared.applyLateLocalDefaults()
                Notifier.shared.registerCategories()
                EchoShortcuts.updateAppShortcutParameters()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .inactive, .background:
                    lock.appWillResignActive()
                    ConversationStore.shared.saveNow()
                    Drafts.shared.saveNow()
                case .active:
                    lock.appDidBecomeActive()
                    CloudSync.shared.cameForward()
                    // A conversation left without its reply fetches it, or picks the turn up.
                    Task { await conversation.catchUp() }
                    Task { await CaptureInbox.shared.file() }   // notes taken offline
                    IdeasInbox.shared.reload()
                    // With Current Location on, where the Mac is, for the next place question.
                    if CurrentLocation.isOn { CurrentLocationService.shared.cameForward() }
                    Task { await ReplyCardsSwitch.publish() }
                    Mutes.publish()
                @unknown default: break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                ConversationStore.shared.saveNow()
                Drafts.shared.saveNow()
            }
        }
        .defaultSize(width: 1120, height: 780)
        .commands { ReddeCommands() }

        // Redde → Settings… (⌘,): the iPhone's Settings in a window of its own, with a normal
        // toolbar, so a page's back button sits at the top left as a browser's does (asked
        // 2026-10-30; the Mac's Settings window centred it under the title).
        Window(String(localized: "Settings"), id: Self.settingsWindow) {
            SettingsView()
                .environment(conversation)
                .environment(voiceSession)
                .environment(\.theme, theme)
                .tint(theme.accent)
                .preferredColorScheme(settings.effectiveColorScheme)
                .menuStyle(PlainMenu())
                .disclosureGroupStyle(WholeRowDisclosure())
                .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 760)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 640, height: 760)
    }

    static let settingsWindow = "settings"
}

/// A menu drawn as the iPhone draws one: its label alone, without the Mac's bezel and arrow.
struct PlainMenu: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration)
            .menuStyle(.button)
            .buttonStyle(.plain)   // (borderless lets go of the label's own frame)
            .menuIndicator(.hidden)
    }
}

/// A section that folds open from anywhere on its row, as on the iPhone, not from its arrow alone
/// (asked 2026-10-30). The Mac's own disclosure group draws it; its label takes the click.
struct WholeRowDisclosure: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        DisclosureGroup(isExpanded: configuration.$isExpanded) {
            configuration.content
        } label: {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { configuration.isExpanded.toggle() } }
                .accessibilityAddTraits(.isButton)
        }
        // The Mac's own look inside, so this style isn't asked for again.
        .disclosureGroupStyle(.automatic)
    }
}

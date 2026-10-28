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
            .onAppear {
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

        // Redde → Settings… (⌘,): the iPhone's Settings, in the Mac's Settings window.
        SwiftUI.Settings {
            SettingsView()
                .environment(conversation)
                .environment(voiceSession)
                .environment(\.theme, theme)
                .tint(theme.accent)
                .preferredColorScheme(settings.effectiveColorScheme)
                .menuStyle(PlainMenu())
                .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 760)
        }
    }
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

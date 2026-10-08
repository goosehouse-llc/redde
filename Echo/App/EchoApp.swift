import SwiftUI

@main
struct EchoApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @State private var conversation: Conversation
    @State private var voiceSession: VoiceSession

    init() {
        let conversation = Conversation()
        _conversation = State(initialValue: conversation)
        let voice = VoiceSession(conversation: conversation)
        _voiceSession = State(initialValue: voice)
        VoiceSession.current = voice
        Conversation.current = conversation   // Siri AI's intents send through it
        Notifier.shared.attach(conversation: conversation)   // the delegate must exist before launch finishes
        // Approve and Deny on the Live Activity run here, in the app, and answer the same way.
        ApprovalAnswer.deliver = { Notifier.shared.answerApproval(requestID: $0, choice: $1) }
        StatusWidgets.lockChanged(Settings.shared.requireBiometrics)   // a lock turned on before the widgets existed
        TipJar.shared.start()   // finish tips that completed while the app wasn't looking
        TurnActivity.shared.clearStrays()   // a reply's Live Activity left by a run that crashed or was closed
        // Before any scene: the watch can wake the app in the background with a question to
        // run for it, and no window ever appears then to do this from.
        WatchLink.shared.activate()
    }

    @State private var settings = Settings.shared
    @State private var lock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .accessibilityHidden(lock.isLocked || lock.isCovered)
                if lock.isLocked || lock.isCovered {
                    LockScreenView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.2), value: lock.isLocked || lock.isCovered)
            .environment(conversation)
            .environment(voiceSession)
            .environment(\.theme, settings.resolvedTheme)
            .tint(settings.resolvedTheme.accent)
            .preferredColorScheme(settings.effectiveColorScheme)
            // With the CarPlay scene declared the app supports multiple scenes; keep widget and
            // Live Activity links (echo://) landing in this window instead of asking for a new one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onAppear {
                lock.appDidLaunch()
                Settings.shared.applyLateLocalDefaults()
                // Daemon round trips (notification categories, Siri phrases) wait for the first frame.
                Notifier.shared.registerCategories()
                Notifier.shared.registerForPush()
                PushService.shared.refreshAtLaunch()
                EchoShortcuts.updateAppShortcutParameters()
                SiriHooks.appLaunched()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .inactive: lock.appWillResignActive()
                case .background:
                    lock.appWillResignActive()
                    ConversationStore.shared.saveNow()   // don't leave a debounced write for a suspended process
                    Drafts.shared.saveNow()
                    // Every scene is in the background now, the car's included if there is one.
                    voiceSession.leftForeground(carPlayConnected: CarPlaySceneDelegate.isConnected)
                case .active:
                    lock.appDidBecomeActive()
                    WatchLink.shared.push()   // settings may have changed since the watch last heard
                    // The app may have been closed while the agent worked: a conversation left
                    // without its reply fetches it, or picks the turn up where it stands.
                    Task { await conversation.catchUp() }
                @unknown default: break
                }
            }
        }
    }
}

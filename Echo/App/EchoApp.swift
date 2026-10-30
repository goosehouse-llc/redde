import SwiftUI

@main
struct EchoApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @State private var conversation: Conversation
    @State private var voiceSession: VoiceSession

    init() {
        // Keys stored before 2.2 could be read only while the iPhone was unlocked, so the car found
        // none (GitHub issue 34): from now on they can be once it has been unlocked since it was
        // turned on. Done here if it is unlocked, else as it is (`PushDelegate`).
        Keychain.moveToAfterFirstUnlock()
        let conversation = Conversation()
        _conversation = State(initialValue: conversation)
        let voice = VoiceSession(conversation: conversation)
        _voiceSession = State(initialValue: voice)
        VoiceSession.current = voice
        Conversation.current = conversation   // Siri AI's intents send through it
        CloudSync.shared.start()   // with Sync with iCloud on, what other devices changed meanwhile
        Notifier.shared.attach(conversation: conversation)   // the delegate must exist before launch finishes
        // An agent's call can be what started the app: PushKit hands it over once this is set up.
        AgentCalls.shared.start()
        // Approve and Deny on the Live Activity run here, in the app, and answer the same way.
        ApprovalAnswer.deliver = { Notifier.shared.answerApproval(requestID: $0, choice: $1) }
        StatusWidgets.lockChanged(Settings.shared.requireBiometrics)   // a lock turned on before the widgets existed
        TipJar.shared.start()   // finish tips that completed while the app wasn't looking
        TurnActivity.shared.clearStrays()   // a reply's Live Activity left by a run that crashed or was closed
        // Before any scene: the watch can wake the app in the background with a question to
        // run for it, and no window ever appears then to do this from.
        WatchLink.shared.activate()
        #if os(iOS)
        // Places: iOS wakes Redde when a place's circle is crossed; its events are listened to from here.
        Places.shared.start()
        #endif
        #if DEBUG
        AlarmTrace.watch()   // what iOS does with Redde's alarms, kept in a file to read off a phone
        if DevHooks.has("-echo.hitches") { FrameMonitor.shared.start() }
        #endif
    }

    @State private var settings = Settings.shared
    @State private var lock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    #if DEBUG
                    .modifier(LayoutFlip())
                    #endif
                    .modifier(HingeWatch())
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
            .environment(conversation)
            .environment(voiceSession)
            .environment(\.theme, settings.resolvedTheme)
            .tint(settings.resolvedTheme.accent)
            .preferredColorScheme(settings.effectiveColorScheme)
            // And on the windows themselves: a sheet already open (Settings, as a wallpaper is
            // picked) kept the old one with the preference alone.
            .onChange(of: settings.effectiveColorScheme, initial: true) { _, scheme in WindowStyle.apply(scheme) }
            // With the CarPlay scene declared the app supports multiple scenes; keep widget and
            // Live Activity links (echo://) landing in this window instead of asking for a new one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onAppear {
                lock.appDidLaunch()
                WakeListener.shared.begin()   // listens for wake phrases where they're on (Settings → Voice)
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
                    PhotoLooking.shared.pause()
                case .active:
                    lock.appDidBecomeActive()
                    CloudSync.shared.cameForward()
                    WatchLink.shared.push()   // settings may have changed since the watch last heard
                    // The app may have been closed while the agent worked: a conversation left
                    // without its reply fetches it, or picks the turn up where it stands.
                    Task { await conversation.catchUp() }
                    Task { await CaptureInbox.shared.file() }   // notes taken offline
                    IdeasInbox.shared.reload()   // ideas that came while Redde was closed
                    BriefingsInbox.shared.reload()   // and briefings
                    HeldNote.seen()   // what came in quiet hours is here to see: no digest of it later
                    FeedbackFold.cameForward()   // a word on ideas or briefings that didn't reach the jobs yet
                    // With Current Location on, where the person is, for their next place question.
                    if CurrentLocation.isOn { CurrentLocationService.shared.cameForward() }
                    #if os(iOS)
                    Places.shared.noteWhereThePhoneIs()   // for when to leave for a heads-up's event
                    Task { await HealthDays.refresh() }   // the day's steps, if Health-Aware Days is on
                    #endif
                    // Which phone tools the agent is offered is this phone's to say, and the
                    // server may have been restarted, or reached for the first time, since it did.
                    if Settings.shared.phoneTools.on { Task { await DeviceToolsService.shared.publish() } }
                    // Cards on or off, and with them on this phone's time zone (which travels with
                    // it), said again in case this server hasn't heard.
                    Task { await ReplyCardsSwitch.publish() }
                    Task { await AgentAutonomy.publish() }   // how much each agent may do unasked
                    // A timed mute may have run out meanwhile, or one been set on another device.
                    Mutes.publish()
                    // Who may call this phone, said again in case this server hasn't heard.
                    AgentCalls.shared.publish()
                    // With Photos among them, the library is looked through while Redde is open,
                    // so that the agent can find a picture by what it shows.
                    PhotoLooking.shared.resume()
                @unknown default: break
                }
            }
        }
    }
}

/// Light or dark on every window of the app's own scenes, sheets included (`Settings.effectiveColorScheme`).
@MainActor
enum WindowStyle {
    static func apply(_ scheme: ColorScheme?) {
        let style: UIUserInterfaceStyle = switch scheme {
        case .light: .light
        case .dark: .dark
        default: .unspecified
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                if window.overrideUserInterfaceStyle != style { window.overrideUserInterfaceStyle = style }
                // A sheet up already keeps the style it was presented with, set on it by SwiftUI:
                // Settings stayed light under a dark wallpaper picked while it was open.
                var presented = window.rootViewController?.presentedViewController
                while let controller = presented {
                    if controller.overrideUserInterfaceStyle != style { controller.overrideUserInterfaceStyle = style }
                    presented = controller.presentedViewController
                }
            }
        }
    }
}

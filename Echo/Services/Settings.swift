import Foundation
import SwiftUI
import Observation

/// Which backend a turn is sent to.
nonisolated enum Transport: String, CaseIterable, Identifiable, Codable {
    // Declaration order is the order Settings and setup list them: Dashboard, API, OpenAI-compatible.
    /// `hermes serve` desktop gateway over WebSocket: live reasoning, approvals, slash commands.
    case hermesServe
    /// Hermes gateway sessions API — the shared ledger (Telegram, CLI, Discord, Echo), with live
    /// reasoning and tool events. Bearer key required.
    case hermesSessions
    /// OpenAI-compatible `/v1/chat/completions` — used for the llama-swap "fast lane" straight to the model.
    case chatCompletions

    var id: String { rawValue }
    var label: String {
        switch self {
        case .hermesSessions: "Hermes API (shared sessions)"
        case .hermesServe: "Hermes Dashboard (WebSocket)"
        case .chatCompletions: "OpenAI-compatible (direct to a model)"
        }
    }
    /// Uses the API server (8642) with the bearer key.
    var usesGateway: Bool { self == .hermesSessions }

    /// Old installs may have stored a transport that no longer exists; map it to the default.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Transport(rawValue: raw) ?? .hermesSessions
    }
    /// Shows a server-side session list.
    var hasLedger: Bool { self == .hermesSessions || self == .hermesServe }
}

/// Non-secret configuration. The API key is *never* here — see `Keychain`.
@Observable
final class Settings: ServeEndpoint {
    static let shared: Settings = {
        let settings = Settings()
        settings.moveLegacySecretsToActiveServer()
        return settings
    }()

    // Shipped defaults are empty: the app is configured on first run. Personal builds can drop a
    // git-ignored Echo/Resources/LocalDefaults.json into the bundle to prefill (see README).
    nonisolated static let defaultGatewayURL = ""
    nonisolated static let defaultFastLaneURL = ""
    nonisolated static let defaultFastLaneModel = ""

    var transport: Transport {
        didSet { store(transport.rawValue, forKey: Keys.transport); syncActiveServer() }
    }
    var gatewayURL: String {
        didSet { store(gatewayURL, forKey: Keys.gatewayURL); syncActiveServer() }
    }
    var fastLaneURL: String {
        didSet { store(fastLaneURL, forKey: Keys.fastLaneURL) }
    }
    var fastLaneModel: String {
        didSet { store(fastLaneModel, forKey: Keys.fastLaneModel) }
    }
    /// Model for the Hermes transports. Empty = the gateway's default.
    var gatewayModel: String {
        didSet { store(gatewayModel, forKey: Keys.gatewayModel); syncActiveServer() }
    }
    /// Provider slug that goes with `gatewayModel` (Hermes routes by both). Empty = default.
    var gatewayProvider: String {
        didSet { store(gatewayProvider, forKey: Keys.gatewayProvider); syncActiveServer() }
    }
    /// The effort levels offered, lowest first; "" leaves it to the gateway, "none" turns
    /// reasoning off. X-High and Max are for frontier models (Claude, GPT); the values are the
    /// ones their APIs use.
    static let reasoningEfforts: [(value: String, label: String)] = [
        ("", "Default"), ("none", "None"), ("low", "Low"), ("medium", "Medium"), ("high", "High"),
        ("xhigh", "X-High"), ("max", "Max"),
    ]

    static func effortLabel(_ value: String) -> String {
        reasoningEfforts.first { $0.value == value }?.label ?? value
    }

    /// Ask the agent to answer in this language (an ISO code). Empty = Automatic.
    var replyLanguage: String {
        didSet { store(replyLanguage, forKey: Keys.replyLanguage) }
    }

    /// Fresh installs start with reasoning off: a phone wants quick answers, and the gateway's
    /// own default is often tuned for a desk.
    static let defaultReasoningEffort = "none"

    /// "" (gateway default) or one of `reasoningEfforts`.
    var reasoningEffort: String {
        didSet { store(reasoningEffort, forKey: Keys.reasoningEffort) }
    }
    /// Start listening every time the app comes to the foreground. Makes the built-in
    /// "Hey Siri, open Redde" behave like the App Shortcut.
    var listenOnOpen: Bool {
        didSet { store(listenOnOpen, forKey: Keys.listenOnOpen) }
    }
    /// Listen for wake phrases while Redde is open (`WakeListener`). This device's own, off until
    /// turned on: it keeps the microphone open.
    var wakeListening: Bool {
        didSet { store(wakeListening, forKey: Keys.wakeListening) }
    }
    /// Voice mode opens with Hands-free switched on. Requests that ask for a mode themselves (the
    /// hands-free button, Siri, the controls) keep theirs.
    var handsFreeByDefault: Bool {
        didSet { store(handsFreeByDefault, forKey: Keys.handsFreeByDefault) }
    }
    /// Whether a spoken reply can be interrupted by talking over it (`VoiceSession`). With
    /// headphones nothing of the reply reaches the microphone, so that is on from the start. On
    /// the phone's speaker the echo has to be cancelled for as long as Redde speaks, which plays
    /// the reply at call volume: that is a choice.
    enum TalkOver: String, CaseIterable, Sendable { case off, headphones, everywhere }
    var talkOver: TalkOver {
        didSet { store(talkOver.rawValue, forKey: Keys.talkOver) }
    }
    /// What it takes to interrupt a reply that can be talked over: anything said, or the word
    /// "stop" alone. With the second, whatever else is said near the microphone, a room full of
    /// people included, the reply goes on.
    enum Interruption: String, CaseIterable, Sendable { case speech, stopWord }
    var interruption: Interruption {
        didSet { store(interruption.rawValue, forKey: Keys.interruption) }
    }
    /// In the car, while Redde speaks: "stop" ends the reply, "skip" jumps to its end. Only those
    /// two words, whatever `talkOver` and `interruption` say. Off until turned on: a car's
    /// speakers sit near its microphone.
    var stopAndSkipInCar: Bool {
        didSet { store(stopAndSkipInCar, forKey: Keys.stopAndSkipInCar) }
    }
    /// The person's own ways of saying "that's all" in voice mode, heard beside the built-in
    /// English ones (`StopPhrase`): another language's, or a word of the household's. They also
    /// stop a reply where only "stop" does.
    var stopPhrases: [String] {
        didSet { store(stopPhrases, forKey: Keys.stopPhrases) }
    }
    /// In voice mode a command that waits for approval, or a question from the agent, is read
    /// out and answered by voice (`SpokenRequest`). Off until asked for: whoever is in earshot
    /// can answer, and what the agent wants to run is said aloud.
    var answerRequestsByVoice: Bool {
        didSet { store(answerRequestsByVoice, forKey: Keys.answerRequestsByVoice) }
    }
    /// A question asked by voice in a car asks the agent for a short answer (`CarBrevity`). Off
    /// until asked for: on the Dashboard connection the request is a line added to the message,
    /// which other clients of the same server show.
    var shortAnswersInCar: Bool {
        didSet { store(shortAnswersInCar, forKey: Keys.shortAnswersInCar) }
    }
    /// Voice mode fills the silence while the agent works with a quiet sound
    /// (`ThinkingSoundPlayer`): never, only with a car connected, or always. Off until chosen.
    enum ThinkingSound: String, CaseIterable, Sendable { case off, car, always }
    var thinkingSound: ThinkingSound {
        didSet { store(thinkingSound.rawValue, forKey: Keys.thinkingSound) }
    }
    /// Who holds a voice conversation: Redde (the phone hears, the agent answers, a voice reads
    /// it), or a live voice model (GPT-Live, Gemini Live, Grok Voice: `LiveEngine`), which talks
    /// and listens at once and hands the real work to the agent (`LiveVoice`). Redde until chosen:
    /// a live call sends the microphone to its company and costs money by the minute.
    enum VoiceEngine: String, CaseIterable, Sendable {
        case redde, gptLive, gemini, grok, elevenLabs
        var live: LiveEngine? { LiveEngine(rawValue: rawValue) }
    }
    var voiceEngine: VoiceEngine {
        didSet { store(voiceEngine.rawValue, forKey: Keys.voiceEngine) }
    }
    /// GPT-Live is in this build: development builds only until it's finished (`GPT_LIVE`,
    /// project.yml). Its calls go over a WebSocket on Apple's TLS since 2026-10-24, so it brings no
    /// cryptography of its own to declare (it went without WebRTC for that).
    #if GPT_LIVE
    static let gptLiveIncluded = true
    #else
    static let gptLiveIncluded = false
    #endif
    /// The live engine holding the voice conversations with `profile` (nil or "default": the main
    /// agent): the bot's own choice (Edit Bot → Voice), else the one above; nil for Redde's, and
    /// in a build without live calls. Picked on a device that has them and synced to one that
    /// doesn't, Redde holds them.
    func liveEngine(for profile: String?) -> LiveEngine? {
        guard Self.gptLiveIncluded else { return nil }
        if let profile, profile != "default", let own = botVoicesHere[profile]?.conversation { return own.live }
        return voiceEngine.live
    }
    func usesLiveCall(for profile: String?) -> Bool { liveEngine(for: profile) != nil }
    /// The voice `engine` speaks with in calls with `profile`: its own for that engine, else the
    /// app's; one the engine doesn't offer (Redde listed OpenAI's older voices until 2026-10-25)
    /// is its default.
    func liveVoice(for profile: String?, engine: LiveEngine = .gptLive) -> String {
        if let profile, profile != "default", let own = botVoicesHere[profile]?.liveVoices?[engine.rawValue],
           engine.voicesFromAccount ? !own.isEmpty : engine.voices.contains(own) {
            return own
        }
        return appLiveVoice(engine)
    }
    /// The app's voice for `engine` (Settings → Voice → Conversation).
    func appLiveVoice(_ engine: LiveEngine) -> String {
        let picked = engine == .gptLive ? liveVoice : liveVoices[engine.rawValue]
        if engine.voicesFromAccount { return picked ?? "" }
        return picked.flatMap { engine.voices.contains($0) ? $0 : nil } ?? engine.defaultVoice
    }
    func setAppLiveVoice(_ voice: String, for engine: LiveEngine) {
        if engine == .gptLive { liveVoice = voice } else { liveVoices[engine.rawValue] = voice }
    }
    /// GPT-Live's voice when Redde sets the call up with its own OpenAI key.
    var liveVoice: String {
        didSet { store(liveVoice, forKey: Keys.liveVoice) }
    }
    /// The other live engines' voices, by `LiveEngine` raw value.
    var liveVoices: [String: String] {
        didSet { store(liveVoices, forKey: Keys.liveVoices) }
    }
    /// Minutes of quiet after which a GPT-Live call hangs up by itself: OpenAI bills every minute
    /// it is open, silent ones too. 0: only when ended.
    var liveHangUp: Int {
        didSet { store(liveHangUp, forKey: Keys.liveHangUp) }
    }
    static let liveHangUps = [1, 2, 5, 10, 0]
    /// With that on, a nod of the head approves and a shake denies, with AirPods that sense
    /// movement (`HeadGestures`). Off until asked for: iOS has to be asked for Motion & Fitness.
    var answerRequestsByNod: Bool {
        didSet { store(answerRequestsByNod, forKey: Keys.answerRequestsByNod) }
    }
    /// Coming into voice mode from outside the chat (Siri, the Action button, a control, opening
    /// Redde) starts a new conversation, unless the current one is empty or busy. The Talk button
    /// in a chat carries that chat on.
    var newConversationForVoice: Bool {
        didSet { store(newConversationForVoice, forKey: Keys.newConversationForVoice) }
    }
    /// What Redde shows when it starts: the last conversation, the conversation list (iPhone's
    /// panel, open on its last tab), or the voice screen (listening only with `listenOnOpen`).
    enum LaunchScreen: String, CaseIterable, Sendable { case conversation, conversations, voice }
    var launchScreen: LaunchScreen {
        didSet { store(launchScreen.rawValue, forKey: Keys.launchScreen) }
    }
    /// Launch straight into the voice screen. (Once its own switch; now one of `launchScreen`.)
    var openToVoiceScreen: Bool { launchScreen == .voice }
    /// Who reads replies out: the iPhone's own voice, a Kokoro server, or the person's Hermes
    /// with the voice it is set up with (`HermesSpeech`, over the Dashboard).
    enum ReplyVoice: String, CaseIterable, Sendable { case onDevice, kokoro, hermes }
    var replyVoice: ReplyVoice {
        didSet { store(replyVoice.rawValue, forKey: Keys.replyVoice) }
    }
    /// Speak replies with a Kokoro server instead of the on-device voice.
    var useKokoro: Bool { replyVoice == .kokoro }
    var kokoroURL: String {
        didSet { store(kokoroURL, forKey: Keys.kokoroURL) }
    }
    /// Spoken-reply speed multiplier — Kokoro's `speed` field, and the fallback
    /// synthesizer's rate scaled around the system default.
    var voiceSpeed: Double {
        didSet { store(voiceSpeed, forKey: Keys.voiceSpeed) }
    }
    var kokoroVoice: String {
        didSet { store(kokoroVoice, forKey: Keys.kokoroVoice) }
    }
    /// The language Redde listens for, as a locale id ("es-MX"). Empty = the iPhone's language.
    var speechLanguage: String {
        didSet { store(speechLanguage, forKey: Keys.speechLanguage) }
    }
    /// Read each reply with a voice for the language it's written in, not only `speechLanguage`.
    var matchReplyLanguage: Bool {
        didSet { store(matchReplyLanguage, forKey: Keys.matchReplyLanguage) }
    }
    /// What Redde listens for: `speechLanguage`, or the iPhone's language.
    var speechLocale: Locale { speechLanguage.isEmpty ? .current : Locale(identifier: speechLanguage) }
    /// Spoken prefixes: a leading word in a voice or Siri message ("Claude, …") becomes a text
    /// prefix ("C ") before sending. Empty by default, and typed text is never touched.
    var spokenPrefixes: [SpokenPrefix] {
        didSet { store(try? JSONEncoder().encode(spokenPrefixes), forKey: Keys.spokenPrefixes) }
    }
    /// The Bots section's rows in the order the person put them, per server (its id): `BotListItem`
    /// ids. Empty for a server: the main bot first, then the most recently talked to.
    var botOrder: [String: [String]] {
        didSet { store(try? JSONEncoder().encode(botOrder), forKey: Keys.botOrder) }
    }
    /// Bots added on this phone for the Hermes API alone, per server (its id): where there is no
    /// Dashboard login to list the server's, each by its profile and that profile's own API key
    /// (`Keychain.profileAccount`).
    var apiBots: [String: [APIBot]] {
        didSet { store(try? JSONEncoder().encode(apiBots), forKey: Keys.apiBots) }
    }
    /// The voices picked for bots, per server (its id), then bot (its profile). A bot with none
    /// picked reads in one of its own (`BotVoices`).
    var botVoices: [String: [String: BotVoice]] {
        didSet { store(try? JSONEncoder().encode(botVoices), forKey: Keys.botVoices) }
    }
    /// Bots and group chats muted, per server (its id), then `BotListItem` id: until when
    /// (`Date.distantFuture`: until turned back on). See `Mutes`.
    var mutes: [String: [String: Date]] {
        didSet { store(try? JSONEncoder().encode(mutes), forKey: Keys.mutes) }
    }
    /// Wake phrases, per server (its id), then agent: "default" for the main agent, else the
    /// bot's profile. None set for an agent: `Settings.wakePhrase(for:)`.
    var wakePhrases: [String: [String: WakePhrase]] {
        didSet { store(try? JSONEncoder().encode(wakePhrases), forKey: Keys.wakePhrases) }
    }
    /// `wakePhrases` for the server in use.
    var wakePhrasesHere: [String: WakePhrase] {
        get { wakePhrases[activeServerID.uuidString] ?? [:] }
        set { wakePhrases[activeServerID.uuidString] = newValue.isEmpty ? nil : newValue }
    }
    /// `mutes` for the server in use.
    var mutesHere: [String: Date] {
        get { mutes[activeServerID.uuidString] ?? [:] }
        set { mutes[activeServerID.uuidString] = newValue.isEmpty ? nil : newValue }
    }
    /// `botVoices` for the server in use.
    var botVoicesHere: [String: BotVoice] {
        get { botVoices[activeServerID.uuidString] ?? [:] }
        set { botVoices[activeServerID.uuidString] = newValue.isEmpty ? nil : newValue }
    }

    /// `apiBots` for the server in use.
    var apiBotsHere: [APIBot] {
        get { apiBots[activeServerID.uuidString] ?? [] }
        set { apiBots[activeServerID.uuidString] = newValue.isEmpty ? nil : newValue }
    }

    /// The Hermes API as a profile has it: the app's own address and key (nil, or the profile the
    /// app is on), the main profile's ("default"), or another profile's at /p/<profile>/. Hermes
    /// takes the API_SERVER_KEY in that profile's own .env there, often the main key put there too,
    /// so the main key is used unless one of the profile's own was kept here.
    func gatewayEndpoint(profile: String?) -> (url: URL, key: String)? {
        guard let profile, profile != profileName else {
            guard let url = gatewayBaseURL, let key = gatewayAPIKey, !key.isEmpty else { return nil }
            return (url, key)
        }
        guard let base = Self.normalizedBase(gatewayURL) else { return nil }
        let server = activeServerID.uuidString
        let main = Keychain.read(account: Keychain.account(.gatewayAPIKey, server: server))?.nilIfEmpty
        if profile == "default" { return main.map { (base, $0) } }
        guard let key = Keychain.read(account: Keychain.profileAccount(profile, server: server))?.nilIfEmpty ?? main else { return nil }
        return (base.appending(path: "p/\(profile)"), key)
    }

    /// `botOrder` for the server in use.
    var botOrderHere: [String] {
        get { botOrder[activeServerID.uuidString] ?? [] }
        set { botOrder[activeServerID.uuidString] = newValue.isEmpty ? nil : newValue }
    }
    var theme: Theme {
        didSet { store(theme.rawValue, forKey: Keys.theme) }
    }
    /// Your accent and bubble colors, per theme (keyed by `Theme.rawValue`). A theme with no
    /// entry uses its own colors, so switching themes never carries one theme's picks to another.
    var themeColors: [String: ThemeColors] {
        didSet { store(try? JSONEncoder().encode(themeColors), forKey: Keys.themeColors) }
    }
    /// The active theme with your colors applied: what the app renders.
    var resolvedTheme: ResolvedTheme { resolved(theme) }
    func resolved(_ theme: Theme) -> ResolvedTheme { theme.resolved(with: themeColors[theme.rawValue]) }
    /// Light / dark / follow the system, for the Default theme (the others fix their own).
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" } }
        var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    }
    var appearance: Appearance {
        didSet { store(appearance.rawValue, forKey: Keys.appearance) }
    }
    /// The orb at the centre of voice mode.
    var voiceOrb: VoiceOrb {
        didSet { store(voiceOrb.rawValue, forKey: Keys.voiceOrb) }
    }
    /// What moves inside the orb's face in voice mode.
    var orbLight: OrbLight {
        didSet { store(orbLight.rawValue, forKey: Keys.orbLight) }
    }
    /// How CarPlay's Ask tab draws its three cards.
    var carPlayCards: CarPlayCardLook {
        didSet { store(carPlayCards.rawValue, forKey: Keys.carPlayCards) }
    }
    /// How CarPlay's voice screen shows Redde listening, thinking and speaking.
    var carPlayVoice: CarPlayVoiceLook {
        didSet { store(carPlayVoice.rawValue, forKey: Keys.carPlayVoice) }
    }
    /// How CarPlay's Bots tab draws its bots' cards.
    var carPlayBots: CarPlayBotLook {
        didSet { store(carPlayBots.rawValue, forKey: Keys.carPlayBots) }
    }
    /// The CarPlay tab last picked ("ask", "chats", "bots"), which the car opens on next time.
    /// This phone's alone: not synced.
    var carPlayTab: String {
        didSet { store(carPlayTab, forKey: Keys.carPlayTab) }
    }
    /// Settings → Phone tools: which of the phone's own things the agent may use (`DeviceTool`).
    /// Everything off until turned on.
    var phoneTools: PhoneToolsSettings {
        didSet { if phoneTools != oldValue { store(try? JSONEncoder().encode(phoneTools), forKey: Keys.phoneTools) } }
    }
    /// What the app renders in: the appearance choice, nil meaning follow the system.
    var effectiveColorScheme: ColorScheme? { appearance.colorScheme }
    /// Local notifications for approvals / replies / failures while the app is in the background.
    var notifyInBackground: Bool {
        didSet { store(notifyInBackground, forKey: Keys.notifyInBackground) }
    }
    /// Dynamic Island / Lock Screen activity while a turn runs.
    var showLiveActivity: Bool {
        didSet { store(showLiveActivity, forKey: Keys.showLiveActivity) }
    }
    /// Three follow-up questions under each reply, written by the OpenAI-compatible model.
    var suggestFollowUps: Bool {
        didSet { store(suggestFollowUps, forKey: Keys.suggestFollowUps) }
    }
    /// Route replies to the earpiece when the proximity sensor says the phone is at your ear.
    /// Redde's background alerts are time-sensitive, so Siri can read them on AirPods (Announce
    /// Notifications) and they can break through a Focus.
    var announceOnAirPods: Bool {
        didSet { store(announceOnAirPods, forKey: Keys.announceOnAirPods) }
    }
    /// Return in the composer sends the message; off, it starts a new line, and the Send button
    /// (or ⌘Return) sends. With it on, Shift-Return on a keyboard starts the new line.
    var returnSends: Bool {
        didSet { store(returnSends, forKey: Keys.returnSends) }
    }
    /// Settings → Appearance → Bot colors: a bot's chat takes its face's colour for your bubbles
    /// and the accent (`BotFace.chatColors`), and so does Redde's when its face has a colour of its
    /// own. Group chats keep the theme's colours. Asked 2026-10-21; on unless turned off.
    var botColors: Bool {
        didSet { store(botColors, forKey: Keys.botColors) }
    }
    /// A card with the page's title and picture under a message with a web link
    /// (`LinkPreviews`). Off until turned on: the phone opens the page itself, so the site sees
    /// the visit, where Redde otherwise only ever talks to the servers it is set up with.
    var linkPreviews: Bool {
        didSet { store(linkPreviews, forKey: Keys.linkPreviews) }
    }
    /// Settings → Appearance → Bot faces: off, every bot (Redde too) is drawn as a circle in its
    /// colour with its initial instead of a creature, and voice mode shows the voice orb (the
    /// Bubble one in place of Redde's face). The faces stay on the server. Asked 2026-10-21, for
    /// people who'd rather not have faces; on unless turned off.
    var botFaces: Bool {
        didSet {
            store(botFaces, forKey: Keys.botFaces)
            if self === Settings.shared { WatchLink.shared.botsChanged() }   // the watch's bot pictures
        }
    }
    /// Settings → Agent → Cards in replies: the agent is offered Redde's `redde_show` (a map,
    /// places, the weather under a reply; his ask 2026-10-22). On unless turned off: off, the
    /// plugin stops offering it, and its description leaves every prompt (`ReplyCardsSwitch`).
    var replyCards: Bool {
        didSet {
            store(replyCards, forKey: Keys.replyCards)
            if self === Settings.shared, oldValue != replyCards { Task { await ReplyCardsSwitch.publish() } }
        }
    }
    /// Settings → Appearance → Pictures from Hermes: a bot with a picture set in Hermes Desktop is
    /// drawn as that picture (`BotPictures`). Asked on Reddit 2026-10-22; on unless turned off.
    var botPictures: Bool {
        didSet {
            store(botPictures, forKey: Keys.botPictures)
            if self === Settings.shared { WatchLink.shared.botsChanged() }
        }
    }
    /// How much larger or smaller than the iPhone's own text size the conversation is set, in
    /// steps of that scale: `chatTextSizes`. Zero follows the system.
    var chatTextSize: Int {
        didSet { store(chatTextSize, forKey: Keys.chatTextSize) }
    }
    static let chatTextSizes = -2 ... 2
    /// Whether Redde's notifications make a sound. Kept in the app group as well: the
    /// notification extension decides for the ones a paired Hermes sends (`NotificationSound`).
    var notificationSound: Bool {
        didSet {
            store(notificationSound, forKey: Keys.notificationSound)
            if self === Settings.shared { NotificationSound.isOn = notificationSound }
        }
    }
    var earpieceAtEar: Bool {
        didSet { store(earpieceAtEar, forKey: Keys.earpieceAtEar) }
    }
    /// Face ID / Touch ID / passcode gate on the app. Kept in the app group as well: the status
    /// widgets leave out a command, a question and a title while it is on (`NeedsYou.hidesWords`).
    var requireBiometrics: Bool {
        didSet {
            store(requireBiometrics, forKey: Keys.requireBiometrics)
            if self === Settings.shared {
                SiriHooks.indexInputsChanged()   // App Lock indexes titles only
                StatusWidgets.lockChanged(requireBiometrics)
            }
        }
    }
    /// Siri AI (iOS 27) may send messages to Redde and see its conversations. Off by default:
    /// Apple Intelligence then reads what you say to Siri, the one path that leaves the tailnet.
    var siriAIEnabled: Bool {
        didSet {
            store(siriAIEnabled, forKey: Keys.siriAIEnabled)
            if self === Settings.shared, oldValue != siriAIEnabled { SiriHooks.accessChanged(siriAIEnabled) }
        }
    }
    /// A message Siri drafts for Redde waits in a new conversation's composer, not the open
    /// one's (GitHub issue 21). Unless the open one is empty anyway.
    var siriDraftsInNewConversation: Bool {
        didSet { store(siriDraftsInNewConversation, forKey: Keys.siriDraftsInNewConversation) }
    }
    /// The chat list shows the server's bots (Hermes's Bot Mode, on the Dashboard), once it has
    /// any besides the main profile. Off, Redde is as it was without them.
    var showBots: Bool {
        didSet { store(showBots, forKey: Keys.showBots) }
    }
    /// The chat list shows the Dashboard's projects above the conversations. Off, their
    /// conversations are still in the list; only the section goes (GitHub issue 32).
    var projectsInChatList: Bool {
        didSet { store(projectsInChatList, forKey: Keys.projectsInChatList) }
    }
    /// How long the app may be in the background before it locks again.
    var lockGraceSeconds: Double {
        didSet { store(lockGraceSeconds, forKey: Keys.lockGraceSeconds) }
    }
    /// What the header calls the assistant. Empty means "Redde".
    var displayName: String {
        didSet { store(displayName, forKey: Keys.displayName) }
    }
    var headerTitle: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Redde" : trimmed
    }

    // hermes serve (desktop gateway). Password lives in the Keychain.
    var serveURL: String {
        didSet { store(serveURL, forKey: Keys.serveURL); syncActiveServer() }
    }
    var serveUsername: String {
        didSet { store(serveUsername, forKey: Keys.serveUsername); syncActiveServer() }
    }
    /// The Hermes profile Redde talks to; empty means the server's default profile. Nothing
    /// profile-related is sent for the default, so servers without profile support keep working.
    var hermesProfile: String {
        didSet { store(hermesProfile, forKey: Keys.hermesProfile); syncActiveServer() }
    }
    /// That profile's home directory on the server (from the dashboard's profile list), where
    /// its context and memory files live. Empty: the default `~/.hermes`.
    var hermesProfileHome: String {
        didSet { store(hermesProfileHome, forKey: Keys.hermesProfileHome); syncActiveServer() }
    }
    /// The profile to name in requests, or nil for the default profile.
    var profileName: String? {
        let name = hermesProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.lowercased() == "default" ? nil : name
    }
    /// The Hermes API key for requests: a named profile's own key when one is saved (the gateway
    /// checks each profile's API_SERVER_KEY on its /p/<profile>/ routes), else the main key.
    var gatewayAPIKey: String? {
        if let profile = profileName, let key = Keychain.read(account: Keychain.profileAccount(profile)), !key.isEmpty {
            return key
        }
        return Keychain.read(.gatewayAPIKey)
    }

    /// Where a file in the selected profile's Hermes home lives, e.g. "SOUL.md". In `home` when
    /// the server just said where that is (`HermesServeClient.profileHome`), else in the home it
    /// reported when the profile was picked, else Hermes's usual layout (`~/.hermes`,
    /// `~/.hermes/profiles/<name>`).
    func profileFilePath(_ relative: String, home: String? = nil) -> String {
        // The home kept from picking a profile is a named profile's: not the default's.
        var home = (home ?? (profileName == nil ? "" : hermesProfileHome)).trimmingCharacters(in: .whitespacesAndNewlines)
        if home.isEmpty { home = profileName.map { "~/.hermes/profiles/\($0)" } ?? "~/.hermes" }
        while home.hasSuffix("/") { home.removeLast() }
        return home + "/" + relative
    }

    /// Cloudflare Access service-token id (`CF-Access-Client-Id`); the secret lives in the Keychain.
    var cfAccessClientID: String {
        didSet { store(cfAccessClientID, forKey: Keys.cfAccessClientID); syncActiveServer() }
    }

    /// Headers Cloudflare Access expects in front of hermes serve, or empty when not configured.
    nonisolated static func cloudflareAccessHeaders(clientID: String, secret: String?) -> [String: String] {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, let secret, !secret.isEmpty else { return [:] }
        return ["CF-Access-Client-Id": id, "CF-Access-Client-Secret": secret]
    }
    /// The person's own headers for this server (`CustomHeader`): what a reverse proxy in front of
    /// it asks for. Names and values both live in the Keychain, per server.
    var customHeaders: [CustomHeader] {
        get { CustomHeader.decode(Keychain.read(.customHeaders)) }
        set { Keychain.write(.customHeaders, value: CustomHeader.encode(newValue)) }
    }
    /// The same as request fields.
    var customHeaderFields: [String: String] { CustomHeader.fields(customHeaders) }
    /// What every request to the Hermes API carries besides its key: the person's own headers and
    /// a Pangolin Link's access token.
    var apiHeaders: [String: String] {
        customHeaderFields.merging(Self.pangolinHeaders(Keychain.read(.pangolinAPI) ?? Keychain.read(.pangolinDashboard))) { _, token in token }
    }
    /// What every request to the Dashboard carries besides its login: the person's own headers,
    /// Cloudflare Access's service token and a Pangolin Link's access token.
    var accessHeaders: [String: String] {
        customHeaderFields
            .merging(Self.cloudflareAccessHeaders(clientID: cfAccessClientID, secret: Keychain.read(.cfAccessClientSecret))) { _, access in access }
            .merging(Self.pangolinHeaders(Keychain.read(.pangolinDashboard) ?? Keychain.read(.pangolinAPI))) { _, token in token }
    }

    /// A Pangolin Link's access token as the two headers Pangolin reads on every request
    /// (docs.pangolin.net, Links: `P-Access-Token-Id`, `P-Access-Token`), or none.
    nonisolated static func pangolinHeaders(_ stored: String?) -> [String: String] {
        guard let stored, let (id, token) = pangolinParts(stored) else { return [:] }
        return ["P-Access-Token-Id": id, "P-Access-Token": token]
    }

    /// What was pasted for a Pangolin access token, as it is stored (`<token-id>.<token>`): the
    /// pair itself, its `p_token` value, or a link with `p_token=` in it. Nil when it is none of them.
    nonisolated static func pangolinToken(_ pasted: String) -> String? {
        var text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "p_token=") {
            text = String(text[range.upperBound...].prefix { $0 != "&" && $0 != "#" })
            text = text.removingPercentEncoding ?? text
        }
        guard let (id, token) = pangolinParts(text) else { return nil }
        return id + "." + token
    }

    private nonisolated static func pangolinParts(_ text: String) -> (id: String, token: String)? {
        let pair = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = pair.firstIndex(of: ".") else { return nil }
        let id = String(pair[..<dot]), token = String(pair[pair.index(after: dot)...])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !id.isEmpty, !token.isEmpty, (id + token).unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return (id, token)
    }
    nonisolated static let defaultServeURL = ""
    var serveBaseURL: URL? {
        let raw = serveURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw.hasSuffix("/") ? String(raw.dropLast()) : raw)
    }

    /// Fallback when the backend doesn't report its window (the gateway doesn't). 131072 suits most local models.
    var contextWindow: Int {
        didSet { store(contextWindow, forKey: Keys.contextWindow) }
    }

    /// Push relay (companion/push-relay): hermes webhooks become APNs alerts. Empty = off.
    var pushRelayURL: String {
        didSet { store(pushRelayURL, forKey: Keys.pushRelayURL) }
    }
    nonisolated static let defaultContextWindow = 131_072
    nonisolated static let defaultKokoroURL = ""
    nonisolated static let defaultKokoroVoice = "am_onyx(2)+bm_george(1)"

    var kokoroBaseURL: URL? {
        let raw = kokoroURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw.hasSuffix("/") ? String(raw.dropLast()) : raw)
    }

    private let defaults: UserDefaults
    private enum Keys {
        static let transport = "transport"
        static let gatewayURL = "gatewayURL"
        static let fastLaneURL = "fastLaneURL"
        static let fastLaneModel = "fastLaneModel"
        static let gatewayModel = "gatewayModel"
        static let gatewayProvider = "gatewayProvider"
        static let reasoningEffort = "reasoningEffort"
        static let replyLanguage = "replyLanguage"
        static let listenOnOpen = "listenOnOpen"
        static let wakeListening = "wakeListening"
        static let wakePhrases = "wakePhrases"
        static let openToVoiceScreen = "openToVoiceScreen"   // before launchScreen; read once to carry it over
        static let launchScreen = "launchScreen"
        static let handsFreeByDefault = "handsFreeByDefault"
        static let newConversationForVoice = "newConversationForVoice"
        static let talkOver = "talkOver"
        static let interruption = "interruption"
        static let stopPhrases = "stopPhrases"
        static let answerRequestsByVoice = "answerRequestsByVoice"
        static let answerRequestsByNod = "answerRequestsByNod"
        static let shortAnswersInCar = "shortAnswersInCar"
        static let thinkingSound = "thinkingSound"
        static let voiceEngine = "voiceEngine"
        static let liveVoice = "liveVoice"
        static let liveVoices = "liveVoices"
        static let liveHangUp = "liveHangUp"
        static let useKokoro = "useKokoro"
        static let replyVoice = "replyVoice"
        static let kokoroURL = "kokoroURL"
        static let kokoroVoice = "kokoroVoice"
        static let voiceSpeed = "voiceSpeed"
        static let speechLanguage = "speechLanguage"
        static let matchReplyLanguage = "matchReplyLanguage"
        static let spokenPrefixes = "spokenPrefixes"
        static let botOrder = "botOrder"
        static let apiBots = "apiBots"
        static let botVoices = "botVoices"
        static let mutes = "mutes"
        static let contextWindow = "contextWindow"
        static let theme = "theme"
        static let themeColors = "themeColors"
        static let appearance = "appearance"
        static let voiceOrb = "voiceOrb"
        static let orbLight = "orbLight"
        static let carPlayCards = "carPlayCards"
        static let carPlayVoice = "carPlayVoice"
        static let carPlayBots = "carPlayBots"
        static let carPlayTab = "carPlayTab"
        static let stopAndSkipInCar = "stopAndSkipInCar"
        static let phoneTools = "phoneTools"
        static let notifyInBackground = "notifyInBackground"
        static let showLiveActivity = "showLiveActivity"
        static let suggestFollowUps = "suggestFollowUps"
        static let earpieceAtEar = "earpieceAtEar"
        static let announceOnAirPods = "announceOnAirPods"
        static let notificationSound = "notificationSound"
        static let returnSends = "returnSends"
        static let chatTextSize = "chatTextSize"
        static let botColors = "botColors"
        static let linkPreviews = "linkPreviews"
        static let botFaces = "botFaces"
        static let botPictures = "botPictures"
        static let replyCards = "replyCards"
        static let requireBiometrics = "requireBiometrics"
        static let siriAIEnabled = "siriAIEnabled"
        static let siriDraftsInNewConversation = "siriDraftsInNewConversation"
        static let showBots = "showBots"
        static let projectsInChatList = "projectsInChatList"
        static let lockGraceSeconds = "lockGraceSeconds"
        static let displayName = "displayName"
        static let setupDone = "setupDone"
        static let localDefaultsApplied = "localDefaultsApplied"
        static let pushRelayURL = "pushRelayURL"
        static let serveURL = "serveURL"
        static let serveUsername = "serveUsername"
        static let hermesProfile = "hermesProfile"
        static let hermesProfileHome = "hermesProfileHome"
        static let cfAccessClientID = "cfAccessClientID"
        static let hermesServers = "hermesServers"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        transport = Transport(rawValue: defaults.string(forKey: Keys.transport) ?? "") ?? .hermesSessions
        gatewayURL = defaults.string(forKey: Keys.gatewayURL) ?? Self.defaultGatewayURL
        fastLaneURL = defaults.string(forKey: Keys.fastLaneURL) ?? Self.defaultFastLaneURL
        fastLaneModel = defaults.string(forKey: Keys.fastLaneModel) ?? Self.defaultFastLaneModel
        gatewayModel = defaults.string(forKey: Keys.gatewayModel) ?? ""
        pushRelayURL = defaults.string(forKey: Keys.pushRelayURL) ?? ""
        gatewayProvider = defaults.string(forKey: Keys.gatewayProvider) ?? ""
        reasoningEffort = defaults.string(forKey: Keys.reasoningEffort) ?? Self.defaultReasoningEffort
        replyLanguage = defaults.string(forKey: Keys.replyLanguage) ?? ""
        listenOnOpen = defaults.bool(forKey: Keys.listenOnOpen)
        wakeListening = defaults.bool(forKey: Keys.wakeListening)
        launchScreen = defaults.string(forKey: Keys.launchScreen).flatMap(LaunchScreen.init(rawValue:))
            ?? (defaults.bool(forKey: Keys.openToVoiceScreen) ? .voice : .conversation)
        handsFreeByDefault = defaults.bool(forKey: Keys.handsFreeByDefault)
        newConversationForVoice = defaults.bool(forKey: Keys.newConversationForVoice)
        talkOver = defaults.string(forKey: Keys.talkOver).flatMap(TalkOver.init(rawValue:)) ?? .headphones
        interruption = defaults.string(forKey: Keys.interruption).flatMap(Interruption.init(rawValue:)) ?? .speech
        stopPhrases = defaults.stringArray(forKey: Keys.stopPhrases) ?? []
        answerRequestsByVoice = defaults.bool(forKey: Keys.answerRequestsByVoice)
        answerRequestsByNod = defaults.bool(forKey: Keys.answerRequestsByNod)
        shortAnswersInCar = defaults.bool(forKey: Keys.shortAnswersInCar)
        thinkingSound = defaults.string(forKey: Keys.thinkingSound).flatMap(ThinkingSound.init(rawValue:)) ?? .off
        voiceEngine = defaults.string(forKey: Keys.voiceEngine).flatMap(VoiceEngine.init(rawValue:)) ?? .redde
        liveVoice = defaults.string(forKey: Keys.liveVoice) ?? LiveSetup.defaultVoice
        liveVoices = defaults.dictionary(forKey: Keys.liveVoices) as? [String: String] ?? [:]
        liveHangUp = defaults.object(forKey: Keys.liveHangUp) as? Int ?? 2
        // Before there were three, Kokoro was a switch.
        replyVoice = defaults.string(forKey: Keys.replyVoice).flatMap(ReplyVoice.init(rawValue:))
            ?? (defaults.bool(forKey: Keys.useKokoro) ? .kokoro : .onDevice)
        kokoroURL = defaults.string(forKey: Keys.kokoroURL) ?? Self.defaultKokoroURL
        kokoroVoice = defaults.string(forKey: Keys.kokoroVoice) ?? Self.defaultKokoroVoice
        // "kokoroSpeed" was this setting's name for one build; carry the value over.
        let storedSpeed = defaults.double(forKey: Keys.voiceSpeed)
        let legacySpeed = defaults.double(forKey: "kokoroSpeed")
        voiceSpeed = storedSpeed != 0 ? storedSpeed : (legacySpeed != 0 ? legacySpeed : 1.0)
        theme = Theme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .standard
        themeColors = defaults.data(forKey: Keys.themeColors)
            .flatMap { try? JSONDecoder().decode([String: ThemeColors].self, from: $0) } ?? [:]
        spokenPrefixes = defaults.data(forKey: Keys.spokenPrefixes)
            .flatMap { try? JSONDecoder().decode([SpokenPrefix].self, from: $0) } ?? []
        botOrder = defaults.data(forKey: Keys.botOrder)
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        apiBots = defaults.data(forKey: Keys.apiBots)
            .flatMap { try? JSONDecoder().decode([String: [APIBot]].self, from: $0) } ?? [:]
        botVoices = defaults.data(forKey: Keys.botVoices)
            .flatMap { try? JSONDecoder().decode([String: [String: BotVoice]].self, from: $0) } ?? [:]
        mutes = defaults.data(forKey: Keys.mutes)
            .flatMap { try? JSONDecoder().decode([String: [String: Date]].self, from: $0) } ?? [:]
        wakePhrases = defaults.data(forKey: Keys.wakePhrases)
            .flatMap { try? JSONDecoder().decode([String: [String: WakePhrase]].self, from: $0) } ?? [:]
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        // Redde's own face unless another was picked; a still orb picked in an earlier version
        // falls back to it too (they are gone).
        voiceOrb = VoiceOrb(rawValue: defaults.string(forKey: Keys.voiceOrb) ?? "") ?? .reddeFace
        orbLight = OrbLight(rawValue: defaults.string(forKey: Keys.orbLight) ?? "") ?? .nebula
        carPlayCards = CarPlayCardLook(rawValue: defaults.string(forKey: Keys.carPlayCards) ?? "") ?? .color
        carPlayVoice = CarPlayVoiceLook(rawValue: defaults.string(forKey: Keys.carPlayVoice) ?? "") ?? .bars
        carPlayBots = CarPlayBotLook(rawValue: defaults.string(forKey: Keys.carPlayBots) ?? "") ?? .sticker
        carPlayTab = defaults.string(forKey: Keys.carPlayTab) ?? "ask"
        stopAndSkipInCar = defaults.bool(forKey: Keys.stopAndSkipInCar)
        phoneTools = defaults.data(forKey: Keys.phoneTools).flatMap { try? JSONDecoder().decode(PhoneToolsSettings.self, from: $0) } ?? .init()
        notifyInBackground = defaults.bool(forKey: Keys.notifyInBackground)
        showLiveActivity = defaults.object(forKey: Keys.showLiveActivity) as? Bool ?? true
        suggestFollowUps = defaults.bool(forKey: Keys.suggestFollowUps)
        speechLanguage = defaults.string(forKey: Keys.speechLanguage) ?? ""
        matchReplyLanguage = defaults.object(forKey: Keys.matchReplyLanguage) as? Bool ?? true
        earpieceAtEar = defaults.object(forKey: Keys.earpieceAtEar) as? Bool ?? true
        announceOnAirPods = defaults.bool(forKey: Keys.announceOnAirPods)
        notificationSound = defaults.object(forKey: Keys.notificationSound) as? Bool ?? true
        returnSends = defaults.bool(forKey: Keys.returnSends)
        chatTextSize = min(max(defaults.integer(forKey: Keys.chatTextSize), Self.chatTextSizes.lowerBound), Self.chatTextSizes.upperBound)
        botColors = defaults.object(forKey: Keys.botColors) as? Bool ?? true
        linkPreviews = defaults.bool(forKey: Keys.linkPreviews)
        botFaces = defaults.object(forKey: Keys.botFaces) as? Bool ?? true
        botPictures = defaults.object(forKey: Keys.botPictures) as? Bool ?? true
        replyCards = defaults.object(forKey: Keys.replyCards) as? Bool ?? true
        requireBiometrics = defaults.bool(forKey: Keys.requireBiometrics)
        siriAIEnabled = defaults.bool(forKey: Keys.siriAIEnabled)
        siriDraftsInNewConversation = defaults.bool(forKey: Keys.siriDraftsInNewConversation)
        showBots = defaults.object(forKey: Keys.showBots) as? Bool ?? true
        projectsInChatList = defaults.object(forKey: Keys.projectsInChatList) as? Bool ?? true
        lockGraceSeconds = defaults.object(forKey: Keys.lockGraceSeconds) as? Double ?? 60
        displayName = defaults.string(forKey: Keys.displayName) ?? ""
        setupDone = defaults.bool(forKey: Keys.setupDone)
        serveURL = defaults.string(forKey: Keys.serveURL) ?? Self.defaultServeURL
        serveUsername = defaults.string(forKey: Keys.serveUsername) ?? ""
        hermesProfile = defaults.string(forKey: Keys.hermesProfile) ?? ""
        hermesProfileHome = defaults.string(forKey: Keys.hermesProfileHome) ?? ""
        cfAccessClientID = defaults.string(forKey: Keys.cfAccessClientID) ?? ""
        let storedWindow = defaults.integer(forKey: Keys.contextWindow)
        contextWindow = storedWindow > 0 ? storedWindow : Self.defaultContextWindow

        // Saved servers. An install from before multi-server has none: its one setup becomes
        // the first server, and its secrets move under that server (moveLegacySecretsToActiveServer).
        let savedData = defaults.data(forKey: Keys.hermesServers)
        let saved = savedData.flatMap { try? JSONDecoder().decode([HermesServer].self, from: $0) } ?? []
        let storedActive = defaults.string(forKey: Keychain.activeServerKey).flatMap(UUID.init(uuidString:))
        if let active = saved.first(where: { $0.id == storedActive }) ?? saved.first {
            servers = saved
            activeServerID = active.id
        } else {
            // A list that's there but can't be read is kept aside rather than overwritten, and
            // the active server keeps its id, so the Keychain secrets filed under it still match.
            if let savedData { defaults.set(savedData, forKey: Keys.hermesServers + ".unreadable") }
            // Built from the stored values: the properties can't be read before `servers` is set.
            let stored = { (key: String) in defaults.string(forKey: key) ?? "" }
            let storedTransport = Transport(rawValue: stored(Keys.transport)) ?? .hermesSessions
            let first = HermesServer(id: storedActive ?? UUID(), name: "",
                                     transport: storedTransport == .chatCompletions ? .hermesServe : storedTransport,
                                     gatewayURL: stored(Keys.gatewayURL), serveURL: stored(Keys.serveURL),
                                     serveUsername: stored(Keys.serveUsername), cfAccessClientID: stored(Keys.cfAccessClientID),
                                     gatewayModel: stored(Keys.gatewayModel), gatewayProvider: stored(Keys.gatewayProvider),
                                     hermesProfile: stored(Keys.hermesProfile), hermesProfileHome: stored(Keys.hermesProfileHome))
            servers = [first]
            activeServerID = first.id
            defaults.set(try? JSONEncoder().encode(servers), forKey: Keys.hermesServers)
        }
        defaults.set(activeServerID.uuidString, forKey: Keychain.activeServerKey)
        scopeShortcutSessionKeys()
    }

    // MARK: - iCloud

    /// Saves a setting, and tells `CloudSync` which one.
    private func store(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        onStore?(key)
    }

    /// Called with each setting's key as it is saved: `CloudSync`, while Sync with iCloud is on.
    @ObservationIgnored var onStore: ((String) -> Void)?

    /// The key the server list is saved under, which `onStore` names when it changes.
    static var serversKey: String { Keys.hermesServers }

    /// The settings Sync with iCloud carries to the person's other devices, by their keys here.
    /// Each device keeps its own: the connection in use and the server it is on (and, in each
    /// server's record, the profile and model it is on), what Redde does on opening, App Lock,
    /// Siri, Phone tools, what needs a permission of the device (notifications, motion), and the
    /// push relay.
    static let syncedKeys: [String] = [
        Keys.displayName, Keys.theme, Keys.themeColors, Keys.appearance, Keys.chatTextSize, Keys.botColors, Keys.linkPreviews, Keys.botFaces, Keys.botPictures, Keys.replyCards, Keys.returnSends,
        Keys.voiceOrb, Keys.orbLight, Keys.carPlayCards, Keys.carPlayVoice, Keys.carPlayBots, Keys.showBots, Keys.projectsInChatList,
        Keys.fastLaneURL, Keys.fastLaneModel, Keys.reasoningEffort, Keys.replyLanguage, Keys.contextWindow,
        Keys.suggestFollowUps, Keys.showLiveActivity, Keys.notificationSound, Keys.announceOnAirPods, Keys.earpieceAtEar,
        Keys.handsFreeByDefault, Keys.newConversationForVoice, Keys.talkOver, Keys.interruption, Keys.stopAndSkipInCar, Keys.stopPhrases,
        Keys.answerRequestsByVoice, Keys.shortAnswersInCar, Keys.thinkingSound, Keys.voiceEngine, Keys.liveVoice, Keys.liveVoices, Keys.liveHangUp,
        Keys.replyVoice, Keys.kokoroURL,
        Keys.kokoroVoice, Keys.voiceSpeed, Keys.speechLanguage, Keys.matchReplyLanguage, Keys.spokenPrefixes,
        Keys.botOrder, Keys.apiBots, Keys.botVoices, Keys.mutes, Keys.wakePhrases,
    ]

    /// A synced setting as it is saved here, for `CloudSync` to send.
    func storedValue(_ key: String) -> Any? { defaults.object(forKey: key) }

    /// A synced setting changed on another device: it takes the value saved there, or (nil) its
    /// default. Saving it calls `onStore`, which finds iCloud holding the same and sends nothing.
    func applySynced(_ key: String, _ value: Any?) {
        func text(_ fallback: String = "") -> String { value as? String ?? fallback }
        func flag(_ fallback: Bool = false) -> Bool { value as? Bool ?? fallback }
        func pick<T: RawRepresentable>(_ fallback: T) -> T where T.RawValue == String { (value as? String).flatMap(T.init(rawValue:)) ?? fallback }
        func decoded<T: Decodable>(_ fallback: T) -> T { (value as? Data).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? fallback }
        switch key {
        case Keys.displayName: displayName = text()
        case Keys.theme: theme = pick(Theme.standard)
        case Keys.themeColors: themeColors = decoded([:])
        case Keys.appearance: appearance = pick(Appearance.system)
        case Keys.chatTextSize: chatTextSize = min(max(value as? Int ?? 0, Self.chatTextSizes.lowerBound), Self.chatTextSizes.upperBound)
        case Keys.botColors: botColors = flag(true)
        case Keys.linkPreviews: linkPreviews = flag()
        case Keys.botFaces: botFaces = flag(true)
        case Keys.botPictures: botPictures = flag(true)
        case Keys.replyCards: replyCards = flag(true)
        case Keys.returnSends: returnSends = flag()
        case Keys.voiceOrb: voiceOrb = pick(VoiceOrb.reddeFace)
        case Keys.orbLight: orbLight = pick(OrbLight.nebula)
        case Keys.carPlayCards: carPlayCards = pick(CarPlayCardLook.color)
        case Keys.carPlayVoice: carPlayVoice = pick(CarPlayVoiceLook.bars)
        case Keys.carPlayBots: carPlayBots = pick(CarPlayBotLook.sticker)
        case Keys.showBots: showBots = flag(true)
        case Keys.projectsInChatList: projectsInChatList = flag(true)
        case Keys.fastLaneURL: fastLaneURL = text(Self.defaultFastLaneURL)
        case Keys.fastLaneModel: fastLaneModel = text(Self.defaultFastLaneModel)
        case Keys.reasoningEffort: reasoningEffort = text(Self.defaultReasoningEffort)
        case Keys.replyLanguage: replyLanguage = text()
        case Keys.contextWindow: contextWindow = (value as? Int).flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultContextWindow
        case Keys.suggestFollowUps: suggestFollowUps = flag()
        case Keys.showLiveActivity: showLiveActivity = flag(true)
        case Keys.notificationSound: notificationSound = flag(true)
        case Keys.announceOnAirPods: announceOnAirPods = flag()
        case Keys.earpieceAtEar: earpieceAtEar = flag(true)
        case Keys.handsFreeByDefault: handsFreeByDefault = flag()
        case Keys.newConversationForVoice: newConversationForVoice = flag()
        case Keys.talkOver: talkOver = pick(TalkOver.headphones)
        case Keys.interruption: interruption = pick(Interruption.speech)
        case Keys.stopAndSkipInCar: stopAndSkipInCar = flag()
        case Keys.stopPhrases: stopPhrases = value as? [String] ?? []
        case Keys.answerRequestsByVoice: answerRequestsByVoice = flag()
        case Keys.shortAnswersInCar: shortAnswersInCar = flag()
        case Keys.thinkingSound: thinkingSound = pick(ThinkingSound.off)
        case Keys.voiceEngine: voiceEngine = pick(VoiceEngine.redde)
        case Keys.liveVoice: liveVoice = text(LiveSetup.defaultVoice)
        case Keys.liveVoices: liveVoices = value as? [String: String] ?? [:]
        case Keys.liveHangUp: liveHangUp = value as? Int ?? 2
        case Keys.replyVoice: replyVoice = pick(ReplyVoice.onDevice)
        case Keys.kokoroURL: kokoroURL = text(Self.defaultKokoroURL)
        case Keys.kokoroVoice: kokoroVoice = text(Self.defaultKokoroVoice)
        case Keys.voiceSpeed: voiceSpeed = (value as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 1.0
        case Keys.speechLanguage: speechLanguage = text()
        case Keys.matchReplyLanguage: matchReplyLanguage = flag(true)
        case Keys.spokenPrefixes: spokenPrefixes = decoded([])
        case Keys.botOrder: botOrder = decoded([:])
        case Keys.apiBots: apiBots = decoded([:])
        case Keys.botVoices: botVoices = decoded([:])
        case Keys.mutes: mutes = decoded([:])
        case Keys.wakePhrases: wakePhrases = decoded([:])
        default: break
        }
    }

    /// Servers from another device: each in `remote` added, or brought up to date keeping what
    /// this device chose on it (the profile and model it is on); each in `removed` taken away,
    /// unless this device is on it. True when the active server's connection changed, so the
    /// caller connects again.
    @discardableResult
    func mergeSyncedServers(_ remote: [HermesServer], removed: Set<UUID>) -> Bool {
        var list = servers
        for server in remote where !removed.contains(server.id) {
            guard let i = list.firstIndex(where: { $0.id == server.id }) else {
                list.append(server)
                continue
            }
            var merged = server
            merged.hermesProfile = list[i].hermesProfile
            merged.hermesProfileHome = list[i].hermesProfileHome
            merged.gatewayModel = list[i].gatewayModel
            merged.gatewayProvider = list[i].gatewayProvider
            list[i] = merged
        }
        list.removeAll { removed.contains($0.id) && $0.id != activeServerID }
        for gone in servers where !list.contains(where: { $0.id == gone.id }) { removeShortcutSessions(server: gone.id) }
        let before = activeServer
        guard list != servers else { return false }
        servers = list
        guard let after = activeServer, after != before else { return false }
        // The working copy follows the active server's record.
        loadingServer = true
        defer { loadingServer = false }
        gatewayURL = after.gatewayURL
        serveURL = after.serveURL
        serveUsername = after.serveUsername
        cfAccessClientID = after.cfAccessClientID
        if transport != .chatCompletions { transport = after.transport }
        return true
    }

    /// The server this device is on was never set up (a new install that skipped setup): servers
    /// from another device can take its place.
    var activeServerIsBlank: Bool {
        guard let server = activeServer else { return true }
        return server.name.isEmpty && server.serveURL.isEmpty && server.gatewayURL.isEmpty
    }

    /// Takes away a server this device isn't on, its secrets left alone (the other devices still
    /// use the ones in iCloud Keychain): a blank one after synced servers arrived.
    func forgetServerRecord(_ id: UUID) {
        guard id != activeServerID else { return }
        servers.removeAll { $0.id == id }
        removeShortcutSessions(server: id)
    }

    // MARK: - Servers

    /// Shortcuts keep their own session per server and profile under keys with this prefix
    /// (`ShortcutRunner`).
    static let shortcutSessionPrefix = "shortcutSessionID"
    /// Quick capture's notes have a chat of their own the same way (`CaptureFiler`).
    static let notesSessionPrefix = "notesSessionID"

    /// Once: the keys from before they carried a server id (`shortcutSessionID`,
    /// `shortcutSessionID.<profile>`, with `.serve` for the Dashboard) belong to the first server.
    private func scopeShortcutSessionKeys() {
        let done = "shortcutSessionKeysScoped"
        guard !defaults.bool(forKey: done), let first = servers.first?.id.uuidString else { return }
        let prefix = Self.shortcutSessionPrefix
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            if rest.dropFirst().prefix(36).count == 36, UUID(uuidString: String(rest.dropFirst().prefix(36))) != nil { continue }
            defaults.set(value, forKey: prefix + ".\(first)" + rest)
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: done)
    }

    /// Forgets the Shortcuts and Notes sessions of one server, or of all of them.
    private func removeShortcutSessions(server: UUID?) {
        for kind in [Self.shortcutSessionPrefix, Self.notesSessionPrefix] {
            let prefix = kind + (server.map { ".\($0.uuidString)" } ?? "")
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) }
        }
    }

    /// Saved Hermes servers. The connection fields above are the active server's working copy:
    /// editing them updates its record, and switching loads another record into them.
    private(set) var servers: [HermesServer] {
        didSet { store(try? JSONEncoder().encode(servers), forKey: Keys.hermesServers) }
    }
    private(set) var activeServerID: UUID {
        didSet { store(activeServerID.uuidString, forKey: Keychain.activeServerKey) }
    }
    var activeServer: HermesServer? { servers.first { $0.id == activeServerID } }
    /// Changes whenever requests would go somewhere else: another server or another profile.
    /// Screens that load from the server key their loading (or their identity) on it.
    var connectionKey: String { "\(activeServerID.uuidString)|\(hermesProfile)" }
    /// Set while a server's record is being loaded into the working copy.
    @ObservationIgnored private var loadingServer = false

    /// Copies the working copy into the active server's record.
    private func syncActiveServer() {
        guard !loadingServer, let i = servers.firstIndex(where: { $0.id == activeServerID }) else { return }
        var server = servers[i]
        server.gatewayURL = gatewayURL
        server.serveURL = serveURL
        server.serveUsername = serveUsername
        server.cfAccessClientID = cfAccessClientID
        server.gatewayModel = gatewayModel
        server.gatewayProvider = gatewayProvider
        server.hermesProfile = hermesProfile
        server.hermesProfileHome = hermesProfileHome
        // The OpenAI-compatible connection isn't a server's; the record keeps its Hermes connection.
        if transport != .chatCompletions { server.transport = transport }
        if server != servers[i] { servers[i] = server }
    }

    /// Makes another saved server active: its record becomes the working copy and the Keychain
    /// scope. Callers reset connections first (`ServerSwitcher`), while the old server is current.
    func activateServer(_ id: UUID) {
        guard id != activeServerID, let target = servers.first(where: { $0.id == id }) else { return }
        syncActiveServer()
        loadingServer = true
        defer { loadingServer = false }
        activeServerID = id
        gatewayURL = target.gatewayURL
        serveURL = target.serveURL
        serveUsername = target.serveUsername
        cfAccessClientID = target.cfAccessClientID
        gatewayModel = target.gatewayModel
        gatewayProvider = target.gatewayProvider
        hermesProfile = target.hermesProfile
        hermesProfileHome = target.hermesProfileHome
        // The OpenAI-compatible connection isn't a server's: switching servers doesn't leave it.
        if transport != .chatCompletions { transport = target.transport }
    }

    /// A new, empty server (not yet active). Its connection is filled in by setup.
    @discardableResult
    func addServer(name: String) -> UUID {
        let server = HermesServer(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        servers.append(server)
        return server.id
    }

    func renameServer(_ id: UUID, to name: String) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a server that isn't active, and its secrets. The last server can't be removed.
    func removeServer(_ id: UUID) {
        guard id != activeServerID, servers.count > 1 else { return }
        servers.removeAll { $0.id == id }
        let suffix = "@\(id.uuidString)"
        for account in Keychain.allAccounts() where account.hasSuffix(suffix) { Keychain.delete(account: account) }
        removeShortcutSessions(server: id)
    }

    /// One-time move of pre-multi-server secrets (bare `gateway-api-key` etc.) under the active
    /// server. Each is copied and read back before the old entry goes; safe to run every launch.
    func moveLegacySecretsToActiveServer() {
        let server = activeServerID.uuidString
        let accounts = Keychain.allAccounts()
        for item in Keychain.serverScoped where accounts.contains(item.rawValue) {
            Keychain.move(account: item.rawValue, to: Keychain.account(item, server: server))
        }
        let profilePrefix = Keychain.Item.gatewayAPIKey.rawValue + "."
        for account in accounts where account.hasPrefix(profilePrefix) && !account.contains("@") {
            Keychain.move(account: account, to: account + "@" + server)
        }
    }

    /// Back to first-run values, with one empty server. Secrets live in the Keychain and are
    /// cleared by the caller.
    func reset() {
        removeShortcutSessions(server: nil)
        let fresh = HermesServer(id: UUID(), name: "")
        loadingServer = true
        servers = [fresh]
        activeServerID = fresh.id
        loadingServer = false
        transport = .hermesSessions
        gatewayURL = Self.defaultGatewayURL
        fastLaneURL = Self.defaultFastLaneURL
        fastLaneModel = Self.defaultFastLaneModel
        gatewayModel = ""
        gatewayProvider = ""
        reasoningEffort = Self.defaultReasoningEffort
        replyLanguage = ""
        listenOnOpen = false
        wakeListening = false
        launchScreen = .conversation
        handsFreeByDefault = false
        newConversationForVoice = false
        talkOver = .headphones
        interruption = .speech
        stopAndSkipInCar = false
        stopPhrases = []
        answerRequestsByVoice = false
        answerRequestsByNod = false
        shortAnswersInCar = false
        thinkingSound = .off
        voiceEngine = .redde
        liveVoice = LiveSetup.defaultVoice
        liveHangUp = 2
        replyVoice = .onDevice
        kokoroURL = Self.defaultKokoroURL
        kokoroVoice = Self.defaultKokoroVoice
        voiceSpeed = 1.0
        speechLanguage = ""
        matchReplyLanguage = true
        spokenPrefixes = []
        botOrder = [:]
        apiBots = [:]
        botVoices = [:]
        mutes = [:]
        wakePhrases = [:]
        theme = .standard
        themeColors = [:]
        appearance = .system
        voiceOrb = .reddeFace
        orbLight = .nebula
        carPlayCards = .color
        carPlayVoice = .bars
        carPlayBots = .sticker
        phoneTools = .init()
        notifyInBackground = false
        showLiveActivity = true
        earpieceAtEar = true
        announceOnAirPods = false
        notificationSound = true
        returnSends = false
        chatTextSize = 0
        botColors = true
        linkPreviews = false
        botFaces = true
        botPictures = true
        replyCards = true
        requireBiometrics = false
        siriAIEnabled = false
        siriDraftsInNewConversation = false
        showBots = true
        projectsInChatList = true
        lockGraceSeconds = 60
        displayName = ""
        serveURL = Self.defaultServeURL
        serveUsername = ""
        hermesProfile = ""
        hermesProfileHome = ""
        cfAccessClientID = ""
        pushRelayURL = ""
        contextWindow = Self.defaultContextWindow
        setupDone = false
        defaults.removeObject(forKey: Keys.localDefaultsApplied)
    }

    /// The Hermes API base. A named profile goes through the gateway's `/p/<profile>/` routes,
    /// which exist when the gateway multiplexes profiles (`gateway.multiplex_profiles`).
    var gatewayBaseURL: URL? {
        guard let base = Self.normalizedBase(gatewayURL) else { return nil }
        return profileName.map { base.appending(path: "p/\($0)") } ?? base
    }

    /// True once the selected transport has what it needs to make a request.
    var isConfigured: Bool {
        switch transport {
        case .hermesSessions: return gatewayBaseURL != nil && gatewayAPIKey != nil
        case .hermesServe:
            return serveBaseURL != nil && (DashboardSignIn.tokens(for: serveBaseURL, in: .keychain) != nil
                || (!serveUsername.isEmpty && Keychain.read(.serveDashboardPassword) != nil))
        case .chatCompletions: return activeBaseURL != nil && !fastLaneModel.isEmpty
        }
    }

    /// Set after the first-run setup completes (or is skipped).
    var setupDone: Bool {
        didSet { store(setupDone, forKey: Keys.setupDone) }
    }

    /// Personal builds: prefill from a bundled, git-ignored LocalDefaults.json on first launch.
    func applyLocalDefaultsIfPresent() {
        guard !defaults.bool(forKey: Keys.localDefaultsApplied),
              let url = Bundle.main.url(forResource: "LocalDefaults", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let v = dict["gatewayURL"] as? String { gatewayURL = v }
        if let v = dict["fastLaneURL"] as? String { fastLaneURL = v }
        if let v = dict["fastLaneModel"] as? String { fastLaneModel = v }
        if let v = dict["serveURL"] as? String { serveURL = v }
        if let v = dict["serveUsername"] as? String { serveUsername = v }
        if let v = dict["kokoroURL"] as? String { kokoroURL = v }
        if let v = dict["kokoroVoice"] as? String { kokoroVoice = v }
        if let v = dict["voiceSpeed"] as? Double { voiceSpeed = v }
        if let v = dict["transport"] as? String, let t = Transport(rawValue: v) { transport = t }
        if let v = dict["contextWindow"] as? Int { contextWindow = v }
        defaults.set(true, forKey: Keys.localDefaultsApplied)
    }

    /// Keys added after an install consumed LocalDefaults still prefill, but only while empty,
    /// so a value the user set by hand is never overwritten.
    func applyLateLocalDefaults() {
        guard let url = Bundle.main.url(forResource: "LocalDefaults", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if pushRelayURL.isEmpty, let v = dict["pushRelayURL"] as? String { pushRelayURL = v }
        if Keychain.read(.pushRegisterSecret) == nil, let v = dict["pushRegisterSecret"] as? String {
            _ = Keychain.write(.pushRegisterSecret, value: v)
        }
    }

    var activeBaseURL: URL? {
        if transport == .hermesServe { return serveBaseURL }
        if transport.usesGateway { return gatewayBaseURL }
        return Self.normalizedBase(fastLaneURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Accepts the base as providers document it: trailing slash or trailing `/v1` are dropped,
    /// because the transports add `v1/…` themselves. "https://openrouter.ai/api/v1" → ".../api".
    nonisolated static func normalizedBase(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/v1") { text.removeLast(3) }
        while text.hasSuffix("/") { text.removeLast() }
        return text.isEmpty ? nil : URL(string: text)
    }
}

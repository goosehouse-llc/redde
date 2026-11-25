// Settings' storage keys, and Sync with iCloud.
import Foundation

extension Settings {
    enum Keys {
        static let transport = "transport"
        static let gatewayURL = "gatewayURL"
        static let fastLaneURL = "fastLaneURL"
        static let fastLaneModel = "fastLaneModel"
        static let gatewayModel = "gatewayModel"
        static let gatewayProvider = "gatewayProvider"
        static let reasoningEffort = "reasoningEffort"
        static let replyLanguage = "replyLanguage"
        static let measureUnits = MeasureUnits.key
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
        static let liveWhenLocked = "liveWhenLocked"
        static let liveGroupCalls = "liveGroupCalls"
        static let useKokoro = "useKokoro"
        static let replyVoice = "replyVoice"
        static let kokoroURL = "kokoroURL"
        static let kokoroVoice = "kokoroVoice"
        static let speechModel = "speechModel"
        static let elevenLabsVoice = "elevenLabsVoice"
        static let voiceSpeed = "voiceSpeed"
        static let speechLanguage = "speechLanguage"
        static let matchReplyLanguage = "matchReplyLanguage"
        static let spokenPrefixes = "spokenPrefixes"
        static let botOrder = "botOrder"
        static let botSections = "botSections"
        static let apiBots = "apiBots"
        static let botVoices = "botVoices"
        static let pinnedModels = "pinnedModels"
        static let mutes = "mutes"
        static let agentCalls = "agentCalls"
        static let callsWhileLocked = "callsWhileLocked"
        static let callers = "callers"
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
        static let keepRepliesInBackground = "keepRepliesInBackground"
        static let suggestFollowUps = "suggestFollowUps"
        static let agentsAskEachOther = "agentsAskEachOther"
        static let hermesBotsTalk = "hermesBotsTalk"
        static let askBeforeAgentsAsk = "askBeforeAgentsAsk"
        static let suggestionsFromFastLane = "suggestionsFromFastLane"
        static let earpieceAtEar = "earpieceAtEar"
        static let announceOnAirPods = "announceOnAirPods"
        static let briefingTapsOpenRun = "briefingTapsOpenRun"
        static let notificationSound = "notificationSound"
        static let returnSends = "returnSends"
        static let chatTextSize = "chatTextSize"
        static let botColors = "botColors"
        static let eventColor = "eventColor"
        static let cardColor = "cardColor"
        static let todayColor = "todayColor"
        static let todayTileColors = "todayTileColors"
        static let listLayouts = "listLayouts"
        static let todayTileOrder = "todayTileOrder"
        static let todayUpNext = "todayUpNext"
        static let cardAppearance = "cardAppearance"
        static let chatFont = "chatFont"
        static let agendaCalendars = CalendarChoice.key
        static let newEventsCalendar = CalendarChoice.newEventsKey
        static let currentLocation = CurrentLocation.key
        static let leaveByAlerts = LeaveBy.key
        static let linkPreviews = "linkPreviews"
        static let addressMaps = "addressMaps"
        static let botFaces = "botFaces"
        static let botPictures = "botPictures"
        static let replyCards = "replyCards"
        static let requireBiometrics = "requireBiometrics"
        static let siriAIEnabled = "siriAIEnabled"
        static let siriDraftsInNewConversation = "siriDraftsInNewConversation"
        static let showBots = "showBots"
        static let projectsInChatList = "projectsInChatList"
        static let notifyWhereYouAre = "notifyWhereYouAre"
        static let hiddenChatListCards = "hiddenChatListCards"
        static let lockGraceSeconds = "lockGraceSeconds"
        static let displayName = "displayName"
        static let setupDone = "setupDone"
        static let localDefaultsApplied = "localDefaultsApplied"
        static let pushRelayURL = "pushRelayURL"
        static let serveURL = "serveURL"
        static let acpURL = "acpURL"
        static let acpAgent = "acpAgent"
        static let acpFolder = "acpFolder"
        static let acpAllAgents = "acpAllAgents"
        static let serveUsername = "serveUsername"
        static let serveOpenAccess = "serveOpenAccess"
        static let hermesProfile = "hermesProfile"
        static let hermesProfileHome = "hermesProfileHome"
        static let cfAccessClientID = "cfAccessClientID"
        static let hermesServers = "hermesServers"
    }

    // MARK: - iCloud

    /// The key the server list is saved under, which `onStore` names when it changes.
    static var serversKey: String { Keys.hermesServers }

    /// The settings Sync with iCloud carries to the person's other devices, by their keys here.
    /// Each device keeps its own: the connection in use and the server it is on (and, in each
    /// server's record, the profile and model it is on), what Redde does on opening, App Lock,
    /// Siri, Phone tools, what needs a permission of the device (notifications, motion), and the
    /// push relay.
    static let syncedKeys: [String] = [
        Keys.displayName, Keys.theme, Keys.themeColors, Keys.appearance, Keys.chatTextSize, Keys.chatFont, Keys.botColors, Keys.eventColor, Keys.cardColor, Keys.todayColor, Keys.todayTileColors, Keys.listLayouts, Keys.todayTileOrder, Keys.todayUpNext, Keys.cardAppearance, Keys.agendaCalendars, Keys.newEventsCalendar, Keys.linkPreviews, Keys.addressMaps, Keys.botFaces, Keys.botPictures, Keys.replyCards, Keys.returnSends,
        Keys.voiceOrb, Keys.orbLight, Keys.carPlayCards, Keys.carPlayVoice, Keys.carPlayBots, Keys.showBots, Keys.projectsInChatList, Keys.notifyWhereYouAre, Keys.hiddenChatListCards,
        Keys.fastLaneURL, Keys.fastLaneModel, Keys.pinnedModels, Keys.reasoningEffort, Keys.replyLanguage, Keys.measureUnits, Keys.contextWindow,
        Keys.suggestFollowUps, Keys.agentsAskEachOther, Keys.hermesBotsTalk, Keys.askBeforeAgentsAsk, Keys.suggestionsFromFastLane, Keys.showLiveActivity, Keys.keepRepliesInBackground, Keys.notificationSound, Keys.announceOnAirPods, Keys.briefingTapsOpenRun, Keys.earpieceAtEar,
        Keys.handsFreeByDefault, Keys.newConversationForVoice, Keys.talkOver, Keys.interruption, Keys.stopAndSkipInCar, Keys.stopPhrases,
        Keys.answerRequestsByVoice, Keys.shortAnswersInCar, Keys.thinkingSound, Keys.voiceEngine, Keys.liveVoice, Keys.liveVoices, Keys.liveHangUp, Keys.liveWhenLocked, Keys.liveGroupCalls,
        Keys.replyVoice, Keys.kokoroURL, Keys.speechModel,
        Keys.kokoroVoice, Keys.elevenLabsVoice, Keys.voiceSpeed, Keys.speechLanguage, Keys.matchReplyLanguage, Keys.spokenPrefixes,
        Keys.botOrder, Keys.botSections, Keys.apiBots, Keys.botVoices, Keys.mutes, Keys.wakePhrases,
    ]

    /// The look: what a device with Sync Appearance off keeps to itself (asked 2026-11-25: "allow
    /// device sync between devices but still allow for diff themes"). Its theme and colours, light
    /// or dark, font and text size, the cards' and Today tiles' colours, bot faces and colours, and
    /// the voice orb. Everything else on `syncedKeys` still goes between its devices.
    static let lookKeys: Set<String> = [
        Keys.theme, Keys.themeColors, Keys.appearance, Keys.chatTextSize, Keys.chatFont, Keys.botColors, Keys.botFaces,
        Keys.eventColor, Keys.cardColor, Keys.cardAppearance, Keys.todayColor, Keys.todayTileColors, Keys.listLayouts, Keys.voiceOrb, Keys.orbLight,
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
        case Keys.eventColor: eventColor = pick(EventColor.byCalendar)
        case Keys.cardColor: cardColor = pick(CardColor.plain)
        case Keys.todayColor: todayColor = pick(TodayColor.plain)
        case Keys.todayTileColors: todayTileColors = value as? [String: String] ?? [:]
        case Keys.listLayouts: listLayouts = value as? [String: String] ?? [:]
        case Keys.todayTileOrder: todayTileOrder = value as? [String] ?? []
        case Keys.todayUpNext: todayUpNext = flag()
        case Keys.cardAppearance: cardAppearance = pick(Appearance.system)
        case Keys.chatFont: chatFont = pick(ChatFont.theme)
        case Keys.agendaCalendars: agendaCalendars = value as? [String] ?? []
        case Keys.newEventsCalendar: newEventsCalendar = value as? String ?? ""
        case Keys.pinnedModels: pinnedModels = decoded([:])
        case Keys.linkPreviews: linkPreviews = flag()
        case Keys.addressMaps: addressMaps = flag(true)
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
        case Keys.notifyWhereYouAre: notifyWhereYouAre = flag(true)
        case Keys.hiddenChatListCards: hiddenChatListCards = value as? [String] ?? []
        case Keys.fastLaneURL: fastLaneURL = text(Self.defaultFastLaneURL)
        case Keys.fastLaneModel: fastLaneModel = text(Self.defaultFastLaneModel)
        case Keys.reasoningEffort: reasoningEffort = text(Self.defaultReasoningEffort)
        case Keys.replyLanguage: replyLanguage = text()
        case Keys.measureUnits: measureUnits = MeasureUnits(rawValue: text()) ?? .automatic
        case Keys.contextWindow: contextWindow = (value as? Int).flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultContextWindow
        case Keys.suggestFollowUps: suggestFollowUps = flag()
        case Keys.agentsAskEachOther: agentsAskEachOther = flag(true)
        case Keys.hermesBotsTalk: hermesBotsTalk = flag(true)
        case Keys.askBeforeAgentsAsk: askBeforeAgentsAsk = flag(true)
        case Keys.suggestionsFromFastLane: suggestionsFromFastLane = flag()
        case Keys.showLiveActivity: showLiveActivity = flag(true)
        case Keys.keepRepliesInBackground: keepRepliesInBackground = flag(true)
        case Keys.notificationSound: notificationSound = flag(true)
        case Keys.announceOnAirPods: announceOnAirPods = flag()
        case Keys.briefingTapsOpenRun: briefingTapsOpenRun = flag()
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
        case Keys.liveWhenLocked: liveWhenLocked = flag()
        case Keys.liveGroupCalls: liveGroupCalls = flag()
        case Keys.replyVoice: replyVoice = pick(ReplyVoice.onDevice)
        case Keys.kokoroURL: kokoroURL = text(Self.defaultKokoroURL)
        case Keys.kokoroVoice: kokoroVoice = text(Self.defaultKokoroVoice)
        case Keys.speechModel: speechModel = text()
        case Keys.elevenLabsVoice: elevenLabsVoice = text()
        case Keys.voiceSpeed: voiceSpeed = (value as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 1.0
        case Keys.speechLanguage: speechLanguage = text()
        case Keys.matchReplyLanguage: matchReplyLanguage = flag(true)
        case Keys.spokenPrefixes: spokenPrefixes = decoded([])
        case Keys.botOrder: botOrder = decoded([:])
        case Keys.botSections: botSections = decoded([:])
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
            // With every agent in one list, the agent is the open chat's on this device.
            if list[i].acpAllAgents, merged.acpAllAgents { merged.acpAgent = list[i].acpAgent }
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
        serveOpenAccess = after.serveOpenAccess
        acpURL = after.acpURL
        acpAgent = after.acpAgent
        acpFolder = after.acpFolder
        acpAllAgents = after.acpAllAgents
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
}

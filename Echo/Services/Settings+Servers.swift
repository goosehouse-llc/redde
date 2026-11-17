// Settings' saved servers: switching, adding and removing them, resetting, and local defaults.
import Foundation

extension Settings {
    // MARK: - Servers

    /// Shortcuts keep their own session per server and profile under keys with this prefix
    /// (`ShortcutRunner`).
    static let shortcutSessionPrefix = "shortcutSessionID"
    /// Quick capture's notes have a chat of their own the same way (`CaptureFiler`).
    static let notesSessionPrefix = "notesSessionID"

    /// Once: the keys from before they carried a server id (`shortcutSessionID`,
    /// `shortcutSessionID.<profile>`, with `.serve` for the Dashboard) belong to the first server.
    func scopeShortcutSessionKeys() {
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
    func removeShortcutSessions(server: UUID?) {
        for kind in [Self.shortcutSessionPrefix, Self.notesSessionPrefix] {
            let prefix = kind + (server.map { ".\($0.uuidString)" } ?? "")
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) }
        }
    }

    var activeServer: HermesServer? { servers.first { $0.id == activeServerID } }
    /// Changes whenever requests would go somewhere else: another server or another profile.
    /// Screens that load from the server key their loading (or their identity) on it.
    var connectionKey: String { "\(activeServerID.uuidString)|\(hermesProfile)" }

    /// Copies the working copy into the active server's record.
    func syncActiveServer() {
        guard !loadingServer, let i = servers.firstIndex(where: { $0.id == activeServerID }) else { return }
        var server = servers[i]
        server.gatewayURL = gatewayURL
        server.serveURL = serveURL
        server.serveUsername = serveUsername
        server.serveOpenAccess = serveOpenAccess
        server.acpURL = acpURL
        server.acpAgent = acpAgent
        server.acpFolder = acpFolder
        server.acpAllAgents = acpAllAgents
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
        serveOpenAccess = target.serveOpenAccess
        acpURL = target.acpURL
        acpAgent = target.acpAgent
        acpFolder = target.acpFolder
        acpAllAgents = target.acpAllAgents
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

    #if DEBUG
    /// `-echo.demoAwayBots`: one Hermes server "Home" saved (not the one in use), made once. A test
    /// that left the app on Home had it made the bridge by the next launch's arguments: that one
    /// loses the name, and any other copies go.
    func demoHomeServer() -> UUID {
        if let i = servers.firstIndex(where: { $0.id == activeServerID && $0.name == "Home" }) { servers[i].name = "" }
        let homes = servers.filter { $0.name == "Home" }
        if let home = homes.first(where: { $0.transport == .hermesServe }) {
            servers.removeAll { $0.name == "Home" && $0.id != home.id }
            return home.id
        }
        servers.removeAll { $0.name == "Home" }
        let home = HermesServer(id: UUID(), name: "Home", transport: .hermesServe, serveURL: "http://hermes.test:9119")
        servers.append(home)
        return home.id
    }
    #endif

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
        measureUnits = .automatic
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
        liveWhenLocked = false
        liveGroupCalls = false
        replyVoice = .onDevice
        kokoroURL = Self.defaultKokoroURL
        kokoroVoice = Self.defaultKokoroVoice
        speechModel = ""
        elevenLabsVoice = ""
        voiceSpeed = 1.0
        speechLanguage = ""
        matchReplyLanguage = true
        spokenPrefixes = []
        botOrder = [:]
        botSections = [:]
        apiBots = [:]
        botVoices = [:]
        mutes = [:]
        agentCalls = false
        callsWhileLocked = false
        callers = [:]
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
        keepRepliesInBackground = true
        earpieceAtEar = true
        announceOnAirPods = false
        briefingTapsOpenRun = false
        notificationSound = true
        returnSends = false
        chatTextSize = 0
        chatFont = .theme
        botColors = true
        eventColor = .byCalendar
        cardColor = .plain
        todayColor = .plain
        todayTileColors = [:]
        todayTileOrder = []
        todayUpNext = false
        cardAppearance = .system
        agendaCalendars = []
        newEventsCalendar = ""
        currentLocation = false
        leaveByAlerts = false
        linkPreviews = false
        addressMaps = true
        botFaces = true
        botPictures = true
        replyCards = true
        agentsAskEachOther = true
        hermesBotsTalk = true
        askBeforeAgentsAsk = true
        requireBiometrics = false
        siriAIEnabled = false
        siriDraftsInNewConversation = false
        showBots = true
        projectsInChatList = true
        notifyWhereYouAre = true
        hiddenChatListCards = []
        lockGraceSeconds = 60
        displayName = ""
        serveURL = Self.defaultServeURL
        serveUsername = ""
        serveOpenAccess = false
        acpURL = ""
        acpAgent = ""
        acpFolder = ""
        acpAllAgents = false
        hermesProfile = ""
        hermesProfileHome = ""
        cfAccessClientID = ""
        pushRelayURL = ""
        contextWindow = Self.defaultContextWindow
        setupDone = false
        defaults.removeObject(forKey: Keys.localDefaultsApplied)
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
        if let v = dict["speechModel"] as? String { speechModel = v }
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
}

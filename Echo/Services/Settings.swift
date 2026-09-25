import Foundation
import SwiftUI
import Observation

/// Which backend a turn is sent to.
nonisolated enum Transport: String, CaseIterable, Identifiable, Codable {
    /// Hermes gateway sessions API — the shared ledger (Telegram, CLI, Discord, Echo), with live
    /// reasoning and tool events. Bearer key required.
    case hermesSessions
    /// `hermes serve` desktop gateway over WebSocket: live reasoning, approvals, slash commands.
    case hermesServe
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
final class Settings {
    static let shared = Settings()

    // Shipped defaults are empty: the app is configured on first run. Personal builds can drop a
    // git-ignored Echo/Resources/LocalDefaults.json into the bundle to prefill (see README).
    nonisolated static let defaultGatewayURL = ""
    nonisolated static let defaultFastLaneURL = ""
    nonisolated static let defaultFastLaneModel = ""

    var transport: Transport {
        didSet { defaults.set(transport.rawValue, forKey: Keys.transport) }
    }
    var gatewayURL: String {
        didSet { defaults.set(gatewayURL, forKey: Keys.gatewayURL) }
    }
    var fastLaneURL: String {
        didSet { defaults.set(fastLaneURL, forKey: Keys.fastLaneURL) }
    }
    var fastLaneModel: String {
        didSet { defaults.set(fastLaneModel, forKey: Keys.fastLaneModel) }
    }
    /// Model for the Hermes transports. Empty = the gateway's default.
    var gatewayModel: String {
        didSet { defaults.set(gatewayModel, forKey: Keys.gatewayModel) }
    }
    /// Provider slug that goes with `gatewayModel` (Hermes routes by both). Empty = default.
    var gatewayProvider: String {
        didSet { defaults.set(gatewayProvider, forKey: Keys.gatewayProvider) }
    }
    /// "" (gateway default) | low | medium | high.
    var reasoningEffort: String {
        didSet { defaults.set(reasoningEffort, forKey: Keys.reasoningEffort) }
    }
    /// Start listening every time the app comes to the foreground. Makes the built-in
    /// "Hey Siri, open Redde" behave like the App Shortcut.
    var listenOnOpen: Bool {
        didSet { defaults.set(listenOnOpen, forKey: Keys.listenOnOpen) }
    }
    /// Voice mode opens with Hands-free switched on. Requests that ask for a mode themselves (the
    /// hands-free button, Siri, the controls) keep theirs.
    var handsFreeByDefault: Bool {
        didSet { defaults.set(handsFreeByDefault, forKey: Keys.handsFreeByDefault) }
    }
    /// Launch straight into the voice screen (without listening unless `listenOnOpen`).
    var openToVoiceScreen: Bool {
        didSet { defaults.set(openToVoiceScreen, forKey: Keys.openToVoiceScreen) }
    }
    /// Speak replies with Kokoro on Paloma instead of the on-device voice.
    var useKokoro: Bool {
        didSet { defaults.set(useKokoro, forKey: Keys.useKokoro) }
    }
    var kokoroURL: String {
        didSet { defaults.set(kokoroURL, forKey: Keys.kokoroURL) }
    }
    /// Spoken-reply speed multiplier — Kokoro's `speed` field, and the fallback
    /// synthesizer's rate scaled around the system default.
    var voiceSpeed: Double {
        didSet { defaults.set(voiceSpeed, forKey: Keys.voiceSpeed) }
    }
    var kokoroVoice: String {
        didSet { defaults.set(kokoroVoice, forKey: Keys.kokoroVoice) }
    }
    var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    /// Your accent and bubble colors, per theme (keyed by `Theme.rawValue`). A theme with no
    /// entry uses its own colors, so switching themes never carries one theme's picks to another.
    var themeColors: [String: ThemeColors] {
        didSet { defaults.set(try? JSONEncoder().encode(themeColors), forKey: Keys.themeColors) }
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
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    /// The orb at the centre of voice mode.
    var voiceOrb: VoiceOrb {
        didSet { defaults.set(voiceOrb.rawValue, forKey: Keys.voiceOrb) }
    }
    /// What the app renders in: the appearance choice, nil meaning follow the system.
    var effectiveColorScheme: ColorScheme? { appearance.colorScheme }
    /// Local notifications for approvals / replies / failures while the app is in the background.
    var notifyInBackground: Bool {
        didSet { defaults.set(notifyInBackground, forKey: Keys.notifyInBackground) }
    }
    /// Dynamic Island / Lock Screen activity while a turn runs.
    var showLiveActivity: Bool {
        didSet { defaults.set(showLiveActivity, forKey: Keys.showLiveActivity) }
    }
    /// Route replies to the earpiece when the proximity sensor says the phone is at your ear.
    /// Redde's background alerts are time-sensitive, so Siri can read them on AirPods (Announce
    /// Notifications) and they can break through a Focus.
    var announceOnAirPods: Bool {
        didSet { defaults.set(announceOnAirPods, forKey: Keys.announceOnAirPods) }
    }
    var earpieceAtEar: Bool {
        didSet { defaults.set(earpieceAtEar, forKey: Keys.earpieceAtEar) }
    }
    /// Face ID / Touch ID / passcode gate on the app.
    var requireBiometrics: Bool {
        didSet {
            defaults.set(requireBiometrics, forKey: Keys.requireBiometrics)
            if self === Settings.shared { SiriHooks.indexInputsChanged() }   // App Lock indexes titles only
        }
    }
    /// Siri AI (iOS 27) may send messages to Redde and see its conversations. Off by default:
    /// Apple Intelligence then reads what you say to Siri, the one path that leaves the tailnet.
    var siriAIEnabled: Bool {
        didSet {
            defaults.set(siriAIEnabled, forKey: Keys.siriAIEnabled)
            if self === Settings.shared, oldValue != siriAIEnabled { SiriHooks.accessChanged(siriAIEnabled) }
        }
    }
    /// How long the app may be in the background before it locks again.
    var lockGraceSeconds: Double {
        didSet { defaults.set(lockGraceSeconds, forKey: Keys.lockGraceSeconds) }
    }
    /// What the header calls the assistant. Empty means "Redde".
    var displayName: String {
        didSet { defaults.set(displayName, forKey: Keys.displayName) }
    }
    var headerTitle: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Redde" : trimmed
    }

    // hermes serve (desktop gateway). Password lives in the Keychain.
    var serveURL: String {
        didSet { defaults.set(serveURL, forKey: Keys.serveURL) }
    }
    var serveUsername: String {
        didSet { defaults.set(serveUsername, forKey: Keys.serveUsername) }
    }
    /// The Hermes profile Redde talks to; empty means the server's default profile. Nothing
    /// profile-related is sent for the default, so servers without profile support keep working.
    var hermesProfile: String {
        didSet { defaults.set(hermesProfile, forKey: Keys.hermesProfile) }
    }
    /// That profile's home directory on the server (from the dashboard's profile list), where
    /// its context and memory files live. Empty: the default `~/.hermes`.
    var hermesProfileHome: String {
        didSet { defaults.set(hermesProfileHome, forKey: Keys.hermesProfileHome) }
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

    /// Where a file under `~/.hermes` lives for the selected profile, e.g. "SOUL.md". Uses the
    /// home the server reported, else Hermes's layout for named profiles (`~/.hermes/profiles/<name>`).
    func profileFilePath(_ relative: String) -> String {
        guard let name = profileName else { return "~/.hermes/\(relative)" }
        var home = hermesProfileHome.trimmingCharacters(in: .whitespacesAndNewlines)
        if home.isEmpty { home = "~/.hermes/profiles/\(name)" }
        while home.hasSuffix("/") { home.removeLast() }
        return home + "/" + relative
    }

    /// Cloudflare Access service-token id (`CF-Access-Client-Id`); the secret lives in the Keychain.
    var cfAccessClientID: String {
        didSet { defaults.set(cfAccessClientID, forKey: Keys.cfAccessClientID) }
    }

    /// Headers Cloudflare Access expects in front of hermes serve, or empty when not configured.
    nonisolated static func cloudflareAccessHeaders(clientID: String, secret: String?) -> [String: String] {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, let secret, !secret.isEmpty else { return [:] }
        return ["CF-Access-Client-Id": id, "CF-Access-Client-Secret": secret]
    }
    var accessHeaders: [String: String] {
        Self.cloudflareAccessHeaders(clientID: cfAccessClientID, secret: Keychain.read(.cfAccessClientSecret))
    }
    nonisolated static let defaultServeURL = ""
    var serveBaseURL: URL? {
        let raw = serveURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw.hasSuffix("/") ? String(raw.dropLast()) : raw)
    }

    /// Fallback when the backend doesn't report its window (the gateway doesn't). Paloma runs 131072.
    var contextWindow: Int {
        didSet { defaults.set(contextWindow, forKey: Keys.contextWindow) }
    }

    /// Push relay (companion/push-relay): hermes webhooks become APNs alerts. Empty = off.
    var pushRelayURL: String {
        didSet { defaults.set(pushRelayURL, forKey: Keys.pushRelayURL) }
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
        static let listenOnOpen = "listenOnOpen"
        static let openToVoiceScreen = "openToVoiceScreen"
        static let handsFreeByDefault = "handsFreeByDefault"
        static let useKokoro = "useKokoro"
        static let kokoroURL = "kokoroURL"
        static let kokoroVoice = "kokoroVoice"
        static let voiceSpeed = "voiceSpeed"
        static let contextWindow = "contextWindow"
        static let theme = "theme"
        static let themeColors = "themeColors"
        static let appearance = "appearance"
        static let voiceOrb = "voiceOrb"
        static let notifyInBackground = "notifyInBackground"
        static let showLiveActivity = "showLiveActivity"
        static let earpieceAtEar = "earpieceAtEar"
        static let announceOnAirPods = "announceOnAirPods"
        static let requireBiometrics = "requireBiometrics"
        static let siriAIEnabled = "siriAIEnabled"
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
        reasoningEffort = defaults.string(forKey: Keys.reasoningEffort) ?? ""
        listenOnOpen = defaults.bool(forKey: Keys.listenOnOpen)
        openToVoiceScreen = defaults.bool(forKey: Keys.openToVoiceScreen)
        handsFreeByDefault = defaults.bool(forKey: Keys.handsFreeByDefault)
        useKokoro = defaults.bool(forKey: Keys.useKokoro)
        kokoroURL = defaults.string(forKey: Keys.kokoroURL) ?? Self.defaultKokoroURL
        kokoroVoice = defaults.string(forKey: Keys.kokoroVoice) ?? Self.defaultKokoroVoice
        // "kokoroSpeed" was this setting's name for one build; carry the value over.
        let storedSpeed = defaults.double(forKey: Keys.voiceSpeed)
        let legacySpeed = defaults.double(forKey: "kokoroSpeed")
        voiceSpeed = storedSpeed != 0 ? storedSpeed : (legacySpeed != 0 ? legacySpeed : 1.0)
        theme = Theme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .standard
        themeColors = defaults.data(forKey: Keys.themeColors)
            .flatMap { try? JSONDecoder().decode([String: ThemeColors].self, from: $0) } ?? [:]
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        voiceOrb = VoiceOrb(rawValue: defaults.string(forKey: Keys.voiceOrb) ?? "") ?? .waveform
        notifyInBackground = defaults.bool(forKey: Keys.notifyInBackground)
        showLiveActivity = defaults.object(forKey: Keys.showLiveActivity) as? Bool ?? true
        earpieceAtEar = defaults.object(forKey: Keys.earpieceAtEar) as? Bool ?? true
        announceOnAirPods = defaults.bool(forKey: Keys.announceOnAirPods)
        requireBiometrics = defaults.bool(forKey: Keys.requireBiometrics)
        siriAIEnabled = defaults.bool(forKey: Keys.siriAIEnabled)
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
    }

    /// Back to first-run values. Secrets live in the Keychain and are cleared by the caller.
    func reset() {
        transport = .hermesSessions
        gatewayURL = Self.defaultGatewayURL
        fastLaneURL = Self.defaultFastLaneURL
        fastLaneModel = Self.defaultFastLaneModel
        gatewayModel = ""
        gatewayProvider = ""
        reasoningEffort = ""
        listenOnOpen = false
        openToVoiceScreen = false
        handsFreeByDefault = false
        useKokoro = false
        kokoroURL = Self.defaultKokoroURL
        kokoroVoice = Self.defaultKokoroVoice
        voiceSpeed = 1.0
        theme = .standard
        themeColors = [:]
        appearance = .system
        voiceOrb = .waveform
        notifyInBackground = false
        showLiveActivity = true
        earpieceAtEar = true
        announceOnAirPods = false
        requireBiometrics = false
        siriAIEnabled = false
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
        case .hermesServe: return serveBaseURL != nil && !serveUsername.isEmpty && Keychain.read(.serveDashboardPassword) != nil
        case .chatCompletions: return activeBaseURL != nil && !fastLaneModel.isEmpty
        }
    }

    /// Set after the first-run setup completes (or is skipped).
    var setupDone: Bool {
        didSet { defaults.set(setupDone, forKey: Keys.setupDone) }
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

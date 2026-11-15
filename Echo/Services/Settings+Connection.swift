// Settings for the server in use: per-server values, the agent's name, profiles, headers and addresses.
import Foundation

extension Settings {
    /// `callers` for the server in use.
    var callersHere: [String] {
        get { callers[activeServerID.uuidString] ?? [] }
        set { callers[activeServerID.uuidString] = newValue.isEmpty ? nil : newValue }
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
    /// `pinnedModels` for the connection in use.
    var pinnedModelsHere: [ModelChoice] {
        get { pinnedModels[pinnedModelsKey] ?? pinnedModels[activeServerID.uuidString] ?? [] }
        set {
            pinnedModels[pinnedModelsKey] = newValue.isEmpty ? nil : newValue
            if pinnedModelsKey != activeServerID.uuidString { pinnedModels[activeServerID.uuidString] = nil }
        }
    }
    /// Pins go by the server's host ("host:dchermes"), not its record's id: a server added on each
    /// device by hand has a different id on each, and the pins didn't follow (11-07). The fast lane's
    /// are its own.
    private var pinnedModelsKey: String {
        if transport == .chatCompletions { return "fastLane" }
        let address = activeServer.map { $0.serveURL.isEmpty ? $0.gatewayURL : $0.serveURL } ?? ""
        if let host = (URL(string: address)?.host() ?? URL(string: "http://" + address)?.host())?.lowercased(), !host.isEmpty {
            return "host:" + host
        }
        return activeServerID.uuidString
    }
    func isPinned(_ choice: ModelChoice) -> Bool { pinnedModelsHere.contains { $0.id == choice.id } }
    /// Pins a model at the end of the pinned ones, or unpins it.
    func togglePin(_ choice: ModelChoice) {
        if isPinned(choice) { pinnedModelsHere.removeAll { $0.id == choice.id } }
        else { var kept = choice; kept.isCurrent = false; pinnedModelsHere.append(kept) }
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
    /// `botSections` for the server in use.
    var botSectionsHere: BotSectionsHere {
        get { botSections[activeServerID.uuidString] ?? BotSectionsHere() }
        set { botSections[activeServerID.uuidString] = newValue.isEmpty ? nil : newValue }
    }

    var headerTitle: String {
        // A bridge agent is called what it calls itself (Claude Code, Codex), not by the name given
        // to the Hermes agent (2026-11-14: "Sol is thinking" in a Claude Code chat).
        if transport == .acp, let name = acpAgentName { return name }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "Redde"
    }

    /// The bridge agent the app is on, by what it calls itself when connected, else the bridge's
    /// name for it, else its id. Nil when there is no agent (the demo agent before it has said).
    var acpAgentName: String? {
        if let socket = AcpEndpoint.make(address: acpURL, agent: acpAgent, token: nil, folder: nil)?.socketURL,
           let name = acpAgentNames[socket.absoluteString] {
            return name
        }
        return acpAgent.isEmpty ? nil : AcpAgents.name(of: acpAgent, self)
    }

    /// Where the ACP agent is, when it is set up.
    /// One agent of the bridge's (a chat's own, with every agent in one list), else the server's.
    func acpEndpoint(agent: String?) -> AcpEndpoint? {
        AcpEndpoint.make(address: acpURL, agent: agent ?? acpAgent, token: Keychain.read(.acpToken), folder: acpFolder)
    }
    var acpEndpoint: AcpEndpoint? {
        AcpEndpoint.make(address: acpURL, agent: acpAgent, token: Keychain.read(.acpToken), folder: acpFolder)
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

    /// The Hermes API base. A named profile goes through the gateway's `/p/<profile>/` routes,
    /// which exist when the gateway multiplexes profiles (`gateway.multiplex_profiles`).
    var gatewayBaseURL: URL? {
        guard let base = Self.normalizedBase(gatewayURL) else { return nil }
        return profileName.map { base.appending(path: "p/\($0)") } ?? base
    }

    /// The active server's Dashboard used as one with no sign-in, the person having been warned
    /// (asked 2026-10-30). The saved login goes (username, password, a browser sign-in): the
    /// Dashboard has nothing to check it against, and with it saved the app would keep trying it.
    func useDashboardWithoutLogin() {
        serveUsername = ""
        Keychain.delete(.serveDashboardPassword)
        DashboardTokenStore.keychain.write(nil)
        serveOpenAccess = true
    }

    /// True once the selected transport has what it needs to make a request.
    var isConfigured: Bool {
        switch transport {
        case .hermesSessions: return gatewayBaseURL != nil && gatewayAPIKey != nil
        case .hermesServe:
            return serveBaseURL != nil && (DashboardSignIn.tokens(for: serveBaseURL, in: .keychain) != nil
                || (!serveUsername.isEmpty && Keychain.read(.serveDashboardPassword) != nil) || serveOpenAccess)
        case .chatCompletions: return activeBaseURL != nil && !fastLaneModel.isEmpty
        case .acp: return acpEndpoint != nil
        }
    }

    var activeBaseURL: URL? {
        if transport == .hermesServe { return serveBaseURL }
        if transport.usesGateway { return gatewayBaseURL }
        if transport == .acp { return acpEndpoint?.socketURL }
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

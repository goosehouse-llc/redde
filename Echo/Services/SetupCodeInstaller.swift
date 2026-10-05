import Foundation

/// Saving a setup code, and making one from what is saved.
///
/// The rule that keeps a link from doing harm: a code is only ever combined with secrets it
/// brought itself. It fills in the active server only while nothing is stored for that one (so it
/// has never connected), and otherwise becomes a new server; and a model endpoint at a new
/// address never inherits the key saved for the old one.
@MainActor
extension SetupCode {
    /// What saving a code changes: the confirmation says it, `install` does it.
    struct Plan: Equatable {
        enum Server: Equatable {
            /// The code has no Hermes server in it.
            case none
            /// The active server has never been set up: the code fills it in.
            case fill
            /// A new server, which becomes the active one.
            case add
        }
        var server: Server
        /// A saved server that already has these addresses, by its title: the code adds another.
        var sameAs: String?
        /// The address of an OpenAI-compatible endpoint this replaces, whose key is forgotten.
        /// That connection is the app's, not a server's, so there is only the one.
        var replacesModelURL: String?
        /// What the app talks to afterwards.
        var transport: Transport
    }

    func plan(for settings: Settings) -> Plan {
        let server: Plan.Server = !hasServer ? .none : settings.activeServerIsUnused ? .fill : .add
        var sameAs: String?
        if server == .add {
            func tidy(_ address: String) -> String { Settings.normalizedBase(address)?.absoluteString ?? "" }
            sameAs = settings.servers.first {
                (dashboardURL.isEmpty || tidy($0.serveURL) == dashboardURL) && (apiURL.isEmpty || tidy($0.gatewayURL) == apiURL)
            }?.title
        }
        let current = settings.fastLaneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = modelURL.isEmpty || current.isEmpty || sameModelEndpoint(in: settings) ? nil : current
        return Plan(server: server, sameAs: sameAs, replacesModelURL: replaced, transport: transport ?? settings.transport)
    }

    private func sameModelEndpoint(in settings: Settings) -> Bool {
        Settings.normalizedBase(settings.fastLaneURL)?.absoluteString == modelURL
    }

    /// What a saved code changed that `remove` puts back.
    struct Receipt: Equatable {
        var plan: Plan
        /// The server the code added, and the one that was active before it.
        var added: UUID?
        var previousServer: UUID
        var transport: Transport
        /// The model endpoint as it was, when the code wrote one.
        var wroteModel: Bool
        var modelURL: String
        var model: String
        var modelKey: String?
    }

    /// Saves the code. `switchServer` makes a server the code added the active one; the app
    /// passes `ServerSwitcher`, which also closes the old server's conversation and connection.
    @discardableResult
    func install(in settings: Settings, switchServer: (UUID) -> Void) -> Receipt {
        var receipt = Receipt(plan: plan(for: settings), previousServer: settings.activeServerID, transport: settings.transport,
                              wroteModel: !modelURL.isEmpty, modelURL: settings.fastLaneURL, model: settings.fastLaneModel,
                              modelKey: modelURL.isEmpty ? nil : Keychain.read(.fastLaneAPIKey))
        let plan = receipt.plan
        switch plan.server {
        case .none:
            break
        case .fill:
            if !name.isEmpty { settings.renameServer(settings.activeServerID, to: name) }
        case .add:
            let id = settings.addServer(name: name)
            switchServer(id)
            // Not switched (a caller that declined): the code must not land in another server.
            guard settings.activeServerID == id else {
                settings.removeServer(id)
                return receipt
            }
            receipt.added = id
        }
        if plan.server != .none {
            // Every field, so nothing typed there before is left mixed in with the code.
            settings.serveURL = dashboardURL
            settings.serveUsername = dashboardUser
            settings.gatewayURL = apiURL
            settings.hermesProfile = profile
            settings.hermesProfileHome = ""
            settings.cfAccessClientID = accessID
            settings.gatewayModel = ""
            settings.gatewayProvider = ""
            // Filed under the server by name, not under "the active one": that is read from the
            // app's own defaults, which a Settings made for a test doesn't share. Nothing is
            // stored for this server yet (it is new or unused), so a blank needs no deleting.
            let server = settings.activeServerID.uuidString
            store(dashboardPassword, account: Keychain.account(.serveDashboardPassword, server: server))
            store(apiKey, account: Keychain.account(.gatewayAPIKey, server: server))
            store(accessSecret, account: Keychain.account(.cfAccessClientSecret, server: server))
            if let profile = settings.profileName {
                store(profileKey, account: Keychain.profileAccount(profile, server: server))
            }
        }
        if !modelURL.isEmpty {
            // A different endpoint must not be sent the key saved for the old one: the code's key
            // replaces it, and no key in the code means no key. The same endpoint keeps its key.
            if !modelKey.isEmpty || !sameModelEndpoint(in: settings) { Keychain.write(.fastLaneAPIKey, value: modelKey) }
            settings.fastLaneURL = modelURL
            if !model.isEmpty { settings.fastLaneModel = model }
        }
        settings.transport = plan.transport
        return receipt
    }

    /// Takes a code that added a server back out: the server and its secrets go, and the server,
    /// connection and model endpoint from before return. A code that filled in an unused server
    /// has nothing to go back to; that one is corrected in Setup.
    static func remove(_ receipt: Receipt, from settings: Settings, switchServer: (UUID) -> Void) {
        guard let added = receipt.added else { return }
        switchServer(receipt.previousServer)
        guard settings.activeServerID == receipt.previousServer else { return }
        settings.removeServer(added)
        if receipt.wroteModel {
            settings.fastLaneURL = receipt.modelURL
            settings.fastLaneModel = receipt.model
            Keychain.write(.fastLaneAPIKey, value: receipt.modelKey ?? "")   // blank deletes
        }
        settings.transport = receipt.transport
    }

    /// A blank value writes nothing: `Keychain.write` would take it as "delete".
    private func store(_ value: String, account: String) {
        if !value.isEmpty { Keychain.write(account: account, value: value) }
    }

    /// The code that sets another device up like this one for `server`: its addresses and names,
    /// and with `secrets` its passwords and keys too. The OpenAI-compatible endpoint goes along
    /// when there is one, since it is part of how this phone is set up.
    init(server: HermesServer, settings: Settings, secrets: Bool) {
        self.init()
        let id = server.id.uuidString
        name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        dashboardURL = Settings.normalizedBase(server.serveURL)?.absoluteString ?? ""
        dashboardUser = dashboardURL.isEmpty ? "" : server.serveUsername
        apiURL = Settings.normalizedBase(server.gatewayURL)?.absoluteString ?? ""
        let profileName = server.hermesProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        let namedProfile = !profileName.isEmpty && profileName.lowercased() != "default"
        profile = namedProfile ? profileName : ""
        accessID = server.cfAccessClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        modelURL = Settings.normalizedBase(settings.fastLaneURL)?.absoluteString ?? ""
        model = modelURL.isEmpty ? "" : settings.fastLaneModel
        let active = server.id == settings.activeServerID
        use = active && settings.transport == .chatCompletions ? .chatCompletions : server.transport
        // Only said when the code carries that connection; otherwise the first it carries is used.
        if transport != use { use = nil }
        guard secrets else { return }
        if !dashboardURL.isEmpty {
            dashboardPassword = Keychain.read(account: Keychain.account(.serveDashboardPassword, server: id)) ?? ""
        }
        if !apiURL.isEmpty {
            apiKey = Keychain.read(account: Keychain.account(.gatewayAPIKey, server: id)) ?? ""
            if namedProfile { profileKey = Keychain.read(account: Keychain.profileAccount(profileName, server: id)) ?? "" }
        }
        if !accessID.isEmpty {
            accessSecret = Keychain.read(account: Keychain.account(.cfAccessClientSecret, server: id)) ?? ""
        }
        if !modelURL.isEmpty { modelKey = Keychain.read(.fastLaneAPIKey) ?? "" }
    }
}

extension Settings {
    /// Nothing has ever been stored for the active server (no key, password or token), so it
    /// has never connected: a first run, a server just added, an address typed and left. When
    /// the Keychain can't be read the answer is no, so a server is never taken for unused.
    var activeServerIsUnused: Bool {
        Keychain.hasAccount(endingWith: "@\(activeServerID.uuidString)") == false
    }
}

extension ConnectionTester {
    /// Whichever connection Settings selects, with the secrets stored for it.
    @MainActor
    static func current(_ settings: Settings = .shared) async -> Outcome {
        switch settings.transport {
        case .hermesSessions:
            guard let url = settings.gatewayBaseURL else { return .failed("The Hermes API address isn't a valid URL.") }
            return await hermesAPI(url: url, apiKey: settings.gatewayAPIKey)
        case .hermesServe:
            guard let url = settings.serveBaseURL else { return .failed("The Dashboard address isn't a valid URL.") }
            return await hermesServe(url: url)
        case .chatCompletions:
            guard let url = settings.activeBaseURL else { return .failed("The endpoint address isn't a valid URL.") }
            return await fastLane(url: url, apiKey: Keychain.read(.fastLaneAPIKey), model: settings.fastLaneModel)
        }
    }
}

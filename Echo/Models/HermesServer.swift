import Foundation

/// A saved Hermes server: how to reach it and which profile and model to use there. Its secrets
/// (API key, Dashboard password, Cloudflare Access secret, per-profile keys) live in the Keychain
/// under its id (`Keychain.account(_:server:)`).
nonisolated struct HermesServer: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// Which Hermes connection this server is used with.
    var transport: Transport = .hermesServe
    var gatewayURL = ""
    var serveURL = ""
    var serveUsername = ""
    var cfAccessClientID = ""
    var gatewayModel = ""
    var gatewayProvider = ""
    var hermesProfile = ""
    var hermesProfileHome = ""
    /// The Dashboard has no sign-in, and the person chose to use it that way, warned that anyone
    /// who reaches its address can use the agent (asked 2026-10-30). No secret goes with it: the
    /// Dashboard's session token is read off its page each time and never stored.
    var serveOpenAccess = false

    init(id: UUID, name: String, transport: Transport = .hermesServe, gatewayURL: String = "", serveURL: String = "",
         serveUsername: String = "", cfAccessClientID: String = "", gatewayModel: String = "", gatewayProvider: String = "",
         hermesProfile: String = "", hermesProfileHome: String = "", serveOpenAccess: Bool = false) {
        self.id = id; self.name = name; self.transport = transport
        self.gatewayURL = gatewayURL; self.serveURL = serveURL; self.serveUsername = serveUsername
        self.cfAccessClientID = cfAccessClientID; self.gatewayModel = gatewayModel; self.gatewayProvider = gatewayProvider
        self.hermesProfile = hermesProfile; self.hermesProfileHome = hermesProfileHome
        self.serveOpenAccess = serveOpenAccess
    }

    /// Every field but the id may be missing, so a record written by another version still
    /// loads. A synthesized decoder would throw on a missing key, and the servers (and the
    /// Keychain secrets filed under their ids) would be lost.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? .hermesServe
        gatewayURL = try c.decodeIfPresent(String.self, forKey: .gatewayURL) ?? ""
        serveURL = try c.decodeIfPresent(String.self, forKey: .serveURL) ?? ""
        serveUsername = try c.decodeIfPresent(String.self, forKey: .serveUsername) ?? ""
        cfAccessClientID = try c.decodeIfPresent(String.self, forKey: .cfAccessClientID) ?? ""
        gatewayModel = try c.decodeIfPresent(String.self, forKey: .gatewayModel) ?? ""
        gatewayProvider = try c.decodeIfPresent(String.self, forKey: .gatewayProvider) ?? ""
        hermesProfile = try c.decodeIfPresent(String.self, forKey: .hermesProfile) ?? ""
        hermesProfileHome = try c.decodeIfPresent(String.self, forKey: .hermesProfileHome) ?? ""
        serveOpenAccess = try c.decodeIfPresent(Bool.self, forKey: .serveOpenAccess) ?? false
    }

    /// Its name, else the host of whichever address it uses, else a placeholder.
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let primary = transport == .hermesSessions ? [gatewayURL, serveURL] : [serveURL, gatewayURL]
        for raw in primary {
            if let host = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?.host(), !host.isEmpty {
                return host
            }
        }
        return String(localized: "New server", comment: "A saved server's name until it is given one")
    }
}

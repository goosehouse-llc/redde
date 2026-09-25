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
        return "New server"
    }
}

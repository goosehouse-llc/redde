import CryptoKit
import Foundation
import Observation

/// A key a bot asked for (asked 2026-10-29: "keys go from you straight to the server"): the bot
/// calls `request_secret` with a name, the person pastes the key into a card here, and Redde's
/// plugin writes it into that profile's .env. No model, chat, log or notification holds the
/// value: the bot learns only "set" or "declined" (companion/hermes-plugin/redde-push/keys.py).
nonisolated struct KeyRequest: Identifiable, Equatable, Sendable {
    let id: String
    /// The variable it is saved as: JELLYFIN_API_KEY.
    let name: String
    /// The profile whose .env it goes in ("default", the main agent's).
    let profile: String
    let why: String
    /// The asking agent's profile, and what it is called.
    let asker: String
    let askerName: String
    /// A key by that name is there already: this one takes its place.
    let replace: Bool
    /// The request's own public key, X25519: the key is sealed to it, and only it opens it.
    let publicKey: Data
    let until: Date

    /// From the plugin's list (`/redde-push keys list`): `i`, `t`, `g`, `b`, `p`, `d`, `r`, `k`, `u`.
    init?(listed value: JSONValue) {
        guard let id = value["i"]?.string, !id.isEmpty, let name = value["t"]?.string, !name.isEmpty,
              let key = value["k"]?.string.flatMap(PushSeal.data(base64URL:)), key.count == 32 else { return nil }
        self.id = id
        self.name = name
        profile = value["g"]?.string ?? "default"
        why = value["b"]?.string ?? ""
        asker = value["p"]?.string ?? ""
        askerName = value["d"]?.string ?? ""
        replace = value["r"]?.bool ?? false
        publicKey = key
        until = Date(timeIntervalSince1970: value["u"]?.number ?? 0)
    }

    init(id: String, name: String, profile: String, why: String, asker: String, askerName: String, replace: Bool,
         publicKey: Data, until: Date) {
        self.id = id; self.name = name; self.profile = profile; self.why = why; self.asker = asker
        self.askerName = askerName; self.replace = replace; self.publicKey = publicKey; self.until = until
    }

    /// Where it goes, as the card says it.
    var destination: String {
        profile == "default"
            ? String(localized: "Your main agent's .env", comment: "Key request card: the key goes into the main agent's settings file")
            : String(localized: "\(profile)'s .env", comment: "Key request card: the key goes into a bot's settings file, by its profile name")
    }

    /// Who asked, as the card's heading says it.
    var who: String { askerName.isEmpty ? (asker.isEmpty || asker == "default" ? String(localized: "Your agent") : asker) : askerName }
}

/// Sealing a key to its request (the plugin's `keys.opened` is the other half): X25519 between a
/// key pair made here for this one answer and the request's, HKDF-SHA256 with both public keys as
/// salt, AES-GCM with the request's id, name and profile as associated data, so the box opens for
/// that request and nothing else. Nothing about the key is kept.
nonisolated enum KeySeal {
    static let info = Data("redde-push key v1".utf8)

    static func associatedData(_ request: KeyRequest) -> Data {
        Data("\(request.id)\n\(request.name)\n\(request.profile)".utf8)
    }

    /// This phone's public key and the sealed key, base64url, as the plugin takes them. The key
    /// pair and the nonce are given only by a test, to compare with the plugin's own sealing.
    static func seal(_ value: String, to request: KeyRequest,
                     ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(),
                     nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> (publicKey: String, box: String) {
        let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.publicKey)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: theirs)
        let mine = ephemeral.publicKey.rawRepresentation
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: mine + request.publicKey, sharedInfo: info,
                                                 outputByteCount: 32)
        let box = try AES.GCM.seal(Data(value.utf8), using: key, nonce: nonce, authenticating: associatedData(request))
        guard let combined = box.combined else { throw KeyRequestError.refused("seal") }
        return (PushSeal.base64URL(mine), PushSeal.base64URL(combined))
    }
}

nonisolated enum KeyRequestError: LocalizedError, Equatable {
    /// No Dashboard login for this server: the only way a key reaches the plugin.
    case noDashboard
    case noPlugin
    /// Answered already, or expired.
    case gone
    case empty
    case notOneLine
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .noDashboard:
            String(localized: "Saving a key needs this server's Hermes Dashboard login (Settings › Connection). Over the Hermes API alone there's no safe way to hand it over, so nothing was sent.")
        case .noPlugin:
            String(localized: "This Hermes's Redde plugin can't take keys yet. Update the plugin there, restart Hermes, and try again.")
        case .gone: String(localized: "That request was answered already, or it expired.")
        case .empty: String(localized: "Paste the key first.")
        case .notOneLine: String(localized: "A key is one line: this has more than one.")
        case .refused(let why): String(localized: "Your Hermes didn't take it (\(why)). Nothing was saved.")
        }
    }
}

/// The keys bots have asked for on the server in use, and the person's answers. Asked of the
/// plugin only when there is reason to (a notification, a request's card in a chat, the list in
/// Settings), never at launch or per message.
@MainActor
@Observable
final class KeyRequests {
    static let shared = KeyRequests()

    private(set) var pending: [KeyRequest] = []
    /// The card open over the app.
    var showing: KeyRequest?
    /// Something to say where the card would have been: the request was answered, the server
    /// can't be reached.
    var notice: String?
    private(set) var loading = false
    /// Whether this server can be answered at all (its Dashboard login). Nil until asked.
    private(set) var canAnswer: Bool?

    @ObservationIgnored var plugin: PushService.PluginCommand = PushService.command(over: .shared)
    @ObservationIgnored var reachable: () async -> Bool = { await HermesServeClient.shared.canUse() }
    @ObservationIgnored var restart: () async throws -> Void = { _ = try await HermesServeClient.shared.restartGateway() }

    enum Outcome: Equatable { case set(String), declined }

    func reload() async {
        loading = true
        defer { loading = false }
        guard await reachable() else {
            canAnswer = false
            return
        }
        canAnswer = true
        do {
            let reply = try await plugin("keys list")
            guard reply.hasPrefix("redde-push keys ") else { return }
            let json = Data(reply.dropFirst("redde-push keys ".count).utf8)
            pending = ((try? JSONValue.parse(json))?.array ?? []).compactMap(KeyRequest.init(listed:))
        } catch PushError.noPlugin {
            pending = []
        } catch {
            notice = error.localizedDescription
        }
    }

    /// From a notification or a chat's card: the request, fetched afresh, open over the app.
    func show(id: String) {
        Task {
            await reload()
            if let found = pending.first(where: { $0.id == id }) {
                showing = found
            } else if canAnswer == false {
                notice = KeyRequestError.noDashboard.errorDescription
            } else {
                notice = KeyRequestError.gone.errorDescription
            }
        }
    }

    /// The key, sealed to its request, handed to the plugin. The value goes nowhere else: not to a
    /// log, the store, the clipboard or a chat.
    func answer(_ request: KeyRequest, with pasted: String) async throws -> Outcome {
        let value = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw KeyRequestError.empty }
        guard !value.contains(where: \.isNewline), !value.contains("\0") else { throw KeyRequestError.notOneLine }
        guard await reachable() else { throw KeyRequestError.noDashboard }
        let sealed = try KeySeal.seal(value, to: request)
        let reply: String
        do {
            reply = try await plugin("keys set \(request.id) \(sealed.publicKey) \(sealed.box)")
        } catch PushError.noPlugin {
            throw KeyRequestError.noPlugin
        }
        return try settle(request, reply: reply)
    }

    func decline(_ request: KeyRequest) async throws {
        guard await reachable() else { throw KeyRequestError.noDashboard }
        _ = try settle(request, reply: try await plugin("keys decline \(request.id)"))
    }

    func restartHermes() async throws { try await restart() }

    private func settle(_ request: KeyRequest, reply: String) throws -> Outcome {
        let words = reply.split(separator: " ").map(String.init)
        guard words.count >= 3, words[0] == "redde-push", words[1] == "keys" else { throw KeyRequestError.noPlugin }
        switch words[2] {
        case "set", "declined":
            pending.removeAll { $0.id == request.id }
            return words[2] == "set" ? .set(request.name) : .declined
        case "gone":
            pending.removeAll { $0.id == request.id }
            throw KeyRequestError.gone
        default:
            throw KeyRequestError.refused(words.dropFirst(3).joined(separator: " "))
        }
    }

    #if DEBUG
    /// `-echo.demoKeyRequest`: a request shown over the app, answered by nothing (screenshots).
    func showDemo() {
        let demo = KeyRequest(id: "demo0000demo0000", name: "JELLYFIN_API_KEY", profile: "jellyfin",
                              why: "So the Jellyfin bot can search your library and start playback on the TV.",
                              asker: "claude", askerName: "Coder", replace: false,
                              publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                              until: .now.addingTimeInterval(86_400))
        reachable = { true }
        plugin = { arguments in arguments.hasPrefix("keys list") ? "redde-push keys []" : "redde-push keys set JELLYFIN_API_KEY" }
        restart = {}
        canAnswer = true
        pending = [demo]
        showing = demo
    }
    #endif
}

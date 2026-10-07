import CryptoKit
import Foundation
import Observation
import UIKit
import os

/// A pairing link, as `hermes redde-push pair` shows it (and draws it as a QR code):
///
///     https://redde.goosehouse.org/connect#push=<the plugin's public key>
///     redde://connect?push=<the plugin's public key>
///
/// It rides on the setup link's address so the Camera opens it in the app; the key comes after
/// the "#", which a browser never sends. Nothing in it is secret: it is one half of a key
/// agreement, and what makes it trustworthy is where it was read, the person's own terminal.
nonisolated struct PushOffer: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// The plugin's X25519 public key for this pairing.
    var publicKey: Data
    /// The relay the plugin was told to use, when it isn't the usual one.
    var relay: String?

    static let parameter = "push"

    init?(url: URL) {
        guard let parameters = SetupCode.parameters(of: url), url.absoluteString.utf8.count <= 600 else { return nil }
        var fields: [String: String] = [:]
        for pair in parameters.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let value = String(parts[1]).removingPercentEncoding else { continue }
            if fields[String(parts[0]).lowercased()] == nil { fields[String(parts[0]).lowercased()] = value }
        }
        guard let code = fields[Self.parameter], let key = PushSeal.data(base64URL: code), key.count == 32 else { return nil }
        publicKey = key
        relay = fields["relay"].flatMap { Settings.normalizedBase($0)?.absoluteString }
    }

    /// Nil when there is no pairing link in `text`.
    init?(text: String) {
        guard let url = SetupCode.link(in: text) else { return nil }
        self.init(url: url)
    }

    static func == (a: PushOffer, b: PushOffer) -> Bool { a.publicKey == b.publicKey && a.relay == b.relay }
}

/// Why a pairing or a removal didn't go through, in words for the person.
nonisolated enum PushError: LocalizedError, Equatable {
    case notAllowed
    case noToken(String)
    case otherRelay(String)
    case relay(String)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .notAllowed: "Notifications are off for Redde. Turn them on in the iPhone's Settings › Notifications › Redde, then pair again."
        case .noToken(let reason): "This iPhone couldn't register for notifications: \(reason)"
        case .otherRelay(let host): "That Hermes is set to send through another relay (\(host)), which this copy of Redde doesn't use."
        case .relay(let reason): "The notification relay refused: \(reason)"
        case .unreachable: "Couldn't reach the notification relay. Check the connection and try again."
        }
    }
}

/// The app's side of the push relay (`companion/push-relay`, the /v1 routes): registers this
/// iPhone's push address under a secret, and leaves the answer to a pairing offer.
nonisolated struct PushRelay: Sendable {
    var base: URL
    var session: URLSession = .shared

    /// Registers `token`; the relay keeps the hash of `sendKey`, never the key. Returns its id.
    func register(token: String, environment: String, sendKey: String) async throws -> String {
        let auth = PushSeal.hex(SHA256.hash(data: Data(sendKey.utf8)))
        let reply = try await send("POST", "v1/devices", body: ["token": token, "env": environment, "auth": auth])
        guard let id = reply["id"] as? String, !id.isEmpty else { throw PushError.relay("no id") }
        return id
    }

    /// A new push address for a registration, or just a sign of life: one unused for four months
    /// is forgotten.
    func update(id: String, sendKey: String, token: String, environment: String) async throws {
        _ = try await send("PUT", "v1/devices/\(id)", body: ["token": token, "env": environment], bearer: sendKey)
    }

    func remove(id: String, sendKey: String) async throws {
        _ = try await send("DELETE", "v1/devices/\(id)", bearer: sendKey)
    }

    func leave(answer: (pub: String, box: String), at rendezvous: String, id: String, sendKey: String) async throws {
        _ = try await send("PUT", "v1/pairings/\(rendezvous)", body: ["pub": answer.pub, "box": answer.box],
                           bearer: sendKey, headers: ["X-Redde-Device": id])
    }

    private func send(_ method: String, _ path: String, body: [String: String]? = nil, bearer: String? = nil,
                      headers: [String: String] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PushError.unreachable
        }
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(status) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PushError.relay(reply["error"] as? String ?? "HTTP \(status)")
        }
        return reply
    }
}

/// Notifications from the person's own Hermes when Redde isn't running: pairing with the plugin
/// there, keeping this iPhone's registration at the relay current, and telling the plugin which
/// conversations this phone has taken part in. `Shared/PushSeal.swift` has the design; the
/// notification itself is opened by the `EchoPush` extension, not here.
@MainActor
@Observable
final class PushService {
    static let shared = PushService()

    /// The relay everyone's copy of Redde uses, run by Goosehouse (`companion/push-relay`). It
    /// has to be this one: only it holds the key Apple accepts for this app's notifications.
    nonisolated static let defaultRelay = "https://redde-push.goosehouse.org"

    private(set) var pairings: [PushPairing]

    @ObservationIgnored private let log = Logger(subsystem: "com.goosehouse.echo", category: "notify")
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let vault: (load: () -> [PushPairing], save: ([PushPairing]) -> Bool)
    /// Asks iOS for this iPhone's push address; the answer comes back through `received(token:)`.
    @ObservationIgnored private let askForToken: () -> Void
    @ObservationIgnored private let allowed: () async -> Bool
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var tokenWaiters: [CheckedContinuation<String, Error>] = []
    /// Conversations already announced to the plugin since launch, and servers found to have no
    /// plugin (or none paired with this phone): neither is asked again until the next launch.
    @ObservationIgnored private var followed: Set<String> = []
    @ObservationIgnored private var deaf: Set<String> = []

    private static let uploadedKey = "push.uploaded"
    private static let relayKey = "push.relay"

    init(defaults: UserDefaults = .standard, session: URLSession = .shared,
         vault: (load: () -> [PushPairing], save: ([PushPairing]) -> Bool) = ({ PushVault.load() }, { PushVault.save($0) }),
         askForToken: @escaping () -> Void = { UIApplication.shared.registerForRemoteNotifications() },
         allowed: @escaping () async -> Bool = { await Notifier.shared.requestAuthorization() }) {
        self.defaults = defaults
        self.session = session
        self.vault = vault
        self.askForToken = askForToken
        self.allowed = allowed
        pairings = vault.load()
    }

    /// The relay this copy uses: the usual one, unless a developer's build points elsewhere
    /// (`defaults write … push.relay`, or `-push.relay <url>` at launch).
    var relayURL: String {
        defaults.string(forKey: Self.relayKey).flatMap { Settings.normalizedBase($0)?.absoluteString } ?? Self.defaultRelay
    }

    /// Sandbox or production, as Apple will route this build's notifications. A build installed
    /// from Xcode carries a provisioning profile that says; one from the App Store has none.
    nonisolated static let environment: String = {
        #if targetEnvironment(simulator)
        return "dev"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? String(contentsOf: url, encoding: .isoLatin1),
              let key = profile.range(of: "<key>aps-environment</key>") else { return "prod" }
        return profile[key.upperBound...].prefix(60).contains("development") ? "dev" : "prod"
        #endif
    }()

    /// The pairings as the Keychain has them now: the notification extension marks one
    /// confirmed, and names its machine, when the first note from it opens.
    func reload() {
        let stored = vault.load()
        if stored != pairings { pairings = stored }
    }

    // MARK: - This iPhone's push address

    /// From the app delegate, whenever iOS hands over (or renews) the address.
    func received(token data: Data) {
        let hex = PushSeal.hex(data)
        token = hex
        for waiter in tokenWaiters { waiter.resume(returning: hex) }
        tokenWaiters = []
        Task { await refreshRegistrations(token: hex) }
    }

    func failedToRegister(_ error: PushError) {
        for waiter in tokenWaiters { waiter.resume(throwing: error) }
        tokenWaiters = []
    }

    private func currentToken() async throws -> String {
        if let token { return token }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            self.failedToRegister(.noToken("iOS didn't answer. Check the connection and try again."))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { waiter in
            tokenWaiters.append(waiter)
            askForToken()
        }
    }

    /// At launch: a phone that is paired asks for its address again, which iOS answers through
    /// `received(token:)`. One that isn't never registers for remote notifications at all.
    func refreshAtLaunch() {
        guard !pairings.isEmpty else { return }
        askForToken()
    }

    /// Tells the relay where this phone is now. Only when the address changed, or once a week as
    /// the sign of life that keeps the registration.
    private func refreshRegistrations(token: String) async {
        guard !pairings.isEmpty else { return }
        let stamp = "\(token)|\(Self.environment)|\(pairings.map(\.id).sorted().joined(separator: ","))"
        let last = defaults.string(forKey: Self.uploadedKey).map { $0.split(separator: "@", maxSplits: 1).map(String.init) }
        if let last, last.count == 2, last[1] == stamp, let at = Double(last[0]), Date.now.timeIntervalSince1970 - at < 7 * 86_400 { return }
        var allSent = true
        for pairing in pairings {
            guard let base = URL(string: pairing.relay) else { continue }
            do {
                try await PushRelay(base: base, session: session).update(id: pairing.id, sendKey: pairing.sendKey, token: token, environment: Self.environment)
            } catch PushError.relay(let reason) where reason == "no such device" {
                // The relay forgot it (unused for months, or that Hermes's notes bounced at Apple).
                log.notice("a pairing is gone from the relay; removed here")
                forget(pairing)
            } catch {
                allSent = false
            }
        }
        if allSent { defaults.set("\(Date.now.timeIntervalSince1970)@\(stamp)", forKey: Self.uploadedKey) }
    }

    // MARK: - Pairing

    /// Answers a pairing offer: registers this phone at the relay under a fresh secret, and
    /// leaves there, for the plugin, this phone's public key and the registration sealed to the
    /// key the two now share. The pairing is kept at once and counts as confirmed when the
    /// plugin's first note opens (`waitUntilConfirmed`).
    @discardableResult
    func pair(_ offer: PushOffer) async throws -> PushPairing {
        if let asked = offer.relay, asked != relayURL {
            throw PushError.otherRelay(URL(string: asked)?.host() ?? asked)
        }
        guard let base = URL(string: relayURL) else { throw PushError.unreachable }
        guard await allowed() else { throw PushError.notAllowed }
        let token = try await currentToken()
        let relay = PushRelay(base: base, session: session)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PushError.relay("no randomness") }
        let sendKey = PushSeal.base64URL(Data(bytes))
        let id = try await relay.register(token: token, environment: Self.environment, sendKey: sendKey)
        let answer: (pub: String, box: String, noteKey: Data)
        do {
            answer = try PushSeal.answer(to: offer.publicKey, deviceID: id, sendKey: sendKey, name: UIDevice.current.name)
            try await relay.leave(answer: (answer.pub, answer.box), at: PushSeal.rendezvous(offered: offer.publicKey), id: id, sendKey: sendKey)
        } catch {
            try? await relay.remove(id: id, sendKey: sendKey)   // nothing was paired: leave nothing behind
            throw (error as? PushError) ?? PushError.relay("that isn't a pairing code Redde can use")
        }
        let pairing = PushPairing(id: id, sendKey: sendKey, key: answer.noteKey, relay: relayURL)
        // Pairing again with the same Hermes makes a new registration; an unconfirmed leftover
        // from an attempt that never finished goes.
        let stale = pairings.filter { !$0.confirmed }
        guard vault.save(pairings.filter(\.confirmed) + [pairing]) else {
            try? await relay.remove(id: id, sendKey: sendKey)
            throw PushError.relay("the pairing couldn't be saved on this iPhone")
        }
        reload()
        for old in stale { try? await PushRelay(base: URL(string: old.relay) ?? base, session: session).remove(id: old.id, sendKey: old.sendKey) }
        return pairing
    }

    /// Waits for the plugin's first note to arrive and open, which the notification extension
    /// records. False when it hasn't after `seconds`: the code was stale, or its command had ended.
    func waitUntilConfirmed(_ pairing: PushPairing, seconds: Double = 40) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline, !Task.isCancelled {
            reload()
            if pairings.first(where: { $0.id == pairing.id })?.confirmed == true { return true }
            try? await Task.sleep(for: .milliseconds(700))
        }
        return false
    }

    /// Forgets a pairing here and at the relay. The plugin finds out with its next note, which
    /// the relay turns away, and forgets the phone too.
    func unpair(_ pairing: PushPairing) async {
        forget(pairing)
        guard let base = URL(string: pairing.relay) else { return }
        try? await PushRelay(base: base, session: session).remove(id: pairing.id, sendKey: pairing.sendKey)
    }

    private func forget(_ pairing: PushPairing) {
        _ = vault.save(vault.load().filter { $0.id != pairing.id })
        reload()
        followed = []
    }

    // MARK: - Which conversations notify

    /// The plugin command that has this phone follow a conversation, or nil when there is nothing
    /// to say: no confirmed pairing, said already, or a server known not to listen.
    func followCommand(stored session: String, server: String) -> String? {
        let ids = pairings.filter(\.confirmed).map(\.id)
        guard !ids.isEmpty, !session.isEmpty, !deaf.contains(server), followed.insert("\(server)|\(session)").inserted else { return nil }
        return "watch \(session) \(ids.joined(separator: ","))"
    }

    /// A Dashboard turn is starting in `stored`: tell the plugin this phone takes part in that
    /// conversation, so its replies and approvals notify it. Once per conversation per launch,
    /// off to the side of the turn. Over the Hermes API there is no such channel, and none is
    /// needed: the plugin notifies for every API turn.
    func follow(stored session: String, runtime: String, client: HermesServeClient, server: String) {
        guard let command = followCommand(stored: session, server: server) else { return }
        Task { [weak self] in
            do {
                let reply = try await client.call("command.dispatch", params: .object([
                    "session_id": .string(runtime), "name": .string("redde-push"), "arg": .string(command)]), timeout: 20)
                // "watching 0": the plugin is there but paired with another phone, or another Hermes's.
                if reply["output"]?.string?.contains("watching 0") == true { self?.deaf.insert(server) }
            } catch let error as HermesServeClient.RPCError where error.code == 4018 {
                self?.deaf.insert(server)   // no such command: the plugin isn't on this Hermes
            } catch {
                self?.followed.remove("\(server)|\(session)")   // the socket dropped: say it next turn
            }
        }
    }
}

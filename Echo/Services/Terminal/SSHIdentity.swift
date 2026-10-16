import CryptoKit
import Foundation
import NIOSSH

/// This device's SSH key for the terminal: Ed25519, made on the device the first time it is
/// needed and kept in the Keychain for this device only (it never syncs, and no backup carries
/// it). A server learns its public half from the person, who adds `publicKeyLine` to
/// `~/.ssh/authorized_keys`. One key for every server, as an SSH client on a computer has one.
nonisolated enum SSHIdentity {
    /// The comment after the key in `authorized_keys`, so the line says whose it is.
    static let comment = "redde"

    /// The key, made and kept on first use; nil when the Keychain can't keep it (the device is
    /// locked), so a key nobody can use twice is never handed out.
    static func privateKey() -> Curve25519.Signing.PrivateKey? {
        if let stored = Keychain.read(.sshKey), let raw = Data(base64Encoded: stored),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        return Keychain.write(.sshKey, value: key.rawRepresentation.base64EncodedString()) ? key : nil
    }

    /// "ssh-ed25519 AAAA… redde": the line for `authorized_keys`.
    static var publicKeyLine: String? {
        privateKey().map { line(for: $0) }
    }

    static func line(for key: Curve25519.Signing.PrivateKey) -> String {
        String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey) + " " + comment
    }

    /// A new key in place of this one: every server needs the new line before it lets this device in.
    @discardableResult
    static func replace() -> String? {
        Keychain.delete(.sshKey)
        return publicKeyLine
    }
}

/// Servers the terminal has met, by the fingerprint of the key each showed the first time
/// (trust on first use, as `ssh` keeps `known_hosts`). A server showing another key afterwards is
/// refused until its old one is forgotten here. Fingerprints aren't secret: UserDefaults.
nonisolated enum KnownHosts {
    private static let storeKey = "terminal.knownHosts"

    /// "SHA256:…" of the key's wire form, as `ssh-keygen -lf` and `ssh` print it.
    static func fingerprint(of hostKey: NIOSSHPublicKey) -> String {
        fingerprint(openSSHLine: String(openSSHPublicKey: hostKey))
    }

    static func fingerprint(openSSHLine line: String) -> String {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return line }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// How a server is named in the list: its host, with the port when it isn't 22 (as known_hosts does).
    static func name(host: String, port: Int) -> String {
        port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)"
    }

    static func trusted(_ name: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String])?[name]
    }

    static func trust(_ fingerprint: String, for name: String) {
        var all = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String]) ?? [:]
        all[name] = fingerprint
        UserDefaults.standard.set(all, forKey: storeKey)
    }

    static func forget(_ name: String) {
        var all = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String]) ?? [:]
        all[name] = nil
        UserDefaults.standard.set(all, forKey: storeKey)
    }

    /// Part of "Erase everything", with the accounts (`TerminalAccount.forgetAll`); the device's
    /// key is a Keychain item and goes with the rest of them.
    static func forgetAll() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }
}

/// Where the terminal logs in, for one Hermes server: the SSH host (the server's own by
/// default), port and user. Kept per server in UserDefaults; nothing here is secret.
nonisolated struct TerminalAccount: Codable, Equatable, Sendable {
    var host: String
    var port: Int = 22
    var user: String

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && (1 ... 65535).contains(port)
    }

    private static func key(_ server: String) -> String { "terminal.account.\(server)" }

    static func saved(server: String) -> TerminalAccount? {
        UserDefaults.standard.data(forKey: key(server)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    static func save(_ account: TerminalAccount, server: String) {
        if let data = try? JSONEncoder().encode(account) { UserDefaults.standard.set(data, forKey: key(server)) }
    }

    static func forgetAll() {
        for name in UserDefaults.standard.dictionaryRepresentation().keys where name.hasPrefix("terminal.account.") {
            UserDefaults.standard.removeObject(forKey: name)
        }
    }

    /// The host Redde already talks to, for a first guess: the Dashboard's, else the Hermes API's.
    static func suggestedHost(serve: URL?, gateway: URL?) -> String {
        (serve?.host() ?? gateway?.host()) ?? ""
    }
}

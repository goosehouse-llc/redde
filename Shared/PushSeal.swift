import CryptoKit
import Foundation
import Security
import UserNotifications

/// Notifications when Redde isn't running come from the person's own Hermes: a plugin there
/// (`companion/hermes-plugin/redde-push`) writes a short note when a reply finishes or a command
/// waits for approval, seals it with a key only it and this iPhone hold, and hands it to a relay
/// that passes it to Apple unread. The notification extension (`EchoPush`) opens it here.
///
/// The key comes from pairing. `hermes redde-push pair` shows a link with a fresh public key; the
/// app answers with its own through the relay, and both derive the same secret (X25519, then
/// HKDF-SHA256). The relay sees two public keys and a box it can't open. `docs/push.md` has the
/// design; `core.py` in the plugin is the other end of everything in this file.

/// What the plugin tells the phone, as it is sealed: short keys, since every byte rides in a
/// notification Apple caps at 4 KB.
nonisolated struct PushNote: Codable, Equatable, Sendable {
    enum Kind: String, Sendable {
        /// The agent finished a reply (`b` is how it starts).
        case reply
        /// A command waits for a yes or no (`b` is the command, `d` why it was stopped).
        case approval
        /// The first note after pairing: the plugin has the key too.
        case paired
        /// `hermes redde-push test`.
        case test
    }

    var v = 1
    var k: String
    /// The Hermes session the note is about.
    var s: String?
    /// The conversation's title.
    var t: String?
    var b: String?
    var d: String?
    /// The name of the machine Hermes runs on.
    var n: String?
    var at: Double?
    /// On an approval that can be answered from the notification: `digest(of:)` the command, so
    /// the answer is given to that command and no other. Absent when it can't be (a turn the
    /// Dashboard has no hand in: over the Hermes API, or at a terminal).
    var h: String?

    /// Nil for a kind a newer plugin sends and this build doesn't know.
    var kind: Kind? { Kind(rawValue: k) }
}

/// One Hermes this iPhone is paired with.
nonisolated struct PushPairing: Codable, Equatable, Identifiable, Sendable {
    /// The relay's name for this phone as that Hermes knows it. Not a secret.
    var id: String
    /// What the plugin shows the relay to be let through, and the app to change or remove the
    /// registration.
    var sendKey: String
    /// The key notes are sealed with. The relay never has it.
    var key: Data
    var relay: String
    /// The machine's name, from the first note that arrives. Empty until then.
    var host = ""
    /// To the second, so a copy read back from the Keychain equals the one written.
    var pairedAt = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded())
    /// A note has arrived and opened: the plugin took the answer and derived the same key.
    var confirmed = false
}

nonisolated enum PushSeal {
    static let pairingAAD = Data("redde-push pairing".utf8)

    enum Failure: Error { case malformed }

    /// Where on the relay the answer to an offer is left: named after the offered key, so the
    /// plugin and the phone find the same place without telling the relay anything else.
    static func rendezvous(offered: Data) -> String {
        hex(SHA256.hash(data: Data("redde-push rendezvous v1".utf8) + offered).prefix(16))
    }

    /// The key notes are sealed with and the key the pairing answer is sealed with.
    static func keys(shared: SharedSecret, offered: Data, answered: Data) -> (note: Data, box: SymmetricKey) {
        let material = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: offered + answered,
                                                      sharedInfo: Data("redde-push v1".utf8), outputByteCount: 64)
        let bytes = material.withUnsafeBytes { Data($0) }
        return (bytes.prefix(32), SymmetricKey(data: bytes.suffix(32)))
    }

    /// Four bytes that say which pairing a note is from, and nothing about the key.
    static func keyID(_ key: Data) -> Data {
        Data(SHA256.hash(data: Data("redde-push key id".utf8) + key).prefix(4))
    }

    /// AES-256-GCM, as nonce, ciphertext, tag: what the plugin's `seal` writes.
    static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined else { throw Failure.malformed }
        return combined
    }

    static func open(_ sealed: Data, key: SymmetricKey, aad: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
    }

    /// The phone's half of a pairing: its public key, and its relay id and send key sealed for
    /// the plugin. `noteKey` is what both ends will seal notes with.
    static func answer(to offered: Data, deviceID: String, sendKey: String, name: String,
                       with privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) throws -> (pub: String, box: String, noteKey: Data) {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: offered))
        let mine = privateKey.publicKey.rawRepresentation
        let keys = keys(shared: shared, offered: offered, answered: mine)
        let inside = try JSONSerialization.data(withJSONObject: ["id": deviceID, "send": sendKey, "name": name])
        return (base64URL(mine), base64URL(try seal(inside, key: keys.box, aad: pairingAAD)), keys.note)
    }

    /// Opens what a notification carries (`e`), with whichever pairing it was sealed for: four
    /// bytes of key id, then the note sealed to that pairing's id.
    static func note(from payload: String, pairings: [PushPairing]) -> (note: PushNote, pairing: PushPairing)? {
        guard let blob = Data(base64Encoded: payload), blob.count > 4 + 12 + 16 else { return nil }
        let id = blob.prefix(4), sealed = Data(blob.dropFirst(4))
        for pairing in pairings where keyID(pairing.key) == id {
            guard let plain = try? open(sealed, key: SymmetricKey(data: pairing.key), aad: Data(pairing.id.utf8)),
                  let note = try? JSONDecoder().decode(PushNote.self, from: plain) else { continue }
            return (note, pairing)
        }
        return nil
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Where the pairings are kept: one Keychain item in the app group, so the notification
/// extension can read it, and readable after the first unlock, since a notification can arrive
/// while the phone is locked. It never leaves this device.
nonisolated enum PushVault {
    static let group = "group.com.goosehouse.echo"
    private static let service = "com.goosehouse.echo.push"
    /// The item's name. Tests keep theirs under another, beside the real one.
    static let account = "pairings"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group]
    }

    static func load(account: String = account) -> [PushPairing] {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([PushPairing].self, from: data)) ?? []
    }

    @discardableResult
    static func save(_ pairings: [PushPairing], account: String = account) -> Bool {
        let query = query(account)
        guard !pairings.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard let data = try? JSONEncoder().encode(pairings) else { return false }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return updated == errSecSuccess
    }

    /// A note from this pairing arrived and opened: it works, and the machine has a name.
    static func confirm(_ pairing: PushPairing, host: String?, account: String = account) {
        var all = load(account: account)
        guard let index = all.firstIndex(where: { $0.id == pairing.id }) else { return }
        let host = host ?? all[index].host
        guard !all[index].confirmed || all[index].host != host else { return }
        all[index].confirmed = true
        all[index].host = host
        save(all, account: account)
    }
}

nonisolated extension PushNote {
    /// The category of a reply that arrived as a push: its Reply button waits for an unlock,
    /// because the app is started for it and its saved passwords can't be read while locked.
    static let repliedCategory = "redde.replied.push"
    /// The category of an approval that arrived as a push and can be answered from it: Approve
    /// and Deny, which start the app in the background to answer (`Notifier.answerPushedApproval`).
    static let approvalCategory = "redde.approval.push"
    /// `userInfo` keys on a notification that came this way. `session` is also how the app tells
    /// one from a banner it posted itself. `approval` is the note's `h`.
    static let sessionKey = "session"
    static let kindKey = "kind"
    static let approvalKey = "approval"
    /// The sealed note, as the relay hands it to Apple. Gone once the note has been opened.
    static let sealedKey = "e"

    /// Writes the note into the notification that will be shown in place of the relay's words.
    /// False for a note this build doesn't know: the relay's words stay.
    @discardableResult
    func fill(_ content: UNMutableNotificationContent) -> Bool {
        guard let kind else { return false }
        let host = n.flatMap { $0.isEmpty ? nil : $0 }
        switch kind {
        case .reply:
            content.title = t.flatMap { $0.isEmpty ? nil : $0 } ?? "Redde"
            content.body = String(PlainText.display(b ?? "").prefix(300))
            content.categoryIdentifier = Self.repliedCategory
            content.threadIdentifier = "redde.turn"
        case .approval:
            content.title = "Redde needs your approval"
            if let t, !t.isEmpty { content.subtitle = t }
            content.body = [d, b].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            content.threadIdentifier = "redde.turn"
            if let h, !h.isEmpty, let s, !s.isEmpty { content.categoryIdentifier = Self.approvalCategory }
        case .paired:
            content.title = host.map { "Paired with \($0)" } ?? "Paired"
            content.body = "Redde will tell you here when this Hermes finishes a reply or needs an approval."
        case .test:
            content.title = host.map { "Redde · \($0)" } ?? "Redde"
            content.body = b ?? "Notifications from your Hermes reach this iPhone."
        }
        if content.body.isEmpty { content.body = "Open Redde to see it." }
        var info: [AnyHashable: Any] = [Self.kindKey: k]
        if let s, !s.isEmpty { info[Self.sessionKey] = s }
        if kind == .approval, let h, !h.isEmpty { info[Self.approvalKey] = h }
        content.userInfo = info
        return true
    }

    /// What stands for a command in a note: sixteen hex digits of its SHA-256. The plugin's
    /// `core.digest` is the same.
    static func digest(of command: String) -> String {
        PushSeal.hex(SHA256.hash(data: Data(command.utf8)).prefix(8))
    }
}

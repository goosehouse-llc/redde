import Foundation
import Security
import Testing
@testable import Echo

/// GitHub issue 34: the first question of a drive got "No API key is stored", since the keys
/// could be read only while the iPhone was unlocked. They are kept to be read once it has been
/// unlocked since it was turned on, and the ones stored before are moved.
@MainActor
@Suite(.serialized)
struct KeychainLockTests {
    private static let service = "com.goosehouse.echo"

    /// How an item is kept, as the Keychain says.
    private static func accessible(_ account: String, synced: Bool = false) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synced,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
    }

    @Test func everyKeyButTheSSHOneCanBeReadWhileLocked() {
        let afterFirstUnlock = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        #expect(Keychain.accessibility(of: Keychain.account(.gatewayAPIKey, server: "s1"), synced: false) as String == afterFirstUnlock)
        #expect(Keychain.accessibility(of: Keychain.profileAccount("scout", server: "s1"), synced: false) as String == afterFirstUnlock)
        #expect(Keychain.accessibility(of: Keychain.Item.serveSignIn.rawValue, synced: false) as String == afterFirstUnlock)
        #expect(Keychain.accessibility(of: Keychain.Item.gatewayAPIKey.rawValue, synced: true) as String == kSecAttrAccessibleAfterFirstUnlock as String,
                "one in iCloud Keychain can't be this device's only")
        #expect(Keychain.accessibility(of: Keychain.Item.sshKey.rawValue, synced: false) as String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                "only the terminal, on screen, uses the SSH key")
    }

    @Test func aKeyStoredNowCanBeReadWhileLocked() {
        let account = "gateway-api-key@lock-test-\(UUID().uuidString)"
        defer { Keychain.delete(account: account) }
        #expect(Keychain.write(account: account, value: "sk-test"))
        #expect(Self.accessible(account) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(Keychain.read(account: account) == "sk-test" && !Keychain.isShut)
        #expect(TransportError.noAPIKey.errorDescription == TransportError.missingAPIKey.errorDescription, "an open Keychain with no key has none")
    }

    @Test func aKeyStoredBeforeIsMovedOnce() {
        let account = "gateway-api-key@lock-test-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        let wasMoved = defaults.object(forKey: Keychain.movedKey)
        defer {
            Keychain.delete(account: account)
            defaults.set(wasMoved, forKey: Keychain.movedKey)
        }
        // As 2.1 stored it.
        let old: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: Data("sk-old".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        #expect(SecItemAdd(old as CFDictionary, nil) == errSecSuccess)
        #expect(Self.accessible(account) == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)

        defaults.removeObject(forKey: Keychain.movedKey)
        #expect(Keychain.moveToAfterFirstUnlock())
        #expect(Self.accessible(account) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(Keychain.read(account: account) == "sk-old", "the key itself is untouched")
        #expect(defaults.bool(forKey: Keychain.movedKey), "and it isn't done again")
    }
}

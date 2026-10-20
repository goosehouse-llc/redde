import Foundation
import os
import Security

/// Minimal Keychain wrapper for the app's secrets. A Hermes server's secrets (its API key,
/// Dashboard password or sign-in, Cloudflare Access secret and per-profile API keys) are stored per server as
/// `<account>@<server id>`; the rest are app-wide.
/// Items are `WhenUnlockedThisDeviceOnly`, never synced or migrated to another device, except with
/// Sync with iCloud on (`CloudSync`): then the `syncable` ones are kept in iCloud Keychain
/// (synchronizable, `WhenUnlocked`, end-to-end encrypted) and every device of the person's has
/// them. Each account is in one place or the other, never both.
nonisolated enum Keychain {
    enum Item: String {
        case gatewayAPIKey = "gateway-api-key"
        case serveDashboardPassword = "serve-dashboard-password"
        /// The tokens of a browser sign-in to the Dashboard (`DashboardTokens`, as JSON).
        case serveSignIn = "serve-sign-in"
        case fastLaneAPIKey = "fast-lane-api-key"
        case cfAccessClientSecret = "cf-access-client-secret"
        /// The person's own headers for a server behind a reverse proxy (`CustomHeader`, as JSON).
        case customHeaders = "custom-headers"
        case pushRegisterSecret = "push-register-secret"
        /// This device's SSH key for the terminal (`SSHIdentity`), Ed25519, raw and base64: app-wide.
        case sshKey = "ssh-key"
    }

    private static let service = "com.goosehouse.echo"

    /// Values read or written in this process. `SecItemCopyMatching` is an XPC round trip, and
    /// callers ask from view bodies and once per REST call; only this app writes these items,
    /// so a cached answer stays right until `write`/`delete` replaces it. A read that fails for
    /// any reason other than "no such item" (the device is locked) is not cached.
    private static let cache = OSAllocatedUnfairLock<[String: String?]>(initialState: [:])

    /// What goes to iCloud Keychain with Sync with iCloud on: a server's connection secrets (its
    /// profiles' API keys too, `gateway-api-key.<profile>@…`) and the OpenAI-compatible key. Never
    /// a browser sign-in (each device refreshes its own tokens), the push registration secret or
    /// this device's SSH key.
    static let syncable: [Item] = [.gatewayAPIKey, .serveDashboardPassword, .cfAccessClientSecret, .customHeaders, .fastLaneAPIKey]
    static func isSyncable(account: String) -> Bool {
        syncable.contains { account == $0.rawValue || account.hasPrefix($0.rawValue + "@") || account.hasPrefix($0.rawValue + ".") }
    }
    /// Where `CloudSync` records that Sync with iCloud is on, read here directly like the active server.
    static let syncKey = "iCloudSync"
    static var syncsToICloud: Bool { UserDefaults.standard.bool(forKey: syncKey) }

    /// Items that belong to one Hermes server.
    static let serverScoped: Set<Item> = [.gatewayAPIKey, .serveDashboardPassword, .serveSignIn, .cfAccessClientSecret, .customHeaders]
    /// Where Settings records the active server. Read here directly (UserDefaults is thread-safe),
    /// so a secret read can never happen before the scope is known.
    static let activeServerKey = "activeServerID"
    static var activeServerID: String? { UserDefaults.standard.string(forKey: activeServerKey) }

    /// The Keychain account for an item: per server for the server-scoped ones.
    static func account(_ item: Item, server: String? = activeServerID) -> String {
        guard serverScoped.contains(item), let server else { return item.rawValue }
        return "\(item.rawValue)@\(server)"
    }

    static func read(_ item: Item) -> String? { read(account: account(item)) }
    @discardableResult
    static func write(_ item: Item, value: String) -> Bool { write(account: account(item), value: value) }
    @discardableResult
    static func delete(_ item: Item) -> Bool { delete(account: account(item)) }

    /// The Hermes API key for a named profile on a server: the gateway checks each profile's own
    /// API_SERVER_KEY on its /p/<profile>/ routes.
    static func profileAccount(_ profile: String, server: String? = activeServerID) -> String {
        "\(Item.gatewayAPIKey.rawValue).\(profile)" + (server.map { "@\($0)" } ?? "")
    }

    /// Every account this app has stored, on this device or in iCloud Keychain (for migrations and
    /// for removing a server's secrets).
    static func allAccounts() -> [String] { accounts(synced: kSecAttrSynchronizableAny) }

    /// The accounts on this device only (false) or in iCloud Keychain only (true).
    static func accounts(synced: Any) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: synced,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return Array(Set(items.compactMap { $0[kSecAttrAccount as String] as? String })).sorted()
    }

    /// Sync with iCloud turned on: each syncable secret on this device goes to iCloud Keychain,
    /// unless another device put one there for the same account already (that one is kept: the
    /// others use it). Turned off: a copy of each comes back to this device, and the ones in
    /// iCloud stay for the other devices. Either way the cache starts over.
    static func moveSecrets(toICloud: Bool) {
        if toICloud {
            for account in accounts(synced: false) where isSyncable(account: account) {
                guard let value = stored(account, synced: false) else { continue }
                if stored(account, synced: true) == nil, !put(account, value, synced: true) { continue }
                remove(account, synced: false)
            }
        } else {
            for account in accounts(synced: true) where isSyncable(account: account) {
                guard let value = stored(account, synced: true), stored(account, synced: false) == nil else { continue }
                put(account, value, synced: false)
            }
        }
        forgetCache()
    }

    /// Reads again what was cached: another device may have changed a secret in iCloud Keychain,
    /// which says nothing when it does.
    static func forgetCache() { cache.withLock { $0.removeAll() } }

    /// Whether any stored account ends with `suffix` (a server's secrets end with `@<its id>`).
    /// Nil when the Keychain couldn't be read, which is not the same as "none".
    static func hasAccount(endingWith suffix: String) -> Bool? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            return (result as? [[String: Any]] ?? []).contains { ($0[kSecAttrAccount as String] as? String)?.hasSuffix(suffix) == true }
        case errSecItemNotFound:
            return false
        default:
            return nil
        }
    }

    /// Moves a secret to a new account, deleting the old one only once the copy reads back.
    @discardableResult
    static func move(account from: String, to: String) -> Bool {
        guard let value = read(account: from) else { return true }
        guard read(account: to) == nil else { return delete(account: from) }   // already moved
        guard write(account: to, value: value), read(account: to) == value else { return false }
        return delete(account: from)
    }

    /// With Sync with iCloud on, a syncable account is read from iCloud Keychain, else (not moved
    /// there yet) from this device.
    static func read(account: String) -> String? {
        if let cached = cache.withLock({ $0[account] }) { return cached }
        var value = lookUp(account, synced: false)
        if syncsToICloud, isSyncable(account: account), let synced = lookUp(account, synced: true), synced != nil { value = synced }
        if let value { cache.withLock { $0[account] = value } }
        return value ?? nil
    }

    /// With Sync with iCloud on, a syncable account is written to iCloud Keychain (and any copy on
    /// this device goes); otherwise to this device only.
    @discardableResult
    static func write(account: String, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(account: account) }
        let toICloud = syncsToICloud && isSyncable(account: account)
        let stored = put(account, trimmed, synced: toICloud)
        if stored, toICloud { remove(account, synced: false) }
        cache.withLock { $0[account] = stored ? .some(trimmed) : nil }
        return stored
    }

    /// With Sync with iCloud on, a syncable account goes from iCloud Keychain too: from every
    /// device (a server removed, a key cleared). Off, only this device's copy.
    @discardableResult
    static func delete(account: String) -> Bool {
        let here = remove(account, synced: false)
        let gone = syncsToICloud && isSyncable(account: account) ? remove(account, synced: true) && here : here
        cache.withLock { $0[account] = gone ? .some(nil) : nil }
        return gone
    }

    /// The value in one place: `.some(nil)` when there is none, nil when the Keychain couldn't say
    /// (the device is locked).
    private static func lookUp(_ account: String, synced: Bool) -> String?? {
        var query = baseQuery(account, synced: synced)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: (result as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound: .some(nil)
        default: nil
        }
    }

    private static func stored(_ account: String, synced: Bool) -> String? { lookUp(account, synced: synced) ?? nil }

    @discardableResult
    private static func put(_ account: String, _ value: String, synced: Bool) -> Bool {
        let query = baseQuery(account, synced: synced)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            // A synchronizable item can't be "this device only".
            kSecAttrAccessible as String: synced ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = query
        add.merge(attributes) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    private static func remove(_ account: String, synced: Bool) -> Bool {
        let status = SecItemDelete(baseQuery(account, synced: synced) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(_ account: String, synced: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synced,
        ]
    }
}

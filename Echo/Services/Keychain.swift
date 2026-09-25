import Foundation
import os
import Security

/// Minimal Keychain wrapper for the app's secrets. A Hermes server's secrets (its API key,
/// Dashboard password, Cloudflare Access secret and per-profile API keys) are stored per server as
/// `<account>@<server id>`; the rest are app-wide.
/// Items are `WhenUnlockedThisDeviceOnly` so they never sync or migrate to another device.
nonisolated enum Keychain {
    enum Item: String {
        case gatewayAPIKey = "gateway-api-key"
        case serveDashboardPassword = "serve-dashboard-password"
        case fastLaneAPIKey = "fast-lane-api-key"
        case cfAccessClientSecret = "cf-access-client-secret"
        case pushRegisterSecret = "push-register-secret"
    }

    private static let service = "com.goosehouse.echo"

    /// Values read or written in this process. `SecItemCopyMatching` is an XPC round trip, and
    /// callers ask from view bodies and once per REST call; only this app writes these items,
    /// so a cached answer stays right until `write`/`delete` replaces it. A read that fails for
    /// any reason other than "no such item" (the device is locked) is not cached.
    private static let cache = OSAllocatedUnfairLock<[String: String?]>(initialState: [:])

    /// Items that belong to one Hermes server.
    static let serverScoped: Set<Item> = [.gatewayAPIKey, .serveDashboardPassword, .cfAccessClientSecret]
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

    /// Every account this app has stored (for migrations and for removing a server's secrets).
    static func allAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Moves a secret to a new account, deleting the old one only once the copy reads back.
    @discardableResult
    static func move(account from: String, to: String) -> Bool {
        guard let value = read(account: from) else { return true }
        guard read(account: to) == nil else { return delete(account: from) }   // already moved
        guard write(account: to, value: value), read(account: to) == value else { return false }
        return delete(account: from)
    }

    static func read(account: String) -> String? {
        if let cached = cache.withLock({ $0[account] }) { return cached }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value: String?? = switch status {
        case errSecSuccess: (result as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound: .some(nil)
        default: nil
        }
        if let value { cache.withLock { $0[account] = value } }
        return value ?? nil
    }

    @discardableResult
    static func write(account: String, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(account: account) }
        let data = Data(trimmed.utf8)
        let query = baseQuery(account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let stored: Bool
        if update == errSecSuccess {
            stored = true
        } else if update == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            stored = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        } else {
            stored = false
        }
        cache.withLock { $0[account] = stored ? .some(trimmed) : nil }
        return stored
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        let gone = status == errSecSuccess || status == errSecItemNotFound
        cache.withLock { $0[account] = gone ? .some(nil) : nil }
        return gone
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

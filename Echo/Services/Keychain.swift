import Foundation
import os
import Security

/// Minimal Keychain wrapper for the app's secrets: keys, passwords and one Hermes API key per
/// named profile (`gateway-api-key.<profile>`).
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

    static func read(_ item: Item) -> String? { read(account: item.rawValue) }
    @discardableResult
    static func write(_ item: Item, value: String) -> Bool { write(account: item.rawValue, value: value) }
    @discardableResult
    static func delete(_ item: Item) -> Bool { delete(account: item.rawValue) }

    /// The Hermes API key for a named profile: the gateway checks each profile's own
    /// API_SERVER_KEY on its /p/<profile>/ routes.
    static func profileAccount(_ profile: String) -> String { "\(Item.gatewayAPIKey.rawValue).\(profile)" }

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

import Foundation
import os
import Security

/// Minimal Keychain wrapper. Echo stores exactly one secret: the scoped gateway API key.
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
    private static let cache = OSAllocatedUnfairLock<[Item: String?]>(initialState: [:])

    static func read(_ item: Item) -> String? {
        if let cached = cache.withLock({ $0[item] }) { return cached }
        var query = baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value: String?? = switch status {
        case errSecSuccess: (result as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound: .some(nil)
        default: nil
        }
        if let value { cache.withLock { $0[item] = value } }
        return value ?? nil
    }

    @discardableResult
    static func write(_ item: Item, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(item) }
        let data = Data(trimmed.utf8)
        let query = baseQuery(item)
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
        cache.withLock { $0[item] = stored ? .some(trimmed) : nil }
        return stored
    }

    @discardableResult
    static func delete(_ item: Item) -> Bool {
        let status = SecItemDelete(baseQuery(item) as CFDictionary)
        let gone = status == errSecSuccess || status == errSecItemNotFound
        cache.withLock { $0[item] = gone ? .some(nil) : nil }
        return gone
    }

    private static func baseQuery(_ item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
    }
}

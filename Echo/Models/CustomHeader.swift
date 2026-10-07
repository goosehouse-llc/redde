import Foundation

/// A header of the person's own that every request to a Hermes server carries: what a reverse
/// proxy in front of the server asks for before it lets a request through (a token, a tenant,
/// its own basic auth). Kept in the Keychain with the server's other secrets, the name too.
nonisolated struct CustomHeader: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var value: String
    /// Header names don't tell upper case from lower: one "X-Token" at most.
    var id: String { name.lowercased() }

    init(name: String, value: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Headers the connection itself depends on. Setting one would be ignored at best and break
    /// the request or the WebSocket at worst.
    private static let reserved: Set<String> = ["host", "content-length", "connection", "upgrade", "transfer-encoding", "te", "trailer"]

    /// Why this name can't be used, or nil when it can. A name is an HTTP token (RFC 9110): no
    /// spaces, no colon.
    static func problem(withName name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Give the header a name." }
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~").union(.alphanumerics)
        guard name.unicodeScalars.allSatisfy({ $0.isASCII && token.contains($0) }) else {
            return "A header name is letters, digits and hyphens, without spaces or a colon."
        }
        let lower = name.lowercased()
        guard !reserved.contains(lower), !lower.hasPrefix("sec-websocket-") else {
            return "\(name) is set by the connection itself and can't be replaced."
        }
        return nil
    }

    var isUsable: Bool { Self.problem(withName: name) == nil && !value.isEmpty && !value.contains(where: \.isNewline) }

    /// The list as the Keychain holds it (JSON), and back. An empty list is no entry at all.
    static func encode(_ headers: [CustomHeader]) -> String {
        guard !headers.isEmpty, let data = try? JSONEncoder().encode(headers) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ stored: String?) -> [CustomHeader] {
        guard let stored, let headers = try? JSONDecoder().decode([CustomHeader].self, from: Data(stored.utf8)) else { return [] }
        return headers
    }

    /// The headers as request fields; one that couldn't be sent is left out.
    static func fields(_ headers: [CustomHeader]) -> [String: String] {
        Dictionary(headers.filter(\.isUsable).map { ($0.name, $0.value) }) { first, _ in first }
    }

    /// `headers` with `new` added, in place of one by the same name.
    static func adding(_ new: CustomHeader, to headers: [CustomHeader]) -> [CustomHeader] {
        headers.filter { $0.id != new.id } + [new]
    }
}

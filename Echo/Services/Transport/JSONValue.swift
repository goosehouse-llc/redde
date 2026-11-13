import Foundation

/// Minimal dynamic JSON for the JSON-RPC transport. Sendable, Codable, and cheap to poke at.
nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }
    var string: String? { if case let .string(s) = self { return s }; return nil }
    var bool: Bool? { if case let .bool(b) = self { return b }; return nil }
    var number: Double? { if case let .number(n) = self { return n }; return nil }
    /// Truncates like `Int(Double)`, but a non-finite or out-of-range number (a corrupt frame)
    /// is nil instead of a trap.
    var int: Int? {
        guard let n = number, n.isFinite, n > -9.2e18, n < 9.2e18 else { return nil }
        return Int(n)
    }
    var array: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case let .object(o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    /// Parses JSON text without `Decoder`: `init(from:)` throws and catches up to four times per
    /// node, which is what WebSocket frames at token rate and every REST reply used to pay.
    ///
    /// `keepingLongWholeNumbers`: a whole number of 16 figures or more, which a Double can't hold
    /// exactly, is kept as its figures, as text (UAT 2.3.1, 2026-10-31: a 22-digit USPS tracking
    /// number an agent wrote as a JSON number crashed its card, and as a Double had lost its last
    /// six figures). Only for what is shown as written (`ReplyCards`); the transport reads numbers.
    static func parse(_ data: Data, keepingLongWholeNumbers: Bool = false) throws -> JSONValue {
        try convert(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), keepingLongWholeNumbers)
    }

    private static func convert(_ any: Any, _ keepLong: Bool) throws -> JSONValue {
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            // Foundation keeps such a literal's figures exactly: as an integer, or an NSDecimalNumber past UInt64.
            if keepLong, let figures = longWhole(n) { return .string(figures) }
            return .number(n.doubleValue)
        case let a as [Any]: return .array(try a.map { try convert($0, keepLong) })
        case let o as [String: Any]: return .object(try o.mapValues { try convert($0, keepLong) })
        case is NSNull: return .null
        default: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unsupported JSON value"))
        }
    }

    /// A whole number's figures, where there are 16 or more ("9400111899223197428490"); else nil.
    private static func longWhole(_ n: NSNumber) -> String? {
        let figures = n.stringValue
        let digits = figures.hasPrefix("-") ? figures.dropFirst() : Substring(figures)
        guard digits.count >= 16, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return figures
    }

    /// Best-effort text for display: strings as-is, everything else as compact JSON.
    var displayText: String {
        if let s = string { return s }
        if let data = try? JSONEncoder().encode(self) { return String(decoding: data, as: UTF8.self) }
        return ""
    }
}

/// The Redde plugin's answers to the app's commands: `redde-push <command> <JSON>`, as the
/// plugin's `wire.reply` writes them. Anything else (an older plugin's usage line, a refusal) is
/// not an answer: nil.
nonisolated enum PluginReply {
    /// The JSON after `redde-push <command> `, as it was sent.
    static func data(_ reply: String, _ command: String) -> Data? {
        guard let start = reply.range(of: "redde-push \(command) ") else { return nil }
        return Data(reply[start.upperBound...].utf8)
    }

    /// The JSON after `redde-push <command> `, read.
    static func json(_ reply: String, _ command: String) -> JSONValue? {
        data(reply, command).flatMap { try? JSONValue.parse($0) }
    }
}

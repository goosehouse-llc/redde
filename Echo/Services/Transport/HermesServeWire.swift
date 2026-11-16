import Foundation

/// Request shapes for the Dashboard's legacy and session-authority transports.
nonisolated enum HermesServeWire {
    static func sessionAuthority(_ ready: JSONValue) -> Bool {
        ready["session_authority"]?.bool == true
    }

    static func create(_ params: [String: JSONValue], canonical: Bool, requestID: String) -> [String: JSONValue] {
        params
    }

    static func submit(_ params: [String: JSONValue], canonical: Bool, submissionID: String) -> [String: JSONValue] {
        params
    }
}

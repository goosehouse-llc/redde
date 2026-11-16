import Foundation

/// Request shapes for the Dashboard's legacy and session-authority transports.
nonisolated enum HermesServeWire {
    static func sessionAuthority(_ ready: JSONValue) -> Bool {
        ready["session_authority"]?.bool == true
    }

    static func create(_ params: [String: JSONValue], canonical: Bool, requestID: String) -> [String: JSONValue] {
        guard canonical else { return params }
        var params = params
        params["source"] = .string("gui")
        params.removeValue(forKey: "close_on_disconnect")
        if let reasoning = params.removeValue(forKey: "reasoning_effort") { params["reasoning"] = reasoning }
        params["request_id"] = .string(requestID)
        return params
    }

    static func submit(_ params: [String: JSONValue], canonical: Bool, submissionID: String) -> [String: JSONValue] {
        guard canonical else { return params }
        var params = params
        params["submission_id"] = .string(submissionID)
        return params
    }

    /// Target the submitted admission, or the exact generation observed when rejoining.
    /// A missing identity is uncertain; a session-wide stop could cancel somebody else's turn.
    static func stop(sessionID: String, canonical: Bool, admissionID: String?, generation: Int?)
        -> (method: String, params: [String: JSONValue])? {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        guard canonical else { return ("session.interrupt", params) }
        if let admissionID, !admissionID.isEmpty {
            params["admission_id"] = .string(admissionID)
            return ("prompt.cancel", params)
        }
        guard let generation else { return nil }
        params["execution_generation"] = .number(Double(generation))
        return ("session.interrupt", params)
    }
}

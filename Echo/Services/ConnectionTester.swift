import Foundation

/// Probes each backend the way the transports use it, so Setup and Settings can say
/// "reachable, credentials accepted" before the user sends anything.
nonisolated enum ConnectionTester {
    enum Outcome: Equatable, Sendable {
        case ok(String)
        case failed(String)

        var isOK: Bool { if case .ok = self { return true }; return false }
        var message: String {
            switch self {
            case let .ok(m): m
            case let .failed(m): m
            }
        }
    }

    /// Hermes API server: /health, then /v1/models with the key.
    static func hermesAPI(url: URL, apiKey: String?, headers: [String: String] = [:]) async -> Outcome {
        guard let (_, health) = try? await get(url.appending(path: "health"), key: nil, headers: headers) else {
            return .failed(String(localized: "No Hermes API server answered at \(url.host() ?? url.absoluteString)."))
        }
        // A sign-in gate in front (Pangolin, Cloudflare Access, a proxy) sends its login page instead.
        if [302, 303, 307, 401, 403].contains(health) {
            return .failed(gated(url, status: health, headers: headers))
        }
        guard health == 200 else { return .failed(String(localized: "No Hermes API server answered at \(url.host() ?? url.absoluteString).")) }
        guard let apiKey, !apiKey.isEmpty else { return .failed(String(localized: "Server reachable. Add the API key.")) }
        guard let (_, status) = try? await get(url.appending(path: "v1/models"), key: apiKey, headers: headers) else {
            return .failed(String(localized: "Server reachable, but the key check didn't complete."))
        }
        switch status {
        case 200: return .ok(String(localized: "Connected. Key accepted."))
        case 401, 403: return .failed(String(localized: "Server reachable, but the key was rejected."))
        default: return .failed(String(localized: "Server answered HTTP \(status) to the key check."))
        }
    }

    /// hermes serve: /api/status (public), then a real login.
    @MainActor
    static func hermesServe(url: URL) async -> Outcome {
        let access = Settings.shared.accessHeaders
        guard let (data, status) = try? await get(url.appending(path: "api/status"), key: nil, headers: access) else {
            return .failed(String(localized: "No Hermes Dashboard answered at \(url.host() ?? url.absoluteString)."))
        }
        if status == 403 || status == 302 {
            return .failed(gated(url, status: status, headers: access))
        }
        guard status == 200 else { return .failed(String(localized: "Hermes Dashboard answered HTTP \(status).")) }
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        let version = json["version"]?.string ?? String(localized: "unknown version", comment: "Stands in for the Hermes Dashboard's version number")
        guard json["auth_required"]?.bool == true else {
            // No sign-in (asked 2026-10-30): proven the way the app goes in, by the token off its
            // page; a login saved for it is said to be of no use.
            do {
                try await HermesServeClient.shared.ensureLoggedIn()
                return .ok(String(localized: "Connected to Hermes Dashboard \(version). It has no sign-in.", comment: "Connection test passed; the Dashboard's version"))
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        do {
            try await HermesServeClient.shared.ensureLoggedIn()
            return .ok(String(localized: "Connected to Hermes Dashboard \(version). Login accepted."))
        } catch {
            return .failed(String(localized: "Hermes Dashboard \(version) reachable, but login failed: \(error.localizedDescription)"))
        }
    }

    /// Whether the Dashboard at `url` asks for a login (`auth_required` in its public status),
    /// for the form to show the right fields; nil when nothing answered as a Dashboard.
    @MainActor
    static func dashboardAsksForLogin(url: URL) async -> Bool? {
        guard let (data, status) = try? await get(url.appending(path: "api/status"), key: nil, headers: Settings.shared.accessHeaders),
              status == 200, let json = try? JSONValue.parse(data), json["version"] != nil || json["auth_required"] != nil else { return nil }
        return json["auth_required"]?.bool == true
    }

    /// OpenAI-compatible endpoint: /v1/models, with the optional key.
    static func fastLane(url: URL, apiKey: String?, model: String) async -> Outcome {
        guard let (data, status) = try? await get(url.appending(path: "v1/models"), key: apiKey) else {
            return .failed(String(localized: "Nothing answered at \(url.host() ?? url.absoluteString)."))
        }
        guard status == 200 else {
            return .failed(status == 401 || status == 403 ? String(localized: "Endpoint reachable, but the key was rejected.") : String(localized: "Endpoint answered HTTP \(status)."))
        }
        let ids = ((try? JSONDecoder().decode(JSONValue.self, from: data))?["data"]?.array ?? []).compactMap { $0["id"]?.string }
        if !model.isEmpty, !ids.isEmpty, !ids.contains(model) {
            return .failed(String(localized: "Connected, but the endpoint doesn't list a model named \(model)."))
        }
        return .ok(ids.isEmpty ? String(localized: "Connected.") : String(localized: "Connected. \(ids.count) models available."))
    }

    /// What to say when an access gate turns the check away.
    private static func gated(_ url: URL, status: Int, headers: [String: String]) -> String {
        headers.isEmpty
            ? String(localized: "\(url.host() ?? String(localized: "The host")) is behind an access gate (HTTP \(status)). Add what it asks for under Settings → Connection details: a Cloudflare Access service token, a Pangolin access token, or the proxy's own headers.")
            : String(localized: "The access gate in front of \(url.host() ?? String(localized: "the host")) turned the request away (HTTP \(status)). Check the Cloudflare Access client ID and secret, the Pangolin access token, or the custom headers.")
    }

    private static func get(_ url: URL, key: String?, headers: [String: String] = [:]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        // Don't follow the Access login redirect; the status is the diagnosis.
        let (data, response) = try await NoRedirectSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}


/// A session that reports redirects instead of following them (used to detect access gates).
nonisolated final class NoRedirectSession: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared: URLSession = {
        URLSession(configuration: .ephemeral, delegate: NoRedirectSession(), delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

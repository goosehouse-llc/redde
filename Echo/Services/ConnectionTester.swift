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
    static func hermesAPI(url: URL, apiKey: String?) async -> Outcome {
        guard let (_, health) = try? await get(url.appending(path: "health"), key: nil), health == 200 else {
            return .failed("No Hermes API server answered at \(url.host() ?? url.absoluteString).")
        }
        guard let apiKey, !apiKey.isEmpty else { return .failed("Server reachable. Add the API key.") }
        guard let (_, status) = try? await get(url.appending(path: "v1/models"), key: apiKey) else {
            return .failed("Server reachable, but the key check didn't complete.")
        }
        switch status {
        case 200: return .ok("Connected. Key accepted.")
        case 401, 403: return .failed("Server reachable, but the key was rejected.")
        default: return .failed("Server answered HTTP \(status) to the key check.")
        }
    }

    /// hermes serve: /api/status (public), then a real login.
    @MainActor
    static func hermesServe(url: URL) async -> Outcome {
        let access = Settings.shared.accessHeaders
        guard let (data, status) = try? await get(url.appending(path: "api/status"), key: nil, headers: access) else {
            return .failed("No Hermes Dashboard answered at \(url.host() ?? url.absoluteString).")
        }
        if status == 403 || status == 302 {
            return .failed(access.isEmpty
                ? "\(url.host() ?? "The host") is behind an access gate (HTTP \(status)). Add Cloudflare Access service-token headers below."
                : "Cloudflare Access rejected the service token (HTTP \(status)). Check the client ID and secret.")
        }
        guard status == 200 else { return .failed("Hermes Dashboard answered HTTP \(status).") }
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        let version = json["version"]?.string ?? "unknown version"
        guard json["auth_required"]?.bool == true else { return .ok("Connected to Hermes Dashboard \(version) (no login required).") }
        do {
            try await HermesServeClient.shared.ensureLoggedIn()
            return .ok("Connected to Hermes Dashboard \(version). Login accepted.")
        } catch {
            return .failed("Hermes Dashboard \(version) reachable, but login failed: \(error.localizedDescription)")
        }
    }

    /// OpenAI-compatible endpoint: /v1/models, with the optional key.
    static func fastLane(url: URL, apiKey: String?, model: String) async -> Outcome {
        guard let (data, status) = try? await get(url.appending(path: "v1/models"), key: apiKey) else {
            return .failed("Nothing answered at \(url.host() ?? url.absoluteString).")
        }
        guard status == 200 else {
            return .failed(status == 401 || status == 403 ? "Endpoint reachable, but the key was rejected." : "Endpoint answered HTTP \(status).")
        }
        let ids = ((try? JSONDecoder().decode(JSONValue.self, from: data))?["data"]?.array ?? []).compactMap { $0["id"]?.string }
        if !model.isEmpty, !ids.isEmpty, !ids.contains(model) {
            return .failed("Connected, but the endpoint doesn't list a model named \(model).")
        }
        return .ok(ids.isEmpty ? "Connected." : "Connected. \(ids.count) model\(ids.count == 1 ? "" : "s") available.")
    }

    private static func get(_ url: URL, key: String?, headers: [String: String] = [:]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
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

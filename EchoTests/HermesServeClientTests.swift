import Foundation
import Testing
@testable import Echo

/// Answers the serve client's REST calls in-process. WebSockets don't pass through URLProtocol,
/// so these cover login, ticket minting and the 401 retry, not the socket itself.
nonisolated final class ServeStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data?) -> (Int, Data))?
    nonisolated(unsafe) static var log: [String] = []

    static func reset() { handler = nil; log = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
        Self.log.append("\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")")
        let (status, payload) = Self.handler?(request, body) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct HermesServeClientTests {
    private func makeClient(profile: String = "") -> HermesServeClient {
        let settings = Settings(defaults: UserDefaults(suiteName: "serve-test-\(UUID().uuidString)")!)
        settings.serveURL = "http://serve.test:9119"
        settings.serveUsername = "redde"
        settings.hermesProfile = profile
        return HermesServeClient(settings: settings, password: { "hunter2" }, protocolClasses: [ServeStub.self])
    }

    @Test func sessionListAsksForTheProfile() async throws {
        ServeStub.reset()
        nonisolated(unsafe) var urls: [String] = []
        ServeStub.handler = { request, _ in
            urls.append(request.url?.absoluteString ?? "")
            return (200, Data(#"{"sessions":[]}"#.utf8))
        }
        defer { ServeStub.reset() }
        let client = makeClient(profile: "work")
        _ = try await client.listSessions(limit: 10)
        #expect(urls.contains { $0.contains("/api/sessions?") && $0.contains("profile=work") })
    }

    /// Stateful stub: the session probe fails until a login has happened, like a cookie jar.
    private func installGateway(rejectLogin: Bool = false, jobsFirstStatus: Int = 200) {
        ServeStub.reset()
        nonisolated(unsafe) var loggedIn = false
        nonisolated(unsafe) var jobsCalls = 0
        ServeStub.handler = { request, body in
            switch (request.httpMethod, request.url?.path()) {
            case ("GET", "/api/sessions"):
                return loggedIn ? (200, Data("[]".utf8)) : (401, Data())
            case ("POST", "/auth/password-login"):
                let fields = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
                guard !rejectLogin, fields?["username"] as? String == "redde", fields?["password"] as? String == "hunter2",
                      fields?["provider"] as? String == "basic" else { return (401, Data()) }
                loggedIn = true
                return (200, Data("{}".utf8))
            case ("POST", "/api/auth/ws-ticket"):
                return loggedIn ? (200, Data(#"{"ticket":"t-1"}"#.utf8)) : (401, Data())
            case ("GET", "/api/cron/jobs"):
                jobsCalls += 1
                return jobsCalls == 1 ? (jobsFirstStatus, Data()) : (200, Data(#"{"ok":true}"#.utf8))
            default:
                return (404, Data())
            }
        }
    }

    @Test func logsInOnceThenReusesTheCookieWithinTheTTL() async throws {
        installGateway()
        let client = makeClient()
        let ticket = try await client.authenticate()
        #expect(ticket == "t-1")
        #expect(ServeStub.log == ["GET /api/sessions", "POST /auth/password-login", "POST /api/auth/ws-ticket"])

        _ = try await client.authenticate()
        #expect(ServeStub.log.count == 4, "within the TTL only the ticket is minted again")
        #expect(ServeStub.log.last == "POST /api/auth/ws-ticket")
    }

    @Test func retriesOnceAfterA401() async throws {
        installGateway(jobsFirstStatus: 401)
        let client = makeClient()
        _ = try await client.authenticate()
        ServeStub.log = []
        let result = try await client.restJSON("GET", "api/cron/jobs")
        #expect(result["ok"]?.bool == true)
        #expect(ServeStub.log == ["GET /api/cron/jobs", "GET /api/sessions", "GET /api/cron/jobs"],
                "an expired cookie is re-proven (the probe still passes here) and the call retried once")
    }

    @Test func surfacesARejectedLogin() async {
        installGateway(rejectLogin: true)
        let client = makeClient()
        await #expect(throws: TransportError.self) { try await client.authenticate() }
        #expect(ServeStub.log == ["GET /api/sessions", "POST /auth/password-login"])
    }
}

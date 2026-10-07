import Foundation
import Network
import Testing
@testable import Echo

/// A server on this machine's loopback that keeps what it is sent and answers `{}`: the only way
/// to see the headers a request really left with, the session's own included.
nonisolated final class CaptureServer: @unchecked Sendable {
    let port: UInt16
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private let listener: NWListener
    private let lock = NSLock()
    private var requests: [String] = []
    private static let queue = DispatchQueue(label: "capture-server")

    /// Every request so far, head and all.
    var received: [String] { lock.withLock { requests } }

    private init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }

    static func start() async throws -> CaptureServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let box = Box()
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                box.server?.record(data.map { String(decoding: $0, as: UTF8.self) } ?? "")
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                connection.send(content: Data(reply.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in connection.cancel() }
                })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { ready in
            let resumed = NSLock()
            nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { state in
                resumed.lock(); defer { resumed.unlock() }
                guard !done else { return }
                switch state {
                case .ready: done = true; ready.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): done = true; ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let server = CaptureServer(listener: listener, port: port)
        box.server = server
        return server
    }

    func stop() { listener.cancel() }
    private func record(_ request: String) { lock.withLock { requests.append(request) } }

    private final class Box: @unchecked Sendable { var server: CaptureServer? }
}

struct CustomHeaderTests {
    @Test func namesAreHeaderTokensAndNotTheConnectionsOwn() {
        #expect(CustomHeader.problem(withName: "X-Proxy-Token") == nil)
        #expect(CustomHeader.problem(withName: "Authorization") == nil, "a proxy's basic auth is a fair use")
        #expect(CustomHeader.problem(withName: "") != nil)
        #expect(CustomHeader.problem(withName: "X Proxy") != nil)
        #expect(CustomHeader.problem(withName: "X-Proxy: abc") != nil)
        #expect(CustomHeader.problem(withName: "Host") != nil)
        #expect(CustomHeader.problem(withName: "content-length") != nil)
        #expect(CustomHeader.problem(withName: "Sec-WebSocket-Key") != nil)
    }

    @Test func theListSurvivesTheKeychainAndAnEmptyOneIsNoEntry() {
        let headers = [CustomHeader(name: " X-Proxy-Token ", value: " s3cret "), CustomHeader(name: "X-Tenant", value: "home")]
        #expect(headers[0] == CustomHeader(name: "X-Proxy-Token", value: "s3cret"), "pasted with spaces around it")
        #expect(CustomHeader.decode(CustomHeader.encode(headers)) == headers)
        #expect(CustomHeader.encode([]) == "")
        #expect(CustomHeader.decode(nil).isEmpty)
        #expect(CustomHeader.decode("not json").isEmpty)
    }

    @Test func onlyHeadersThatCanBeSentBecomeFields() {
        let fields = CustomHeader.fields([
            CustomHeader(name: "X-Proxy-Token", value: "s3cret"),
            CustomHeader(name: "Host", value: "elsewhere"),
            CustomHeader(name: "X-Empty", value: ""),
            CustomHeader(name: "X-Split", value: "a\nInjected: yes"),
        ])
        #expect(fields == ["X-Proxy-Token": "s3cret"])
    }

    @Test func addingReplacesTheOneByTheSameName() {
        let headers = CustomHeader.adding(CustomHeader(name: "x-proxy-token", value: "new"),
                                          to: [CustomHeader(name: "X-Proxy-Token", value: "old"), CustomHeader(name: "X-Tenant", value: "home")])
        #expect(headers == [CustomHeader(name: "X-Tenant", value: "home"), CustomHeader(name: "x-proxy-token", value: "new")])
    }

    @Test func theAppsOwnHeadersWinInAStreamingRequest() throws {
        struct Body: Encodable { var input = "hi" }
        let request = try StreamingHTTP.makeRequest(url: URL(string: "http://h.test/api")!, apiKey: "key",
                                                    headers: ["X-Proxy-Token": "s3cret", "Authorization": "Basic cHJveHk=", "Accept": "text/plain"], body: Body())
        #expect(request.value(forHTTPHeaderField: "X-Proxy-Token") == "s3cret")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func theHermesAPISendsThemWithItsKey() async throws {
        let server = try await CaptureServer.start()
        defer { server.stop() }
        let api = HermesSessionsAPI(baseURL: server.baseURL, apiKey: "key", headers: ["X-Proxy-Token": "s3cret"])
        _ = try? await api.listSessions()
        let request = try #require(server.received.first)
        #expect(request.localizedCaseInsensitiveContains("x-proxy-token: s3cret"))
        #expect(request.localizedCaseInsensitiveContains("authorization: Bearer key"))
    }

    @MainActor final class Endpoint: ServeEndpoint {
        var serveBaseURL: URL?
        var serveUsername = ""
        var profileName: String?
        var accessHeaders: [String: String] = [:]
    }

    /// The Dashboard's requests take them from the session, so they ride on every one of them
    /// (and on the WebSocket's handshake) without each request having to add them.
    @Test @MainActor func theDashboardSendsThemOnEveryRequest() async throws {
        let server = try await CaptureServer.start()
        defer { server.stop() }
        let endpoint = Endpoint()
        endpoint.serveBaseURL = server.baseURL
        endpoint.accessHeaders = ["X-Proxy-Token": "s3cret"]
        let signedIn = HermesServeClientTests.TokenBox(DashboardTokens(accessToken: "access", refreshToken: "refresh"))
        let client = HermesServeClient(settings: endpoint, password: { nil }, tokens: signedIn.store)
        _ = try await client.restJSON("GET", "api/cron/jobs")
        let request = try #require(server.received.first)
        #expect(request.hasPrefix("GET /api/cron/jobs "))
        #expect(request.localizedCaseInsensitiveContains("x-proxy-token: s3cret"))
        #expect(request.localizedCaseInsensitiveContains("authorization: Bearer access"))

        // Changed in Settings: the next request carries the new ones.
        endpoint.accessHeaders = ["X-Proxy-Token": "rotated"]
        _ = try await client.restJSON("GET", "api/cron/jobs")
        #expect(server.received.last?.localizedCaseInsensitiveContains("x-proxy-token: rotated") == true)
    }

    @Test @MainActor func theWatchIsHandedThemWithTheHermesAPI() {
        let settings = Settings(defaults: UserDefaults(suiteName: "headers-\(UUID().uuidString)")!)
        settings.transport = .hermesSessions
        settings.gatewayURL = "https://hermes.example"
        let handed = WatchLink.connection(settings, gatewayKey: { "key" }, dashboardPassword: { nil }, dashboardSignedIn: { false },
                                          customHeaders: { ["X-Proxy-Token": "s3cret"] })
        #expect(handed?.kind == .hermesAPI)
        #expect(handed?.headers == ["X-Proxy-Token": "s3cret"])
        let plain = WatchLink.connection(settings, gatewayKey: { "key" }, dashboardPassword: { nil }, dashboardSignedIn: { false },
                                         customHeaders: { [:] })
        #expect(plain?.headers == nil)
        // A copy from before headers existed still reads.
        let old = #"{"kind":"hermesAPI","url":"https://hermes.example","apiKey":"","model":"","provider":"","reasoningEffort":"","replyLanguage":"","agentName":"Redde"}"#
        #expect((try? JSONDecoder().decode(WatchConnection.self, from: Data(old.utf8)))?.headers == nil)
    }
}

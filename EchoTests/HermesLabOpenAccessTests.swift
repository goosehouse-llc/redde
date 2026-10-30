import Foundation
import Testing
@testable import Echo

/// A Dashboard with no sign-in, for real (`scripts/hermes-lab/lab.sh open`, asked 2026-10-30): the
/// lab's `hermes serve` on 127.0.0.1 with no public address and no login, as Hermex uses one. The
/// app's own client, with nothing stored, reads the token off the page, lists the conversations,
/// opens the WebSocket and the Kanban board's, and has a turn answered by the stand-in model. Then
/// the lab restarts the Dashboard (`restart_dashboard.py`, which the test asks), and the client
/// has to come back on the new token, on the socket and on REST; the same as the whole Dashboard
/// page (`hermes dashboard`); and a Dashboard that turns its sign-in on, or a login saved for one
/// that has none, has to be said as that. Skips when that lab isn't up.
struct HermesLabOpenAccessTests {
    private static let dashboard = URL(string: "http://127.0.0.1:19119")!
    private static let restarter = URL(string: "http://127.0.0.1:18979/restart")!

    private static func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }

    private static func status() async -> JSONValue? {
        var probe = URLRequest(url: dashboard.appending(path: "api/status"))
        probe.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: probe) else { return nil }
        return try? JSONValue.parse(data)
    }

    /// Asks the lab to restart the Dashboard as `kind` (serve, dashboard, gated); nil when there
    /// is no one to ask (a lab brought up by hand), else what it said.
    private static func restart(_ kind: String) async -> JSONValue? {
        var request = URLRequest(url: restarter.appending(queryItems: [.init(name: "as", value: kind)]))
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONValue.parse(data)) ?? .null
    }

    private static func page() async -> String {
        guard let (data, _) = try? await URLSession.shared.data(from: dashboard) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One turn in a new conversation; the stand-in model answers "[A:alpha]".
    private static func turn(_ client: HermesServeClient) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var reply = ""
                let request = TurnRequest(userText: "Say something, lab.", history: [], sessionID: nil, model: nil, instructions: nil)
                for try await event in HermesServeTransport(client: client).stream(request) {
                    switch event {
                    case let .textDelta(delta): reply += delta
                    case let .textFinal(text): reply = text
                    default: break
                    }
                }
                return reply.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw TransportError.malformed("the turn did not finish in a minute")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
    }

    /// Whether a WebSocket the client opened is open: a ping comes back.
    private nonisolated static func pings(_ socket: URLSessionWebSocketTask) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            socket.sendPing { error in done.resume(returning: error == nil) }
        }
    }

    private static func settings(open: Bool, username: String = "") -> Settings {
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-open-\(UUID().uuidString)")!)
        settings.serveURL = dashboard.absoluteString
        settings.serveUsername = username
        settings.serveOpenAccess = open
        return settings
    }

    @Test func theAppGoesInWithNoSignInAndComesBackAfterARestart() async throws {
        guard let before = await Self.status(), before["auth_required"]?.bool == false else {
            print("LAB SKIP: no Hermes lab with a Dashboard with no sign-in on 127.0.0.1:19119 (scripts/hermes-lab/lab.sh open)")
            return
        }
        print("  ----  Hermes \(before["version"]?.string ?? "?"), auth_required false")
        let client = HermesServeClient(settings: Self.settings(open: true), password: { nil }, tokens: HermesServeClientTests.TokenBox().store)
        defer { client.disconnect() }

        // In, with nothing stored.
        var said = ""
        do { try await client.ensureConnected() } catch { said = error.localizedDescription }
        Self.report(client.state == .connected && client.usesPageToken, "the WebSocket opens on the token read off the page (?token=, no ticket)", said)
        let listed = (try? await client.listSessions(limit: 5)) != nil
        Self.report(listed, "the conversation list comes with the token in X-Hermes-Session-Token")
        var reply = ""
        do { reply = try await Self.turn(client) } catch { reply = "error: \(error.localizedDescription)" }
        Self.report(reply.contains("[A:"), "a message is answered over the socket", reply)
        var board = false
        if let socket = try? await client.openPluginSocket(path: "api/plugins/kanban/events", query: [.init(name: "since", value: "0")]) {
            board = await Self.pings(socket)
            socket.cancel(with: .goingAway, reason: nil)
        }
        Self.report(board, "a plugin's WebSocket (the Kanban board's events) opens on the token too")

        guard let restarted = await Self.restart("serve") else {
            print("  ----  no one to restart the Dashboard (lab.sh open starts restart_dashboard.py); restarts not tried")
            return
        }
        Self.report(restarted["ok"]?.bool == true, "the lab restarts the Dashboard (a new session token)", "\(restarted)")
        // The socket drops with the host; the reconnect has to read the page again.
        let back = await client.waitForConnection(timeout: 90)
        Self.report(back, "after a restart the WebSocket comes back on the new token", "state \(client.state)")
        let listedAgain = (try? await client.listSessions(limit: 5)) != nil
        Self.report(listedAgain, "after a restart the conversation list loads")
        do { reply = try await Self.turn(client) } catch { reply = "error: \(error.localizedDescription)" }
        Self.report(reply.contains("[A:"), "after a restart a message is answered", reply)

        // REST first this time: a 401, the page read once, the call sent again.
        _ = await Self.restart("serve")
        let restAfter = (try? await client.listSessions(limit: 5)) != nil
        Self.report(restAfter, "after another restart a REST call reads the page once and goes through")

        // The whole Dashboard page, as `hermes dashboard` serves it.
        let full = await Self.restart("dashboard")
        let shape = await Self.page()
        if full?["ok"]?.bool == true, shape.contains("__HERMES_DASHBOARD_EMBEDDED_CHAT__") {
            let listedFull = (try? await client.listSessions(limit: 5)) != nil
            Self.report(listedFull, "the whole Dashboard page (hermes dashboard): its token is read and taken")
            let backFull = await client.waitForConnection(timeout: 90)
            do { reply = try await Self.turn(client) } catch { reply = "error: \(error.localizedDescription)" }
            Self.report(backFull && reply.contains("[A:"), "the whole Dashboard page: the WebSocket opens and a message is answered", "\(client.state) \(reply)")
        } else {
            Self.report(false, "the lab serves the whole Dashboard page", "\(full ?? .null) \(shape.prefix(160))")
        }

        // The sign-in turned on: said as that, not as a missing password.
        _ = await Self.restart("gated")
        var gatedSaid: Error?
        do { _ = try await client.listSessions(limit: 1) } catch { gatedSaid = error }
        Self.report((gatedSaid as? DashboardSignInChange) == .nowAsksForLogin, "a Dashboard that now asks for a login is said to",
                    gatedSaid?.localizedDescription ?? "it let the phone in")

        // And the other way: a login saved for a Dashboard that has none.
        _ = await Self.restart("serve")
        let withLogin = HermesServeClient(settings: Self.settings(open: false, username: "lab"), password: { "labpass-labpass" },
                                          tokens: HermesServeClientTests.TokenBox().store)
        var loginSaid: Error?
        do { _ = try await withLogin.listSessions(limit: 1) } catch { loginSaid = error }
        Self.report((loginSaid as? DashboardSignInChange) == .noLongerAsks, "a login saved for a Dashboard with no sign-in is said to be of no use",
                    loginSaid?.localizedDescription ?? "it went through")
        let fine = (try? await client.listSessions(limit: 1)) != nil
        Self.report(fine, "and the client with no login is let in again")
    }
}

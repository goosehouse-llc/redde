import Foundation
import Testing
@testable import Echo

/// Live tests against a real tailnet. They skip cleanly when the backend isn't reachable so the
/// suite still passes on a plane. Run from a machine that can reach the servers.
struct LiveTransportTests {
    private static func reachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse).map { (200 ..< 500).contains($0.statusCode) } ?? false
    }

    @Test(.enabled(if: TestEndpoints.fastLane != nil, "no fast-lane endpoint in LocalDefaults.json"))
    func fastLaneStreamsAReply() async throws {
        guard let base = TestEndpoints.fastLane, await Self.reachable(base.appending(path: "v1/models")) else {
            print("SKIP: no reachable fast-lane endpoint configured")
            return
        }
        let transport = ChatCompletionsTransport(baseURL: base, apiKey: nil)
        let request = TurnRequest(userText: "Reply with exactly the word: pong", history: [],
                                  sessionID: nil, model: TestEndpoints.fastLaneModel, instructions: nil)
        var text = ""
        var sawDone = false
        let start = Date()
        var firstToken: Date?
        for try await event in transport.stream(request) {
            switch event {
            case let .textDelta(delta):
                if firstToken == nil { firstToken = .now }
                text += delta
            case .done: sawDone = true
            default: break
            }
        }
        print(String(format: "fast lane TTFT %.2fs total %.2fs text=%@",
                     firstToken?.timeIntervalSince(start) ?? -1, Date().timeIntervalSince(start), text))
        #expect(sawDone)
        #expect(text.lowercased().contains("pong"))
    }

    @Test(.enabled(if: TestEndpoints.gateway != nil, "no gateway endpoint in LocalDefaults.json"))
    func gatewayRejectsMissingKeyWithClearError() async throws {
        guard let base = TestEndpoints.gateway, await Self.reachable(base.appending(path: "health")) else {
            print("SKIP: no reachable gateway configured")
            return
        }
        // Wrong key (not missing): proves TLS + ATS + routing work and the 401 body surfaces.
        let transport = HermesSessionsTransport(baseURL: base, apiKey: "not-a-real-key")
        let request = TurnRequest(userText: "ping", history: [], sessionID: "probe", model: nil, instructions: nil)
        var thrown: Error?
        do { for try await _ in transport.stream(request) {} } catch { thrown = error }
        guard case let .http(status, body)? = thrown as? TransportError else {
            Issue.record("expected TransportError.http, got \(String(describing: thrown))")
            return
        }
        #expect(status == 401)
        #expect(body.contains("gateway_auth"))
    }
}

/// The app's Hermes API transport against the stub-endpoint lab (`scripts/hermes-lab/lab.sh`):
/// an unmodified Hermes on loopback whose model endpoints answer "[<stub>:<model>]", so the reply
/// says where a turn went. Skips when no lab is up.
struct HermesLabTests {
    private static let base = URL(string: "http://127.0.0.1:18642")!
    private static let key = "labkey-labkey-labkey"
    /// Stub A serves alpha and beta, stub B serves gamma.
    private static let stubs = ["alpha": "A", "beta": "A", "gamma": "B"]

    private static func reply(_ transport: HermesSessionsTransport, session: String, model: String?, provider: String?) async -> String {
        var text = ""
        do {
            let request = TurnRequest(userText: "hi", history: [], sessionID: session, model: model, provider: provider, instructions: nil)
            for try await event in transport.stream(request) {
                if case let .textDelta(delta) = event { text += delta }
                if case let .textFinal(final) = event { text = final }
            }
        } catch {
            return "\(text) then: \(error.localizedDescription.prefix(100))"
        }
        return text
    }

    @Test func aPickedModelReachesItsEndpoint() async throws {
        var probe = URLRequest(url: Self.base.appending(path: "health"))
        probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            print("LAB SKIP: no Hermes lab on 127.0.0.1:18642 (scripts/hermes-lab/lab.sh up <tag> <scenario>)")
            return
        }
        let api = HermesSessionsAPI(baseURL: Self.base, apiKey: Self.key)
        let transport = HermesSessionsTransport(baseURL: Self.base, apiKey: Self.key)
        let choices = try await api.modelOptions()
        for choice in choices where Self.stubs[choice.model] != nil {
            let provider = Conversation.liveProvider(for: choice.model, saved: choice.provider, in: choices)
            let expected = "[\(Self.stubs[choice.model]!):\(choice.model)]"

            let created = try await api.createSession(title: "lab \(UUID().uuidString)", model: choice.model, provider: provider)
            var replies = [await Self.reply(transport, session: created.id, model: choice.model, provider: provider),
                           await Self.reply(transport, session: created.id, model: choice.model, provider: provider)]
            var ok = replies.allSatisfy { $0 == expected }
            print("  \(ok ? "PASS" : "FAIL")  new conversation: \(choice.model) picked under \(choice.provider), sent as \(provider ?? "none") \(ok ? "" : "\(replies)")")
            #expect(ok)

            let open = try await api.createSession(title: "lab \(UUID().uuidString)")
            _ = await Self.reply(transport, session: open.id, model: nil, provider: nil)
            try await api.lockSessionModel(id: open.id, model: choice.model, provider: provider)
            replies = [await Self.reply(transport, session: open.id, model: choice.model, provider: provider),
                       await Self.reply(transport, session: open.id, model: choice.model, provider: provider)]
            ok = replies.allSatisfy { $0 == expected }
            print("  \(ok ? "PASS" : "FAIL")  live switch:      \(choice.model) picked under \(choice.provider), sent as \(provider ?? "none") \(ok ? "" : "\(replies)")")
            #expect(ok)
        }
    }
}

/// The app's Dashboard client against the lab's `approval` scenario (`scripts/hermes-lab/lab.sh
/// approvals`): an unmodified Hermes whose Dashboard asks for a login, and a model that calls a
/// command Hermes asks before running. From Hermes 0.21.3 the question reaches the client a
/// different way, and from 0.21.5 only a client that says it can answer; a personal Hermes on an
/// older release hid that the app was never asked. Skips when that lab isn't up.
struct HermesLabApprovalTests {
    private static let dashboard = URL(string: "http://127.0.0.1:19119")!

    private struct Outcome {
        var asked: ApprovalRequest?
        var reply = ""
    }

    /// One turn the stub answers with `rm -rf` on its target folder. The reply is "[gone]" when
    /// the command ran and "[kept]" when it didn't: the stub looks.
    private static func turn(_ client: HermesServeClient, answer: String) async throws -> Outcome {
        var outcome = Outcome()
        let request = TurnRequest(userText: "Do the danger thing.", history: [], sessionID: nil, model: nil, instructions: nil)
        for try await event in HermesServeTransport(client: client).stream(request) {
            switch event {
            case let .textDelta(delta): outcome.reply += delta
            case let .textFinal(text): outcome.reply = text
            case let .interrupt(.approval(approval), runtime):
                outcome.asked = approval
                try await client.respondApproval(runtimeSession: runtime, requestID: approval.id, choice: answer)
            default: break
            }
        }
        // The reply after a tool call opens a new paragraph.
        outcome.reply = outcome.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return outcome
    }

    /// A turn nobody was asked about would wait on the host; a minute is plenty for a stub.
    private static func timed(_ work: @escaping @Sendable () async throws -> Outcome) async throws -> Outcome {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw TransportError.malformed("the turn did not finish in a minute")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? Outcome()
        }
    }

    @Test func theDashboardAsksBeforeACommandRuns() async throws {
        var probe = URLRequest(url: Self.dashboard.appending(path: "api/status"))
        probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            print("LAB SKIP: no Hermes lab on 127.0.0.1:19119 (scripts/hermes-lab/lab.sh up <tag> approval)")
            return
        }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-approval-\(UUID().uuidString)")!)
        settings.serveURL = Self.dashboard.absoluteString
        settings.serveUsername = "lab"
        let client = HermesServeClient(settings: settings, password: { "labpass-labpass" })
        do {
            try await client.ensureConnected()
        } catch {
            print("LAB SKIP: the lab's Dashboard has no login for the app (scripts/hermes-lab/lab.sh up <tag> approval): \(error.localizedDescription.prefix(80))")
            return
        }
        defer { client.disconnect() }
        for (answer, expected) in [("once", "[gone]"), ("deny", "[kept]")] {
            var detail = ""
            var ok = false
            do {
                let outcome = try await Self.timed { try await Self.turn(client, answer: answer) }
                ok = outcome.asked?.command.contains("rm -rf") == true && outcome.asked?.yesNo != nil && outcome.reply == expected
                detail = "asked \(outcome.asked?.command ?? "nothing") \(outcome.asked?.choices ?? []), reply \(outcome.reply)"
            } catch {
                detail = String(error.localizedDescription.prefix(160))
            }
            print("  \(ok ? "PASS" : "FAIL")  a command the agent wants to run is asked about; \"\(answer)\" \(expected == "[gone]" ? "runs it" : "stops it") \(ok ? "" : detail)")
            #expect(ok)
        }
    }
}

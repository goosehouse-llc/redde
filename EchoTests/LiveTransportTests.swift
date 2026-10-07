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

    /// A client signed in to the lab's Dashboard; nil, with the reason printed, when that lab isn't up.
    static func client() async -> HermesServeClient? {
        var probe = URLRequest(url: dashboard.appending(path: "api/status"))
        probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            print("LAB SKIP: no Hermes lab on 127.0.0.1:19119 (scripts/hermes-lab/lab.sh up <tag> approval, or push)")
            return nil
        }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-approval-\(UUID().uuidString)")!)
        settings.serveURL = dashboard.absoluteString
        settings.serveUsername = "lab"
        let client = HermesServeClient(settings: settings, password: { "labpass-labpass" })
        do {
            try await client.ensureConnected()
        } catch {
            print("LAB SKIP: the lab's Dashboard has no login for the app (scripts/hermes-lab/lab.sh up <tag> approval): \(error.localizedDescription.prefix(80))")
            return nil
        }
        return client
    }

    static func report(_ ok: Bool, _ what: String, _ detail: String = "") {
        print("  \(ok ? "PASS" : "FAIL")  \(what) \(ok ? "" : detail)")
        #expect(ok, "\(what): \(detail)")
    }

    @Test func theDashboardAsksBeforeACommandRuns() async throws {
        guard let client = await Self.client() else { return }
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
            Self.report(ok, "a command the agent wants to run is asked about; \"\(answer)\" \(expected == "[gone]" ? "runs it" : "stops it")", detail)
        }
    }

    /// Starts the turn that asks about `rm -rf`, and goes away before the agent gets to it, as the
    /// app does when iOS closes it. The agent then asks nobody, and waits. Returns the session.
    private static func leaveATurnWaiting() async throws -> String? {
        guard let first = await client() else { return nil }
        let (runtime, stored) = try await first.openSession(stored: nil)
        try await first.call("prompt.submit", params: .object(["session_id": .string(runtime), "text": .string("Do the danger thing.")]))
        first.disconnect()
        try await Task.sleep(for: .seconds(4))
        return stored
    }

    /// The reply the host has recorded for a session, once there is one.
    private static func recordedReply(_ client: HermesServeClient, stored: String) async throws -> String {
        for _ in 0 ..< 40 {
            let messages = Conversation.messages(fromServeRows: try await client.history(stored: stored))
            if let last = messages.last, last.role == .assistant, !last.text.isEmpty {
                return last.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        return ""
    }

    /// The app was closed while the agent worked, and comes back: the turn is joined where it
    /// stands, the approval it waits on is put again, and the answer counts.
    @Test func aTurnLeftWaitingIsJoinedAndItsQuestionAnswered() async throws {
        guard let stored = try await Self.leaveATurnWaiting(), let client = await Self.client() else { return }
        defer { client.disconnect() }
        var detail = ""
        var ok = false
        do {
            let outcome = try await Self.timed {
                guard let joined = try await HermesServeTransport(client: client).rejoin(stored: stored) else {
                    throw TransportError.malformed("the host says nothing is under way")
                }
                var outcome = Outcome()
                for try await event in joined.events {
                    switch event {
                    case let .textDelta(delta): outcome.reply += delta
                    case let .textFinal(text): outcome.reply = text
                    case let .interrupt(.approval(approval), runtime):
                        outcome.asked = approval
                        try await client.respondApproval(runtimeSession: runtime, requestID: approval.id, choice: "once")
                    default: break
                    }
                }
                let recorded = try await joined.transcript()
                outcome.reply = outcome.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    + " | question: \(joined.question) | recorded: \(recorded.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")"
                return outcome
            }
            ok = outcome.asked?.command.contains("rm -rf") == true
                && outcome.reply == "[gone] | question: Do the danger thing. | recorded: [gone]"
            detail = "asked \(outcome.asked?.command ?? "nothing"), \(outcome.reply)"
        } catch {
            detail = String(error.localizedDescription.prefix(160))
        }
        Self.report(ok, "a turn left waiting on an approval is joined by the app when it returns, and its answer counts", detail)

        // Over: there is nothing to join.
        let finished = try await HermesServeTransport(client: client).rejoin(stored: stored) == nil
        Self.report(finished, "a session whose turn has ended has nothing to join")
    }

    /// Approve or Deny on a notification: no card, only the session and the command's digest.
    @Test func anAnswerFromANotificationReachesTheCommandItWasFor() async throws {
        for (approve, expected) in [(false, "[kept]"), (true, "[gone]")] {
            guard let stored = try await Self.leaveATurnWaiting(), let client = await Self.client() else { return }
            defer { client.disconnect() }
            var detail = ""
            var ok = false
            do {
                let waiting = try await client.resume(stored: stored, withMessages: false)
                let command = waiting["pending_approval"]?["command"]?.string ?? ""
                let other = try await client.answerWaitingApproval(stored: stored, digest: PushNote.digest(of: "some other command"), approve: true)
                let answered = try await client.answerWaitingApproval(stored: stored, digest: PushNote.digest(of: command), approve: approve)
                let reply = try await Self.recordedReply(client, stored: stored)
                let after = try await client.answerWaitingApproval(stored: stored, digest: PushNote.digest(of: command), approve: true)
                ok = command.contains("rm -rf") && other == .anotherCommand && answered == .answered && reply == expected && after == .nothingWaiting
                detail = "command \(command), another command's answer \(other), this one's \(answered), reply \(reply), afterwards \(after)"
            } catch {
                detail = String(error.localizedDescription.prefix(160))
            }
            Self.report(ok, "\(approve ? "Approve" : "Deny") from a notification \(approve ? "runs" : "stops") the command it was shown for, and no other", detail)
        }
    }
}

/// The app pairing with the push plugin over the lab's Dashboard (`scripts/hermes-lab/lab.sh push
/// --app`): the app's own client and push service, an unmodified Hermes with the plugin from
/// this repository, and the relay's code on this machine. Skips when that lab isn't up.
struct HermesLabPushTests {
    private final class Vault { var pairings: [PushPairing] = [] }

    @Test func theAppPairsWithThePluginInOneStep() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        let plugin = PushService.command(over: client)
        let vault = Vault()
        let defaults = UserDefaults(suiteName: "lab-push-\(UUID().uuidString)")!
        defaults.set("http://127.0.0.1:18980", forKey: "push.relay")
        // A push address of the right shape: the lab's stand-in for Apple takes any.
        let token = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
        nonisolated(unsafe) weak var made: PushService?
        let service = PushService(defaults: defaults, session: .shared, vault: ({ vault.pairings }, { vault.pairings = $0; return true }),
                                  askForToken: { Task { @MainActor in made?.received(token: token) } }, allowed: { true })
        made = service
        func paired() async throws -> Int { Int(try await plugin("status").split(separator: " ").last ?? "") ?? -1 }

        var detail = ""
        var ok = false
        do {
            let before = try await paired()
            let pairing = try await service.pairDirectly(through: plugin)
            let after = try await paired()
            ok = pairing.accepted == true && !pairing.host.isEmpty && after == before + 1 && vault.pairings == [pairing]
            detail = "accepted \(String(describing: pairing.accepted)), host \(pairing.host), the plugin had \(before) phones and has \(after)"
            await service.unpair(pairing)
        } catch PushError.noPlugin {
            print("LAB SKIP: this lab's Hermes has no push plugin (scripts/hermes-lab/lab.sh up <tag> push)")
            return
        } catch {
            detail = String(error.localizedDescription.prefix(200))
        }
        HermesLabApprovalTests.report(ok, "the app pairs with the plugin over the Dashboard in one step", detail)
    }
}

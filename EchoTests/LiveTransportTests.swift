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
        /// What else the turn waited on a person for: a question, the sudo password, a secret.
        var waitedOn = ""
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
        let client = HermesServeClient(settings: settings, password: { "labpass-labpass" }, tokens: HermesServeClientTests.TokenBox().store)
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
    private static func leaveATurnWaiting(saying text: String = "Do the danger thing.") async throws -> String? {
        guard let first = await client() else { return nil }
        let (runtime, stored) = try await first.openSession(stored: nil)
        try await first.call("prompt.submit", params: .object(["session_id": .string(runtime), "text": .string(text)]))
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

    /// The same for the other things a turn waits on a person for, which a paired Hermes also
    /// announces: a question, the sudo password, a secret. Each is put again to the app that
    /// opens the conversation, and its answer lets the turn go on. Hermes 0.21.0 keeps no list
    /// of what a turn waits on, so there nothing comes back; that is said, not failed.
    @Test func aQuestionAPasswordAndASecretLeftWaitingComeBackToo() async throws {
        let cases = [("lab:question please", "a question", "question Which branch should I deploy? [main (Recommended), release]"),
                     ("lab:sudo please", "the sudo password", "sudo"),
                     ("lab:secret please", "a secret", "secret Enter the lab token for LAB_SECRET_TOKEN")]
        for (text, what, expected) in cases {
            guard let stored = try await Self.leaveATurnWaiting(saying: text), let client = await Self.client() else { return }
            defer { client.disconnect() }
            let waiting = try await client.resume(stored: stored, withMessages: false)
            guard let listed = waiting["open_requests"]?.array, !listed.isEmpty else {
                print(waiting["open_requests"]?.array == nil
                    ? "  ----  this Hermes keeps no list of what a turn waits on (0.21.0): \(what) doesn't come back on opening"
                    : "  ----  nothing is waiting for \(what) here (sudo needs no password on this machine?)")
                _ = try? await client.call("session.interrupt", params: .object(["session_id": .string(waiting["session_id"]?.string ?? "")]))
                continue
            }
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
                        case let .interrupt(.clarify(request), runtime):
                            let asked = request.questions.first
                            outcome.waitedOn = "question \(asked?.question ?? "") [\((asked?.choices ?? []).joined(separator: ", "))]"
                            try await client.respondClarify(runtimeSession: runtime, requestID: request.id, questionID: asked?.id, answer: "release")
                        case let .interrupt(.sudo(id), runtime):
                            outcome.waitedOn = "sudo"
                            try await client.respondSudo(runtimeSession: runtime, requestID: id, password: "")   // none given: the command fails, the turn goes on
                        case let .interrupt(.secret(request), runtime):
                            outcome.waitedOn = "secret \(request.prompt) for \(request.envVar)"
                            try await client.respondSecret(runtimeSession: runtime, requestID: request.id, value: "")   // skipped
                        default: break
                        }
                    }
                    outcome.reply = outcome.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    return outcome
                }
                ok = outcome.waitedOn == expected && !outcome.reply.isEmpty
                detail = "waited on \(outcome.waitedOn.isEmpty ? "nothing" : outcome.waitedOn), reply \(outcome.reply)"
            } catch {
                detail = String(error.localizedDescription.prefix(160))
            }
            Self.report(ok, "a turn left waiting on \(what) is joined by the app when it returns, and goes on once it is answered", detail)
        }
    }

    /// A file that isn't a picture or a PDF is only put in the session's workspace by the
    /// Dashboard; the agent hears of it when the message names it, by the reference the
    /// Dashboard answers with. The stub says whether the file's text (or, for one that can't
    /// be read as text, its name) reached the model.
    @Test func aFileAttachedOverTheDashboardReachesTheAgent() async throws {
        guard let client = await Self.client() else { return }
        defer { client.disconnect() }
        let notes = Attachment(kind: .text, filename: "lab-notes.txt", mimeType: "text/plain", data: Data("The password is lab-file-token.".utf8))
        let clip = Attachment(kind: .other, filename: "lab-clip.mp4", mimeType: "video/mp4", data: Data(repeating: 7, count: 2048))
        for (attachment, what) in [(notes, "a text file"), (clip, "a video")] {
            var detail = ""
            var ok = false
            do {
                let outcome = try await Self.timed {
                    var outcome = Outcome()
                    let request = TurnRequest(userText: "lab:file please", history: [], sessionID: nil, model: nil, instructions: nil, attachments: [attachment])
                    for try await event in HermesServeTransport(client: client).stream(request) {
                        switch event {
                        case let .textDelta(delta): outcome.reply += delta
                        case let .textFinal(text): outcome.reply = text
                        default: break
                        }
                    }
                    outcome.reply = outcome.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    return outcome
                }
                ok = outcome.reply == "[file seen]"
                detail = "reply \(outcome.reply)"
            } catch {
                detail = String(error.localizedDescription.prefix(160))
            }
            Self.report(ok, "\(what) attached to a message over the Dashboard reaches the agent", detail)
        }
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

/// Signing in through a browser, against the same lab (`scripts/hermes-lab/lab.sh signin`): the
/// Dashboard's own native sign-in routes, with this test standing in for the person in the
/// browser. The lab's login is a username and a password, so the browser's part is the Dashboard's
/// login page; with Google or another provider only that part differs, and it never involves the
/// app. What is checked is the app's half: the code comes back to the phone, buys tokens, and the
/// tokens work for REST, for the WebSocket, and across a refresh. Skips when no lab is up.
struct HermesLabSignInTests {
    private static let dashboard = URL(string: "http://127.0.0.1:19119")!

    /// What a person does in the browser: open the address, type the login, and be sent back.
    private static func browser(_ authorize: URL) async throws {
        // A browser of its own: the Dashboard's sign-in cookie lives here, never in the app.
        let web = URLSession(configuration: .ephemeral)
        _ = try await web.data(from: authorize)   // lands on the login page, with the pending sign-in in a cookie
        var login = URLRequest(url: dashboard.appending(path: "auth/password-login"))
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = Data(#"{"provider":"basic","username":"lab","password":"labpass-labpass"}"#.utf8)
        let (data, _) = try await web.data(for: login)
        guard let next = try JSONValue.parse(data)["next"]?.string, let back = URL(string: next) else {
            throw TransportError.malformed("the login page gave no way back: \(String(decoding: data.prefix(120), as: UTF8.self))")
        }
        _ = try await NoRedirectSession.shared.data(from: back)   // the loopback address on this "phone"
    }

    @Test func theAppSignsInThroughABrowserAndStaysSignedIn() async throws {
        var probe = URLRequest(url: Self.dashboard.appending(path: "api/status"))
        probe.timeoutInterval = 2
        guard let (status, _) = try? await URLSession.shared.data(for: probe),
              (try? JSONValue.parse(status))?["auth_required"]?.bool == true else {
            print("LAB SKIP: no Hermes lab with a Dashboard login on 127.0.0.1:19119 (scripts/hermes-lab/lab.sh up <tag> approval)")
            return
        }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-signin-\(UUID().uuidString)")!)
        settings.serveURL = Self.dashboard.absoluteString
        let box = HermesServeClientTests.TokenBox()
        // No username, no password: the browser sign-in is the only login this client has.
        let client = HermesServeClient(settings: settings, password: { nil }, tokens: box.store)
        defer { client.disconnect() }

        do {
            try await client.signIn { try await Self.browser($0) }
        } catch {
            report(false, "the app signs in through a browser", error.localizedDescription)
            return
        }
        report(box.current?.accessToken.isEmpty == false, "the app signs in through a browser", "no tokens came back")

        let name = (try? await client.signedInName()) ?? ""
        report(name == "lab", "the Dashboard knows who signed in", "it said \"\(name)\"")
        var connected = true
        do { try await client.ensureConnected() } catch { connected = false }
        report(connected, "the WebSocket opens on a ticket bought with the token")
        let listed = (try? await client.listSessions(limit: 1)) != nil
        report(listed, "the token is taken for the session list")

        // The access token lapses (here: is swapped for one the Dashboard refuses). The next
        // call trades the refresh token for a new pair and goes through.
        if var lapsed = box.current {
            lapsed.accessToken = "lapsed"
            box.store.write(lapsed)
        }
        let afterRefresh = (try? await client.listSessions(limit: 1)) != nil
        report(afterRefresh && box.current?.accessToken != "lapsed", "a lapsed token is refreshed and the call retried",
               "token now \(box.current?.accessToken.prefix(8) ?? "nil")")

        // A refresh token the Dashboard no longer takes: the phone is signed out and says so.
        box.store.write(DashboardTokens(accessToken: "lapsed", refreshToken: "spent", provider: "basic"))
        var said = ""
        do { _ = try await client.listSessions(limit: 1) } catch { said = error.localizedDescription }
        report(box.current == nil && said.contains("Sign in again"), "a spent sign-in ends with \"sign in again\"", "it said \"\(said)\"")
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

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

    /// A reply on a question's notification: no card, only the session, the question's digest and
    /// the answer. It reaches that question and no other, and the agent hears it.
    @Test func anAnswerFromANotificationReachesTheQuestionItWasFor() async throws {
        guard let stored = try await Self.leaveATurnWaiting(saying: "lab:question please"), let client = await Self.client() else { return }
        defer { client.disconnect() }
        let waiting = try await client.resume(stored: stored, withMessages: false)
        guard waiting["open_requests"]?.array != nil else {
            print("  ----  this Hermes keeps no list of what a turn waits on (0.21.0): a question can't be answered from its notification")
            _ = try? await client.call("session.interrupt", params: .object(["session_id": .string(waiting["session_id"]?.string ?? "")]))
            return
        }
        var detail = ""
        var ok = false
        do {
            let asked = PushNote.digest(of: "Which branch should I deploy?")
            let other = try await client.answerWaitingQuestion(stored: stored, digest: PushNote.digest(of: "Something else?"), answer: "main")
            let answered = try await client.answerWaitingQuestion(stored: stored, digest: asked, answer: "release")
            let reply = try await Self.recordedReply(client, stored: stored)
            let after = try await client.answerWaitingQuestion(stored: stored, digest: asked, answer: "main")
            ok = other == .anotherQuestion && answered == .answered && reply == "[answered: release]" && after == .nothingWaiting
            detail = "another question's answer \(other), this one's \(answered), reply \(reply), afterwards \(after)"
        } catch {
            detail = String(error.localizedDescription.prefix(160))
        }
        Self.report(ok, "an answer from a notification reaches the question it was shown for, and no other", detail)
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

/// The agent's task list against the lab (`scripts/hermes-lab/lab.sh todos`): the stub model
/// writes a list of three with Hermes's to-do tool, merges two changes into it, and then tries a
/// merge that Hermes 0.21.3 and later turn down. The app has to have the list as it stands after
/// each, from what really comes down each connection: live over the Dashboard (the host says the
/// list), live over the Hermes API (the calls alone), and from the stored transcript of each when
/// the conversation is opened again.
struct HermesLabTodoTests {
    private static let api = URL(string: "http://127.0.0.1:18642")!
    private static let key = "labkey-labkey-labkey"

    private static func says(_ list: [TodoItem]?) -> String {
        list.map { $0.map { "\($0.id)=\($0.status.rawValue)" }.joined(separator: " ") } ?? "no list"
    }

    private static let written: [TodoItem.Status] = [.inProgress, .pending, .pending]
    private static let ticked: [TodoItem.Status] = [.completed, .inProgress, .pending]
    /// The merge on a Hermes API that forgot the list: only the two items it named.
    private static let tickedAlone: [TodoItem.Status] = [.completed, .inProgress]
    /// Where Hermes takes the third call (0.21.0), the second item is done as well.
    private static let tickedAgain: [TodoItem.Status] = [.completed, .completed, .pending]

    @Test func theChecklistFollowsTheAgentsListOnBothConnections() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }

        // The Dashboard, through a conversation of the app's own.
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-todo-\(UUID().uuidString)")!)
        settings.transport = .hermesServe   // the later turns have to go into the first one's session
        let conversation = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-todo-\(UUID().uuidString)")),
                                        transportOverride: HermesServeTransport(client: client))
        // Each turn goes out a moment after the one before ends. Hermes 0.21.3 and later say the
        // session has settled some 75 ms after a reply's last message, which the next turn is
        // already listening for by then: about one run in three here, and it once ended that
        // turn with nothing in it.
        func turn(_ text: String) async throws -> Message? {
            _ = conversation.send(text)
            for _ in 0 ..< 600 where conversation.isStreaming { try await Task.sleep(for: .milliseconds(100)) }
            return conversation.messages.last
        }
        let first = try await turn("lab:todo")
        guard first?.todos != nil || first?.tools.contains(where: { TodoList.isTool($0.name) }) == true else {
            print("  ----  this Hermes gave the model no way to its to-do tool; nothing to draw")
            return
        }
        report(first?.todos?.map(\.status) == Self.written && first?.todos?.first?.content == "Export the posts",
               "Dashboard, live: a list the agent writes is the reply's checklist", "\(Self.says(first?.todos)), steps \(first?.tools.map(\.name) ?? [])")
        let second = try await turn("lab:tick")
        report(second?.todos?.map(\.status) == Self.ticked && second?.todos?.map(\.content) == ["Export the posts", "Import them", "Check the feed"],
               "Dashboard, live: a merge in the next turn ticks the same list",
               "\(Self.says(second?.todos)), steps \(second?.tools.map { "\($0.name):\($0.status)" } ?? []), text \(second?.text.prefix(80) ?? ""), error \(second?.error ?? "none")")
        let third = try await turn("lab:badtick")
        let refused = third?.todos == nil
        if refused { print("  ----  this Hermes turns down a merge whose item has no words, without running the tool (0.21.3 and later)") }
        report(refused || third?.todos?.map(\.status) == Self.tickedAgain, "Dashboard, live: a call Hermes turns down changes nothing; one it takes ticks",
               Self.says(third?.todos))
        let final = refused ? Self.ticked : Self.tickedAgain

        // Opened again from the server's own transcript, set against what the host says the list is.
        if let stored = conversation.serverSessionID {
            var reread = Conversation.messages(fromServeRows: try await client.history(stored: stored))
            TodoList.resolve(&reread)
            TodoList.reconcile(&reread, with: client.hostTodos[stored])
            let lists = reread.compactMap(\.todos)
            report(lists.count >= 2 && lists.first?.map(\.status) == Self.written && lists.last?.map(\.status) == final,
                   "Dashboard, reopened: the replies have their checklists back, the last as the host has it", lists.map(Self.says).joined(separator: " | "))
            report(reread.filter { $0.role == .assistant }.allSatisfy { !$0.tools.isEmpty }, "Dashboard, reopened: each reply has its tool steps again",
                   "\(reread.map { "\($0.role.rawValue):\($0.tools.map(\.name))" })")
        } else {
            report(false, "Dashboard, reopened: the replies have their checklists back", "the conversation has no session on the server")
        }

        // The Hermes API: the stream names a finished call without its result.
        var probe = URLRequest(url: Self.api.appending(path: "health"))
        probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            print("  ----  no Hermes API on 127.0.0.1:18642; only the Dashboard was checked")
            return
        }
        let ledger = HermesSessionsAPI(baseURL: Self.api, apiKey: Self.key)
        let transport = HermesSessionsTransport(baseURL: Self.api, apiKey: Self.key)
        // As the app asks: the model by its full name, every turn.
        let choices = (try? await ledger.modelOptions()) ?? []
        let model = choices.first { $0.model == "alpha" }
        let provider = model.flatMap { Conversation.liveProvider(for: $0.model, saved: $0.provider, in: choices) }
        let session = try await ledger.createSession(title: "lab todo \(UUID().uuidString.prefix(8))", model: model?.model, provider: provider)
        var list: [TodoItem] = []
        var names: Set<String> = []
        var forgets = false
        for (text, expected, what) in [("lab:todo", Self.written, "a list the agent writes is read from the call"), ("lab:tick", Self.ticked, "a merge ticks the same list")] {
            let request = TurnRequest(userText: text, history: [], sessionID: session.id, model: model?.model, provider: provider, instructions: nil)
            var running: [ToolActivity] = []
            do {
                for try await event in transport.stream(request) {
                    if case let .toolStarted(name, preview, args) = event {
                        names.insert(name)
                        running.append(ToolActivity(name: name, preview: preview, status: .running, args: args))
                    }
                    if case let .toolFinished(name, failed, output) = event, let i = running.lastIndex(where: { name.isEmpty || $0.name == name }) {
                        var done = running.remove(at: i)
                        done.status = failed ? .failed : .completed
                        done.output = output
                        if let next = TodoList.after(step: done, previous: list) { list = next }
                    }
                }
            } catch {
                report(false, "Hermes API, live: \(what)", String(error.localizedDescription.prefix(160)))
                continue
            }
            report(list.map(\.status) == expected, "Hermes API, live: \(what)", "\(Self.says(list)), steps \(names.sorted())")
            // As a conversation does once the turn is over: the tool's own answer is the list.
            let answered = await ledger.answeredTodos(sessionID: session.id)
            if let answered, answered != list {
                forgets = answered.map(\.status) == Self.tickedAlone
                if forgets { print("  ----  this Hermes API starts each turn on an empty list (0.21.3 and later), so the merge left two items; the app shows the tool's answer") }
                list = answered
            }
            report(answered != nil && (list.map(\.status) == expected || forgets), "Hermes API, after the turn: the tool's own answer is the checklist", Self.says(answered))
        }
        report(!names.contains("tool_call"), "Hermes API, live: a step is named for the tool, not for the way it was reached", "\(names.sorted())")
        var stored = Conversation.mapStored(try await ledger.messages(sessionID: session.id))
        TodoList.resolve(&stored)
        let lists = stored.compactMap(\.todos)
        report(lists.count == 2 && lists.first?.map(\.status) == Self.written && lists.last == list,
               "Hermes API, reopened: both replies have the checklist they had live", lists.map(Self.says).joined(separator: " | "))
    }
}

/// The file browser's client against the lab (`scripts/hermes-lab/lab.sh files`, the `approval`
/// scenario, whose Dashboard has a login): the app's own calls on an unmodified Hermes. Everything
/// happens inside a scratch folder the test makes under the lab's directory and removes at the
/// end; nothing else on the machine is written or deleted. Skips when no such lab is up.
struct HermesLabFilesTests {
    private func local(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "lab-files-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    @Test func theFileBrowserWorksOnAnUnmodifiedHermes() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }
        func refusal(_ work: () async throws -> Void) async -> String {
            do { try await work(); return "it went through" } catch { return ServerFiles.explain(error) }
        }

        // Where the server starts: its user's home, with nothing locked.
        let home = try await client.folder(at: nil)
        report(home.path.hasPrefix("/") && home.lockedRoot == nil && !home.entries.isEmpty && home.parent != nil,
               "the starting folder is the server user's home, and lists", "\(home.entries.count) entries, locked: \(home.lockedRoot ?? "no")")
        report(home.entries.first?.isDirectory == true || home.entries.allSatisfy { !$0.isDirectory }, "folders come first")
        let tilde = try? await client.folder(at: "~")
        report(tilde?.path == home.path, "~ is that home", tilde?.path ?? "refused")

        // A scratch folder of the test's own, under the lab's directory.
        let labs = ServerFiles.join(home.path, ".cache/redde-hermes-lab")
        let scratchName = "files-\(UUID().uuidString.prefix(8))"
        let scratch = try await client.makeFolder(scratchName, in: labs)
        report(scratch.isDirectory && scratch.path == ServerFiles.join(labs, scratchName), "a folder is made", scratch.path)
        guard scratch.path.contains("/redde-hermes-lab/files-") else { return }

        // Up, listed, down: a name with a space and a plus in it.
        let words = Data("line one\nline two: ünïcödé\n".utf8)
        let name = "hello world+1.txt"
        do {
            let up = try await client.upload(try local("a.txt", words), as: name, into: scratch.path, replacing: false, watch: nil)
            report(up.name == name && up.size == words.count, "a file is uploaded under its name", "\(up.name), \(up.size ?? -1) bytes")
            let listed = try await client.folder(at: scratch.path)
            let entry = listed.entry(named: name)
            report(entry?.size == words.count && entry?.modified != nil && entry?.mimeType == "text/plain" && listed.parent == labs,
                   "the folder lists it with its size, date and type", "\(String(describing: entry))")
            let down = try await client.download(entry ?? up, watch: nil)
            report((try? Data(contentsOf: down)) == words && down.lastPathComponent == name, "it comes back byte for byte, under its name", down.lastPathComponent)
        } catch {
            report(false, "a file goes up, is listed and comes down", String(error.localizedDescription.prefix(200)))
        }

        // A file of that name is not replaced unasked.
        let file = ServerFile(name: name, path: ServerFiles.join(scratch.path, name), isDirectory: false)
        let other = Data("replaced\n".utf8)
        let said = await refusal { _ = try await client.upload(try self.local("b.txt", other), as: name, into: scratch.path, replacing: false, watch: nil) }
        report(said == "Something with that name is already there.", "a second upload of that name is refused", said)
        do {
            _ = try await client.upload(try local("b.txt", other), as: name, into: scratch.path, replacing: true, watch: nil)
            let text = try await client.text(of: file)
            report(text == ServerText(text: "replaced\n"), "asked to replace, it replaces, and the text reads back", "\(text)")
            try await client.write("changed on the phone\n", to: file)
            report(try await client.text(of: file).text == "changed on the phone\n", "text changed on the phone is saved")
        } catch {
            report(false, "replacing and editing text", String(error.localizedDescription.prefix(200)))
        }

        // Something bigger than a packet or two, and not text.
        do {
            var bytes = Data(count: 3_300_000)
            bytes.withUnsafeMutableBytes { raw in for i in stride(from: 0, to: raw.count, by: 97) { raw[i] = UInt8(truncatingIfNeeded: i &* 31) } }
            let watch = TransferWatch()
            let up = try await client.upload(try local("blob.bin", bytes), as: "blob.bin", into: scratch.path, replacing: false, watch: watch)
            let down = try await client.download(up, watch: watch)
            report((try? Data(contentsOf: down)) == bytes && watch.fraction == 1, "three megabytes go up and come down whole, with progress to the end",
                   "progress \(String(describing: watch.fraction))")
            let read = try await client.text(of: up)
            report(read.binary && !read.canEdit, "bytes that aren't text are known for it")
        } catch {
            report(false, "a larger file both ways", String(error.localizedDescription.prefix(200)))
        }

        // Hermes keeps credentials out of its file manager.
        do {
            let secret = ServerFile(name: ".env", path: ServerFiles.join(scratch.path, ".env"), isDirectory: false)
            try await client.write("LAB_SECRET=not-a-secret\n", to: secret)
            let listed = try await client.folder(at: scratch.path)
            let hidden = listed.entry(named: ".env") == nil
            let why = await refusal { _ = try await client.download(secret, watch: nil) }
            report(hidden && why == "Hermes doesn't hand this one out: it holds credentials.", "a credentials file is neither listed nor handed out", "listed: \(!hidden); download: \(why)")
        } catch {
            report(false, "a credentials file is kept out", String(error.localizedDescription.prefix(200)))
        }

        // A folder with something in it, removed whole; then a file.
        do {
            let sub = try await client.makeFolder("sub folder", in: scratch.path)
            _ = try await client.upload(try local("c.txt", words), as: "inside.txt", into: sub.path, replacing: false, watch: nil)
            try await client.delete(sub)
            try await client.delete(file)
            let listed = try await client.folder(at: scratch.path)
            report(listed.entry(named: "sub folder") == nil && listed.entry(named: name) == nil && listed.entry(named: "blob.bin") != nil,
                   "a folder goes with what is in it, and a file goes alone", "\(listed.entries.map(\.name))")
        } catch {
            report(false, "deleting a folder and a file", String(error.localizedDescription.prefix(200)))
        }
        let gone = await refusal { _ = try await client.folder(at: ServerFiles.join(scratch.path, "sub folder")) }
        report(gone == "It isn't there any more.", "a folder that is gone says so", gone)

        // The scratch folder itself.
        do {
            try await client.delete(scratch)
            let left = try await client.folder(at: labs).entry(named: scratchName)
            report(left == nil, "the scratch folder is removed")
        } catch {
            report(false, "the scratch folder is removed", String(error.localizedDescription.prefix(200)))
        }
    }
}

/// A conversation's own switches and a move to a project, against the lab
/// (`scripts/hermes-lab/lab.sh controls`, the `approval` scenario): the app's client on an
/// unmodified Hermes. Auto-approve is checked by what it is for: the stub's "danger" turn wants to
/// run `rm -rf`, which Hermes asks about, and with the switch on it must run unasked. Fast mode can
/// only be refused here, since the lab's model has none. Skips when no such lab is up.
struct HermesLabChatControlsTests {
    private struct Outcome: Sendable {
        var asked = false
        var reply = ""
    }

    /// One "danger" turn in a stored session. A question about the command is answered no, so
    /// "[kept]" is a turn that asked and "[gone]" one that ran the command.
    private static func danger(_ client: HermesServeClient, stored: String) async throws -> Outcome {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                var outcome = Outcome()
                let request = TurnRequest(userText: "Do the danger thing.", history: [], sessionID: stored, model: nil, instructions: nil)
                for try await event in HermesServeTransport(client: client).stream(request) {
                    switch event {
                    case let .textDelta(delta): outcome.reply += delta
                    case let .textFinal(text): outcome.reply = text
                    case let .interrupt(.approval(approval), runtime):
                        outcome.asked = true
                        try await client.respondApproval(runtimeSession: runtime, requestID: approval.id, choice: "deny")
                    default: break
                    }
                }
                outcome.reply = outcome.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                return outcome
            }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw TransportError.malformed("the turn did not finish in a minute")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? Outcome()
        }
    }

    @Test func aConversationsSwitchesAndAMoveWorkOnAnUnmodifiedHermes() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }
        func say(_ outcome: Outcome) -> String { "asked \(outcome.asked), reply \(outcome.reply)" }

        let stored: String
        do {
            stored = try await client.openSession(stored: nil).stored
            let first = try await Self.danger(client, stored: stored)
            report(first.asked && first.reply == "[kept]", "as it comes, a conversation asks before the command", say(first))
        } catch {
            report(false, "as it comes, a conversation asks before the command", String(error.localizedDescription.prefix(160)))
            return
        }

        let read = try? await client.chatControls(stored: stored)
        report(read == ChatControls(autoApprove: false, approvalMode: "manual", fast: false), "the server says how the conversation runs",
               "\(String(describing: read))")

        // Run commands without asking: on, and it runs; off, and it asks again.
        do {
            let on = try await client.setAutoApprove(true, stored: stored)
            report(on.autoApprove && ChatControlStore.shared.controls(for: stored)?.autoApprove == true,
                   "the switch turns on, and the header's mark has it", "\(on)")
            let unasked = try await Self.danger(client, stored: stored)
            report(!unasked.asked && unasked.reply == "[gone]", "with it on, the command runs unasked", say(unasked))
            let off = try await client.setAutoApprove(false, stored: stored)
            let asked = try await Self.danger(client, stored: stored)
            report(!off.autoApprove && asked.asked && asked.reply == "[kept]", "with it off again, the conversation asks", say(asked))
        } catch {
            report(false, "running commands without asking can be switched", String(error.localizedDescription.prefix(160)))
        }

        // Another conversation is not touched by the first one's switch.
        do {
            _ = try await client.setAutoApprove(true, stored: stored)
            let other = try await client.openSession(stored: nil).stored
            let asked = try await Self.danger(client, stored: other)
            report(asked.asked && asked.reply == "[kept]", "the switch is that conversation's alone: another one still asks", say(asked))
            _ = try await client.setAutoApprove(false, stored: stored)
        } catch {
            report(false, "the switch is that conversation's alone", String(error.localizedDescription.prefix(160)))
        }

        // Fast mode: the lab's model has none, so this is the refusal, and the way back.
        var refusal = ""
        do { _ = try await client.setFast(true, stored: stored) } catch { refusal = ChatControls.fastRefusal(error.localizedDescription) }
        report(refusal == "This model has no fast mode.", "fast mode on a model without one is refused, and said plainly", "it said \"\(refusal)\"")
        let normal = try? await client.setFast(false, stored: stored)
        report(normal?.fast == false, "and normal is accepted", "\(String(describing: normal))")

        // Move to a project: a folder that exists on the server (the simulator shares the Mac's disk).
        let folder = FileManager.default.temporaryDirectory.appending(path: "lab-project-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try await client.moveSession(stored: stored, toFolder: folder.path())
            let tree = try await client.projectTree()
            let project = tree.first { $0.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path() } == folder.standardizedFileURL.path() }
            report(project != nil && project?.isHome == false && (project?.sessionCount ?? 0) >= 1, "a conversation moved to a folder is in that project",
                   "projects: \(tree.map { "\($0.label)=\($0.sessionCount)" })")
            let row = try await client.listSessions(limit: 50).first { $0.id == stored }
            if row?.cwd == nil {
                print("  ----  this Dashboard's session list doesn't say which folder a session is in; the menu then offers every project")
            } else {
                report(row?.cwd.map { URL(fileURLWithPath: $0).standardizedFileURL.path() } == folder.standardizedFileURL.path(),
                       "and the list says which folder it is in now", row?.cwd ?? "")
            }
            let after = try? await client.chatControls(stored: stored)
            report(after?.approvalMode == "manual", "its switches are still readable after the move", "\(String(describing: after))")
        } catch {
            report(false, "a conversation moved to a folder is in that project", String(error.localizedDescription.prefix(160)))
        }
        var missing = ""
        do { try await client.moveSession(stored: stored, toFolder: "/no/such/folder") } catch { missing = error.localizedDescription }
        report(missing.contains("does not exist"), "a folder that isn't there is refused in Hermes's words", "it said \"\(missing)\"")
    }
}

/// Settings → Gateway against the same kind of lab (`scripts/hermes-lab/lab.sh admin`): the app's
/// own client and the screen's own model, asking an unmodified Hermes for its status, its MCP
/// servers and its logs, switching and testing a server, checking for an update without applying
/// one, and restarting the gateway. The lab runs its gateway by hand, with no service manager,
/// which is the case where Hermes's restart command never ends. Skips when no such lab is up.
struct HermesLabAdminTests {
    @Test func theGatewayScreenReadsAndRunsAnUnmodifiedHermes() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }
        guard let listed = try? await client.mcpServers(), listed.contains(where: { $0.name == "lab-notes" }) else {
            print("LAB SKIP: this lab has no MCP server to switch (scripts/hermes-lab/lab.sh up <tag> admin)")
            return
        }

        let model = GatewayModel(source: client)
        await model.load()
        let status = model.status ?? GatewayStatus()
        report(!status.version.isEmpty && status.gatewayRunning, "the status names the version and a running gateway",
               "version \"\(status.version)\", running \(status.gatewayRunning), \(model.problem ?? "")")
        report(status.platforms.contains { $0.id == "api_server" && $0.isConnected }, "the Hermes API is among its connections",
               "\(status.platforms.map { "\($0.id)=\($0.state)" })")
        report(model.host?.hostname.isEmpty == false, "the host has a name", "\(String(describing: model.host))")

        // An MCP server: off, switched on, tested, and off again.
        report(model.servers.first { $0.name == "lab-notes" }?.enabled == false, "an MCP server that is off is listed as off")
        if let server = model.servers.first(where: { $0.name == "lab-notes" }) {
            await model.setServer(server, enabled: true)
            report(model.servers.first { $0.name == "lab-notes" }?.enabled == true && model.problem == nil, "a switch turns it on in Hermes's config",
                   model.problem ?? "still off")
            await model.test(server)
            let probe = model.probes["lab-notes"]
            report(probe?.ok == true && probe?.tools == ["lab_echo"], "a test connects and lists its tools", probe?.summary ?? "no result")
            await model.setServer(server, enabled: false)
            report(model.servers.first { $0.name == "lab-notes" }?.enabled == false, "and off again")
        }
        var refused = ""
        do { try await client.setMCPServer("no such server", enabled: true) } catch { refused = error.localizedDescription }
        report(refused.contains("not found"), "a server that isn't there is refused in Hermes's words", "it said \"\(refused)\"")

        // Logs.
        let gatewayLog = (try? await client.gatewayLogs(.gateway, lines: 50, level: .all, search: "")) ?? []
        report(!gatewayLog.isEmpty && !gatewayLog.contains { $0.hasSuffix("\n") }, "the gateway's log comes as lines", "\(gatewayLog.count) lines")
        let none = try? await client.gatewayLogs(.agent, lines: 50, level: .all, search: "no-line-says-this-\(UUID().uuidString)")
        report(none?.isEmpty == true, "a search that matches nothing finds nothing", "\(none?.count ?? -1) lines")
        let errors = try? await client.gatewayLogs(.errors, lines: 20, level: .error, search: "")
        report(errors != nil, "the errors log and a level are accepted")

        // The update check answers; nothing is updated here.
        await model.checkForUpdate()
        report(model.update?.currentVersion == status.version, "the update check knows the running version",
               "it said \"\(model.update?.currentVersion ?? "nothing")\": \(model.outcome?.text ?? "")")

        // A restart, followed to its end.
        let before = status.startedAt
        await model.restart()
        if model.outcome?.ok == false, model.status?.gatewayRunning == false, model.progress.contains(where: { $0.contains("nothing to start") }) {
            // Hermes 0.21.5 and a gateway started by hand, as the lab's is: its restart command stops
            // the gateway, takes the one it stopped for a running one and starts nothing. What can be
            // checked is that the app says so, and how to get it back.
            print("  ----  this Hermes stops a gateway that was started by hand and doesn't start it again (0.21.5)")
            report(model.outcome?.text.contains("hermes gateway start") == true, "a gateway that didn't come back is reported, with the way to start it",
                   model.outcome?.text ?? "no outcome")
            return
        }
        report(model.outcome?.ok == true, "a restart is followed until the gateway is back", model.outcome?.text ?? "no outcome")
        report(model.status?.gatewayRunning == true && model.status?.startedAt != before, "and it is a new gateway that runs",
               "started \(before ?? "?") before, \(model.status?.startedAt ?? "?") now")
        var api = URLRequest(url: URL(string: "http://127.0.0.1:18642/health")!)
        api.timeoutInterval = 5
        var answered = false
        for _ in 0 ..< 20 where !answered {
            answered = ((try? await URLSession.shared.data(for: api))?.1 as? HTTPURLResponse)?.statusCode == 200
            if !answered { try? await Task.sleep(for: .milliseconds(500)) }
        }
        report(answered, "the Hermes API answers again")
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

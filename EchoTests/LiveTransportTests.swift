import Foundation
import Testing
import UIKit
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

    /// The same over the Hermes API. A turn there is a run (from 1.10), which asks on every
    /// release (`approval.request` in the run's events, answered at `/v1/runs/{run}/approval`);
    /// the chat stream asked only from 0.21.6. A release that doesn't ask is said, not failed.
    @Test func theHermesAPIAsksBeforeACommandRuns() async throws {
        let api = URL(string: "http://127.0.0.1:18642")!, key = "labkey-labkey-labkey"
        var probe = URLRequest(url: Self.dashboard.appending(path: "api/status"))
        probe.timeoutInterval = 2
        guard let (status, _) = try? await URLSession.shared.data(for: probe) else {
            print("LAB SKIP: no Hermes lab on 127.0.0.1:19119 (scripts/hermes-lab/lab.sh up <tag> approval)")
            return
        }
        let version = (try? JSONValue.parse(status))?["version"]?.string ?? ""
        let asksOnAPI = version.split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes([0, 21, 6]) == false
        let ledger = HermesSessionsAPI(baseURL: api, apiKey: key)
        let transport = HermesSessionsTransport(baseURL: api, apiKey: key)
        // As the app asks: the model by its full name, every turn.
        let choices = (try? await ledger.modelOptions()) ?? []
        let model = choices.first { $0.model == "alpha" }
        let provider = model.flatMap { Conversation.liveProvider(for: $0.model, saved: $0.provider, in: choices) }
        for (answer, expected) in [("once", "[gone]"), ("deny", "[kept]")] {
            var detail = ""
            var ok = false
            var asked: ApprovalRequest?
            do {
                let session = try await ledger.createSession(title: "lab api approval \(UUID().uuidString.prefix(8))", model: model?.model, provider: provider)
                let request = TurnRequest(userText: "Do the danger thing.", history: [], sessionID: session.id, model: model?.model, provider: provider, instructions: nil)
                let outcome = try await Self.timed {
                    var outcome = Outcome()
                    for try await event in transport.stream(request) {
                        switch event {
                        case let .textDelta(delta): outcome.reply += delta
                        case let .textFinal(text): outcome.reply = text
                        case let .interrupt(.approval(approval), run):
                            outcome.asked = approval
                            try await ledger.respondApproval(runID: run, requestID: approval.id, choice: answer)
                        default: break
                        }
                    }
                    outcome.reply = outcome.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    return outcome
                }
                asked = outcome.asked
                ok = outcome.asked?.command.contains("rm -rf") == true && outcome.reply == expected
                detail = "asked \(outcome.asked?.command ?? "nothing") \(outcome.asked?.choices ?? []), reply \(outcome.reply.prefix(120))"
            } catch {
                detail = String(error.localizedDescription.prefix(160))
            }
            if asked == nil, !asksOnAPI {
                print("  ----  Hermes \(version) doesn't ask over the Hermes API (stock asks from 0.21.6): \(detail)")
                return
            }
            Self.report(ok, "Hermes API: a command the agent wants to run is asked about; \"\(answer)\" \(expected == "[gone]" ? "runs it" : "stops it")", detail)
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

/// Leaving a conversation while the agent works in it, for another one (GitHub issue 12), against
/// the lab's `approval` scenario (`scripts/hermes-lab/lab.sh switch`), whose stub answers
/// "lab:slow" after eight seconds. Left, the turn goes on on the host, and coming back finds it:
/// joined on the Dashboard, waited for on the Hermes API. Stopped, it stops. Skips when that lab
/// isn't up.
struct HermesLabSwitchTests {
    private static let api = URL(string: "http://127.0.0.1:18642")!
    private static let key = "labkey-labkey-labkey"
    private static let slow = "lab:slow, please"
    private static let done = "[slow done]"

    private static func conversation(_ settings: Settings, _ transport: any HermesTransport) -> Conversation {
        Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-switch-\(UUID().uuidString)")),
                     transportOverride: transport)
    }

    private static func settings() -> Settings {
        Settings(defaults: UserDefaults(suiteName: "lab-switch-\(UUID().uuidString)")!)
    }

    /// Asks the slow question and gives the host a moment to have it under way.
    private static func askSlowly(_ conversation: Conversation) async throws {
        _ = conversation.send(slow)
        try await Task.sleep(for: .seconds(2))
    }

    /// The last reply the Dashboard's host has recorded for a session, after `wait`.
    private static func recorded(_ client: HermesServeClient, stored: String) async throws -> String {
        let messages = Conversation.messages(fromServeRows: try await client.history(stored: stored))
        return messages.last { $0.role == .assistant }?.text ?? ""
    }

    @Test func aTurnLeftOnTheDashboardGoesOnAndIsJoinedOnReturn() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        let settings = Self.settings()
        settings.transport = .hermesServe

        // Left: another conversation is started while the agent works.
        let left = Self.conversation(settings, HermesServeTransport(client: client))
        try await Self.askSlowly(left)
        if let stored = left.serverSessionID {
            left.reset()
            var heard = ""
            let joined = try await HermesServeTransport(client: client).rejoin(stored: stored)
            if let joined { for try await event in joined.events { if case let .textDelta(text) = event { heard += text } } }
            HermesLabApprovalTests.report(joined != nil && heard.contains(Self.done),
                                          "Dashboard: a turn left for another conversation goes on, and is joined on return",
                                          "joined: \(joined != nil), heard: \(heard)")
        } else {
            HermesLabApprovalTests.report(false, "Dashboard: a turn left for another conversation goes on", "the conversation got no session")
        }

        // Stopped: the agent is told to stop, and records no reply.
        let stopped = Self.conversation(settings, HermesServeTransport(client: client))
        try await Self.askSlowly(stopped)
        if let stored = stopped.serverSessionID {
            stopped.cancel()
            try await Task.sleep(for: .seconds(10))
            let reply = try await Self.recorded(client, stored: stored)
            HermesLabApprovalTests.report(!reply.contains(Self.done), "Dashboard: a turn stopped with Stop is stopped on the host", "recorded: \(reply)")
        }
    }

    @Test func aTurnLeftOnTheHermesAPIIsWaitedForOnReturn() async throws {
        var probe = URLRequest(url: Self.api.appending(path: "health"))
        probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            print("LAB SKIP: no Hermes lab on 127.0.0.1:18642 (scripts/hermes-lab/lab.sh up <tag> approval)")
            return
        }
        let settings = Self.settings()
        settings.transport = .hermesSessions
        settings.gatewayURL = Self.api.absoluteString
        // The key where the app keeps it, for the server it is on now; what was there goes back.
        let account = Keychain.account(.gatewayAPIKey)
        let before = Keychain.read(account: account)
        Keychain.write(account: account, value: Self.key)
        defer { if let before { Keychain.write(account: account, value: before) } else { Keychain.delete(account: account) } }

        let conversation = Self.conversation(settings, HermesSessionsTransport(baseURL: Self.api, apiKey: Self.key))
        try await Self.askSlowly(conversation)
        guard let stored = conversation.serverSessionID else {
            HermesLabApprovalTests.report(false, "Hermes API: a turn left for another conversation is waited for", "the conversation got no session")
            return
        }
        conversation.reset()
        try await conversation.open(serverSession: stored)
        let waiting = conversation.statusLine
        for _ in 0 ..< 50 where !(conversation.messages.last?.text.contains(Self.done) ?? false) {
            try await Task.sleep(for: .milliseconds(500))
        }
        let reply = conversation.messages.last?.text ?? ""
        HermesLabApprovalTests.report(waiting != nil && reply.contains(Self.done) && conversation.statusLine == nil,
                                      "Hermes API: a turn left for another conversation is waited for on return, and its reply shown",
                                      "status on return: \(waiting ?? "none"), reply: \(reply), status after: \(conversation.statusLine ?? "none")")
    }
}

/// Installing the notification plugin through the Dashboard, against the lab
/// (`scripts/hermes-lab/lab.sh plugin`, the `approval` scenario, which has a Dashboard login and
/// no plugin): Hermes fetches the plugin from this repository on GitHub, so the machine has to
/// reach it, and what is installed is what is published there. Skips when no such lab is up.
struct HermesLabPluginTests {
    @Test func thePluginIsInstalledFromThePhone() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }
        let command = PushService.command(over: client)
        func loaded() async -> Bool { (try? await command("offer"))?.hasPrefix("redde-push offer ") == true }

        let before = try await client.pushPlugin()
        report(before == PushPlugin.State(), "a Hermes without the plugin says so", "\(before)")
        report(!(await loaded()), "and its Dashboard has no such command")

        // Hermes allows its clone a minute; the first fetch of a repository can take longer.
        var outcome: PushPlugin.Outcome?
        var said = ""
        for _ in 1 ... 3 where outcome == nil {
            do { outcome = try await client.installPushPlugin(replacing: false) } catch {
                said = PushPlugin.explain(error)
                guard said.contains("try again") else { break }
                print("  ----  the download timed out on Hermes's side; trying again")
            }
        }
        report(outcome != nil, "Hermes installs it when the phone asks", outcome.map { "\($0)" } ?? said)
        guard let outcome else { return }

        let after = try await client.pushPlugin()
        report(after.installed && after.enabled && after.version == PushPlugin.version && !after.isOutdated,
               "it is listed, switched on, at the version this app goes with", "\(after)")

        let live = await loaded()
        switch outcome {
        case .running:
            report(live, "Hermes loaded it then and there: the plugin answers, and pairing can go ahead")
        case .needsRestart:
            print("  ----  this Hermes loads a new plugin only when it starts (0.21.0 and 0.21.3): the app says to restart it")
            report(!live, "until that restart the plugin doesn't answer, as the app says")
        }

        // Asked again without replacing, Hermes refuses; asked to replace, it fetches it anew.
        do {
            _ = try await client.installPushPlugin(replacing: false)
            report(false, "a second install is refused", "it went through")
        } catch {
            report(PushPlugin.explain(error).contains("already exists"), "a second install is refused", PushPlugin.explain(error))
        }
        var again: PushPlugin.Outcome?
        for _ in 1 ... 3 where again == nil { again = try? await client.installPushPlugin(replacing: true) }
        report(again == outcome, "an update fetches it again and ends the same way", "\(String(describing: again))")
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

    /// Files a reply names (`MEDIA:` tags) fetched as a chat fetches them: by their full path,
    /// from `~/`, and relative to the chat's own folder (the session goes with the path; Hermes
    /// 0.21.0 doesn't take it), whole for the chat and by download for a tap.
    @Test func theFilesAReplyNamesAreFetched() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }
        let version = (try? await client.restJSON("GET", "api/status"))?["version"]?.string ?? ""
        let home = try await client.folder(at: nil)
        let labs = ServerFiles.join(home.path, ".cache/redde-hermes-lab")
        let scratch = try await client.makeFolder("media-\(UUID().uuidString.prefix(8))", in: labs)
        guard scratch.path.contains("/redde-hermes-lab/media-") else { return }
        let words = Data("# Brief\n\n- one thing\n".utf8)
        let up = try await client.upload(try local("brief.md", words), as: "My brief.md", into: scratch.path, replacing: false, watch: nil)
        func whole(_ path: String, _ source: FileSource? = nil) async -> Data? {
            guard let url = try? await client.readDataURL(path: path, in: source) else { return nil }
            return ServeMedia.attachment(dataURL: url, name: "My brief.md")?.data
        }

        report(await whole(up.path) == words, "a file named by its full path comes whole", up.path)
        let down = try? await client.downloadDelivered(path: up.path, in: nil)
        report(down.flatMap { try? Data(contentsOf: $0) } == words, "and comes down whole on a tap")
        let fromHome = "~/" + up.path.dropFirst(home.path.count + 1)
        report(await whole(fromHome) == words, "one named from ~/ comes too", fromHome)
        // A chat in that folder with a turn in it, as any chat whose reply names a file is: Hermes
        // keeps a session's row (and its folder) from its first message, not from its making.
        var stored = ""
        var request = TurnRequest(userText: "Hello.", history: [], sessionID: nil, model: nil, instructions: nil)
        request.folder = scratch.path
        for try await event in HermesServeTransport(client: client).stream(request) {
            if case let .sessionID(id) = event { stored = id }
        }
        let relative = await whole("My brief.md", FileSource(sessionID: stored, profile: nil))
        if version.hasPrefix("0.21.0") {
            print("  ----  a path relative to the chat's folder: Hermes \(version) takes no session, \(relative == words ? "found anyway" : "not found")")
        } else {
            report(relative == words, "one named relative to the chat's folder is found there", "session \(stored)")
            let tapped = try? await client.downloadDelivered(path: "My brief.md", in: FileSource(sessionID: stored, profile: nil))
            report(tapped.flatMap { try? Data(contentsOf: $0) } == words, "and comes down on a tap")
        }
        let missing = try? await client.readDataURL(path: ServerFiles.join(scratch.path, "gone.md"))
        report(missing == .some(nil), "a file that isn't there is nothing, not an error")
        do {
            _ = try await client.downloadDelivered(path: ServerFiles.join(scratch.path, "gone.md"), in: nil)
            report(false, "a missing file's download says it isn't there", "it went through")
        } catch TransportError.http(let status, _) {
            report(status == 404, "a missing file's download says it isn't there", "\(status)")
        }
        try? await client.delete(scratch)
    }

    /// A page the agent made (`::preview`) is read as a chat reads it, and what the page sends
    /// reaches the agent with no message of the person's for it, then or when the chat is opened
    /// again: hidden on the Dashboard, marked and left out on the Hermes API.
    @Test func aPageTalksBackUnseen() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }
        let home = try await client.folder(at: nil)
        let labs = ServerFiles.join(home.path, ".cache/redde-hermes-lab")
        let scratch = try await client.makeFolder("page-\(UUID().uuidString.prefix(8))", in: labs)
        guard scratch.path.contains("/redde-hermes-lab/page-") else { return }
        defer { Task { try? await client.delete(scratch) } }
        let html = Data("<!doctype html><button data-hermes-send=\"Show Porto instead\">Porto</button>".utf8)
        let page = try await client.upload(try local("rain.html", html), as: "rain.html", into: scratch.path, replacing: false, watch: nil)
        let reply = "Here's the rain.\n\n::preview{file=\"\(page.path)\"}"
        let found = ServeMedia.candidates(in: reply)
        report(found.count == 1 && found.first?.isPage == true && found.first?.path == page.path, "a reply's ::preview names its page", "\(found)")
        let fetched = try? await client.readDataURL(path: page.path)
        report(fetched.flatMap { ServeMedia.attachment(dataURL: $0, name: "rain.html") }?.data == html, "the page comes whole")

        // Dashboard: a chat with a turn in it, then the page's message.
        var stored = ""
        var request = TurnRequest(userText: "Hello.", history: [], sessionID: nil, model: nil, instructions: nil)
        request.folder = scratch.path
        for try await event in HermesServeTransport(client: client).stream(request) {
            if case let .sessionID(id) = event { stored = id }
        }
        var fromPage = TurnRequest(userText: "Show Porto instead", history: [], sessionID: stored, model: nil, instructions: nil)
        fromPage.fromPage = true
        var answered = ""
        for try await event in HermesServeTransport(client: client).stream(fromPage) {
            if case let .textDelta(delta) = event { answered += delta }
            if case let .textFinal(text) = event { answered = text }
        }
        report(!answered.isEmpty, "Dashboard: the agent answers what the page sent", String(answered.prefix(60)))
        // The host never hands a hidden message back to the Dashboard; what it keeps is checked below,
        // through the Hermes API, which reads the same store.
        let reread = Conversation.messages(fromServeRows: try await client.history(stored: stored))
        report(!reread.contains { $0.role == .user && $0.text.contains("Show Porto instead") } && reread.filter { $0.role == .assistant }.count == 2,
               "Dashboard, reopened: no message for it, and both replies", reread.map { "\($0.role.rawValue): \($0.text.prefix(24))" }.joined(separator: " | "))

        // The Hermes API.
        let api = URL(string: "http://127.0.0.1:18642")!, key = "labkey-labkey-labkey"
        var probe = URLRequest(url: api.appending(path: "health"))
        probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            print("  ----  no Hermes API on 127.0.0.1:18642; only the Dashboard was checked")
            return
        }
        let ledger = HermesSessionsAPI(baseURL: api, apiKey: key)
        let transport = HermesSessionsTransport(baseURL: api, apiKey: key)
        let kept = try? await ledger.messages(sessionID: stored)
        let row = kept?.first { $0.role == "user" && $0.content?.text.contains("Show Porto instead") == true }
        report(row?.display_kind == "hidden", "Dashboard: the host keeps it, as a hidden message", row.map { "\($0.display_kind ?? "no kind")" } ?? "no row")
        // The lab's own stub model, by its full name, as the app asks every turn.
        let choices = (try? await ledger.modelOptions()) ?? []
        let model = choices.first { $0.model == "alpha" }
        let provider = model.flatMap { Conversation.liveProvider(for: $0.model, saved: $0.provider, in: choices) }
        let session = try await ledger.createSession(title: "lab page \(UUID().uuidString.prefix(8))", model: model?.model, provider: provider)
        for text in ["Hello.", "Show Porto instead"] {
            var turn = TurnRequest(userText: text, history: [], sessionID: session.id, model: model?.model, provider: provider, instructions: nil)
            turn.fromPage = text != "Hello."
            for try await _ in transport.stream(turn) {}
        }
        let rows = try await ledger.messages(sessionID: session.id)
        report(rows.contains { $0.role == "user" && $0.content?.text == PageTurn.marker + "Show Porto instead" },
               "Hermes API: the agent is told the page sent it", rows.filter { $0.role == "user" }.map { $0.content?.text ?? "" }.joined(separator: " | "))
        let mapped = Conversation.mapStored(rows)
        report(!mapped.contains { $0.role == .user && $0.text.contains("Show Porto instead") } && mapped.filter { $0.role == .assistant }.count == 2,
               "Hermes API, reopened: no message for it, and both replies", mapped.map { "\($0.role.rawValue): \($0.text.prefix(24))" }.joined(separator: " | "))
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

/// Settings' context and memory files against the lab (`scripts/hermes-lab/lab.sh context`), where
/// Hermes's home is a folder of the lab's own and not `~/.hermes`, as in Docker (GitHub issue 15):
/// the files are found where the server says, SOUL.md through its own route. `lab.sh context`
/// puts a SOUL.md and a MEMORY.md there first. Nothing is written outside the lab's run folder.
struct HermesLabContextFilesTests {
    @Test func contextFilesAreFoundWhereHermesKeepsThem() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-context-\(UUID().uuidString)")!)

        let home = await client.profileHome()
        report(home?.contains("/redde-hermes-lab/run-") == true && home != "~/.hermes", "the Dashboard says where the profile keeps its files",
               home ?? "it didn't say")
        // Never write anywhere but the lab's own run folder.
        guard let home, home.contains("/redde-hermes-lab/run-") else { return }

        let memory = settings.profileFilePath("memories/MEMORY.md", home: home)
        let found = try? await client.readText(path: memory)
        report(found == "Lab memory for issue 15.\n", "MEMORY.md is found there", "\(memory): \(found ?? "nothing")")
        // With a home of the lab's own, the old guess looks in an empty folder, as on a Docker host.
        if (try? await client.folder(at: nil))?.path.contains("/redde-hermes-lab/run-") == true {
            let guessed = try? await client.readText(path: settings.profileFilePath("memories/MEMORY.md"))
            report(guessed == nil, "the old guess, ~/.hermes, finds nothing (what issue 15 saw)", guessed ?? "")
        }

        do {
            let soul = try await client.soul(profile: ProfileCatalog.defaultID)
            report(soul == "Lab soul for issue 15.\n", "SOUL.md reads through its own route", soul ?? "none")
            try await client.setSoul(profile: ProfileCatalog.defaultID, content: "Changed on the phone.\n")
            let landed = try await client.readText(path: settings.profileFilePath("SOUL.md", home: home))
            report(landed == "Changed on the phone.\n", "SOUL.md saved through its route lands in that home", landed ?? "nothing")
        } catch {
            report(false, "SOUL.md through its own route", String(error.localizedDescription.prefix(160)))
        }

        do {
            let user = settings.profileFilePath("memories/USER.md", home: home)
            report(try await client.readText(path: user) == nil, "a file not made yet reads as missing", user)
            try await client.writeText(path: user, content: "Likes short answers.\n")
            report(try await client.readText(path: user) == "Likes short answers.\n", "USER.md saved lands there")
        } catch {
            report(false, "USER.md saved", String(error.localizedDescription.prefix(160)))
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

/// Projects as the app makes them, against the lab (`scripts/hermes-lab/lab.sh projects`, the
/// `approval` scenario, with a home folder of the lab's own, so `~/Projects` is the lab's): the
/// app's client on an unmodified Hermes makes a project and its folder, starts a conversation in
/// it, moves the conversation to a second one made for it, renames that one and removes it. The
/// header's project name is checked through the store it reads. Skips when no such lab is up.
struct HermesLabProjectsTests {
    @Test func projectsMadeInTheAppWorkOnAnUnmodifiedHermes() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }
        func named(_ stored: String) async -> String? {
            _ = try? await client.chatControls(stored: stored)
            return ChatControlStore.shared.project(for: stored)?.name
        }

        // `lab.sh projects` gives Hermes a home of the lab's own. A lab started some other way has
        // the real one, and then the projects go in a scratch folder instead of ~/Projects.
        let home = try await client.folder(at: nil)
        let ownHome = home.path.contains("/redde-hermes-lab/run-")
        let root: String? = ownHome ? nil : ServerFiles.join(home.path, ".cache/redde-hermes-lab/projects-\(UUID().uuidString.prefix(8))")
        if let root { print("  ----  this lab has the real home folder; the projects go in \(root)") }
        let parent = root ?? ServerFiles.join(home.path, "Projects")
        let name = "Lab Garden \(UUID().uuidString.prefix(4))"

        let first: ProjectPlace
        do {
            first = try await client.createProject(named: name, under: root)
            report(first.name == name && first.path == ServerFiles.join(parent, name), "a project is made, its folder in ~/Projects", first.path)
        } catch {
            report(false, "a project is made", String(error.localizedDescription.prefix(160)))
            return
        }
        report((try? await client.folder(at: first.path)) != nil, "its folder is there on the server", first.path)
        let before = try await client.projectTree()
        let listed = HermesServeClient.Project.listed(before).first { $0.path == first.path }
        report(listed?.isOwn == true && listed?.label == name && listed?.sessionCount == 0, "the list shows it before its first conversation",
               "\(before.map { "\($0.label)=\($0.sessionCount) auto \($0.isAuto)" })")
        let firstID = listed?.id ?? ""
        do {
            let opened = try await client.projectSessions(firstID)
            report(opened != nil && opened?.lanes.allSatisfy(\.sessions.isEmpty) == true, "opened, it has no conversations yet, and no error",
                   "\(String(describing: opened?.lanes.map(\.sessions.count)))")
        } catch {
            report(false, "opened, it has no conversations yet, and no error", String(error.localizedDescription.prefix(160)))
        }

        // A conversation started in it.
        var stored = ""
        do {
            var reply = ""
            var request = TurnRequest(userText: "Hello from the garden.", history: [], sessionID: nil, model: nil, instructions: nil)
            request.folder = first.path
            for try await event in HermesServeTransport(client: client).stream(request) {
                switch event {
                case let .sessionID(id): stored = id
                case let .textDelta(delta): reply += delta
                case let .textFinal(text): reply = text
                default: break
                }
            }
            report(!stored.isEmpty && !reply.isEmpty, "a conversation starts in it and is answered", reply)
        } catch {
            report(false, "a conversation starts in it and is answered", String(error.localizedDescription.prefix(160)))
            return
        }
        let inside = try await client.projectTree().first { $0.id == firstID }
        report((inside?.sessionCount ?? 0) == 1, "the conversation is in the project", "\(inside?.sessionCount ?? -1) conversations")
        let rows = (try? await client.projectSessions(firstID))?.lanes.flatMap(\.sessions).map(\.id) ?? []
        report(rows == [stored], "and on the project's screen", "\(rows)")
        let header = await named(stored)
        report(header == name, "the header names the project", header ?? "nothing")
        if let cwd = try await client.listSessions(limit: 50).first(where: { $0.id == stored })?.cwd {
            report(cwd == first.path, "the conversation works in the project's folder", cwd)
        }

        // The same name again: that folder is a project's already.
        var again = ""
        do { _ = try await client.createProject(named: name, under: root) } catch { again = error.localizedDescription }
        report(again.contains("already a project's folder"), "a second project over the same folder is refused, in words", again)

        // Moved to a project made for it from its menu.
        let second: ProjectPlace
        do {
            second = try await client.createProject(named: name + " Two", under: root)
            try await client.moveSession(stored: stored, toFolder: second.path)
        } catch {
            report(false, "a conversation moves to a new project", String(error.localizedDescription.prefix(160)))
            return
        }
        let moved = try await client.projectTree()
        let secondID = moved.first { $0.path == second.path }?.id ?? ""
        report(moved.first { $0.id == secondID }?.sessionCount == 1 && moved.first { $0.id == firstID }?.sessionCount == 0,
               "a conversation moves to a new project", "\(moved.map { "\($0.label)=\($0.sessionCount)" })")
        let movedHeader = await named(stored)
        report(movedHeader == second.name, "and the header names that one", movedHeader ?? "nothing")

        // Renamed: the folder keeps its name; the list and the header take the new one.
        do {
            try await client.renameProject(secondID, to: name + " Renamed")
            let renamed = try await client.projectTree().first { $0.id == secondID }
            report(renamed?.label == name + " Renamed" && renamed?.path == second.path, "a project is renamed, its folder kept",
                   "\(renamed?.label ?? "gone") at \(renamed?.path ?? "")")
            let renamedHeader = await named(stored)
            report(renamedHeader == name + " Renamed", "and the header has the new name", renamedHeader ?? "nothing")
        } catch {
            report(false, "a project is renamed", String(error.localizedDescription.prefix(160)))
        }

        // Removed: off the list; its folder and its conversation stay, in no project now.
        do {
            try await client.removeProject(secondID)
            let after = try await client.projectTree()
            report(!after.contains { $0.id == secondID }, "a project is removed from the list", "\(after.map(\.label))")
            report((try? await client.folder(at: second.path)) != nil, "its folder stays")
            report(try await client.listSessions(limit: 50).contains { $0.id == stored }, "and so does its conversation")
            let none = await named(stored)
            report(ChatControlStore.shared.project(for: stored) != nil && none == nil, "which the header shows in no project", none ?? "none")
        } catch {
            report(false, "a project is removed", String(error.localizedDescription.prefix(160)))
        }
        try? await client.removeProject(firstID)
    }
}

/// Searching inside messages against an unmodified Hermes (`scripts/hermes-lab/lab.sh search`): a
/// word said in a Dashboard conversation and one said over the Hermes API are both found through
/// the Dashboard's search, whole and by their first letters, with the word marked in the snippet.
/// Skips when no such lab is up.
struct HermesLabSearchTests {
    @Test func wordsSaidAnywhereAreFound() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }
        // Letters only: one word to Hermes's full-text index, and nobody's said it before.
        func madeUpWord() -> String { "zeph" + String(UUID().uuidString.lowercased().filter(\.isLetter).prefix(6)) }
        func found(_ query: String, _ id: String, word: String) async -> (Bool, String) {
            do {
                let hits = try await client.searchMessages(query)
                let hit = hits.first { $0.id == id }
                let marked = hit?.runs.contains { $0.matched && $0.text.lowercased() == word } == true
                return (hit != nil && marked, "\(hits.count) hits; ours: \(hit.map { "\($0.snippet.prefix(90))" } ?? "none")")
            } catch {
                return (false, String(error.localizedDescription.prefix(160)))
            }
        }

        // Said in a Dashboard conversation.
        let word = madeUpWord()
        var stored = ""
        do {
            let request = TurnRequest(userText: "Please remember the word \(word) for me.", history: [], sessionID: nil, model: nil, instructions: nil)
            for try await event in HermesServeTransport(client: client).stream(request) {
                if case let .sessionID(id) = event { stored = id }
            }
        } catch {
            report(false, "a Dashboard conversation to search", String(error.localizedDescription.prefix(160)))
            return
        }
        let (whole, wholeDetail) = await found(word, stored, word: word)
        report(whole, "a word said in a Dashboard conversation is found, marked in the snippet", wholeDetail)
        let (prefix, prefixDetail) = await found(String(word.prefix(7)), stored, word: word)
        report(prefix, "and by its first letters", prefixDetail)

        // Said over the Hermes API: the same server, so the same search finds it.
        let api = URL(string: "http://127.0.0.1:18642")!, key = "labkey-labkey-labkey"
        let ledger = HermesSessionsAPI(baseURL: api, apiKey: key)
        let choices = (try? await ledger.modelOptions()) ?? []
        let model = choices.first { $0.model == "alpha" }
        let provider = model.flatMap { Conversation.liveProvider(for: $0.model, saved: $0.provider, in: choices) }
        let apiWord = madeUpWord()
        var apiSession = ""
        do {
            let session = try await ledger.createSession(title: "lab search \(UUID().uuidString.prefix(8))", model: model?.model, provider: provider)
            apiSession = session.id
            let request = TurnRequest(userText: "Note \(apiWord) down.", history: [], sessionID: session.id, model: model?.model, provider: provider, instructions: nil)
            for try await _ in HermesSessionsTransport(baseURL: api, apiKey: key).stream(request) {}
        } catch {
            report(false, "a Hermes API conversation to search", String(error.localizedDescription.prefix(160)))
            return
        }
        let (overAPI, apiDetail) = await found(apiWord, apiSession, word: apiWord)
        report(overAPI, "a word said over the Hermes API is found too", apiDetail)

        // A word nobody said.
        let none = (try? await client.searchMessages(madeUpWord() + "q")) ?? [MessageSearchHit(session: .init(id: "error"), snippet: "")]
        report(none.isEmpty, "a word nobody said finds nothing", "\(none.map(\.id))")
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

/// The app's own side of phone tools against the plugin in an unmodified Hermes
/// (`scripts/hermes-lab/lab.sh device --app`): the app's Dashboard client carries the plugin's
/// command, its service fetches the request and hands back the answer, and its files tool does
/// the work, in a folder of the test's own. The turn runs over the Hermes API, so the agent's
/// call waits in the gateway's process while the app talks to the Dashboard's. Skips when that
/// lab isn't up.
struct HermesLabDeviceTests {
    private static let base = URL(string: "http://127.0.0.1:18642")!
    private static let key = "labkey-labkey-labkey"

    @MainActor final class Asked { var count = 0 }

    @Test func theAppCarriesOutAPhoneToolTheAgentCalls() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        let plugin = PushService.command(over: client)
        do {
            guard try await plugin("device status").hasPrefix("redde-push device status") else {
                print("LAB SKIP: this lab's plugin has no phone tools")
                return
            }
        } catch {
            print("LAB SKIP: this lab's Hermes has no push plugin (scripts/hermes-lab/lab.sh up <tag> push)")
            return
        }
        let defaults = UserDefaults(suiteName: "lab-device-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.phoneTools.on = true
        settings.phoneTools.set(.files, .allow)
        let folder = FileManager.default.temporaryDirectory.appending(path: "lab-device-\(UUID().uuidString)")
        let runner = DeviceToolRunner(files: DeviceFiles(root: folder))
        let asked = Asked()
        let service = DeviceToolsService(settings: settings, defaults: defaults, command: plugin,
                                         run: { try await runner.run($0, $1, info: $2) },
                                         ask: { _ in asked.count += 1; return .allow }, onScreen: { true })

        let open = await service.publish()
        HermesLabApprovalTests.report(open == [.files], "the app tells the plugin which areas are on", "\(String(describing: open))")
        try await Task.sleep(for: .seconds(5))   // each Hermes process hears of it within a couple of seconds

        var reply = "", tools: [String] = [], detail = ""
        do {
            let session = try await HermesSessionsAPI(baseURL: Self.base, apiKey: Self.key).createSession(title: "device lab app \(Date.now.timeIntervalSince1970)")
            let transport = HermesSessionsTransport(baseURL: Self.base, apiKey: Self.key)
            let request = TurnRequest(userText: "lab:note please", history: [], sessionID: session.id, model: nil, instructions: nil)
            for try await event in transport.stream(request) {
                switch event {
                case let .toolStarted(name, _, _):
                    tools.append(name)
                    service.toolStarted(name)   // what Conversation does with a turn it follows
                case let .textDelta(delta): reply += delta
                case let .textFinal(final): reply = final
                default: break
                }
            }
        } catch {
            detail = String(error.localizedDescription.prefix(200))
        }
        let saved = try? String(contentsOf: folder.appending(path: "lab/note.txt"), encoding: .utf8)
        HermesLabApprovalTests.report(tools.contains("phone_files_write"), "the turn shows the phone tool starting, by its own name", "\(tools) \(detail)")
        HermesLabApprovalTests.report(saved == "from the agent", "the app does what was asked, on the phone", "\(String(describing: saved))")
        HermesLabApprovalTests.report(asked.count == 1, "after asking the person, since it is a change", "asked \(asked.count) times")
        HermesLabApprovalTests.report(reply.contains("[phone: saved]"), "and the agent is told it was done", "\(reply) \(detail)")
        HermesLabApprovalTests.report(service.log.first?.outcome == .done && service.log.first?.title == "Save a file to Redde's folder",
                                      "the phone's list of what was asked for has it", "\(service.log)")

        settings.phoneTools.on = false
        let shut = await service.publish()
        HermesLabApprovalTests.report(shut == [], "turned off, the plugin is told so", "\(String(describing: shut))")
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The chat list's marks against the lab (`scripts/hermes-lab/lab.sh status`, the `approval`
/// scenario): `ChatActivity` with the app's own clients on both connections, a conversation left
/// while its turn goes on, then its reply, and one whose agent asks a question. Skips when no lab
/// is up.
@MainActor
struct HermesLabStatusTests {
    private static let api = URL(string: "http://127.0.0.1:18642")!
    private static let key = "labkey-labkey-labkey"
    private static let slow = "lab:slow, please"

    private static func setup(_ transport: Transport) -> (Settings, ChatActivity) {
        let defaults = UserDefaults(suiteName: "lab-status-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.transport = transport
        return (settings, ChatActivity(defaults: defaults))
    }

    private static func conversation(_ settings: Settings, _ transport: any HermesTransport) -> Conversation {
        Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-status-\(UUID().uuidString)")),
                     transportOverride: transport)
    }

    /// Looks every second until the mark is `want`, or `seconds` pass; the last one seen.
    private static func until(_ want: ChatActivity.Kind?, of stored: String, _ activity: ChatActivity, open: Conversation,
                              _ settings: Settings, dashboard: HermesServeClient? = nil, seconds: Int = 30) async throws -> ChatActivity.Kind? {
        var kind: ChatActivity.Kind?
        for _ in 0 ..< seconds {
            if let dashboard { await activity.look(open, settings: settings, dashboard: dashboard) } else { await activity.look(open, settings: settings) }
            kind = activity.kind(of: stored, open: open, settings: settings)
            if kind == want { break }
            try await Task.sleep(for: .seconds(1))
        }
        return kind
    }

    @Test func theDashboardSaysWhatIsUnderWayAndUnread() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, "Dashboard: \(what)", detail) }
        let (settings, activity) = Self.setup(.hermesServe)

        let left = Self.conversation(settings, HermesServeTransport(client: client))
        _ = left.send(Self.slow)
        try await Task.sleep(for: .seconds(2))
        guard let stored = left.serverSessionID else { report(false, "a conversation left mid-turn", "it got no session"); return }
        left.reset()   // another conversation started: the turn goes on
        try await client.updateSession(stored: stored, unread: false)   // what leaving it marks, for the app's own
        await activity.look(left, settings: settings, dashboard: client)
        let during = activity.kind(of: stored, open: left, settings: settings)
        report(during == .working, "a conversation left mid-turn is working", "\(String(describing: during))")
        let after = try await Self.until(nil, of: stored, activity, open: left, settings, dashboard: client)
        report(after == nil, "and not once its turn is over", "\(String(describing: after))")
        let row = try await client.listSessions().first { $0.id == stored }
        report(row.map { activity.isUnread($0, open: left, settings: settings) } == true, "and its reply is unread",
               "row unread: \(String(describing: row?.unread))")

        let asking = Self.conversation(settings, HermesServeTransport(client: client))
        _ = asking.send("lab:question")
        try await Task.sleep(for: .seconds(2))
        if let waiting = asking.serverSessionID {
            // Seen from the list, not as the open conversation, which says for itself.
            let kind = try await Self.until(.needsYou, of: waiting, activity, open: left, settings, dashboard: client, seconds: 20)
            report(kind == .needsYou, "one whose agent asks a question needs you", "\(String(describing: kind))")
        } else {
            report(false, "one whose agent asks a question needs you", "it got no session")
        }
        asking.cancel()
    }

    @Test func theHermesAPIsLeftTurnIsAskedAfterByItsRun() async throws {
        var probe = URLRequest(url: Self.api.appending(path: "health"))
        probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            print("LAB SKIP: no Hermes lab on 127.0.0.1:18642 (scripts/hermes-lab/lab.sh up <tag> approval)")
            return
        }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, "Hermes API: \(what)", detail) }
        let (settings, activity) = Self.setup(.hermesSessions)
        settings.gatewayURL = Self.api.absoluteString
        // The key where the app keeps it, for the server it is on now; what was there goes back.
        let account = Keychain.account(.gatewayAPIKey)
        let before = Keychain.read(account: account)
        Keychain.write(account: account, value: Self.key)
        defer { if let before { Keychain.write(account: account, value: before) } else { Keychain.delete(account: account) } }

        let left = Self.conversation(settings, HermesSessionsTransport(baseURL: Self.api, apiKey: Self.key))
        _ = left.send(Self.slow)
        try await Task.sleep(for: .seconds(2))
        guard let stored = left.serverSessionID, let run = left.currentRunID else {
            report(false, "a conversation left mid-turn", "session \(String(describing: left.serverSessionID)), run \(String(describing: left.currentRunID))")
            return
        }
        activity.noteLeft(sessionID: stored, runID: run, settings: settings)   // what leaving it notes, for the app's own
        left.reset()
        await activity.look(left, settings: settings)
        let during = activity.kind(of: stored, open: left, settings: settings)
        report(during == .working, "a conversation left mid-turn is working, by its run", "\(String(describing: during))")
        let after = try await Self.until(nil, of: stored, activity, open: left, settings)
        report(after == nil, "and not once its run is over", "\(String(describing: after))")
        let api = HermesSessionsAPI(baseURL: Self.api, apiKey: Self.key)
        let row = try await api.listSessions().first { $0.id == stored }
        report(row.map { activity.isUnread($0, open: left, settings: settings) } == true, "and its reply is unread")
        do {
            try await api.updateSession(id: stored, unread: false)
            report(true, "the read mark is taken")
        } catch {
            report(false, "the read mark is taken", error.localizedDescription)
        }
    }
}

/// Bots with the app's own Dashboard client (lab.sh bots, after bots_check.py): a bot's chat found
/// or made on the bot's profile, the same one every time, a turn in it, its transcript read again
/// over a new connection, the main profile as a bot, an @mention's note reaching Hermes (and
/// coming off what the app shows), and the bots let message each other.
@MainActor
struct HermesLabBotsTests {
    private static func say(_ text: String, in stored: String, _ client: HermesServeClient, note: String? = nil) async throws -> String {
        var request = TurnRequest(userText: text, history: [], sessionID: stored, model: nil, instructions: nil)
        request.mentionNote = note
        var reply = ""
        for try await event in HermesServeTransport(client: client).stream(request) {
            switch event {
            case let .textDelta(delta): reply += delta
            case let .textFinal(text): reply = text
            default: break
            }
        }
        return reply
    }

    /// All Profiles (his ask 2026-10-22): another profile's ordinary chat is listed with its
    /// profile, its bot chat isn't, and it opens and goes on in that profile, on the Dashboard and
    /// on the Hermes API with the Dashboard's login.
    @Test func anotherProfilesChatIsListedAndGoesOnInItsProfile() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        // A profile of its own: the other tests make and change theirs at the same time.
        _ = try? await client.call("profiles.create", params: .object(["name": .string("wren"), "clone_from": .string("default"),
                                                                       "no_alias": .bool(true)]))
        let roster = try await client.bots()
        guard let ranger = roster.bots.first(where: { $0.name == "wren" }) else {
            return HermesLabApprovalTests.report(false, "the lab has another profile", "\(roster.bots.map(\.name))")
        }
        let title = "Lab elsewhere \(UUID().uuidString.prefix(6))"
        let made = try await client.call("session.create", params: .object([
            "profile": .string(ranger.name), "title": .string(title), "source": .string("desktop"), "close_on_disconnect": .bool(false)]))
        let runtime = try #require(made["session_id"]?.string)
        let stored = made["stored_session_id"]?.string ?? runtime
        client.noteProfile(ranger.name, forStored: stored)
        client.adopt(runtime: runtime, stored: stored)
        _ = try await Self.say("hello from another profile", in: stored, client)

        func settle(_ c: Conversation) async {
            for _ in 0 ..< 120 where c.isStreaming || c.messages.last?.role != .assistant || (c.messages.last?.text.isEmpty ?? true) {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let account = Keychain.account(.gatewayAPIKey)
        let keyBefore = Keychain.read(account: account)
        Keychain.write(account: account, value: "labkey-labkey-labkey")
        defer { if let keyBefore { Keychain.write(account: account, value: keyBefore) } else { Keychain.delete(account: account) } }

        for connection in [Transport.hermesServe, .hermesSessions] {
            let settings = Settings(defaults: UserDefaults(suiteName: "lab-elsewhere-\(UUID().uuidString)")!)
            settings.transport = connection
            settings.gatewayURL = "http://127.0.0.1:18642"
            settings.serveURL = "http://127.0.0.1:19119"
            settings.serveUsername = "lab"
            let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-elsewhere-\(UUID().uuidString)"))
            let conversation = Conversation(settings: settings, store: store, dashboard: client)
            let rows = try await SessionBackend.everyProfile(conversation, settings: settings, dashboard: client, bots: try await client.bots())
            let row = rows.first { $0.id == stored }
            HermesLabApprovalTests.report(row?.elsewhere == ProfileRoute(profile: ranger.name, viaAPI: false) && row?.profile == ranger.name,
                   "\(connection): another profile's chat is listed with its profile", "\(String(describing: row?.elsewhere)) of \(rows.count) rows")
            HermesLabApprovalTests.report(!rows.contains { $0.elsewhere != nil && $0.title == BotChat.title },
                   "\(connection): another profile's bot chat is its bot's, not a row")
            guard let row else { continue }
            try await conversation.loadServeSession(row, elsewhere: row.elsewhere)
            HermesLabApprovalTests.report(conversation.elsewhere?.profile == ranger.name && conversation.connection == .hermesServe
                                          && conversation.messages.contains { $0.text.contains("hello from another profile") },
                   "\(connection): it opens in its profile, with what was said there", "\(String(describing: conversation.elsewhere)), \(conversation.messages.count) messages")
            _ = conversation.send("and once more")
            await settle(conversation)
            let listed = try await client.call("session.list", params: .object(["profile": .string(ranger.name), "limit": .number(200)]))
            let there = (listed["sessions"]?.array ?? []).first { ($0["id"]?.string ?? "") == stored || $0["resolved_id"]?.string == stored }
            HermesLabApprovalTests.report(conversation.serverSessionID == stored && conversation.messages.last?.error == nil && there != nil,
                   "\(connection): what is sent there is answered in the same chat, on its profile",
                   "\(conversation.serverSessionID ?? "none") \(conversation.messages.last?.text.prefix(60) ?? "")")
        }
    }

    /// Start Fresh: the bot's chat is put aside under a dated title and the next open makes a new
    /// one; `/compress` condenses a chat in place (slash.exec on the Dashboard).
    @Test func aBotsChatStartsFreshOrIsCondensed() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        _ = try? await client.call("profiles.create", params: .object(["name": .string("pip"), "clone_from": .string("default"),
                                                                       "no_alias": .bool(true)]))
        guard let pip = try await client.bots().bots.first(where: { $0.name == "pip" }) else { return }
        let first = try await client.botChat(for: pip)
        _ = try await Self.say("hello pip", in: first.stored, client)
        _ = try await Self.say("and again", in: first.stored, client)
        // /compress, as the composer sends a slash command on the Dashboard.
        var compressed = ""
        for try await event in HermesServeTransport(client: client).stream(TurnRequest(userText: "/compress", history: [], sessionID: first.stored,
                                                                                          model: nil, instructions: nil)) {
            switch event {
            case let .textDelta(delta): compressed += delta
            case let .textFinal(text): compressed = text
            default: break
            }
        }
        print("  info  /compress said: \(compressed.prefix(160))")
        HermesLabApprovalTests.report(!compressed.isEmpty, "/compress in a bot's chat is answered", compressed)

        guard let current = try await client.bots().bots.first(where: { $0.name == "pip" }) else { return }
        do {
            try await client.startFresh(current)
        } catch BotChat.Problem.cantStartFresh {
            // Hermes before 0.22: said so, and the chat left as it was.
            let still = try await client.botChat(for: current)
            HermesLabApprovalTests.report(still.stored == first.stored, "a release that can't set a bot's chat aside says so, and leaves it")
            return
        }
        guard let after = try await client.bots().bots.first(where: { $0.name == "pip" }) else { return }
        let fresh = try await client.botChat(for: after)
        let history = try await client.history(stored: fresh.stored)
        HermesLabApprovalTests.report(after.chatID == nil && fresh.isNew && fresh.stored != first.stored && history.isEmpty,
                                      "Start Fresh: the bot gets a new, empty chat", "chat \(after.chatID ?? "none"), \(fresh), \(history.count) rows")
        client.noteProfile("pip", forStored: first.stored)
        let old = try await client.history(stored: first.stored)
        HermesLabApprovalTests.report(old.count >= 4, "and the old one stays on the server with its messages", "\(old.count) rows")
    }

    /// On the Hermes API connection, with the Dashboard's login saved too, the bots are there: a
    /// bot's chat goes by the Dashboard (a bot is a profile, which the API serves only with its
    /// own key), answers, and a command it runs asks first, answered from the conversation; the
    /// app's own conversations stay on the API.
    @Test func onTheHermesAPIBotsGoByTheDashboardsLogin() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        _ = try? await client.call("profiles.create", params: .object(["name": .string("ranger"), "clone_from": .string("default"),
                                                                       "no_alias": .bool(true)]))
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-api-bots-\(UUID().uuidString)")!)
        settings.transport = .hermesSessions
        settings.gatewayURL = "http://127.0.0.1:18642"
        settings.serveURL = "http://127.0.0.1:19119"
        settings.serveUsername = "lab"
        let account = Keychain.account(.gatewayAPIKey)
        let before = Keychain.read(account: account)
        Keychain.write(account: account, value: "labkey-labkey-labkey")
        defer { if let before { Keychain.write(account: account, value: before) } else { Keychain.delete(account: account) } }
        HermesLabApprovalTests.report(BotDirectory.reachable(settings, dashboard: client), "on the Hermes API with the Dashboard's login, bots can be reached")

        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-api-bots-\(UUID().uuidString)"))
        let conversation = Conversation(settings: settings, store: store, dashboard: client)
        guard let ranger = try await client.bots().bots.first(where: { $0.name == "ranger" }) else {
            HermesLabApprovalTests.report(false, "the lab has a bot to talk to"); return
        }
        try await conversation.openBot(ranger, mainName: "Redde")
        HermesLabApprovalTests.report(conversation.bot?.profile == "ranger" && conversation.connection == .hermesServe,
                                      "a bot's chat on the Hermes API goes by the Dashboard", "\(conversation.bot.debugDescription), \(conversation.connection)")
        func settle(_ done: () -> Bool) async {
            for _ in 0 ..< 120 where !done() { try? await Task.sleep(for: .milliseconds(500)) }
        }
        _ = conversation.send("hello ranger")
        await settle { !conversation.isStreaming && conversation.messages.last?.role == .assistant && !(conversation.messages.last?.text.isEmpty ?? true) }
        let said = conversation.messages.last?.text ?? ""
        HermesLabApprovalTests.report(!said.isEmpty && conversation.messages.last?.error == nil, "the bot answers there", said.prefix(80).description)

        _ = conversation.send("Do the danger thing.")
        await settle { conversation.pendingInterrupt != nil }
        var asked = false
        if let pending = conversation.pendingInterrupt, case .approval = pending.interrupt { asked = true }
        conversation.respond(approval: "deny")
        await settle { !conversation.isStreaming && (conversation.messages.last?.text.contains("[kept]") ?? false) }
        HermesLabApprovalTests.report(asked && conversation.messages.last?.text.contains("[kept]") == true,
                                      "a command in the bot's chat asks first, and the answer from the conversation is taken",
                                      "asked \(asked), reply \(conversation.messages.last?.text.suffix(40) ?? "")")

        conversation.reset()
        HermesLabApprovalTests.report(conversation.bot == nil && conversation.connection == .hermesSessions, "the app's own conversations stay on the Hermes API")
    }

    @Test func aBotHasOneChatOfItsOwn() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        _ = try? await client.call("profiles.create", params: .object(["name": .string("scout"), "clone_from": .string("default"),
                                                                       "no_alias": .bool(true)]))
        var roster = try await client.bots()
        // (Other tests here make bots of their own.)
        HermesLabApprovalTests.report(Set(["default", "scout"]).isSubset(of: roster.listed.map(\.name)) && !roster.messagingIsOn,
               "the roster lists the main profile and the new one", "\(roster.bots.map(\.name)), on: \(roster.messagingIsOn)")
        guard let scout = roster.bots.first(where: { $0.name == "scout" }), let main = roster.bots.first(where: \.isDefault) else { return }

        let made = try await client.botChat(for: scout)
        let again = try await client.botChat(for: scout)
        HermesLabApprovalTests.report(made.isNew && !again.isNew && again.stored == made.stored, "the first open makes the chat, the next finds the same one",
               "\(made) then \(again)")
        let reply = try await Self.say("hello scout", in: made.stored, client)
        HermesLabApprovalTests.report(reply.hasPrefix("["), "a turn in the bot's chat is answered", reply)
        let listed = try await client.listSessions()
        HermesLabApprovalTests.report(!listed.contains { $0.id == made.stored }, "it stays out of the conversation list")

        // Over a new connection, as after a relaunch: the app names the bot's profile.
        guard let fresh = await HermesLabApprovalTests.client() else { return }
        defer { fresh.disconnect() }
        fresh.noteProfile("scout", forStored: made.stored)
        let rows = try await fresh.history(stored: made.stored)
        let said = Conversation.messages(fromServeRows: rows).map(\.text)
        HermesLabApprovalTests.report(said.contains("hello scout") && said.count >= 2, "its transcript, read again with its profile", "\(said)")
        roster = try await fresh.bots()
        HermesLabApprovalTests.report(roster.bots.first { $0.name == "scout" }?.chatID == made.stored, "the roster names it as the bot's chat")

        // The main profile as a bot, named explicitly as "default".
        let home = try await fresh.botChat(for: main)
        let homeReply = try await Self.say("hello hermes", in: home.stored, fresh)
        HermesLabApprovalTests.report(home.isNew && homeReply.hasPrefix("["), "the main profile's own chat", "\(home) \(homeReply)")

        // An @mention from the main profile's chat: the note reaches Hermes and comes off again.
        let note = try #require(BotMentions.note(for: BotMentions.mentioned(in: "@scout what do you think?", roster: roster.bots, to: "default")))
        _ = try await Self.say("@scout what do you think?", in: home.stored, fresh, note: note)
        let raw = try await fresh.history(stored: home.stored).compactMap { $0["text"]?.string ?? $0["content"]?.displayText }
        let shown = Conversation.messages(fromServeRows: try await fresh.history(stored: home.stored)).map(\.text)
        HermesLabApprovalTests.report(raw.contains { $0.hasPrefix("@scout what do you think?" + MentionNote.opening) }
               && shown.contains("@scout what do you think?"), "a mention's note reaches Hermes, and the app shows the message without it",
               "\(raw.suffix(2)) / \(shown.suffix(2))")

        try await fresh.letBotsMessageEachOther(roster)
        roster = try await fresh.bots()
        HermesLabApprovalTests.report(roster.messagingIsOn && roster.bots.first(where: \.isDefault)?.isSetUp == true, "the bots let message each other",
               "\(roster.bots.map { "\($0.name): \($0.isSetUp)" })")
        try await fresh.letBotsMessageEachOther(roster)   // already on: nothing to do
    }

    /// A bot messaging another with Hermes's own tool (`message_agent`): what lands in the other
    /// bot's chat reads as a message from the first, and the reply that comes back reads as the
    /// other bot's, in each chat as Redde shows it (`BotMessages`).
    @Test func aBotsMessageToAnotherReadsAsThatBots() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        let before = try await client.bots()
        let handle = try #require(BotNames.handle(for: "Lab Relay", taken: Set(before.bots.map(\.name))))
        _ = try await client.makeBot(NewBot(title: "Lab Relay", handle: handle, description: "Answers other bots", soul: "", model: nil, face: nil))
        var roster = try await client.bots()
        guard let relay = roster.bots.first(where: { $0.name == handle }), let main = roster.bots.first(where: \.isDefault) else {
            return HermesLabApprovalTests.report(false, "the bot to message is made", "\(roster.bots.map(\.name))")
        }
        let relayChat = try await client.botChat(for: relay)
        let home = try await client.botChat(for: main)
        let said = try await Self.say("lab:dm:\(handle) ask it about the trail", in: home.stored, client)
        print("  info  the main bot said: \(said.prefix(120))")

        // The message goes off in the background, and the reply comes back the same way.
        var inbound: Message?
        var reply: Message?
        for _ in 0 ..< 90 where inbound == nil || reply == nil {
            try await Task.sleep(for: .seconds(1))
            client.noteProfile(handle, forStored: relayChat.stored)
            inbound = Conversation.messages(fromServeRows: (try? await client.history(stored: relayChat.stored)) ?? []).first { $0.delivered != nil }
            reply = Conversation.messages(fromServeRows: (try? await client.history(stored: home.stored)) ?? []).first { $0.delivered?.kind == .reply }
        }
        let raw = (try? await client.history(stored: relayChat.stored))?.compactMap { $0["text"]?.string ?? $0["content"]?.displayText } ?? []
        print("  info  in its chat: \(raw.map { String($0.prefix(100)) })")
        HermesLabApprovalTests.report(inbound?.delivered?.kind == .message && inbound?.delivered?.profile == "default" && inbound?.text == "Which trailhead for Lost Lake?",
                                      "the message lands in the other bot's chat as one from the main bot", "\(String(describing: inbound))")
        let homeRaw = (try? await client.history(stored: home.stored))?.compactMap { $0["text"]?.string ?? $0["content"]?.displayText } ?? []
        print("  info  back home: \(homeRaw.suffix(3).map { String($0.prefix(160)) })")
        HermesLabApprovalTests.report(reply?.delivered?.profile == handle && reply?.text.hasPrefix("[") == true,
                                      "and its reply comes back as that bot's", "\(String(describing: reply))")

        // The Topology map's arrow for it, read from the bots' newest messages by the Dashboard
        // (read only: no chat opened for it).
        roster = try await client.bots()
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-handoffs-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        settings.serveURL = "http://127.0.0.1:19119"
        settings.serveUsername = "lab"
        let store = BotHandoffStore()
        await store.refresh(roster.bots, settings: settings, dashboard: client, force: true)
        HermesLabApprovalTests.report(store.handoffs[BotHandoff(from: "default", to: handle, kind: .message)].map { $0.count >= 1 } == true,
                                      "the map knows the main bot handed work to the other", "\(store.handoffs)")
        roster = try await client.bots()
        if let row = roster.bots.first(where: { $0.name == handle }) {
            print("  info  its row: \(BotMessages.rowPreview(row.preview, roster: roster.bots, mainName: "Redde") ?? "none")")
            try await client.deleteBot(row)
        }
    }

    /// Making, changing and deleting bots as BotEditor does, Hermes Desktop's way (a copy of the
    /// main profile): one with a model of its own and the personality written for it, one with the
    /// main model and a personality of the person's; renamed and hidden without losing what Hermes
    /// Desktop keeps for it; then deleted.
    @Test func aBotIsMadeChangedAndDeleted() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        let before = try await client.bots()
        let taken = Set(before.bots.map(\.name))
        let models = try await client.modelOptions(forProfile: "default")
        let main = models.first(where: \.isCurrent)
        print("  info  models: \(models.map { "\($0.provider)/\($0.model)\($0.isCurrent ? " (current)" : "")" })")
        // Another of the lab's own models: Hermes 0.21.0 and 0.21.3 also offer a free tier that
        // refuses anyone but its own app.
        let other = models.first { !$0.isCurrent && $0.provider == main?.provider }

        // With a model picked, and no personality written.
        let handle = try #require(BotNames.handle(for: "Lab Helper", taken: taken))
        let picked = BotFace(shape: .hex, eyes: .sparkle, mouth: .grin, mark: .antenna, glance: 1, tilt: 2, color: 4)
        let made = try await client.makeBot(NewBot(title: "Lab Helper", handle: handle, description: "Helps in the lab", soul: "",
                                                   model: other, face: picked))
        HermesLabApprovalTests.report(made.name == handle, "a bot is made", "\(made)")
        print("  info  made with notes: \(made.notes)")
        var roster = try await client.bots()
        guard let bot = roster.bots.first(where: { $0.name == handle }) else { return HermesLabApprovalTests.report(false, "and listed", "\(roster.bots.map(\.name))") }
        HermesLabApprovalTests.report(bot.title == "Lab Helper" && bot.description == "Helps in the lab" && bot.isSetUp && !bot.isHidden && bot.face == picked,
               "listed with its name, what it does and its face, as a bot", "\(bot)")
        let details = try await client.botDetails(bot)
        HermesLabApprovalTests.report(details.soul.contains("You are Lab Helper") && details.soul.contains("**Mission:** Helps in the lab"),
               "its personality is written from its name and what it does", String(details.soul.prefix(160)))
        let wanted = other ?? main
        HermesLabApprovalTests.report(wanted == nil || details.model == wanted?.model, "it has the model picked for it", "\(details.model ?? "none") / \(details.provider ?? "none")")
        let chat = try await client.botChat(for: bot)
        let reply = try await Self.say("hello helper", in: chat.stored, client)
        HermesLabApprovalTests.report(reply.hasPrefix("["), "it answers in its chat", reply)

        // A picture set for it as Hermes Desktop sets one: listed as having it, and fetched whole.
        let png = try #require(UIImage(systemName: "star.fill")?.withTintColor(.orange).pngData())
        _ = try await client.call("profiles.set_asset", params: .object(["name": .string(bot.name), "asset": .string("avatar"),
                                                                          "data": .string("data:image/png;base64,\(png.base64EncodedString())")]))
        let pictured = try await client.bots()
        let fetched = try await client.botPicture(bot.name)
        let mainsPicture = try await client.botPicture("default")
        HermesLabApprovalTests.report(pictured.bots.first { $0.name == bot.name }?.hasPicture == true && pictured.faces[bot.name]?.picture == bot.name
                                      && fetched == png && mainsPicture == nil,
               "a picture set in Hermes Desktop comes over for its bot, and only for it",
               "listed: \(String(describing: pictured.bots.first { $0.name == bot.name }?.hasPicture)), fetched \(fetched?.count ?? 0) of \(png.count) bytes")

        // Its skills, each on or off for it alone (Edit Bot → Skills).
        let ownSkills = try await client.dashboardSkills(profile: bot.name)
        if let skill = ownSkills.first(where: { $0.enabled ?? true }) {
            try await client.toggleSkill(name: skill.name, enabled: false, profile: bot.name)
            let off = try await client.dashboardSkills(profile: bot.name).first { $0.name == skill.name }
            let mains = try await client.dashboardSkills(profile: "default").first { $0.name == skill.name }
            HermesLabApprovalTests.report(off?.enabled == false && (mains?.enabled ?? true),
                   "a skill switched off for the bot is off for it alone, and still listed to switch back on",
                   "bot: \(String(describing: off?.enabled)), main: \(String(describing: mains?.enabled))")
            try await client.toggleSkill(name: skill.name, enabled: true, profile: bot.name)
            let back = try await client.dashboardSkills(profile: bot.name).first { $0.name == skill.name }
            HermesLabApprovalTests.report(back?.enabled ?? true, "and on again", "\(String(describing: back?.enabled))")
        } else {
            HermesLabApprovalTests.report(false, "the bot has skills to switch", "\(ownSkills.count) listed")
        }

        // Always loaded (the pin in Edit Bot → Skills): the bot's list alone, the rest of its config kept.
        if let skill = ownSkills.first(where: { $0.enabled ?? true }) {
            let modelBefore = try await client.botDetails(bot).model
            try await client.setAlwaysLoadedSkills([skill.name], profile: bot.name)
            let pinned = try await client.alwaysLoadedSkills(profile: bot.name)
            let mains = try await client.alwaysLoadedSkills(profile: "default")
            let modelAfter = try await client.botDetails(bot).model
            HermesLabApprovalTests.report(pinned == [skill.name] && !mains.contains(skill.name) && modelAfter == modelBefore,
                   "a skill pinned for the bot is always loaded for it alone, and the rest of its settings stay",
                   "bot \(pinned), main \(mains), model \(modelBefore ?? "none") → \(modelAfter ?? "none")")
            try await client.setAlwaysLoadedSkills([], profile: bot.name)
            let unpinned = try await client.alwaysLoadedSkills(profile: bot.name)
            HermesLabApprovalTests.report(unpinned.isEmpty, "and unpinned", "\(unpinned)")
        }

        // From a template (New Bot's Writer): its tools, and every one again once let go.
        let mainAgent = try await client.toolsetsOffered()
        let writer = try #require(BotTemplate.all.first { $0.id == "writer" })
        let tools = writer.toolsets(offered: mainAgent.toolsets) ?? []
        let writerHandle = try #require(BotNames.handle(for: "Lab Writer", taken: taken.union([handle])))
        let tooled = try await client.makeBot(NewBot(title: "Lab Writer", handle: writerHandle, description: writer.about, soul: writer.soul,
                                                     model: nil, face: writer.face, toolsets: tools))
        let writerBot = HermesBot(name: tooled.name)
        let pinned = try await client.botDetails(writerBot)
        HermesLabApprovalTests.report(tooled.notes.isEmpty && !tools.isEmpty && pinned.enabledToolsets == Set(tools)
                                      && !pinned.enabledToolsets.contains("terminal"),
                                      "a bot made from a template has the template's tools", "\(tooled.notes) \(tools) \(pinned.enabledToolsets)")
        // "Same as" the main agent: its list as it is, never an empty one (0.21.5 takes that for none).
        let mainTools = mainAgent.enabledToolsets
        print("  info  the main agent's toolsets: \(mainTools.sorted()) (pinned: \(mainAgent.toolsetsPinned))")
        _ = try await client.changeBot(writerBot, BotChange(toolsets: mainTools.sorted()))
        let again = try await client.botDetails(writerBot)
        HermesLabApprovalTests.report(again.enabledToolsets == mainTools, "and the main agent's tools again", "\(again.enabledToolsets) vs \(mainTools)")
        _ = try await client.changeBot(writerBot, BotChange(toolsets: []))
        HermesLabApprovalTests.report(try await client.botDetails(writerBot).enabledToolsets == mainTools,
                                      "an empty list is never sent", "")

        // The main agent's own list (Edit Bot → Tools on it): Code Execution off and on again, as
        // the Dashboard's Tools page then shows it.
        let mainBot = HermesBot(name: "default", isDefault: true)
        // As Edit Bot has them: the Dashboard's switches, of those it offers.
        let mainNow = (await client.mainToolsetsNow() ?? mainTools).intersection(mainAgent.toolsets.map(\.name))
        if mainNow.contains("code_execution") {
            // A chat already open, its tools fixed at its first message: it takes the change too.
            let (runtime, stored) = try await client.openSession(stored: nil)
            _ = try await Self.say("hello", in: stored, client)
            func openChatHasCodeExecution(_ wanted: Bool) async throws -> Bool {
                for _ in 0 ..< 40 {
                    let rows = try await client.call("toolsets.list", params: .object(["session_id": .string(runtime)]))["toolsets"]?.array ?? []
                    if rows.first(where: { $0["name"]?.string == "code_execution" })?["enabled"]?.bool == wanted { return true }
                    try await Task.sleep(for: .milliseconds(500))
                }
                return false
            }
            _ = try await client.changeBot(mainBot, BotChange(toolsets: mainNow.subtracting(["code_execution"]).sorted()))
            let without = (await client.mainToolsetsNow() ?? []).intersection(mainAgent.toolsets.map(\.name))
            let page = try await client.dashboardToolsets().first { $0.name == "code_execution" }?.enabled
            HermesLabApprovalTests.report(without == mainNow.subtracting(["code_execution"]) && page == false,
                                          "the main agent's tools changed from Edit Bot, and no other", "\(without.sorted()) page: \(String(describing: page))")
            let version = (try? await client.restJSON("GET", "api/status"))?["version"]?.string ?? ""
            if try await openChatHasCodeExecution(false) {
                HermesLabApprovalTests.report(true, "and a chat already open loses Code Execution, no restart", "")
            } else if version.hasPrefix("0.21.0") {
                // 0.21.0's reload reconnects the MCP servers alone: an open chat keeps the tools it started with.
                print("  ----  Hermes \(version): a chat already open keeps its tools until it starts again (reload.mcp re-reads them from 0.21.3)")
            } else {
                HermesLabApprovalTests.report(false, "and a chat already open loses Code Execution, no restart", "Hermes \(version)")
            }
            _ = try await client.changeBot(mainBot, BotChange(toolsets: mainNow.sorted()))
            let back = (await client.mainToolsetsNow() ?? []).intersection(mainAgent.toolsets.map(\.name))
            HermesLabApprovalTests.report(back == mainNow, "and put back", "\(back.sorted())")
            if !version.hasPrefix("0.21.0") {
                HermesLabApprovalTests.report(try await openChatHasCodeExecution(true), "and the open chat has it again", "")
            }
        } else {
            HermesLabApprovalTests.report(false, "the main agent has Code Execution to switch", "\(mainNow.sorted())")
        }

        // Renamed, described, a personality of the person's own; Hermes Desktop's look kept.
        let row = try await client.call("profiles.list", params: .object(["include_sessions": .bool(false)]))["profiles"]?.array?
            .first { $0["name"]?.string == handle }
        let desktop = try await client.call("profiles.configure", params: .object([
            "name": .string(handle), "ui_meta": .object(["hermes-bots": .object(["title": .string("Lab Helper"), "color": .string("#ff8800")])]),
            "ui_meta_expected_revisions": .object(["hermes-bots": .number(Double(row?["ui_meta_revisions"]?["hermes-bots"]?.int ?? 0))])]))
        HermesLabApprovalTests.report(desktop["applied"]?["ui_meta"]?.bool == true, "(Hermes Desktop gives it a colour)")
        let outcome = try await client.changeBot(bot, BotChange(title: "Lab Aide", description: "Aids the lab", soul: "# Lab Aide\n\nShort answers."))
        roster = try await client.bots()
        let changed = roster.bots.first { $0.name == handle }
        let reread = try await client.botDetails(bot)
        HermesLabApprovalTests.report(outcome == .done && changed?.title == "Lab Aide" && changed?.description == "Aids the lab" && reread.soul == "# Lab Aide\n\nShort answers."
               && changed?.face == picked, "renamed, described anew and given a personality; its face kept", "\(String(describing: changed)) \(reread.soul)")
        _ = try await client.changeBot(try #require(changed), BotChange(hidden: true))
        roster = try await client.bots()
        let look = try await client.call("profiles.list", params: .object(["include_sessions": .bool(false)]))["profiles"]?.array?
            .first { $0["name"]?.string == handle }?["ui_meta"]?["hermes-bots"]
        HermesLabApprovalTests.report(roster.bots.first { $0.name == handle }?.isHidden == true && !roster.listed.contains { $0.name == handle }
               && look?["color"]?.string == "#ff8800" && look?["title"]?.string == "Lab Aide",
               "hidden, it leaves the list, and Hermes Desktop's colour for it stays", "\(String(describing: look))")
        _ = try await client.changeBot(try #require(roster.bots.first { $0.name == handle }), BotChange(hidden: false))
        roster = try await client.bots()
        HermesLabApprovalTests.report(roster.bots.first { $0.name == handle }?.isHidden == false, "and shown again")
        if let main, other != nil {
            let back = try await client.changeBot(try #require(roster.bots.first { $0.name == handle }), BotChange(model: main))
            let now = try await client.botDetails(bot).model
            HermesLabApprovalTests.report(back == .done && now == main.model, "its model changed", "\(back) \(now ?? "none")")
        }

        // The main model, and a personality of the person's own.
        let copyHandle = try #require(BotNames.handle(for: "Lab Copy", taken: taken.union([handle])))
        let copy = try await client.makeBot(NewBot(title: "Lab Copy", handle: copyHandle, description: "", soul: "You are terse.",
                                                   model: nil, face: nil))
        roster = try await client.bots()
        guard let copied = roster.bots.first(where: { $0.name == copyHandle }) else { return HermesLabApprovalTests.report(false, "a copy of the main profile is made", "\(copy)") }
        let copyDetails = try await client.botDetails(copied)
        HermesLabApprovalTests.report(copyDetails.soul == "You are terse." && (main == nil || copyDetails.model == main?.model) && copy.notes.isEmpty,
               "one made with the main model has the personality written for it", "\(copy) \(copyDetails)")
        let copyChat = try await client.botChat(for: copied)
        let copyReply = try await Self.say("hello copy", in: copyChat.stored, client)
        HermesLabApprovalTests.report(copyReply.hasPrefix("["), "and answers in its chat", copyReply)

        // Deleted, with their chats.
        try await client.deleteBot(bot)
        try await client.deleteBot(copied)
        roster = try await client.bots()
        HermesLabApprovalTests.report(!roster.bots.contains { $0.name == handle || $0.name == copyHandle }, "deleted, they are gone from the server", "\(roster.bots.map(\.name))")
        try await client.deleteBot(try #require(roster.bots.first(where: \.isDefault)))   // never the main profile
        HermesLabApprovalTests.report(try await client.bots().bots.contains(where: \.isDefault), "the main profile can't be deleted")
    }
}

/// Hermes API turns as runs (lab.sh runs), with the app's own transport: a turn is a run and is
/// answered; left mid-reply it goes on and its reply lands in the conversation; taken up again it
/// gives its reply (word by word on 0.22, whole on 0.21.x); stopped, it stops; sent again with the
/// same key, it is the same run.
@MainActor
struct HermesLabRunsTests {
    private static let api = URL(string: "http://127.0.0.1:18642")!
    private static let key = "labkey-labkey-labkey"
    private static let drip = "lab:drip, please"

    /// What a turn said, gathered from a `@Sendable` closure.
    nonisolated final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var _text = ""
        private var _run: String?
        private var _deltas = 0
        var text: String { lock.withLock { _text } }
        var run: String? { lock.withLock { _run } }
        var deltas: Int { lock.withLock { _deltas } }
        func take(_ event: TurnEvent) {
            lock.withLock {
                switch event {
                case let .textDelta(delta): _text += delta; _deltas += 1
                case let .textFinal(text): _text = text
                case let .runID(id): _run = id
                default: break
                }
            }
        }
    }

    private static func ledger() async -> HermesSessionsAPI? {
        var probe = URLRequest(url: api.appending(path: "health"))
        probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            print("LAB SKIP: no Hermes lab on 127.0.0.1:18642 (scripts/hermes-lab/lab.sh up <tag> approval)")
            return nil
        }
        return HermesSessionsAPI(baseURL: api, apiKey: key)
    }

    private static func said(in session: String, _ ledger: HermesSessionsAPI) async -> [String] {
        ((try? await ledger.messages(sessionID: session)) ?? []).compactMap { $0.role == "assistant" ? $0.content?.text : nil }
    }

    /// Starts a slow, streaming turn, and lets go of it after `after` seconds: left (it goes on)
    /// or stopped. Returns the run.
    private static func startAndLetGo(in session: String, leaving: Bool, after: Double = 2.5) async throws -> String? {
        let transport = HermesSessionsTransport(baseURL: api, apiKey: key)
        let departure = TurnDeparture()
        var request = TurnRequest(userText: drip, turnKey: UUID().uuidString, history: [], sessionID: session, model: nil, instructions: nil)
        request.departure = departure
        let heard = Heard()
        let task = Task { for try await event in transport.stream(request) { heard.take(event) } }
        try await Task.sleep(for: .seconds(after))
        if leaving { departure.leave() }
        task.cancel()
        return heard.run
    }

    @Test func aTurnIsARunThatOutlivesTheApp() async throws {
        guard let ledger = await Self.ledger() else { return }
        let report = { (ok: Bool, what: String, detail: String) in HermesLabApprovalTests.report(ok, what, detail) }
        let transport = HermesSessionsTransport(baseURL: Self.api, apiKey: Self.key)

        // An ordinary turn.
        let first = try await ledger.createSession(title: "lab runs \(UUID().uuidString.prefix(6))")
        let heard = Heard()
        for try await event in transport.stream(TurnRequest(userText: "hi", turnKey: UUID().uuidString, history: [],
                                                            sessionID: first.id, model: nil, instructions: nil)) { heard.take(event) }
        report(heard.run?.hasPrefix("run_") == true && heard.text.hasPrefix("["), "a turn is a run, and is answered", "\(heard.run ?? "no run") \(heard.text)")
        let again = Heard()
        for try await event in transport.stream(TurnRequest(userText: "and again", turnKey: UUID().uuidString, history: [],
                                                            sessionID: first.id, model: nil, instructions: nil)) { again.take(event) }
        let firstSaid = await Self.said(in: first.id, ledger)
        report(firstSaid.count == 2, "the next turn is in the same conversation", "\(firstSaid)")

        // Left mid-reply: it goes on.
        let left = try await ledger.createSession(title: "lab runs left")
        _ = try await Self.startAndLetGo(in: left.id, leaving: true)
        var kept: [String] = []
        for _ in 0 ..< 25 where !kept.contains(where: { $0.contains("[drip done]") }) {
            try await Task.sleep(for: .seconds(1))
            kept = await Self.said(in: left.id, ledger)
        }
        report(kept.contains { $0.contains("[drip done]") }, "left mid-reply, the run goes on and its reply is kept", "\(kept)")

        // Taken up again.
        let taken = try await ledger.createSession(title: "lab runs taken up")
        guard let run = try await Self.startAndLetGo(in: taken.id, leaving: true) else {
            report(false, "a run to take up again", "no run id"); return
        }
        let followed = Heard()
        let runs = HermesRuns(baseURL: Self.api, apiKey: Self.key)
        try await runs.follow(run) { followed.take($0) }
        report(followed.text.contains("[drip done]"), "taken up again, the run gives its reply", followed.text)
        print("  info  taken up: \(followed.deltas > 0 ? "replayed word by word (\(followed.deltas) pieces)" : "whole, from its status")")

        // Stopped mid-reply: it stops.
        let stopped = try await ledger.createSession(title: "lab runs stopped")
        let stoppedRun = try await Self.startAndLetGo(in: stopped.id, leaving: false)
        try await Task.sleep(for: .seconds(12))
        var status: String?
        if let stoppedRun { status = try await ledger.runStatus(stoppedRun) }
        let stoppedSaid = await Self.said(in: stopped.id, ledger)
        report(!stoppedSaid.contains { $0.contains("[drip done]") } && status != "completed", "stopped mid-reply, the run stops",
               "status \(status ?? "?"), said \(stoppedSaid)")

        // The same message sent twice (its answer lost the first time): one run.
        let twice = try await ledger.createSession(title: "lab runs twice")
        let body = try HermesSessionsTransport.runBody(TurnRequest(userText: "hi", history: [], sessionID: twice.id, model: nil, instructions: nil),
                                                       sessionID: twice.id)
        let key = UUID().uuidString
        let one = try await runs.start(body, key: key)
        let two = try await runs.start(body, key: key)
        report(one != nil && one == two, "sent again with its key, it is the same run", "\(one ?? "-") / \(two ?? "-")")
    }

    /// What the Hermes API connection now does that only the Dashboard did: a turn asking for fast
    /// mode on a model without one is answered as usual; a subagent of a Hermes API turn is read
    /// through the Dashboard; a file that isn't a picture reaches the agent through the
    /// Dashboard's login, named in the message.
    @Test func theHermesAPIDoesWhatTheDashboardDid() async throws {
        guard let ledger = await Self.ledger(), let dashboard = await HermesLabApprovalTests.client() else { return }
        defer { dashboard.disconnect() }
        let transport = HermesSessionsTransport(baseURL: Self.api, apiKey: Self.key)

        let fastSession = try await ledger.createSession(title: "lab runs fast")
        var fast = TurnRequest(userText: "hi", turnKey: UUID().uuidString, history: [], sessionID: fastSession.id, model: nil, instructions: nil)
        fast.fast = true
        let heard = Heard()
        for try await event in transport.stream(fast) { heard.take(event) }
        HermesLabApprovalTests.report(heard.text.hasPrefix("["), "a turn asking for fast mode on a model without one is answered", heard.text)

        let delegating = try await ledger.createSession(title: "lab runs delegate")
        var child: String?
        for try await event in transport.stream(TurnRequest(userText: "lab:delegate please", turnKey: UUID().uuidString, history: [],
                                                            sessionID: delegating.id, model: nil, instructions: nil)) {
            if case let .subagent(update) = event, let id = update.childSessionID { child = id }
        }
        // The child's messages are kept a moment after the turn's reply: looked for a while.
        var childSaid: [String] = []
        for _ in 0 ..< 15 where childSaid.isEmpty {
            if let child, let rows = try? await dashboard.history(stored: child) { childSaid = Conversation.messages(fromServeRows: rows).map(\.text) }
            if childSaid.isEmpty { try await Task.sleep(for: .seconds(1)) }
        }
        HermesLabApprovalTests.report(child != nil && !childSaid.isEmpty, "a subagent of a Hermes API turn is read through the Dashboard",
                                      "child \(child ?? "none"), said \(childSaid)")

        let filing = try await ledger.createSession(title: "lab runs file")
        let clip = Attachment(kind: .other, filename: "lab-clip.mp4", mimeType: "video/mp4", data: Data(count: 2048))
        let asked = TurnRequest(userText: "lab:file please", turnKey: UUID().uuidString, history: [], sessionID: filing.id,
                                model: nil, instructions: nil, attachments: [clip])
        let placed = try await Conversation.placingFiles(asked, client: dashboard)
        let filed = Heard()
        for try await event in transport.stream(placed) { filed.take(event) }
        HermesLabApprovalTests.report(placed.attachments.isEmpty && filed.text.contains("[file seen]"),
                                      "a file goes to the server through the Dashboard, and the agent is told where", filed.text)
        let stored = try await ledger.messages(sessionID: filing.id).first { $0.role == "user" }?.content?.text ?? ""
        HermesLabApprovalTests.report(ReplyLanguage.stripNote(stored) == "lab:file please", "the app shows the message without the note",
                                      ReplyLanguage.stripNote(stored))
    }

    /// The conversation as the app has it: a turn left for another conversation, then the
    /// conversation opened again, takes its run up again and shows its reply. On the app's own
    /// store and run notes (the only ones a run is noted in), so what it saved goes again after.
    @Test func aRunLeftIsTakenUpAgainWhenTheConversationIsOpened() async throws {
        guard await Self.ledger() != nil else { return }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-runs-\(UUID().uuidString)")!)
        settings.transport = .hermesSessions
        settings.gatewayURL = Self.api.absoluteString
        let account = Keychain.account(.gatewayAPIKey)
        let before = Keychain.read(account: account)
        Keychain.write(account: account, value: Self.key)
        defer { if let before { Keychain.write(account: account, value: before) } else { Keychain.delete(account: account) } }

        let conversation = Conversation(settings: settings, store: .shared, transportOverride: HermesSessionsTransport(baseURL: Self.api, apiKey: Self.key))
        conversation.reset()   // not whatever the app had open last
        _ = conversation.send(Self.drip)
        try await Task.sleep(for: .seconds(3))
        guard let stored = conversation.serverSessionID else {
            HermesLabApprovalTests.report(false, "a run left is taken up again", "the conversation got no session"); return
        }
        let noted = ChatActivity.shared.run(of: stored, settings: settings)
        conversation.reset()   // left for a new conversation
        try await conversation.open(serverSession: stored)
        let following = conversation.isStreaming
        for _ in 0 ..< 60 where conversation.isStreaming || !(conversation.messages.last?.text.contains("[drip done]") ?? false) {
            try await Task.sleep(for: .milliseconds(500))
        }
        let reply = conversation.messages.last?.text ?? ""
        HermesLabApprovalTests.report(noted != nil && following && reply.contains("[drip done]") && !conversation.isStreaming
                                      && ChatActivity.shared.run(of: stored, settings: settings) == nil,
                                      "a conversation opened again takes its run up again, and shows its reply",
                                      "noted: \(noted ?? "no"), following: \(following), reply: \(reply.suffix(60)), still noted: \(ChatActivity.shared.run(of: stored, settings: settings) ?? "no")")
        for record in ConversationStore.shared.summaries where record.serverSessionID == stored { conversation.delete(id: record.id) }
    }

    /// An incognito chat on each connection: on the Dashboard its session is hidden from every
    /// list and the agent is told on the message; on the Hermes API, in the turn's instructions;
    /// and once the chat is left its session is deleted from the server, on both.
    @Test func anIncognitoChatIsDeletedFromTheServerWhenLeft() async throws {
        guard let ledger = await Self.ledger(), let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func temp() -> ConversationStore {
            ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-incognito-\(UUID().uuidString)"))
        }
        func settle(_ c: Conversation) async {
            for _ in 0 ..< 120 where c.isStreaming || c.messages.last?.role != .assistant || (c.messages.last?.text.isEmpty ?? true) {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // The Dashboard.
        let serve = Settings(defaults: UserDefaults(suiteName: "lab-incognito-serve-\(UUID().uuidString)")!)
        serve.transport = .hermesServe
        serve.serveURL = "http://127.0.0.1:19119"
        serve.serveUsername = "lab"
        let onDashboard = Conversation(settings: serve, store: temp(), dashboard: client)
        onDashboard.startIncognito()
        _ = onDashboard.send("hello, incognito")
        await settle(onDashboard)
        guard let dashboardSession = onDashboard.serverSessionID else {
            HermesLabApprovalTests.report(false, "an incognito chat on the Dashboard gets a session"); return
        }
        let listed = (try? await client.call("session.list", params: .object(["limit": .number(200)])))?["sessions"]?.array?
            .compactMap { $0["id"]?.string } ?? []
        let asked = ((try? await client.history(stored: dashboardSession)) ?? [])
            .compactMap { $0["content"]?.string ?? $0["text"]?.string }.joined(separator: "\n")
        HermesLabApprovalTests.report(!listed.contains(dashboardSession) && asked.contains("Incognito chat:"),
                                      "on the Dashboard it is listed by no app, and the agent is told it is incognito",
                                      "listed \(listed.contains(dashboardSession)), told \(asked.contains("Incognito chat:"))")
        onDashboard.reset()
        var goneFromDashboard = false
        for _ in 0 ..< 30 where !goneFromDashboard {
            try? await Task.sleep(for: .milliseconds(500))
            let all = (try? await client.call("session.list", params: .object(["limit": .number(200), "include_hidden": .bool(true)])))?["sessions"]?.array?
                .compactMap { $0["id"]?.string }
            goneFromDashboard = all.map { !$0.contains(dashboardSession) } ?? false
        }
        HermesLabApprovalTests.report(goneFromDashboard, "left, its Dashboard session is deleted from the server")

        // The Hermes API.
        let apiSettings = Settings(defaults: UserDefaults(suiteName: "lab-incognito-api-\(UUID().uuidString)")!)
        apiSettings.transport = .hermesSessions
        apiSettings.gatewayURL = Self.api.absoluteString
        let account = Keychain.account(.gatewayAPIKey)
        let before = Keychain.read(account: account)
        Keychain.write(account: account, value: Self.key)
        defer { if let before { Keychain.write(account: account, value: before) } else { Keychain.delete(account: account) } }
        let onAPI = Conversation(settings: apiSettings, store: temp())
        onAPI.startIncognito()
        _ = onAPI.send("hello, incognito")
        await settle(onAPI)
        guard let apiSession = onAPI.serverSessionID else {
            HermesLabApprovalTests.report(false, "an incognito chat on the Hermes API gets a session"); return
        }
        let answered = onAPI.messages.last?.role == .assistant && onAPI.messages.last?.error == nil
        onAPI.reset()
        var goneFromAPI = false
        for _ in 0 ..< 30 where !goneFromAPI {
            try? await Task.sleep(for: .milliseconds(500))
            do { _ = try await ledger.messages(sessionID: apiSession) } catch TransportError.http(404, _) { goneFromAPI = true } catch {}
        }
        HermesLabApprovalTests.report(answered && goneFromAPI, "on the Hermes API it is answered, and deleted from the server once left",
                                      "answered \(answered), gone \(goneFromAPI)")
        Incognito.setPending(Incognito.pending().filter { ![dashboardSession, apiSession].contains($0.session) })
    }

    /// Two chats left with a command each waiting to be approved (asked on Reddit for 2.0): chat
    /// A asks, the app goes to a new chat B, which asks too; then each is opened again, A as a
    /// switch back, B by an app opened afresh (as after the phone was locked and Redde put away).
    /// Each shows its own run's question, each answer goes to that run (A's approved: the command
    /// runs; B's denied: it doesn't), and each question was sent to the host once.
    @Test func twoRunsLeftWaitingOnApprovalsEachKeepTheirOwn() async throws {
        guard let ledger = await Self.ledger() else { return }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-runs-\(UUID().uuidString)")!)
        settings.transport = .hermesSessions
        settings.gatewayURL = Self.api.absoluteString
        let account = Keychain.account(.gatewayAPIKey)
        let before = Keychain.read(account: account)
        Keychain.write(account: account, value: Self.key)
        defer { if let before { Keychain.write(account: account, value: before) } else { Keychain.delete(account: account) } }
        func conversation() -> Conversation {
            Conversation(settings: settings, store: .shared, transportOverride: HermesSessionsTransport(baseURL: Self.api, apiKey: Self.key))
        }
        /// The question the conversation shows, with the run it belongs to.
        func asked(_ c: Conversation, seconds: Int = 90) async -> (run: String, id: String)? {
            for _ in 0 ..< seconds * 2 {
                if let pending = c.pendingInterrupt, case let .approval(request) = pending.interrupt { return (pending.runtimeSession, request.id) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            return nil
        }
        func reply(_ c: Conversation, containing word: String, seconds: Int = 90) async -> String {
            for _ in 0 ..< seconds * 2 {
                if let last = c.messages.last, last.role == .assistant, last.text.contains(word), !c.isStreaming { return last.text }
                try? await Task.sleep(for: .milliseconds(500))
            }
            return c.messages.last?.text ?? ""
        }

        let app = conversation()
        app.reset()
        _ = app.send("Do the danger thing (chat A).")
        let firstA = await asked(app)
        let storedA = app.serverSessionID
        app.reset()   // a new chat, A's run left waiting
        _ = app.send("Do the danger thing (chat B).")
        let firstB = await asked(app)
        let storedB = app.serverSessionID
        guard let firstA, let firstB, let storedA, let storedB else {
            HermesLabApprovalTests.report(false, "two chats each wait on an approval", "A \(firstA.debugDescription), B \(firstB.debugDescription)"); return
        }
        HermesLabApprovalTests.report(firstA.run != firstB.run && storedA != storedB, "two chats each wait on an approval, each in a run of its own",
                                      "A \(firstA.run), B \(firstB.run)")

        // Back to A: its own question, answered to its own run.
        app.reset()
        try await app.open(serverSession: storedA)
        let againA = await asked(app)
        HermesLabApprovalTests.report(againA?.run == firstA.run && againA?.id == firstA.id, "chat A, opened again, shows its own run's question",
                                      "\(againA.debugDescription) for \(firstA)")

        // B from an app opened afresh: its question, not A's, and B's answer to B's run. (B is
        // answered first: the stub's command removes one folder for both, and says what it found.)
        let reopened = conversation()
        try await reopened.open(serverSession: storedB)
        let againB = await asked(reopened)
        HermesLabApprovalTests.report(againB?.run == firstB.run && againB?.id == firstB.id, "chat B, opened by the app afresh, shows its own run's question",
                                      "\(againB.debugDescription) for \(firstB)")
        reopened.respond(approval: "deny")
        let saidB = await reply(reopened, containing: "[kept]")
        app.respond(approval: "once")
        let saidA = await reply(app, containing: "[gone]")
        HermesLabApprovalTests.report(saidA.contains("[gone]") && saidB.contains("[kept]"), "each answer went to its own run: A's command ran, B's didn't",
                                      "A: \(saidA.suffix(40)), B: \(saidB.suffix(40))")

        // Each question went to the host once, opening again and all.
        let askedA = (try? await ledger.messages(sessionID: storedA))?.filter { $0.role == "user" }.count ?? -1
        let askedB = (try? await ledger.messages(sessionID: storedB))?.filter { $0.role == "user" }.count ?? -1
        HermesLabApprovalTests.report(askedA == 1 && askedB == 1, "reconnecting sent neither question again", "A asked \(askedA)×, B \(askedB)×")
        for record in ConversationStore.shared.summaries where [storedA, storedB].contains(record.serverSessionID) { app.delete(id: record.id) }
    }
}

/// A bot on the Hermes API alone, with no Dashboard login (lab.sh apibots): the lab's profile
/// "scout" has an API key of its own, and the gateway serves it at /p/scout/. Added here by that
/// key, it is in the roster; its chat goes by the API there, answers, asks before a command and
/// takes the answer; opened again by an app started afresh it is the same chat; and a run left
/// mid-reply is asked after, and taken up again, by the bot's own address and key.
@MainActor
struct HermesLabAPIBotsTests {
    private static let api = "http://127.0.0.1:18642"
    private static let mainKey = "labkey-labkey-labkey"
    private static let botKey = "scoutkey-scoutkey-scoutkey"

    /// All Profiles on the Hermes API with no Dashboard (his ask 2026-10-22): another profile's
    /// chat, reached at /p/<profile>/ with its own key, goes on there and is listed with its profile.
    @Test func onTheHermesAPIAloneAnotherProfilesChatIsListedAndGoesOn() async throws {
        var probe = URLRequest(url: URL(string: Self.api + "/p/scout/api/sessions?limit=1")!)
        probe.setValue("Bearer \(Self.botKey)", forHTTPHeaderField: "Authorization")
        probe.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: probe), (response as? HTTPURLResponse)?.statusCode == 200 else {
            print("LAB SKIP: no lab profile with its own API key at /p/scout/ (scripts/hermes-lab/lab.sh apibots)")
            return
        }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-api-elsewhere-\(UUID().uuidString)")!)
        settings.transport = .hermesSessions
        settings.gatewayURL = Self.api
        let server = settings.activeServerID.uuidString
        let mainAccount = Keychain.account(.gatewayAPIKey, server: server), botAccount = Keychain.profileAccount("scout", server: server)
        Keychain.write(account: mainAccount, value: Self.mainKey)
        // The app's own key is read for the server the phone is on (`Keychain.activeServerID`).
        let appAccount = Keychain.account(.gatewayAPIKey), appKeyBefore = Keychain.read(account: appAccount)
        Keychain.write(account: appAccount, value: Self.mainKey)
        defer {
            Keychain.delete(account: mainAccount); Keychain.delete(account: botAccount)
            if let appKeyBefore { Keychain.write(account: appAccount, value: appKeyBefore) } else { Keychain.delete(account: appAccount) }
        }
        try await APIBots.add(profile: "scout", title: "Scout", key: Self.botKey, settings: settings)
        let noDashboard = HermesServeClient(settings: settings, password: { nil }, tokens: HermesServeClientTests.TokenBox().store)
        let conversation = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "lab-api-elsewhere-\(UUID().uuidString)")), dashboard: noDashboard)

        let route = ProfileRoute(profile: "scout", viaAPI: true)
        guard let scoutAPI = conversation.ledgerAPI(profile: "scout") else { return HermesLabApprovalTests.report(false, "scout is reachable") }
        let made = try await scoutAPI.createSession(title: "Lab elsewhere \(UUID().uuidString.prefix(6))")
        try await conversation.loadLedgerSession(made, elsewhere: route)
        _ = conversation.send("hello from another profile")
        for _ in 0 ..< 120 where conversation.isStreaming || conversation.messages.last?.role != .assistant { try? await Task.sleep(for: .milliseconds(500)) }
        HermesLabApprovalTests.report(conversation.elsewhere == route && conversation.serverSessionID == made.id && conversation.messages.last?.error == nil
                                      && conversation.messages.last?.role == .assistant,
                                      "a chat of another profile goes on at its /p/<profile>/ with its own key", conversation.messages.last?.error ?? "")
        let rows = try await SessionBackend.everyProfile(conversation, settings: settings, dashboard: noDashboard)
        let row = rows.first { $0.id == made.id }
        HermesLabApprovalTests.report(row?.elsewhere == route && row?.profile == "scout",
                                      "with no Dashboard, every profile's chats are asked of each, and another profile's is listed with it",
                                      "\(String(describing: row?.elsewhere)) of \(rows.count) rows")
        if let row, case .ledger(let api) = SessionBackend.owning(row, conversation, settings: settings) {
            HermesLabApprovalTests.report(api.baseURL.path().hasSuffix("/p/scout") && api.apiKey == Self.botKey, "its row is looked after at its own profile")
        } else {
            HermesLabApprovalTests.report(false, "its row is looked after at its own profile")
        }
        try? await scoutAPI.deleteSession(id: made.id)
    }

    @Test func aBotAddedForTheHermesAPIAloneTalksThere() async throws {
        var probe = URLRequest(url: URL(string: Self.api + "/p/scout/api/sessions?limit=1")!)
        probe.setValue("Bearer \(Self.botKey)", forHTTPHeaderField: "Authorization")
        probe.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: probe), (response as? HTTPURLResponse)?.statusCode == 200 else {
            print("LAB SKIP: no lab bot with its own API key at /p/scout/ (scripts/hermes-lab/lab.sh apibots)")
            return
        }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-api-only-bots-\(UUID().uuidString)")!)
        settings.transport = .hermesSessions
        settings.gatewayURL = Self.api
        let server = settings.activeServerID.uuidString
        let mainAccount = Keychain.account(.gatewayAPIKey, server: server), botAccount = Keychain.profileAccount("scout", server: server)
        Keychain.write(account: mainAccount, value: Self.mainKey)
        Keychain.write(account: botAccount, value: Self.botKey)
        defer { Keychain.delete(account: mainAccount); Keychain.delete(account: botAccount) }
        let noDashboard = HermesServeClient(settings: settings, password: { nil }, tokens: HermesServeClientTests.TokenBox().store)
        // Added as Add Bot adds them: pip, whose .env has the main key, by name alone; scout, which
        // has a key of its own, refused that way and then taken with it.
        Keychain.delete(account: botAccount)
        var addedPip = false
        do { try await APIBots.add(profile: "pip", title: "Pip", key: nil, settings: settings); addedPip = true } catch {}
        var askedForKey = false
        do { try await APIBots.add(profile: "scout", title: "Scout", key: nil, settings: settings) } catch APIBotProblem.needsKey { askedForKey = true }
        try await APIBots.add(profile: "scout", title: "Scout", key: Self.botKey, settings: settings)
        HermesLabApprovalTests.report(addedPip && askedForKey && settings.apiBotsHere.map(\.profile) == ["pip", "scout"],
                                      "a bot with the main key in its .env is added by its name; one with a key of its own asks for it",
                                      "pip \(addedPip), scout asked \(askedForKey), \(settings.apiBotsHere.map(\.profile))")
        let pipChat = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "lab-api-pip-\(UUID().uuidString)")), dashboard: noDashboard)
        let roster0 = await BotDirectory().refreshAPI(settings: settings)
        if let pip = roster0.bots.first(where: { $0.name == "pip" }) {
            try await pipChat.openBot(pip, mainName: "Redde")
            _ = pipChat.send("hello pip")
            for _ in 0 ..< 120 where pipChat.isStreaming || pipChat.messages.last?.role != .assistant { try? await Task.sleep(for: .milliseconds(500)) }
        }
        HermesLabApprovalTests.report(pipChat.ledgerAPI()?.apiKey == Self.mainKey && pipChat.messages.last?.role == .assistant
                                      && pipChat.messages.last?.error == nil, "pip's chat goes by the main key, and pip answers",
                                      pipChat.messages.last?.error ?? "")
        HermesLabApprovalTests.report(BotDirectory.apiOnly(settings, dashboard: noDashboard) && BotDirectory.available(settings, dashboard: noDashboard),
                                      "on the Hermes API with no Dashboard login, the bots are the ones added here")

        let roster = await BotDirectory().refreshAPI(settings: settings)
        guard let scout = roster.bots.first(where: { $0.name == "scout" }) else {
            HermesLabApprovalTests.report(false, "the added bot is in the roster", "\(roster.bots.map(\.name))"); return
        }
        HermesLabApprovalTests.report(scout.viaAPI && scout.label() == "Scout" && roster.listed.map(\.name).contains("scout"),
                                      "the added bot is in the roster, by the name it was given")

        func settle(_ c: Conversation, _ done: () -> Bool) async {
            for _ in 0 ..< 120 where !done() { try? await Task.sleep(for: .milliseconds(500)) }
        }
        let conversation = Conversation(settings: settings, store: .shared, dashboard: noDashboard)
        conversation.reset()
        try await conversation.openBot(scout, mainName: "Redde")
        let stored = conversation.serverSessionID
        HermesLabApprovalTests.report(conversation.connection == .hermesSessions && conversation.ledgerAPI()?.baseURL.path.hasSuffix("/p/scout") == true,
                                      "its chat goes by the Hermes API, at /p/scout/", "\(conversation.connection), \(conversation.ledgerAPI()?.baseURL.absoluteString ?? "none")")
        _ = conversation.send("hello scout")
        await settle(conversation) { !conversation.isStreaming && conversation.messages.last?.role == .assistant && !(conversation.messages.last?.text.isEmpty ?? true) }
        HermesLabApprovalTests.report(!(conversation.messages.last?.text.isEmpty ?? true) && conversation.messages.last?.error == nil,
                                      "the bot answers there", conversation.messages.last?.error ?? "")

        _ = conversation.send("Do the danger thing.")
        await settle(conversation) { conversation.pendingInterrupt != nil }
        var asked = false
        if let pending = conversation.pendingInterrupt, case .approval = pending.interrupt { asked = true }
        conversation.respond(approval: "deny")
        await settle(conversation) { !conversation.isStreaming && (conversation.messages.last?.text.contains("[kept]") ?? false) }
        HermesLabApprovalTests.report(asked && conversation.messages.last?.text.contains("[kept]") == true,
                                      "a command in its chat asks first, and the answer reaches its run", "asked \(asked)")

        // An app started afresh: the same chat, with what was said.
        let again = Conversation(settings: settings, store: .shared, dashboard: noDashboard)
        try await again.openBot(scout, mainName: "Redde")
        HermesLabApprovalTests.report(again.serverSessionID == stored && again.messages.count >= 4, "opened again, it is the same chat",
                                      "\(again.serverSessionID ?? "none") for \(stored ?? "none"), \(again.messages.count) messages")

        // A run left mid-reply: asked after by the bot's address, taken up again when it opens.
        _ = again.send("lab:drip, please")
        try await Task.sleep(for: .seconds(3))
        again.reset()
        await ChatActivity.shared.look(again, settings: settings, dashboard: noDashboard)
        let marked = stored.map { ChatActivity.shared.kind(of: $0, open: again, settings: settings) } ?? nil
        try await again.openBot(scout, mainName: "Redde")
        let following = again.isStreaming
        await settle(again) { !again.isStreaming && (again.messages.last?.text.contains("[drip done]") ?? false) }
        HermesLabApprovalTests.report(marked == .working && following && again.messages.last?.text.contains("[drip done]") == true,
                                      "a run left is asked after, and taken up again, by the bot's own address",
                                      "marked \(String(describing: marked)), following \(following), \(again.messages.last?.text.suffix(40) ?? "")")
        for record in ConversationStore.shared.summaries where record.serverSessionID == stored { again.delete(id: record.id) }
    }
}

/// Group chats with the app's own client and room feed (lab.sh groups, after groups_check.py): a
/// room of the main profile and one more made, a message to both answered by both, one tagging a
/// bot answered by it alone, a bot's command approved from the room's card, renamed, stopped and
/// ended.
@MainActor
struct HermesLabGroupsTests {
    private static func until(_ feed: GroupFeed, seconds: Int = 60, _ done: () -> Bool) async {
        for _ in 0 ..< seconds * 2 {
            await feed.look()
            if done() { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    @Test func aGroupOfBotsTalks() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        _ = try? await client.call("profiles.create", params: .object(["name": .string("scout"), "clone_from": .string("default"),
                                                                       "no_alias": .bool(true)]))
        var support = (supported: false, writable: false)
        for _ in 0 ..< 20 where !support.writable {
            support = try await client.groupSupport()
            if !support.writable { try await Task.sleep(for: .seconds(1)) }
        }
        HermesLabApprovalTests.report(support.supported && support.writable, "this Hermes runs group chats", "\(support)")
        let roster = try await client.bots()
        let bots = roster.bots.filter { $0.isDefault || $0.name == "scout" }
        let room = try await client.createGroup(named: "Lab group", bots: bots, mainName: "Redde")
        HermesLabApprovalTests.report(room.members.map(\.handle).sorted() == ["hermes", "scout"], "a group chat is made of two bots",
                                      "\(room.members.map(\.handle))")

        let feed = GroupFeed(room: room, client: client)
        feed.send("hello both")
        await Self.until(feed) { !feed.discussing && feed.events.contains { $0.kind == "message.member" } }
        let answered = Set(feed.events.filter { $0.kind == "message.member" }.compactMap(\.actorID))
        HermesLabApprovalTests.report(answered == ["default", "scout"] && feed.sending.isEmpty && !feed.discussing,
                                      "a message to the group: both answer, and the round is over", "\(answered), discussing \(feed.discussing)")

        let before = feed.events.count
        feed.send("@scout just you")
        await Self.until(feed) { !feed.discussing && feed.events.count > before + 1 }
        let second = feed.events.dropFirst(before).filter { $0.kind == "message.member" }.compactMap(\.actorID)
        HermesLabApprovalTests.report(second == ["scout"], "a message tagging one bot: that one answers", "\(second)")

        // A reply as it is written (the stub's, a word a second): read from the bot's own session
        // for the room before the room has it, under the bot's name, and gone once the room has it.
        let beforeDrip = feed.events.count
        feed.send("@scout lab:drip")
        var written = "", whose: String?
        for _ in 0 ..< 120 {
            await feed.look()
            await feed.lookAtDrafts()
            if let draft = feed.drafts.first(where: { !$0.text.isEmpty }), draft.finishedAt == nil { (written, whose) = (draft.text, draft.memberID) }
            if feed.events.dropFirst(beforeDrip).contains(where: { $0.kind == "message.member" }) { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        HermesLabApprovalTests.report(written.contains("word2") && whose == "scout", "a bot's reply in the room shows as it is written, under its name",
                                      "\(whose ?? "nobody"): \(written.prefix(60))")
        await Self.until(feed) { !feed.discussing }
        await feed.lookAtDrafts()
        HermesLabApprovalTests.report(feed.drafts.isEmpty, "once the room has the reply, the one being written goes", "\(feed.drafts.map(\.text))")

        // A file to the group: a room takes text alone, so the file goes to the server through the
        // Dashboard and the message names it, for the bots to read with their tools.
        let beforeFile = feed.events.count
        let notes = Attachment(kind: .text, filename: "lab-notes.txt", mimeType: "text/plain", data: Data("the lab's notes".utf8))
        feed.send("what's in this file?", attachments: [notes])
        await Self.until(feed) { feed.sending.isEmpty && feed.events.dropFirst(beforeFile).contains { $0.kind == "message.user" } }
        let withFile = feed.events.dropFirst(beforeFile).first { $0.kind == "message.user" }?.text ?? ""
        let paths = AttachedFileNote.paths(in: withFile)
        var kept = ""
        if let path = paths.first { kept = (try? await client.text(of: ServerFile(name: ServerFiles.name(of: path), path: path, isDirectory: false)).text) ?? "" }
        HermesLabApprovalTests.report(paths.count == 1 && kept == "the lab's notes" && AttachedFileNote.strip(withFile) == "what's in this file?"
                                      && feed.problem == nil, "a file sent to the group is put on the server, and the message names it",
                                      "\(paths), kept \(kept.debugDescription), problem \(feed.problem ?? "none")")
        await Self.until(feed) { !feed.discussing }

        // A bot's command in the group: its card, answered from the feed; answered again (as from
        // another device), the room is read again and there is nothing to fix.
        let asked = feed.events.count
        feed.send("@scout danger")
        await Self.until(feed) { !feed.state.approvals.isEmpty }
        let approval = feed.state.approvals.first
        HermesLabApprovalTests.report(approval?.memberID == "scout" && approval?.request.choices == ["once", "deny"] && feed.state.waitsOnPerson,
                                      "a bot's command in the group waits on the person", "\(String(describing: approval))")
        if let approval {
            feed.answer(approval, "once")
            await Self.until(feed) { feed.state.approvals.isEmpty && feed.answering.isEmpty && !feed.discussing && feed.events.count > asked + 1 }
            let reply = feed.events.dropFirst(asked).last { $0.kind == "message.member" }?.text ?? ""
            HermesLabApprovalTests.report(reply.contains("[gone]"), "approved from the group's card, the command runs and the reply lands", reply)
            feed.answer(approval, "once")
            for _ in 0 ..< 40 where !feed.answering.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            HermesLabApprovalTests.report(feed.problem == nil && feed.answering.isEmpty, "answered again, nothing to fix", feed.problem ?? "")
        }

        // A room Hermes Desktop runs: its copy written into the main profile as Desktop writes
        // it (profiles.configure, compare-and-swap on the key's revision), read back read-only.
        let listed = try await client.call("profiles.list", params: .object(["include_sessions": .bool(false)]))
        let main = listed["profiles"]?.array?.first { $0["name"]?.string == "default" }
        let revision = main?["ui_meta_revisions"]?["hermes-bots-groups"]?.int ?? 0
        let copy: JSONValue = .object([
            "version": .number(3), "updatedAt": .number(Date.now.timeIntervalSince1970 * 1000),
            "rooms": .object(["id:lab-desk": .object([
                "name": .string("Desk room"), "roomId": .string("lab-desk"), "revision": .number(1),
                "members": .array([.object(["name": .string("default")]), .object(["name": .string("scout"), "title": .string("Scout")])]),
                "log": .array([
                    .object(["at": .number(Date.now.timeIntervalSince1970 * 1000 - 5000), "from": .object(["kind": .string("user"), "name": .string("You")]),
                             "text": .string("Which trail?")]),
                    .object(["at": .number(Date.now.timeIntervalSince1970 * 1000), "from": .object(["kind": .string("member"), "name": .string("scout")]),
                             "text": .string("Falls Loop."), "id": .string("lab-m2")]),
                ]),
            ])]),
        ])
        _ = try await client.call("profiles.configure", params: .object([
            "name": .string("default"), "ui_meta": .object(["hermes-bots-groups": copy]),
            "ui_meta_expected_revisions": .object(["hermes-bots-groups": .number(Double(revision))])]))
        let desk = try await client.desktopRooms().first { $0.name == "Desk room" }
        HermesLabApprovalTests.report(desk?.inDesktop == true && desk?.desktopMessages.count == 2,
                                      "a Hermes Desktop room is read from its copy", "\(String(describing: desk?.desktopMessages.map(\.text)))")
        if let desk {
            let deskFeed = GroupFeed(room: desk, client: client)
            await deskFeed.look()
            HermesLabApprovalTests.report(deskFeed.events.map(\.kind) == ["message.user", "message.member"] && deskFeed.events.last?.actorID == "scout"
                                          && !deskFeed.discussing && deskFeed.problem == nil,
                                          "its room shows the messages, read only", "\(deskFeed.events.map(\.text)) \(deskFeed.problem ?? "")")
        }

        try await feed.rename(to: "Renamed group")
        let rooms = try await client.groupRooms()
        HermesLabApprovalTests.report(rooms.contains { $0.id == room.id && $0.name == "Renamed group" } && feed.room.name == "Renamed group",
                                      "the group chat is renamed")
        try await client.stopGroup(room.id)
        try await client.disbandGroup(room.id)
        let after = try await client.groupRooms()
        HermesLabApprovalTests.report(!after.contains { $0.id == room.id }, "an ended group chat leaves the list")
    }
}

/// The butler with the app's own conversation (lab.sh butler --app, after butler_check.py): a
/// message in an open Dashboard conversation makes the main profile hand a coding task to the
/// claude bot; when the card is done Hermes wakes the agent in that conversation itself, a turn
/// the app didn't start, and its question before applying the patch gets its card in the open
/// conversation at once; approved, the patch goes in.
@MainActor
struct HermesLabButlerTests {
    @Test func aQuestionInATurnTheHostStartsReachesTheOpenConversation() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        guard (try await client.bots()).bots.contains(where: { $0.name == "claude" }) else {
            print("LAB SKIP: not the butler lab (scripts/hermes-lab/lab.sh butler --app)")
            return
        }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-butler-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        settings.serveURL = "http://127.0.0.1:19119"
        let conversation = Conversation(settings: settings, store: .shared, transportOverride: HermesServeTransport(client: client))
        conversation.reset()
        _ = conversation.send("lab:butler tag=app Please add a line to hello.py.")
        for _ in 0 ..< 120 where conversation.isStreaming || !(conversation.messages.last?.text.contains("[queued]") ?? false) {
            try await Task.sleep(for: .milliseconds(500))
        }
        let queued = conversation.messages.last?.text ?? ""
        HermesLabApprovalTests.report(queued.contains("[queued]"), "the agent hands the task to the claude bot", queued)

        // The card is done by the claude bot, the agent woken in this conversation: nothing here
        // started that turn, and its question comes to the open conversation.
        for _ in 0 ..< 300 where conversation.pendingInterrupt == nil {
            try await Task.sleep(for: .milliseconds(500))
        }
        guard let pending = conversation.pendingInterrupt, case let .approval(request) = pending.interrupt else {
            HermesLabApprovalTests.report(false, "the turn the host starts asks in the open conversation", "no card in 150 s")
            return
        }
        HermesLabApprovalTests.report(conversation.isStreaming && "\(request.command) \(request.description ?? "")".contains("apply"),
                                      "the turn the host starts asks in the open conversation, and the app follows it",
                                      "\(request.command) \(request.description ?? "")")
        try await client.respondApproval(runtimeSession: pending.runtimeSession, requestID: request.id, choice: "once")
        for _ in 0 ..< 120 where conversation.isStreaming || !(conversation.messages.last?.text.contains("applied]") ?? false) {
            try await Task.sleep(for: .milliseconds(500))
        }
        let reply = conversation.messages.last?.text ?? ""
        HermesLabApprovalTests.report(reply.contains("[applied]") && !conversation.isStreaming, "approved from the card, the patch goes in", reply)
        if let stored = conversation.serverSessionID {
            for record in ConversationStore.shared.summaries where record.serverSessionID == stored { conversation.delete(id: record.id) }
        }
    }
}

import Foundation
import Testing
@testable import Echo

/// A question the watch asks through the phone (`WatchRelay`): the watch's end (`WatchRelayClient`)
/// wired straight to the phone's (`WatchRelayHost`), with a scripted Dashboard behind it. What is
/// left out is WatchConnectivity itself, which only a real watch and phone exercise.
@MainActor
struct WatchRelayTests {
    /// Plays its events, stopping after each `.interrupt` until `release()`. Each call to
    /// `stream` takes the next script; the last one repeats.
    final class Dashboard: HermesTransport, @unchecked Sendable {
        struct Script { var events: [TurnEvent] = []; var error: (any Error)?; var failsOnSession: String? }
        private let lock = NSLock()
        private var scripts: [Script]
        private var gate: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var requests: [TurnRequest] = []

        init(_ scripts: [Script]) { self.scripts = scripts }
        convenience init(_ events: [TurnEvent]) { self.init([Script(events: events)]) }

        func release() {
            lock.lock()
            let waiting = gate
            gate = nil
            released = waiting == nil
            lock.unlock()
            waiting?.resume()
        }

        private func hold() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released { released = false; lock.unlock(); continuation.resume(); return }
                gate = continuation
                lock.unlock()
            }
        }

        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            lock.lock()
            let script = scripts.count > 1 ? scripts.removeFirst() : scripts[0]
            requests.append(request)
            lock.unlock()
            return AsyncThrowingStream { continuation in
                let task = Task {
                    if let stale = script.failsOnSession, request.sessionID == stale {
                        return continuation.finish(throwing: Stale())
                    }
                    for event in script.events {
                        try await Task.sleep(for: .milliseconds(5))
                        continuation.yield(event)
                        if case .interrupt = event { await self.hold() }
                    }
                    continuation.finish(throwing: script.error)
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    struct Stale: Error {}
    struct Down: LocalizedError { var errorDescription: String? { "The Dashboard is down." } }

    /// The phone's end over a scripted Dashboard, the watch's end wired to it, and what the
    /// phone was asked to do on the way.
    final class Rig {
        let dashboard: Dashboard
        let settings: Settings
        let defaults: UserDefaults
        var approvals: [[String]] = []
        var answers: [[String]] = []
        var delivered: [WatchRelay.Snapshot] = []
        var named: [String] = []
        private(set) var host: WatchRelayHost!
        private(set) var watch: WatchRelayClient!

        @MainActor init(_ dashboard: Dashboard) {
            self.dashboard = dashboard
            defaults = UserDefaults(suiteName: "relay-\(UUID().uuidString)")!
            settings = Settings(defaults: defaults)
            let backend = WatchRelayHost.Backend(
                transport: { dashboard },
                respondApproval: { [unowned self] in approvals.append([$0, $1, $2]); dashboard.release() },
                respondClarify: { [unowned self] in answers.append([$0, $1, $2]); dashboard.release() },
                interrupt: { _ in },
                isStaleSession: { $0 is Stale },
                nameSession: { [unowned self] stored, _ in named.append(stored) })
            host = WatchRelayHost(backend: backend, settings: settings, defaults: defaults, deliver: { [unowned self] in delivered.append($0) })
            watch = WatchRelayClient(send: { [unowned self] in host.handle($0) }, pollEvery: .milliseconds(10))
        }
    }

    @Test func aQuestionAskedThroughThePhoneComesBackWhole() async throws {
        let rig = Rig(Dashboard([.sessionID("s1"), .textDelta("Two "), .textDelta("things."), .done]))
        var states: [WatchRelay.Snapshot.State] = []
        let reply = try await rig.watch.ask("What's on today?") { states.append($0.state) }
        #expect(reply.text == "Two things.")
        #expect(reply.state == .done)
        #expect(states.first == .working && states.last == .done)
        let asked = try #require(rig.dashboard.requests.first)
        #expect(asked.userText.hasPrefix("What's on today?"))
        #expect(asked.userText.contains("Apple Watch"), "the agent is told the reply will be read aloud")
        #expect(asked.sessionID == nil)
        #expect(rig.named == ["s1"], "a new session is named for the watch")
        #expect(rig.delivered.last?.state == .done, "the finished reply is also sent without being asked for")
    }

    @Test func theNextQuestionGoesIntoTheSameSession() async throws {
        let rig = Rig(Dashboard([.sessionID("s1"), .textDelta("Yes."), .done]))
        _ = try await rig.watch.ask("One?") { _ in }
        _ = try await rig.watch.ask("Two?") { _ in }
        #expect(rig.dashboard.requests.map(\.sessionID) == [nil, "s1"])
        #expect(rig.named == ["s1"], "named once, when it was made")
    }

    /// A session belongs to the server and profile it was made on.
    @Test func anotherServerStartsItsOwnSession() async throws {
        let rig = Rig(Dashboard([.sessionID("s2"), .textDelta("Yes."), .done]))
        rig.defaults.set("s1", forKey: "watch.relay.session")
        rig.defaults.set("some-other-server|", forKey: "watch.relay.connection")
        _ = try await rig.watch.ask("One?") { _ in }
        #expect(rig.dashboard.requests.first?.sessionID == nil)
    }

    @Test func aSessionDeletedOnTheServerIsReplaced() async throws {
        let rig = Rig(Dashboard([.init(failsOnSession: "gone"), .init(events: [.sessionID("s9"), .textDelta("Here."), .done])]))
        rig.defaults.set("gone", forKey: "watch.relay.session")
        rig.defaults.set(rig.settings.connectionKey, forKey: "watch.relay.connection")
        let reply = try await rig.watch.ask("Still there?") { _ in }
        #expect(reply.text == "Here.")
        #expect(rig.dashboard.requests.map(\.sessionID) == ["gone", nil])
        #expect(rig.defaults.string(forKey: "watch.relay.session") == "s9")
    }

    @Test func aCommandIsApprovedFromTheWrist() async throws {
        let request = ApprovalRequest(id: "req1", command: "rm -rf build", description: nil, choices: ["once", "session", "always", "deny"])
        let rig = Rig(Dashboard([.textDelta("Checking. "), .interrupt(.approval(request), runtimeSession: "rt1"), .textDelta("Removed."), .done]))
        var asked: WatchRelay.Approval?
        let watch = rig.watch!
        let reply = try await watch.ask("Clean up") { snapshot in
            guard snapshot.state == .approval, asked == nil, let approval = snapshot.approval else { return }
            asked = approval
            Task { try? await watch.approve(requestID: approval.id, choice: approval.approve) }
        }
        #expect(asked == .init(id: "req1", command: "rm -rf build", approve: "once", deny: "deny"))
        #expect(rig.approvals == [["rt1", "req1", "once"]])
        #expect(reply.text == "Checking. Removed.")
        #expect(reply.approval == nil)
    }

    @Test func theAgentsQuestionIsAnsweredFromTheWrist() async throws {
        let question = ClarifyQuestion(id: "", question: "Which calendar?", choices: ["Home", "Work"], multiSelect: false)
        let rig = Rig(Dashboard([.interrupt(.clarify(.init(id: "c1", questions: [question], isBatch: false)), runtimeSession: "rt2"),
                                 .textDelta("Added to Work."), .done]))
        var answered = false
        let watch = rig.watch!
        let reply = try await watch.ask("Add lunch") { snapshot in
            guard snapshot.state == .question, !answered, let asked = snapshot.question else { return }
            answered = true
            #expect(asked.text == "Which calendar?" && asked.choices == ["Home", "Work"])
            Task { try? await watch.answer(requestID: asked.id, text: "Work") }
        }
        #expect(rig.answers == [["rt2", "c1", "Work"]])
        #expect(reply.text == "Added to Work.")
    }

    /// A password isn't for the wrist: the watch is told where to go, and nothing is sent.
    @Test func aPasswordWaitsForThePhone() async throws {
        let rig = Rig(Dashboard([.interrupt(.sudo(id: "pw1"), runtimeSession: "rt3"), .done]))
        let asking = rig.host.handle(.init(op: .ask, id: "q1", text: "Update the server"))
        #expect(asking.state == .working)
        var snapshot = asking
        for _ in 0 ..< 100 where snapshot.state == .working {
            try await Task.sleep(for: .milliseconds(10))
            snapshot = rig.host.handle(.init(op: .poll, id: "q1"))
        }
        #expect(snapshot.state == .waiting)
        #expect(snapshot.note?.contains("sudo") == true)
        #expect(rig.host.handle(.init(op: .approve, id: "q1", requestID: "pw1", choice: "once")).state == .waiting, "there is nothing to approve")
        _ = rig.host.handle(.init(op: .stop, id: "q1"))
        #expect(rig.host.handle(.init(op: .poll, id: "q1")).state == .failed, "a stopped question is gone")
    }

    @Test func aFailureOnThePhoneReachesTheWristInWords() async {
        let rig = Rig(Dashboard([.init(events: [.textDelta("Let me ")], error: Down())]))
        await #expect(throws: WatchRelay.Failure.phone("The Dashboard is down.")) {
            _ = try await rig.watch.ask("Anything?") { _ in }
        }
        #expect(rig.delivered.last?.state == .failed)
    }

    /// The phone went out of range, or its app couldn't be woken.
    @Test func aPhoneThatStopsAnsweringIsOutOfReach() async {
        struct Unreachable: Error {}
        let silent = WatchRelayClient(send: { _ in throw Unreachable() }, pollEvery: .milliseconds(5), patience: 2)
        await #expect(throws: WatchRelay.Failure.phoneOutOfReach) { _ = try await silent.ask("Hello?") { _ in } }

        // It took the question, then went quiet: a few missed polls are forgiven, not all of them.
        var calls = 0
        let fading = WatchRelayClient(send: { request in
            calls += 1
            if request.op == .ask { return .init(id: request.id, state: .working) }
            throw Unreachable()
        }, pollEvery: .milliseconds(5), patience: 3)
        await #expect(throws: WatchRelay.Failure.phoneOutOfReach) { _ = try await fading.ask("Hello?") { _ in } }
        #expect(calls == 4, "one ask and three polls")
    }

    /// The phone's app was restarted mid-question, so it no longer knows it.
    @Test func aQuestionThePhoneLostTrackOfSaysSo() {
        let rig = Rig(Dashboard([.done]))
        let snapshot = rig.host.handle(.init(op: .poll, id: "never-asked"))
        #expect(snapshot.state == .failed)
        #expect(snapshot.note?.contains("Ask again") == true)
    }

    /// A finished reply the phone sent on its own ends the wait even when polls aren't getting through.
    @Test func aDeliveredReplyEndsTheWait() async throws {
        struct Unreachable: Error {}
        var client: WatchRelayClient!
        var polls = 0
        client = WatchRelayClient(send: { request in
            if request.op == .ask { return .init(id: request.id, state: .working) }
            polls += 1
            if polls == 1 { client.deliver(.init(id: request.id, state: .done, text: "Late but whole.")) }
            throw Unreachable()
        }, pollEvery: .milliseconds(5), patience: 5)
        let reply = try await client.ask("Hello?") { _ in }
        #expect(reply.text == "Late but whole.")
    }

    @Test func messagesSurviveTheTrip() {
        let request = WatchRelay.Request(op: .approve, id: "q1", requestID: "req1", choice: "once")
        #expect(WatchRelay.decode(WatchRelay.Request.self, from: WatchRelay.message(request)) == request)
        var snapshot = WatchRelay.Snapshot(id: "q1", state: .approval, text: "So far")
        snapshot.approval = .init(id: "req1", command: "ls", approve: "once", deny: "deny")
        #expect(WatchRelay.decode(WatchRelay.Snapshot.self, from: WatchRelay.message(snapshot)) == snapshot)
        #expect(WatchRelay.decode(WatchRelay.Request.self, from: ["sync": true]) == nil, "the watch's other message isn't mistaken for one")
    }
}

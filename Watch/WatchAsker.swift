import Foundation
import os

/// One question's trip to Hermes and back, through the same transports the phone uses. The
/// Hermes API keeps the watch's questions in one session of their own; the fast lane gets the
/// store's short history, since it keeps none. A phone that has only the Dashboard is asked to
/// ask instead (`WatchRelay`).
///
/// A command the agent wants a yes or no for is answered here, on either road: over the Hermes
/// API directly, or through the phone.
@MainActor
final class WatchAsker {
    private let connection: WatchConnection
    private unowned let store: WatchStore
    private let log = Logger(subsystem: "com.goosehouse.echo.watch", category: "ask")
    private var task: Task<Void, Never>?
    /// The question's trip through the phone, when that is the road.
    private var relay: WatchRelayClient?
    /// Hermes API: the run that is waiting on an approval.
    private var waitingRun: String?

    init(connection: WatchConnection, store: WatchStore) {
        self.connection = connection
        self.store = store
    }

    func ask(_ text: String) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await run(text)
                store.finished(error: nil)
            } catch is CancellationError {
            } catch {
                log.error("ask failed: \(error.localizedDescription, privacy: .public)")
                store.finished(error: error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        relay?.stop()
    }

    /// The wrist's yes or no to the command that is waiting.
    func answer(_ approval: WatchRelay.Approval, choice: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let relay {
                    try await relay.approve(requestID: approval.id, choice: choice)
                } else if let run = waitingRun, let base = URL(string: connection.url) {
                    try await HermesSessionsAPI(baseURL: base, apiKey: connection.apiKey)
                        .respondApproval(runID: run, requestID: approval.id, choice: choice)
                }
            } catch {
                failed(error)
            }
        }
    }

    /// The wrist's answer to the agent's question (asked through the phone).
    func answer(_ question: WatchRelay.Question, text: String) {
        Task { [weak self] in
            guard let self, let relay else { return }
            do { try await relay.answer(requestID: question.id, text: text) } catch { failed(error) }
        }
    }

    func relayDelivered(_ snapshot: WatchRelay.Snapshot) { relay?.deliver(snapshot) }

    /// An answer that couldn't be sent ends the question, with the reason.
    private func failed(_ error: Error) {
        log.error("answer failed: \(error.localizedDescription, privacy: .public)")
        task?.cancel()
        store.finished(error: error.localizedDescription)
    }

    private func run(_ text: String) async throws {
        if connection.kind == .phone { return try await askThroughPhone(text) }
        guard let base = URL(string: connection.url) else { throw TransportError.badURL }
        let transport: any HermesTransport
        var request = TurnRequest(userText: text, history: [], sessionID: nil,
                                  model: connection.model.nilIfEmpty, provider: connection.provider.nilIfEmpty,
                                  reasoningEffort: connection.reasoningEffort.nilIfEmpty, instructions: nil,
                                  replyLanguage: connection.replyLanguage.nilIfEmpty)
        switch connection.kind {
        case .hermesAPI:
            let api = HermesSessionsAPI(baseURL: base, apiKey: connection.apiKey)
            if store.sessionID == nil {
                let title = "Apple Watch · \(Date.now.formatted(date: .abbreviated, time: .omitted))"
                store.sessionID = try await api.createSession(title: title, model: request.model, provider: request.provider,
                                                              reasoningEffort: request.reasoningEffort).id
            }
            request.sessionID = store.sessionID
            request.instructions = WatchConnection.spokenHint
            transport = HermesSessionsTransport(baseURL: base, apiKey: connection.apiKey)
        case .fastLane:
            request.history = store.history
            request.instructions = WatchConnection.spokenHint
            transport = ChatCompletionsTransport(baseURL: base, apiKey: connection.apiKey.nilIfEmpty)
        case .dashboard, .phone:
            // The Dashboard is never kept (`WatchStore.apply`): it is a WebSocket, which a watch
            // can't open. Through the phone is handled above.
            throw TransportError.badURL
        }
        do {
            try await stream(transport, request)
        } catch let TransportError.http(status, _) where status == 404 && connection.kind == .hermesAPI && store.sessionID != nil {
            // The watch's session was deleted on the gateway: start another and ask again.
            store.sessionID = nil
            try await run(text)
        }
    }

    private func stream(_ transport: any HermesTransport, _ request: TurnRequest) async throws {
        for try await event in transport.stream(request) {
            try Task.checkCancellation()
            switch event {
            case let .sessionID(id): store.sessionID = id
            case let .textDelta(delta): store.working(); store.append(delta)
            case let .textFinal(text): store.replace(text)
            case let .interrupt(interrupt, runtime):
                switch interrupt {
                case let .approval(r):
                    if let choices = r.yesNo {
                        waitingRun = runtime
                        store.needsApproval(.init(id: r.id, command: r.command, approve: choices.approve, deny: choices.deny))
                    } else {
                        store.waiting("Approval needed on your iPhone: \(r.command)")
                    }
                case let .clarify(r): store.waiting(r.questions.first?.question ?? "A question is waiting on your iPhone.")
                case .sudo: store.waiting("Your iPhone is asking for the sudo password.")
                case let .secret(r): store.waiting("Your iPhone is asking for \(r.envVar).")
                }
            case .interruptExpired: store.working()
            default: break
            }
        }
    }

    /// The phone has only the Dashboard, which a watch can't use: it runs the question, and the
    /// watch follows it by asking how far it has got.
    private func askThroughPhone(_ text: String) async throws {
        let relay = WatchRelayClient(send: { try await PhoneLink.shared.relay($0) })
        self.relay = relay
        let store = store
        _ = try await relay.ask(text) { snapshot in
            store.replace(snapshot.text)
            switch snapshot.state {
            case .working, .done, .failed: store.working()
            case .approval: if let approval = snapshot.approval { store.needsApproval(approval) }
            case .question: if let question = snapshot.question { store.asked(question) }
            case .waiting: store.waiting(snapshot.note ?? "Something is waiting on your iPhone.")
            }
        }
    }
}

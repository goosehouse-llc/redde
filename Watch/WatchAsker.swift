import Foundation
import os

/// One question's trip to Hermes and back, through the same transports the phone uses. The
/// Hermes API keeps the watch's questions in one session of their own; the fast lane gets the
/// store's short history, since it keeps none.
@MainActor
final class WatchAsker {
    private let connection: WatchConnection
    private unowned let store: WatchStore
    private let log = Logger(subsystem: "com.goosehouse.echo.watch", category: "ask")
    private var task: Task<Void, Never>?

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
    }

    private func run(_ text: String) async throws {
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
            request.instructions = Self.watchHint
            transport = HermesSessionsTransport(baseURL: base, apiKey: connection.apiKey)
        case .fastLane:
            request.history = store.history
            request.instructions = Self.watchHint
            transport = ChatCompletionsTransport(baseURL: base, apiKey: connection.apiKey.nilIfEmpty)
        case .dashboard:
            guard let client = store.dashboardClient() else { throw TransportError.badURL }
            // prompt.submit takes no instructions: the hint rides on the message.
            request.userText = text + "\n\n(" + Self.watchHint + ")"
            request.sessionID = store.sessionID
            transport = HermesServeTransport(client: client)
        }
        do {
            try await stream(transport, request)
        } catch let TransportError.http(status, _) where status == 404 && connection.kind == .hermesAPI && store.sessionID != nil {
            // The watch's session was deleted on the gateway: start another and ask again.
            store.sessionID = nil
            try await run(text)
        } catch is HermesServeClient.RPCError where connection.kind == .dashboard && store.sessionID != nil {
            // Same on the Dashboard: a stored session it can't resume.
            store.sessionID = nil
            try await run(text)
        }
    }

    private func stream(_ transport: any HermesTransport, _ request: TurnRequest) async throws {
        for try await event in transport.stream(request) {
            try Task.checkCancellation()
            switch event {
            case let .sessionID(id): store.sessionID = id
            case let .textDelta(delta): store.append(delta)
            case let .textFinal(text): store.replace(text)
            case let .interrupt(interrupt, _):
                switch interrupt {
                case let .approval(r): store.waiting("Approval needed on your iPhone: \(r.command)")
                case let .clarify(r): store.waiting(r.questions.first?.question ?? "A question is waiting on your iPhone.")
                case .sudo: store.waiting("Your iPhone is asking for the sudo password.")
                case let .secret(r): store.waiting("Your iPhone is asking for \(r.envVar).")
                }
            default: break
            }
        }
    }

    /// Replies are read aloud on a watch, so the agent is told to keep them short and plain.
    private static let watchHint = """
        The user is on an Apple Watch and will hear your reply read aloud. Answer in a few plain \
        sentences, no Markdown, lists, tables or code; if a longer answer is needed, give the \
        gist and say the rest is on their phone.
        """
}

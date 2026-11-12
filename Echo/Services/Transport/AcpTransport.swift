import Foundation
import os

/// One turn with an ACP agent (`AcpClient`): makes the session on the first message, picks the
/// model, sends the prompt, and maps its `session/update`s to `TurnEvent`s until the agent answers
/// the prompt. Through the Redde bridge a turn outlives the socket: when the link drops, it
/// reconnects, attaches (`_redde/attach`) and carries on from the last update it heard, or
/// finishes the reply from the bridge's copy when the turn ended meanwhile. See docs/acp.md.
nonisolated struct AcpTransport: HermesTransport {
    let endpoint: AcpEndpoint

    /// What one turn has heard.
    @MainActor
    final class Turn {
        let session: String
        var mapper = AcpTurnMapper()
        var lastSeq = 0
        var ended = false
        var stopReason: String?
        init(session: String) { self.session = session }

        /// An update, unless it was already heard (a catch-up repeats what came before the drop).
        func take(_ update: JSONValue, seq: Int?) -> [TurnEvent] {
            if let seq {
                guard seq > lastSeq else { return [] }
                lastSeq = seq
            }
            return mapper.events(for: update)
        }
    }

    func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        let endpoint = endpoint
        let sessionBox = OSAllocatedUnfairLock<String?>(initialState: request.sessionID)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let client = AcpClient.client(for: endpoint)
                var listener: UUID?
                defer { if let listener { client.removeListener(listener) } }
                do {
                    try await client.ensureConnected()
                    let session: String
                    if let known = request.sessionID {
                        session = known
                    } else {
                        session = try await client.newSession(instructions: Self.instructions(request))
                        sessionBox.withLock { $0 = session }
                    }
                    continuation.yield(.sessionID(session))
                    if let model = request.model?.nilIfEmpty { try? await client.setModel(session, value: model) }

                    let turn = Turn(session: session)
                    let ended = AsyncStream<Void>.makeStream()
                    listener = client.addListener { event in
                        Self.hear(event, turn: turn, continuation: continuation, ended: ended.continuation)
                    }
                    let blocks = try Self.prompt(request, images: client.info?.takesImages ?? false)
                    do {
                        let result = try await client.prompt(session, blocks: blocks)
                        if let usage = turn.mapper.usage(fromPromptResult: result) { continuation.yield(usage) }
                        turn.stopReason = result["stopReason"]?.string
                        turn.ended = true
                    } catch let error where Self.isDrop(error) {
                        // The bridge has the turn; the phone lost the link. Catch up, then wait for its end.
                        guard try await Self.recover(turn, client: client, continuation: continuation) else {
                            throw TransportError.streamLost(error.localizedDescription)
                        }
                        if !turn.ended { for await _ in ended.stream { break } }
                    }
                    try Task.checkCancellation()
                    if let note = AcpTurnMapper.stopNote(turn.stopReason) { continuation.yield(.status(note)) }
                    continuation.yield(.done)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                // Stop stops the agent; leaving for another chat lets it finish (the bridge keeps it).
                guard case .cancelled = reason, request.departure?.hasLeft != true,
                      let session = sessionBox.withLock({ $0 }) else { return }
                Task { @MainActor in AcpClient.client(for: endpoint).cancel(session) }
            }
        }
    }

    @MainActor
    private static func hear(_ event: AcpClient.Event, turn: Turn,
                             continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation,
                             ended: AsyncStream<Void>.Continuation) {
        switch event {
        case let .update(session, update, seq) where session == turn.session:
            for event in turn.take(update, seq: seq) { continuation.yield(event) }
        case let .request(_, session, interrupt) where session == turn.session || session == nil:
            continuation.yield(.interrupt(interrupt, runtimeSession: turn.session))
        case let .resolved(id):
            continuation.yield(.interruptExpired(id: id))
        case let .turnEnded(session, stopReason) where session == turn.session:
            turn.ended = true
            turn.stopReason = turn.stopReason ?? stopReason
            ended.yield()
        default:
            break
        }
    }

    /// After a drop: reconnect for up to a minute and a half, then take what the bridge kept of the
    /// turn. False when there's no bridge to ask (a server that speaks ACP itself keeps nothing).
    @MainActor
    private static func recover(_ turn: Turn, client: AcpClient,
                                continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation) async throws -> Bool {
        let deadline = Date.now.addingTimeInterval(90)
        while true {
            try Task.checkCancellation()
            do {
                try await client.ensureConnected()
                guard let state = try await client.attach(turn.session) else { return false }
                for (update, seq) in state.updates {
                    for event in turn.take(update, seq: seq) { continuation.yield(event) }
                }
                for (_, interrupt) in state.requests {
                    continuation.yield(.interrupt(interrupt, runtimeSession: turn.session))
                }
                if !state.running {
                    turn.ended = true
                    turn.stopReason = state.stopReason
                }
                return true
            } catch let error where isDrop(error) && Date.now < deadline {
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    nonisolated static func isDrop(_ error: Error) -> Bool {
        if case TransportError.streamLost = error { return true }
        if case TransportError.unreachable = error { return true }
        return NetworkFailure.isConnectivity(error)
    }

    /// For a session's start, where the agent takes a system prompt of the client's: the person's
    /// own instructions and reply language. Nothing is added to the messages themselves: they are
    /// the agent's history, shown again whenever the chat is opened.
    nonisolated static func instructions(_ request: TurnRequest) -> String? {
        let parts = [request.instructions?.nilIfEmpty, request.replyLanguage.map(ReplyLanguage.instruction),
                     request.units.map(MeasureUnits.instruction)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The message as ACP content: its text, text files inline, pictures where the agent takes them.
    nonisolated static func prompt(_ request: TurnRequest, images: Bool) throws -> [JSONValue] {
        var text = PageTurn.text(of: request)
        var pictures: [JSONValue] = []
        for attachment in request.attachments {
            switch attachment.kind {
            case .image where images:
                pictures.append(.object(["type": .string("image"), "mimeType": .string(attachment.mimeType),
                                         "data": .string(attachment.data.base64EncodedString())]))
            case .text:
                if let addendum = attachment.promptAddendum { text += "\n\n" + addendum }
            default:
                let kind = attachment.kind == .image ? String(localized: "Image", comment: "As in \"Image attachments aren't supported on …\"")
                    : attachment.kind == .pdf ? "PDF"
                    : attachment.isVideo ? String(localized: "Video", comment: "As in \"Video attachments aren't supported on …\"")
                    : String(localized: "File", comment: "As in \"File attachments aren't supported on …\"")
                throw AttachmentError.unsupported(kind, transport: String(localized: "this agent", comment: "As in \"… aren't supported on this agent\""))
            }
        }
        return [.object(["type": .string("text"), "text": .string(text)])] + pictures
    }

    // MARK: Joining a turn

    /// The turn under way in a session the app isn't following (it was closed while the agent
    /// worked, or another device asked): through the bridge only.
    func rejoin(stored: String) async throws -> RejoinedTurn? {
        let endpoint = endpoint
        guard let state = try await AcpClient.client(for: endpoint).attach(stored), state.running else { return nil }
        let events = AsyncThrowingStream<TurnEvent, Error> { continuation in
            let task = Task { @MainActor in
                let client = AcpClient.client(for: endpoint)
                let turn = Turn(session: stored)
                let ended = AsyncStream<Void>.makeStream()
                let listener = client.addListener { event in
                    Self.hear(event, turn: turn, continuation: continuation, ended: ended.continuation)
                }
                defer { client.removeListener(listener) }
                continuation.yield(.sessionID(stored))
                for (update, seq) in state.updates {
                    for event in turn.take(update, seq: seq) { continuation.yield(event) }
                }
                for (_, interrupt) in state.requests {
                    continuation.yield(.interrupt(interrupt, runtimeSession: stored))
                }
                // It may have ended between the attach and the listener.
                if let again = try? await client.attach(stored) {
                    for (update, seq) in again.updates {
                        for event in turn.take(update, seq: seq) { continuation.yield(event) }
                    }
                    if !again.running { turn.ended = true }
                }
                if !turn.ended { for await _ in ended.stream { break } }
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return RejoinedTurn(question: state.prompt, events: events,
                            stop: { Task { @MainActor in AcpClient.client(for: endpoint).cancel(stored) } },
                            transcript: { @MainActor in AcpHistory.messages(try await AcpClient.client(for: endpoint).load(stored)) })
    }
}

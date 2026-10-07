import Foundation

/// A question the watch asks through the iPhone.
///
/// The Hermes Dashboard runs over a WebSocket, which a watch app may not open (see
/// `WatchConnection`). A phone that reaches its agent only that way is handed over as
/// `WatchConnection.Kind.phone`, and the watch's question travels to the phone over
/// WatchConnectivity instead: the phone runs the turn (`WatchRelayHost`) and the watch follows it
/// by asking, every second or two, for where it has got to. Asking is what keeps the phone's app
/// awake in the background, and an answer is whole each time, so a lost one costs nothing.
///
/// Everything crosses as a property-list dictionary with one key, JSON inside a `Data` value.
nonisolated enum WatchRelay {
    /// The dictionary key a request or a snapshot travels under.
    static let key = "relay"

    struct Request: Codable, Equatable, Sendable {
        enum Op: String, Codable, Sendable {
            /// Start on `text`.
            case ask
            /// Where has it got to?
            case poll
            /// Answer the command waiting for a yes or no (`requestID`, `choice`).
            case approve
            /// Answer the agent's question (`requestID`, `text`).
            case answer
            /// Give up on it.
            case stop
        }

        var op: Op
        /// The question this is about; the watch makes one up for each.
        var id: String
        var text: String?
        var requestID: String?
        var choice: String?
    }

    /// The turn as it stands, whole: a later one replaces an earlier one.
    struct Snapshot: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            case working
            /// Stopped for a yes or no: `approval`.
            case approval
            /// Stopped for an answer the watch can give: `question`.
            case question
            /// Stopped for something only the phone can give (`note` says what).
            case waiting
            case done
            /// `note` says why.
            case failed
        }

        var id: String
        var state: State
        /// The reply so far.
        var text = ""
        var note: String?
        var approval: Approval?
        var question: Question?
    }

    /// A command waiting for a yes or no, and what the two buttons answer with.
    struct Approval: Codable, Equatable, Sendable {
        var id: String
        var command: String
        var approve: String
        var deny: String
    }

    /// One question from the agent, with the answers it suggests, if any.
    struct Question: Codable, Equatable, Sendable {
        var id: String
        var text: String
        var choices: [String]
    }

    static func message<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value) else { return [:] }
        return [key: data]
    }

    static func decode<T: Decodable>(_ type: T.Type, from message: [String: Any]) -> T? {
        guard let data = message[key] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// What went wrong, in words for the wrist.
    enum Failure: LocalizedError, Equatable {
        /// The phone isn't answering: out of range, or its app can't be woken.
        case phoneOutOfReach
        /// The phone ran into something: its own words.
        case phone(String)

        var errorDescription: String? {
            switch self {
            case .phoneOutOfReach:
                "Couldn't reach your iPhone, which asks for the watch while Redde is on the Dashboard. Add the Hermes API there (Settings › Connection details) and the watch asks on its own."
            case let .phone(reason): reason
            }
        }
    }
}

/// The watch's end of a relayed question: asks, then follows the turn by polling until it is
/// done. Here, not in the watch target, so the phone's tests can run it against the phone's end.
@MainActor
final class WatchRelayClient {
    typealias Send = (WatchRelay.Request) async throws -> WatchRelay.Snapshot

    private let send: Send
    private let pollEvery: Duration
    /// Polls in a row that may fail before the phone counts as gone: a wrist turned away for a
    /// moment is not the end of the question.
    private let patience: Int
    private var id = ""
    private var onUpdate: (WatchRelay.Snapshot) -> Void = { _ in }
    /// The finished turn as the phone delivered it of its own accord (it queues one in case
    /// nobody is asking any more): taken up by the loop in place of a poll.
    private var handed: WatchRelay.Snapshot?

    init(send: @escaping Send, pollEvery: Duration = .milliseconds(1500), patience: Int = 6) {
        self.send = send
        self.pollEvery = pollEvery
        self.patience = patience
    }

    /// Asks, and returns the finished reply. `onUpdate` sees every state on the way, the last
    /// included. Throws `WatchRelay.Failure`, or `CancellationError` when stopped.
    func ask(_ text: String, onUpdate: @escaping (WatchRelay.Snapshot) -> Void) async throws -> WatchRelay.Snapshot {
        id = UUID().uuidString
        self.onUpdate = onUpdate
        handed = nil
        var snapshot: WatchRelay.Snapshot
        do {
            snapshot = try await send(.init(op: .ask, id: id, text: text))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WatchRelay.Failure.phoneOutOfReach
        }
        var misses = 0
        while true {
            try Task.checkCancellation()
            if let handed, handed.id == id { snapshot = handed }
            handed = nil
            onUpdate(snapshot)
            switch snapshot.state {
            case .done: return snapshot
            case .failed: throw WatchRelay.Failure.phone(snapshot.note ?? "Your iPhone couldn't get an answer.")
            default: break
            }
            try await Task.sleep(for: pollEvery)
            do {
                snapshot = try await send(.init(op: .poll, id: id))
                misses = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                misses += 1
                if misses >= patience { throw WatchRelay.Failure.phoneOutOfReach }
            }
        }
    }

    /// Answers the command that is waiting. The phone's reply is the turn moving on.
    func approve(requestID: String, choice: String) async throws {
        onUpdate(try await send(.init(op: .approve, id: id, requestID: requestID, choice: choice)))
    }

    /// Answers the agent's question.
    func answer(requestID: String, text: String) async throws {
        onUpdate(try await send(.init(op: .answer, id: id, text: text, requestID: requestID)))
    }

    /// Tells the phone to give up on it. Best effort: the watch has already moved on.
    func stop() {
        let (send, id) = (send, id)
        guard !id.isEmpty else { return }
        Task { _ = try? await send(.init(op: .stop, id: id)) }
    }

    /// The phone's own delivery of a turn (it sends the finished one in case nobody was asking).
    func deliver(_ snapshot: WatchRelay.Snapshot) {
        guard snapshot.id == id else { return }
        handed = snapshot
    }
}

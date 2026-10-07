import Foundation
import UIKit
import os

/// The phone's end of a question the watch asks through it (`WatchRelay`): runs the turn on the
/// Dashboard, in a session of the watch's own, and answers the watch's "where has it got to?"
/// with the turn as it stands. One question at a time, as the watch asks them.
///
/// Nothing of it shows on the phone: it isn't the conversation that is open there. What the
/// agent stops for goes to the wrist instead. A yes or no and a single question can be answered
/// there; a password can't, and the watch says to open the conversation on the phone.
///
/// The phone's app is usually in the background, woken by the watch's message. Each poll is
/// another message, which is what keeps it awake; a background task covers the gaps.
@MainActor
final class WatchRelayHost {
    static let shared = WatchRelayHost()

    /// How a turn is run and how the things it stops for are answered: the Dashboard in the
    /// app, a script in tests.
    struct Backend {
        var transport: () -> any HermesTransport
        var respondApproval: (_ runtime: String, _ requestID: String, _ choice: String) async throws -> Void
        var respondClarify: (_ runtime: String, _ requestID: String, _ answer: String) async throws -> Void
        var interrupt: (_ runtime: String) -> Void
        /// The stored session couldn't be reopened (deleted on the server): ask in a new one.
        var isStaleSession: (Error) -> Bool
        /// A new session is named after where it came from.
        var nameSession: (_ stored: String, _ title: String) async -> Void

        static var dashboard: Backend {
            Backend(transport: { HermesServeTransport() },
                    respondApproval: { try await HermesServeClient.shared.respondApproval(runtimeSession: $0, requestID: $1, choice: $2) },
                    respondClarify: { try await HermesServeClient.shared.respondClarify(runtimeSession: $0, requestID: $1, questionID: nil, answer: $2) },
                    interrupt: { HermesServeClient.shared.interrupt(runtimeSession: $0) },
                    isStaleSession: { $0 is HermesServeClient.RPCError },
                    nameSession: { try? await HermesServeClient.shared.updateSession(stored: $0, title: $1) })
        }
    }

    private final class Turn {
        let id: String
        var snapshot: WatchRelay.Snapshot
        var task: Task<Void, Never>?
        /// The Dashboard's runtime session, once the turn has stopped for something.
        var runtime: String?
        init(id: String) {
            self.id = id
            snapshot = .init(id: id, state: .working)
        }
    }

    private let log = Logger(subsystem: "com.goosehouse.echo", category: "watch")
    private let backend: Backend
    private let settings: Settings
    private let defaults: UserDefaults
    /// Hands a finished turn to the watch of the phone's own accord, in case it stopped asking.
    private let deliver: (WatchRelay.Snapshot) -> Void
    private var current: Turn?
    private var background: UIBackgroundTaskIdentifier = .invalid

    private static let sessionKey = "watch.relay.session"
    private static let sessionOwnerKey = "watch.relay.connection"

    init(backend: Backend = .dashboard, settings: Settings = .shared, defaults: UserDefaults = .standard,
         deliver: @escaping (WatchRelay.Snapshot) -> Void = { WatchLink.shared.deliver($0) }) {
        self.backend = backend
        self.settings = settings
        self.defaults = defaults
        self.deliver = deliver
    }

    /// The watch's Dashboard session for the server and profile in use; a different one starts over.
    private var storedSession: String? {
        get { defaults.string(forKey: Self.sessionOwnerKey) == settings.connectionKey ? defaults.string(forKey: Self.sessionKey) : nil }
        set {
            defaults.set(newValue, forKey: Self.sessionKey)
            defaults.set(newValue == nil ? nil : settings.connectionKey, forKey: Self.sessionOwnerKey)
        }
    }

    /// One message from the watch; the reply is the turn as it now stands.
    func handle(_ request: WatchRelay.Request) -> WatchRelay.Snapshot {
        switch request.op {
        case .ask:
            return start(id: request.id, text: request.text ?? "")
        case .poll:
            guard let turn = current, turn.id == request.id else { return Self.lost(request.id) }
            if turn.snapshot.state != .done, turn.snapshot.state != .failed { keepAwake() }
            return turn.snapshot
        case .approve:
            guard let turn = current, turn.id == request.id else { return Self.lost(request.id) }
            guard let approval = turn.snapshot.approval, approval.id == request.requestID,
                  let runtime = turn.runtime, let choice = request.choice else { return turn.snapshot }
            resume(turn)
            respond(turn) { try await self.backend.respondApproval(runtime, approval.id, choice) }
            return turn.snapshot
        case .answer:
            guard let turn = current, turn.id == request.id else { return Self.lost(request.id) }
            guard let question = turn.snapshot.question, question.id == request.requestID,
                  let runtime = turn.runtime, let answer = request.text, !answer.isEmpty else { return turn.snapshot }
            resume(turn)
            respond(turn) { try await self.backend.respondClarify(runtime, question.id, answer) }
            return turn.snapshot
        case .stop:
            guard let turn = current, turn.id == request.id else { return Self.lost(request.id) }
            turn.task?.cancel()
            if let runtime = turn.runtime { backend.interrupt(runtime) }
            current = nil
            endBackground()
            return turn.snapshot
        }
    }

    /// The phone's app was restarted since, or another question took this one's place.
    private static func lost(_ id: String) -> WatchRelay.Snapshot {
        .init(id: id, state: .failed, note: "Your iPhone lost track of that question. Ask again.")
    }

    // MARK: - The turn

    private func start(id: String, text: String) -> WatchRelay.Snapshot {
        if let previous = current {
            previous.task?.cancel()
            if let runtime = previous.runtime { backend.interrupt(runtime) }
        }
        let turn = Turn(id: id)
        current = turn
        keepAwake()
        turn.task = Task { [weak self] in await self?.run(turn, text: text) }
        return turn.snapshot
    }

    private func run(_ turn: Turn, text: String) async {
        // The Dashboard's prompt takes no instructions: the hint rides on the message.
        var request = TurnRequest(userText: text + "\n\n(" + WatchConnection.spokenHint + ")", history: [],
                                  sessionID: storedSession,
                                  model: settings.gatewayModel.nilIfEmpty, provider: settings.gatewayProvider.nilIfEmpty,
                                  reasoningEffort: settings.reasoningEffort.nilIfEmpty, instructions: nil,
                                  replyLanguage: settings.replyLanguage.nilIfEmpty)
        let isNew = request.sessionID == nil
        do {
            do {
                try await stream(turn, request)
            } catch where request.sessionID != nil && turn.snapshot.text.isEmpty && backend.isStaleSession(error) {
                storedSession = nil
                request.sessionID = nil
                try await stream(turn, request)
            }
            try Task.checkCancellation()   // a cancelled stream ends quietly; that is not a reply
            guard current === turn else { return }
            turn.snapshot.state = .done
            turn.snapshot.approval = nil
            turn.snapshot.question = nil
            turn.snapshot.note = nil
            if isNew || request.sessionID == nil, let stored = storedSession {
                await backend.nameSession(stored, "Apple Watch · \(Date.now.formatted(date: .abbreviated, time: .omitted))")
            }
        } catch is CancellationError {
            return
        } catch {
            guard current === turn else { return }
            log.error("watch relay failed: \(error.localizedDescription, privacy: .public)")
            turn.snapshot.state = .failed
            turn.snapshot.note = Self.explain(error)
        }
        deliver(turn.snapshot)
        endBackground()
    }

    private func stream(_ turn: Turn, _ request: TurnRequest) async throws {
        for try await event in backend.transport().stream(request) {
            try Task.checkCancellation()
            guard current === turn else { throw CancellationError() }
            switch event {
            case let .sessionID(id):
                storedSession = id
            case let .textDelta(delta):
                turn.snapshot.text += delta
            case let .textFinal(text):
                turn.snapshot.text = text
            case let .interrupt(interrupt, runtime):
                turn.runtime = runtime
                stop(turn, for: interrupt)
            case let .interruptExpired(id):
                if turn.snapshot.approval?.id == id || turn.snapshot.question?.id == id { resume(turn) }
            default:
                break
            }
        }
    }

    /// The agent is waiting: for something the wrist can give, or for the phone.
    private func stop(_ turn: Turn, for interrupt: Interrupt) {
        turn.snapshot.approval = nil
        turn.snapshot.question = nil
        turn.snapshot.note = nil
        switch interrupt {
        case let .approval(request):
            if let choices = request.yesNo {
                turn.snapshot.state = .approval
                turn.snapshot.approval = .init(id: request.id, command: String(request.command.prefix(300)),
                                               approve: choices.approve, deny: choices.deny)
            } else {
                wait(turn, "An approval is waiting. Open the Apple Watch conversation in Redde on your iPhone.")
            }
        case let .clarify(request):
            if !request.isBatch, request.questions.count == 1, let question = request.questions.first, !question.multiSelect {
                turn.snapshot.state = .question
                turn.snapshot.question = .init(id: request.id, text: question.question, choices: Array(question.choices.prefix(4)))
            } else {
                wait(turn, "The agent has questions. Open the Apple Watch conversation in Redde on your iPhone.")
            }
        case .sudo:
            wait(turn, "The agent is asking for the sudo password. Open the Apple Watch conversation in Redde on your iPhone.")
        case let .secret(request):
            wait(turn, "The agent is asking for \(request.envVar). Open the Apple Watch conversation in Redde on your iPhone.")
        }
    }

    private func wait(_ turn: Turn, _ note: String) {
        turn.snapshot.state = .waiting
        turn.snapshot.note = note
    }

    /// Answered or timed out: the turn is working again.
    private func resume(_ turn: Turn) {
        turn.snapshot.state = .working
        turn.snapshot.approval = nil
        turn.snapshot.question = nil
        turn.snapshot.note = nil
    }

    /// Sends an answer; one that can't be sent ends the turn with the reason.
    private func respond(_ turn: Turn, _ send: @escaping () async throws -> Void) {
        Task { [weak self] in
            do {
                try await send()
            } catch {
                guard let self, self.current === turn else { return }
                turn.task?.cancel()
                turn.snapshot.state = .failed
                turn.snapshot.note = Self.explain(error)
                self.deliver(turn.snapshot)
            }
        }
    }

    /// Saved passwords can't be read while the phone is locked (unless this run of the app read
    /// them before), which is the usual state of a phone whose watch is being talked to.
    private static func explain(_ error: Error) -> String {
        if !UIApplication.shared.isProtectedDataAvailable {
            return "Your iPhone couldn't sign in to the Dashboard while locked. Unlock it once and ask again."
        }
        return error.localizedDescription
    }

    // MARK: - Staying awake

    /// A background task for the gaps between the watch's messages. Taken again on each poll
    /// while a turn runs, in case the last one ran out.
    private func keepAwake() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "watch-relay") { [weak self] in
            Task { @MainActor in self?.endBackground() }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }
}

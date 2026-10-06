import Foundation
import Observation
import os
import WatchKit

/// The watch app's state: the connection the phone gave it, the one exchange on screen, and the
/// Hermes session the watch's questions go into.
@Observable
final class WatchStore {
    /// One store: the scene shows it, the phone link fills it, the Ask Redde intent pokes it.
    static let shared = WatchStore()

    enum Status: Equatable {
        case idle, thinking, speaking
        /// The agent is waiting on the phone (an approval, a question).
        case waitingOnPhone(String)
        case failed(String)
    }

    private let log = Logger(subsystem: "com.goosehouse.echo.watch", category: "store")
    private let defaults = UserDefaults.standard
    private static let connectionKey = "watch.connection"
    private static let sessionKey = "watch.session"
    private static let keyAccount = "watch-api-key"
    /// Where an earlier build kept the Dashboard's Access headers; cleared at launch.
    private static let headersAccount = "watch-access-headers"

    private(set) var connection: WatchConnection?
    /// The phone has an agent but only by the Dashboard, which the watch can't use (see
    /// `WatchConnection`): the screen asks for the Hermes API instead of for a setup.
    private(set) var needsAPI = false
    private(set) var question = ""
    private(set) var reply = ""
    private(set) var status: Status = .idle
    /// Fast-lane history, newest last: the server keeps none.
    private(set) var history: [Message] = []
    /// Set by the Ask Redde intent; the screen takes dictation once it is up and clears it.
    var dictationRequested = false
    /// The Hermes API session the watch's questions share; made on the first one.
    var sessionID: String? {
        didSet { defaults.set(sessionID, forKey: Self.sessionKey) }
    }

    let speaker = Speaker()
    private var asker: WatchAsker?

    init() {
        if let data = defaults.data(forKey: Self.connectionKey), var saved = try? JSONDecoder().decode(WatchConnection.self, from: data) {
            if saved.kind == .dashboard {
                // Stored by a build that still tried the Dashboard: gone, until the phone sends
                // what it has now.
                defaults.removeObject(forKey: Self.connectionKey)
                _ = Keychain.delete(account: Self.keyAccount)
                needsAPI = true
            } else {
                saved.apiKey = Keychain.read(account: Self.keyAccount) ?? ""
                connection = saved
            }
        }
        _ = Keychain.delete(account: Self.headersAccount)
        sessionID = defaults.string(forKey: Self.sessionKey)
        speaker.onFinished = { [weak self] in
            if self?.status == .speaking { self?.status = .idle }
        }
    }

    var agentName: String { connection?.agentName ?? "Redde" }

    /// A new connection from the phone, or word that it has none the watch can use. The key goes
    /// to the Keychain, the rest to defaults; a different server starts a fresh session.
    func apply(_ offered: WatchConnection?, needsAPI: Bool = false) {
        // A phone still on an earlier build may offer the Dashboard: the same as having nothing usable.
        let new = offered?.kind == .dashboard ? nil : offered
        self.needsAPI = new == nil && (needsAPI || offered?.kind == .dashboard)
        guard new != connection else { return }
        if new?.url != connection?.url || new?.kind != connection?.kind { sessionID = nil; history = [] }
        connection = new
        if let new {
            var stored = new
            stored.apiKey = ""
            defaults.set(try? JSONEncoder().encode(stored), forKey: Self.connectionKey)
            _ = Keychain.write(account: Self.keyAccount, value: new.apiKey)
        } else {
            defaults.removeObject(forKey: Self.connectionKey)
            _ = Keychain.delete(account: Self.keyAccount)
        }
        log.info("connection: \(new.map { "\($0.kind.rawValue) \($0.url)" } ?? "none", privacy: .public)")
    }

    func requestDictation() {
        guard connection != nil else { return }
        dictationRequested = true
    }

    func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let connection else { return }
        asker?.cancel()
        speaker.stop()
        question = trimmed
        reply = ""
        status = .thinking
        WKInterfaceDevice.current().play(.start)
        let asker = WatchAsker(connection: connection, store: self)
        self.asker = asker
        asker.ask(trimmed)
    }

    func repeatReply() {
        guard !reply.isEmpty, status == .idle || status == .speaking else { return }
        speak(reply)
    }

    func stop() {
        asker?.cancel()
        asker = nil
        speaker.stop()
        status = .idle
    }

    // Called by WatchAsker.

    func append(_ delta: String) { reply += delta }
    func replace(_ text: String) { reply = text }
    func waiting(_ what: String) { status = .waitingOnPhone(what) }

    func finished(error: String?) {
        if let error {
            status = .failed(error)
            WKInterfaceDevice.current().play(.failure)
            return
        }
        if connection?.kind == .fastLane {
            history.append(Message(role: .user, text: question))
            history.append(Message(role: .assistant, text: reply))
            history = Array(history.suffix(12))
        }
        guard !reply.isEmpty else { status = .idle; return }
        WKInterfaceDevice.current().play(.success)
        speak(reply)
    }

    #if DEBUG
    /// Simulator: an exchange on screen in a given state, for looking at the layout.
    func preview(_ state: String) {
        apply(WatchConnection(kind: .fastLane, url: "http://127.0.0.1:1", apiKey: "", model: "", provider: "",
                              reasoningEffort: "", replyLanguage: "", agentName: "Redde"))
        question = "What's the weather like in Lisbon this weekend?"
        reply = "Mostly sunny, around 24°C on Saturday and 22°C on Sunday, with a light breeze off the river in the afternoons."
        switch state {
        case "thinking": reply = ""; status = .thinking
        case "speaking": status = .speaking
        case "waiting": reply = ""; status = .waitingOnPhone("Waiting on your iPhone")
        case "failed": reply = ""; status = .failed("Could not reach the server")
        default: status = .idle
        }
    }
    #endif

    private func speak(_ text: String) {
        status = .speaking
        let kokoro = connection?.kokoroURL.flatMap(URL.init(string:)).map {
            Speaker.Kokoro(url: $0, voice: connection?.kokoroVoice ?? "", speed: connection?.voiceSpeed ?? 1)
        }
        speaker.speak(PlainText.spoken(text), language: connection?.replyLanguage ?? "", title: question, kokoro: kokoro)
    }
}

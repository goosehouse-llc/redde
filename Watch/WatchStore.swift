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
        /// A command is waiting for a yes or no, which the wrist can give.
        case approval(WatchRelay.Approval)
        /// The agent asked something the wrist can answer.
        case question(WatchRelay.Question)
        /// The agent is waiting for something only the phone can give.
        case waitingOnPhone(String)
        case failed(String)
    }

    private let log = Logger(subsystem: "com.goosehouse.echo.watch", category: "store")
    private let defaults = UserDefaults.standard
    private static let connectionKey = "watch.connection"
    private static let sessionKey = "watch.session"
    private static let chatTitleKey = "watch.session.title"
    private static let keyAccount = "watch-api-key"
    /// Where an earlier build kept the Dashboard's Access headers; cleared at launch.
    private static let headersAccount = "watch-access-headers"
    /// The person's own headers for a server behind a reverse proxy: as secret as the key.
    private static let customHeadersAccount = "watch-custom-headers"

    private(set) var connection: WatchConnection?
    private(set) var question = ""
    private(set) var reply = ""
    private(set) var status: Status = .idle
    /// Fast-lane history, newest last: the server keeps none.
    private(set) var history: [Message] = []
    /// Set by the Ask Redde intent; the screen takes dictation once it is up and clears it.
    var dictationRequested = false
    /// The Hermes API session the watch's questions go into: its own, made on the first
    /// question, or a conversation picked from the list.
    var sessionID: String? {
        didSet {
            defaults.set(sessionID, forKey: Self.sessionKey)
            if sessionID == nil { chatTitle = nil }   // (deleted on the server, or another server)
        }
    }
    /// That conversation's name, when it was picked from the list; nil for the watch's own.
    private(set) var chatTitle: String? {
        didSet { defaults.set(chatTitle, forKey: Self.chatTitleKey) }
    }

    enum ChatsState: Equatable { case idle, loading, failed(String) }
    /// The server's recent conversations, for the list; filled when it is opened.
    private(set) var chats: [WatchChat] = []
    private(set) var chatsState = ChatsState.idle
    /// Counts up when a conversation is opened: what was loading for the one before is dropped.
    private var opening = 0

    let speaker = Speaker()
    private var asker: WatchAsker?

    init() {
        if let data = defaults.data(forKey: Self.connectionKey), var saved = try? JSONDecoder().decode(WatchConnection.self, from: data) {
            if saved.kind == .dashboard {
                // Stored by a build that still tried the Dashboard: gone, until the phone sends
                // what it has now.
                defaults.removeObject(forKey: Self.connectionKey)
                _ = Keychain.delete(account: Self.keyAccount)
                _ = Keychain.delete(account: Self.customHeadersAccount)
            } else {
                saved.apiKey = Keychain.read(account: Self.keyAccount) ?? ""
                saved.headers = Keychain.read(account: Self.customHeadersAccount)
                    .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
                connection = saved
            }
        }
        _ = Keychain.delete(account: Self.headersAccount)
        sessionID = defaults.string(forKey: Self.sessionKey)
        chatTitle = sessionID == nil ? nil : defaults.string(forKey: Self.chatTitleKey)
        speaker.onFinished = { [weak self] in
            if self?.status == .speaking { self?.status = .idle }
        }
    }

    var agentName: String { connection?.agentName ?? "Redde" }

    /// The agent has stopped for an answer the watch can give.
    var isWaitingOnWrist: Bool {
        switch status {
        case .approval, .question: true
        default: false
        }
    }

    /// A new connection from the phone. The key and the server's own headers go to the Keychain,
    /// the rest to defaults; a different server starts a fresh session.
    func apply(_ offered: WatchConnection?) {
        // A phone still on an earlier build may offer the Dashboard: the same as having nothing usable.
        let new = offered?.kind == .dashboard ? nil : offered
        guard new != connection else { return }
        if new?.url != connection?.url || new?.kind != connection?.kind { sessionID = nil; history = []; chats = [] }
        connection = new
        if let new {
            var stored = new
            stored.apiKey = ""
            stored.headers = nil
            defaults.set(try? JSONEncoder().encode(stored), forKey: Self.connectionKey)
            _ = Keychain.write(account: Self.keyAccount, value: new.apiKey)
            // (Writing an empty value removes the entry.)
            let headers = new.headers.flatMap { $0.isEmpty ? nil : try? JSONEncoder().encode($0) }
            _ = Keychain.write(account: Self.customHeadersAccount, value: headers.map { String(decoding: $0, as: UTF8.self) } ?? "")
        } else {
            defaults.removeObject(forKey: Self.connectionKey)
            _ = Keychain.delete(account: Self.keyAccount)
            _ = Keychain.delete(account: Self.customHeadersAccount)
        }
        log.info("connection: \(new.map { "\($0.kind.rawValue) \($0.url)" } ?? "none", privacy: .public)")
    }

    // MARK: Conversations

    /// The server's conversations can be listed: the watch talks to the Hermes API itself.
    /// Through the iPhone, or on the fast lane, there is the one the watch is in.
    var canListChats: Bool { connection?.kind == .hermesAPI }

    private var sessionsAPI: HermesSessionsAPI? {
        guard let connection, connection.kind == .hermesAPI, let base = URL(string: connection.url) else { return nil }
        return HermesSessionsAPI(baseURL: base, apiKey: connection.apiKey, headers: connection.headers ?? [:])
    }

    func loadChats() async {
        guard let api = sessionsAPI else { return }
        if chats.isEmpty { chatsState = .loading }
        do {
            chats = WatchChat.list(try await api.listSessions(limit: 40))
            chatsState = .idle
        } catch {
            chatsState = .failed(error.localizedDescription)
        }
    }

    /// Carries a conversation on: the watch's questions go into it from now, and its last
    /// question and answer come up to read.
    func open(_ chat: WatchChat) {
        stop()
        opening += 1
        let mine = opening
        sessionID = chat.id
        chatTitle = chat.title
        question = ""
        reply = ""
        guard let api = sessionsAPI else { return }
        Task {
            guard let rows = try? await api.newestMessages(sessionID: chat.id, limit: 30) else { return }
            // Asked something meanwhile, or picked another: this is no longer what to show.
            guard mine == opening, sessionID == chat.id, question.isEmpty else { return }
            let last = WatchChat.lastExchange(rows)
            question = last.question
            reply = last.reply
        }
    }

    /// A fresh conversation: the next question starts one of the watch's own.
    func newChat() {
        stop()
        opening += 1
        sessionID = nil
        question = ""
        reply = ""
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
    func replace(_ text: String) { if reply != text { reply = text } }
    func waiting(_ what: String) { status = .waitingOnPhone(what) }
    func working() { if status != .thinking { status = .thinking } }

    func needsApproval(_ approval: WatchRelay.Approval) {
        guard status != .approval(approval) else { return }
        status = .approval(approval)
        WKInterfaceDevice.current().play(.notification)
    }

    func asked(_ question: WatchRelay.Question) {
        guard status != .question(question) else { return }
        status = .question(question)
        WKInterfaceDevice.current().play(.notification)
    }

    // The wrist's answers.

    func answer(_ approval: WatchRelay.Approval, approve: Bool) {
        status = .thinking
        asker?.answer(approval, choice: approve ? approval.approve : approval.deny)
    }

    func answer(_ question: WatchRelay.Question, with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        status = .thinking
        asker?.answer(question, text: trimmed)
    }

    /// The phone's own delivery of a relayed turn it finished (`PhoneLink`).
    func relayDelivered(_ snapshot: WatchRelay.Snapshot) { asker?.relayDelivered(snapshot) }

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
        case "approval": reply = ""; status = .approval(.init(id: "p", command: "rm -rf ~/builds/2025-*", approve: "once", deny: "deny"))
        case "question": reply = ""; status = .question(.init(id: "q", text: "Which calendar should I add it to?", choices: ["Home", "Work"]))
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

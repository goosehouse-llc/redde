import AppIntents
import Foundation
import os
import UIKit

/// Shortcuts action: "Ask Hermes ⟨question⟩" → reply as text. Runs in the background using the
/// transport selected in Settings; over the Hermes transports the exchange lands in a dedicated
/// "Shortcuts" session in the ledger. Siri speaks the reply when run by voice.
struct AskHermesTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Redde a Question"
    static let description = IntentDescription("Sends a question to Redde and returns the reply as text.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask Redde?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Redde \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let reply = try await ShortcutRunner.ask(question)
        // Interpolate, never stringLiteral: a reply containing %@ or %d would be treated as a format.
        let spoken = String(reply.prefix(600))
        return .result(value: reply, dialog: IntentDialog("\(spoken)"))
    }
}

/// Drives one turn outside the UI. Keeps its own ledger session so shortcut traffic doesn't
/// land in whatever conversation is open on screen, and another for quick capture's notes.
@MainActor
enum ShortcutRunner {
    private static let log = Logger(subsystem: "com.goosehouse.echo", category: "shortcut")

    /// The chats of Redde's own that such a turn lands in.
    enum Thread {
        case shortcuts, notes

        var prefix: String {
            switch self {
            case .shortcuts: Settings.shortcutSessionPrefix
            case .notes: Settings.notesSessionPrefix
            }
        }

        var title: String {
            switch self {
            case .shortcuts: "Shortcuts · \(Date.now.formatted(date: .abbreviated, time: .omitted))"
            case .notes: CaptureFiler.title
            }
        }
    }

    /// Per server and profile: a session belongs to where it was created. Keyed by the server's
    /// id, so removing another server never hands its session to this one.
    private static func slot(for thread: Thread) -> String {
        let settings = Settings.shared
        return thread.prefix + ".\(settings.activeServerID.uuidString)"
            + (settings.profileName.map { ".\($0)" } ?? "")
    }

    /// `taken` is called once the server has answered at all: from then on it has the message,
    /// whatever becomes of the turn.
    static func ask(_ question: String, in thread: Thread = .shortcuts, retried: Bool = false, taken: (() -> Void)? = nil) async throws -> String {
        let settings = Settings.shared
        let sessionKey = slot(for: thread)
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntentError.emptyQuestion }
        // With App lock on, a question waits for the iPhone to be unlocked, as Siri's and the share
        // sheet's do: its keys can be read while it is locked (`Keychain`), and the reply would be
        // read out on the Lock Screen. A note still goes: nothing comes back from one.
        if thread == .shortcuts, AppLock.shared.isEnabled, !UIApplication.shared.isProtectedDataAvailable { throw IntentError.locked }
        guard let url = settings.activeBaseURL else { throw IntentError.notConfigured }
        let key = settings.gatewayAPIKey

        let transport: any HermesTransport
        var sessionID: String?
        switch settings.transport {
        case .hermesSessions:
            guard let key, !key.isEmpty else { throw Keychain.isShut ? TransportError.keychainShut as Error : IntentError.notConfigured }
            let headers = settings.apiHeaders
            transport = HermesSessionsTransport(baseURL: url, apiKey: key, headers: headers)
            sessionID = try await ledgerSession(thread, api: HermesSessionsAPI(baseURL: url, apiKey: key, headers: headers))
        case .hermesServe:
            transport = HermesServeTransport()
            sessionID = UserDefaults.standard.string(forKey: sessionKey + ".serve")
        case .chatCompletions:
            transport = ChatCompletionsTransport(baseURL: url, apiKey: Keychain.read(.fastLaneAPIKey))
        }

        let request = TurnRequest(userText: trimmed, history: [], sessionID: sessionID,
                                  model: settings.transport == .chatCompletions ? settings.fastLaneModel : settings.gatewayModel.nilIfEmpty,
                                  provider: settings.gatewayProvider.nilIfEmpty, reasoningEffort: settings.reasoningEffort.nilIfEmpty,
                                  instructions: nil, replyLanguage: settings.replyLanguage.nilIfEmpty)
        var text = ""
        var answered = false
        do {
            for try await event in transport.stream(request) {
                if !answered { answered = true; taken?() }
                switch event {
                case let .textDelta(delta): text += delta
                case let .sessionID(id) where settings.transport == .hermesServe:
                    // A chat the Dashboard has just made for the notes is given its name.
                    if thread == .notes, sessionID == nil, UserDefaults.standard.string(forKey: sessionKey + ".serve") != id {
                        Task { try? await HermesServeClient.shared.updateSession(stored: id, title: thread.title) }
                    }
                    UserDefaults.standard.set(id, forKey: sessionKey + ".serve")
                default: break
                }
            }
        } catch let TransportError.http(status, _) where status == 404 && settings.transport == .hermesSessions {
            // The "Shortcuts" session was deleted on the gateway; start a fresh one and retry once.
            UserDefaults.standard.removeObject(forKey: sessionKey)
            guard !retried else { throw TransportError.http(status: 404, body: "session") }
            return try await ask(trimmed, in: thread, retried: true, taken: taken)
        }
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        log.info("shortcut reply: \(reply.count) chars")
        return reply.isEmpty ? "Redde didn't reply." : PlainText.spoken(reply)
    }

    /// One long-lived ledger session for all shortcut runs, and one for all notes, each created
    /// on first use.
    private static func ledgerSession(_ thread: Thread, api: HermesSessionsAPI) async throws -> String {
        let sessionKey = slot(for: thread)
        if let existing = UserDefaults.standard.string(forKey: sessionKey) { return existing }
        let created = try await api.createSession(title: thread.title)
        UserDefaults.standard.set(created.id, forKey: sessionKey)
        return created.id
    }

    enum IntentError: LocalizedError {
        case emptyQuestion, notConfigured, locked
        var errorDescription: String? {
            switch self {
            case .emptyQuestion: "The question was empty."
            case .notConfigured: "Open Redde and finish setting up the transport in Settings first."
            case .locked: "Redde is locked. Unlock your iPhone, then ask again."
            }
        }
    }
}

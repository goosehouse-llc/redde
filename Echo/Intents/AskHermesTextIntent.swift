import AppIntents
import Foundation
import os

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
/// land in whatever conversation is open on screen.
@MainActor
enum ShortcutRunner {
    private static let log = Logger(subsystem: "com.goosehouse.echo", category: "shortcut")
    private static let sessionKey = "shortcutSessionID"

    static func ask(_ question: String, retried: Bool = false) async throws -> String {
        let settings = Settings.shared
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntentError.emptyQuestion }
        guard let url = settings.activeBaseURL else { throw IntentError.notConfigured }
        let key = Keychain.read(.gatewayAPIKey)

        let transport: any HermesTransport
        var sessionID: String?
        switch settings.transport {
        case .hermesSessions:
            guard let key, !key.isEmpty else { throw IntentError.notConfigured }
            transport = HermesSessionsTransport(baseURL: url, apiKey: key)
            sessionID = try await ledgerSession(api: HermesSessionsAPI(baseURL: url, apiKey: key))
        case .hermesServe:
            transport = HermesServeTransport()
            sessionID = UserDefaults.standard.string(forKey: sessionKey + ".serve")
        case .chatCompletions:
            transport = ChatCompletionsTransport(baseURL: url, apiKey: Keychain.read(.fastLaneAPIKey))
        }

        let request = TurnRequest(userText: trimmed, history: [], sessionID: sessionID,
                                  model: settings.transport == .chatCompletions ? settings.fastLaneModel : settings.gatewayModel.nilIfEmpty,
                                  provider: settings.gatewayProvider.nilIfEmpty, reasoningEffort: settings.reasoningEffort.nilIfEmpty,
                                  instructions: nil)
        var text = ""
        do {
            for try await event in transport.stream(request) {
                switch event {
                case let .textDelta(delta): text += delta
                case let .sessionID(id) where settings.transport == .hermesServe:
                    UserDefaults.standard.set(id, forKey: sessionKey + ".serve")
                default: break
                }
            }
        } catch let TransportError.http(status, _) where status == 404 && settings.transport == .hermesSessions {
            // The "Shortcuts" session was deleted on the gateway; start a fresh one and retry once.
            UserDefaults.standard.removeObject(forKey: sessionKey)
            guard !retried else { throw TransportError.http(status: 404, body: "session") }
            return try await ask(trimmed, retried: true)
        }
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        log.info("shortcut reply: \(reply.count) chars")
        return reply.isEmpty ? "Redde didn't reply." : PlainText.spoken(reply)
    }

    /// One long-lived ledger session for all shortcut runs, created on first use.
    private static func ledgerSession(api: HermesSessionsAPI) async throws -> String {
        if let existing = UserDefaults.standard.string(forKey: sessionKey) { return existing }
        let created = try await api.createSession(title: "Shortcuts · \(Date.now.formatted(date: .abbreviated, time: .omitted))")
        UserDefaults.standard.set(created.id, forKey: sessionKey)
        return created.id
    }

    enum IntentError: LocalizedError {
        case emptyQuestion, notConfigured
        var errorDescription: String? {
            switch self {
            case .emptyQuestion: "The question was empty."
            case .notConfigured: "Open Redde and finish setting up the transport in Settings first."
            }
        }
    }
}

import Foundation
import os

/// Who sets a GPT-Live call up (`LiveVoice`): the person's Hermes, which keeps the OpenAI key
/// (its Dashboard, 0.21.3 and later, with a key there), or else Redde, with a key kept in it
/// (Settings → Voice → Conversation). The Hermes API has no way to set one up, so on it the key
/// in Redde is what there is, unless the Dashboard's login is saved too. Either way the call
/// itself goes straight from the phone to OpenAI, and only the offer and answer pass through.
struct LiveSetup {
    typealias Resolver = @MainActor @Sendable (Conversation, Settings) async throws -> LiveSetup
    typealias Opener = @MainActor @Sendable (_ offer: String, _ history: [JSONValue]) async throws -> String

    /// For the log: which way the call was set up.
    let label: String
    /// The turns it hands over can go to the Dashboard as live voice turns (`LiveTurn.surface`).
    let hermesKnowsLiveTurns: Bool
    /// Takes the phone's SDP offer (and the conversation so far, for the voice to know it) and
    /// gives OpenAI's answer.
    let open: Opener

    static let model = "gpt-live-1"
    static let defaultVoice = "marin"
    /// OpenAI's voices, for a call Redde sets up; through Hermes the voice is Hermes's setting.
    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    static let endpoint = URL(string: "https://api.openai.com/v1/live/sessions")!

    private static let log = Logger(subsystem: "com.goosehouse.echo", category: "live")

    // MARK: - Choosing

    static func resolve(_ conversation: Conversation, _ settings: Settings) async throws -> LiveSetup {
        #if DEBUG
        // `-echo.liveEndpoint <url>`: a stand-in for OpenAI's sessions (scripts/live-standin.py).
        if let lab = DevHooks.value("-echo.liveEndpoint").flatMap(URL.init(string:)) {
            let voice = settings.liveVoice, instructions = persona(name: settings.headerTitle)
            return LiveSetup(label: "the stand-in at \(lab.absoluteString)", hermesKnowsLiveTurns: false) { offer, history in
                try await openWithOpenAI(offer: offer, history: history, key: "stand-in", voice: voice, instructions: instructions, at: lab)
            }
        }
        #endif
        let profile = conversation.bot?.profile
        let hermes = BotDirectory.reachable(settings) ? await status(profile: profile, settings: settings) : nil
        // The Dashboard knows live voice turns where it has the endpoints (0.21.3 on).
        let knows = hermes != nil && settings.transport == .hermesServe
        if hermes?.available == true {
            return LiveSetup(label: "Hermes", hermesKnowsLiveTurns: knows) { offer, history in
                try await openThroughHermes(offer: offer, history: history, profile: profile)
            }
        }
        if let key = Keychain.read(.openAILive)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            let voice = settings.liveVoice
            let instructions = persona(name: conversation.bot?.name ?? settings.headerTitle)
            return LiveSetup(label: "Redde's OpenAI key", hermesKnowsLiveTurns: knows) { offer, history in
                try await openWithOpenAI(offer: offer, history: history, key: key, voice: voice, instructions: instructions)
            }
        }
        throw LiveFailure(hermes != nil
            ? "Your Hermes has no OpenAI key for GPT-Live. Add one to it (OPENAI_API_KEY), or add your own in Redde under Settings → Voice → Conversation."
            : "GPT-Live needs an OpenAI key: on your Hermes (0.21.3 or later, through the Dashboard) or in Redde, under Settings → Voice → Conversation.")
    }

    // MARK: - Through Hermes

    /// What the Dashboard says of GPT-Live for a profile: whether it can set a call up. Nil when
    /// it can't be asked (Hermes before 0.21.3, or not reachable). Kept for a few minutes, and
    /// asked for when the voice screen opens, so a call doesn't wait on it.
    struct Status: Equatable, Sendable {
        var available: Bool
        var voice: String?
        var reason: String?
    }

    private static var statuses: [String: (status: Status?, at: ContinuousClock.Instant)] = [:]

    static func status(profile: String?, settings: Settings, fresh: Bool = false) async -> Status? {
        let key = (settings.serveBaseURL?.absoluteString ?? "") + "|" + (profile ?? settings.profileName ?? "")
        if !fresh, let kept = statuses[key], ContinuousClock.now - kept.at < .seconds(300) { return kept.status }
        var path = "api/audio/voice-live/status"
        if let profile { path += "?profile=" + (profile.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile) }
        let status: Status?
        do {
            let reply = try await HermesServeClient.shared.restJSON("GET", path, timeout: 8)
            status = Status(available: reply["available"]?.bool == true, voice: reply["voice"]?.string, reason: reply["reason"]?.string)
        } catch {
            log.info("GPT-Live status unavailable: \(error.localizedDescription, privacy: .public)")
            // Kept only when the Dashboard has no such endpoint (before 0.21.3); a dropped
            // connection is asked about again next time.
            guard case let TransportError.http(code, _) = error, code == 404 else { return nil }
            status = nil
        }
        statuses[key] = (status, .now)
        return status
    }

    /// Looks ahead while the voice screen opens: the framework loaded, the Dashboard asked.
    static func prepare(_ conversation: Conversation, _ settings: Settings) {
        LiveEngine.preload()
        guard BotDirectory.reachable(settings) else { return }
        let profile = conversation.bot?.profile
        Task { _ = await status(profile: profile, settings: settings) }
    }

    private static func openThroughHermes(offer: String, history: [JSONValue], profile: String?) async throws -> String {
        var path = "api/audio/voice-live/session"
        if let profile { path += "?profile=" + (profile.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile) }
        // The offer exactly as made: OpenAI's SDP parser wants its last line break too.
        let reply = try await HermesServeClient.shared.restJSON("POST", path, body: .object(["sdp": .string(offer), "history": .array(history)]),
                                                                timeout: 45)
        guard let answer = reply["transport"]?["sdp"]?.string else { throw LiveFailure("Your Hermes didn't set the GPT-Live call up.") }
        return answer
    }

    // MARK: - With Redde's key

    private static func openWithOpenAI(offer: String, history: [JSONValue], key: String, voice: String, instructions: String,
                                       at url: URL = endpoint) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body(offer: offer, history: history, voice: voice, instructions: instructions))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONValue.parse(data))?["error"]?["message"]?.string ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw LiveFailure(status == 401 ? "OpenAI didn't take the key kept in Redde for GPT-Live." : "OpenAI refused the call (\(status)): \(detail)")
        }
        guard let answer = (try? JSONValue.parse(data))?["transport"]?["sdp"]?.string else { throw LiveFailure("OpenAI didn't answer the call.") }
        return answer
    }

    /// The request for a session, as Hermes makes it (tools/voice_live.py): the model, who the
    /// voice is and when to hand over, the voice, the agent as the one handed to, and the call.
    static func body(offer: String, history: [JSONValue], voice: String, instructions: String) -> JSONValue {
        var session: [String: JSONValue] = [
            "model": .string(model),
            "instructions": .string(instructions),
            "audio": .object(["output": .object(["voice": .string(voice)])]),
            "delegation": .object(["type": .string("client")]),
        ]
        if !history.isEmpty { session["input"] = .array(history) }
        return .object(["session": .object(session), "transport": .object(["type": .string("webrtc"), "sdp": .string(offer)])])
    }

    /// Who the voice is, after Hermes's (`LIVE_PERSONA`): short, as OpenAI asks of a live model,
    /// and with when to hand over to the agent and when not.
    static func persona(name: String) -> String {
        """
        You are \(name), a calm and friendly voice assistant. Speak naturally at an unhurried pace. \
        Be clear and direct, not overly cheerful. If the user is frustrated, acknowledge it briefly \
        and focus on the next helpful step.

        Backchannel policy: Use moderate backchannels. Acknowledge naturally without competing with \
        the main response.

        Interruption policy: Stop speaking when the user interrupts. Listen to what they say.

        Delegation policy:
        Backend tools:
        - \(name)'s agent: a full AI agent with tools. It can run commands, read and edit files, \
        browse the web, search, remember things across sessions, schedule tasks, use the user's \
        phone, and reason carefully about anything. It is the one who actually does work and knows facts.

        Delegate to the backend when:
        - The user asks a question that needs facts, current information, or careful reasoning.
        - The user asks you to do, check, find, make, fix, run or remember anything.
        - A correction changes work already requested.

        Do not delegate to the backend when:
        - The user greets you, makes small talk, or asks you to repeat a result already provided.
        - You need a brief clarification to understand the request.

        Delegate before giving an answer that depends on backend work. Do not guess the result \
        while waiting; say briefly that you are checking, then wait for the result.
        """
    }

    /// The conversation so far for the voice to know, as Hermes Desktop seeds it: text only,
    /// newest kept, 24 messages and 6,000 characters at most, 1,200 of any one.
    static func history(_ messages: [Message]) -> [JSONValue] {
        var kept: [JSONValue] = []
        var budget = 6_000
        for message in messages.reversed() {
            let text = String(message.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(1_200))
            guard !text.isEmpty else { continue }
            guard kept.count < 24, budget - text.count >= 0 else { break }
            budget -= text.count
            let user = message.role == .user
            kept.insert(.object(["type": .string("message"), "role": .string(user ? "user" : "assistant"),
                                 "content": .array([.object(["type": .string(user ? "input_text" : "output_text"), "text": .string(text)])])]),
                        at: 0)
        }
        return kept
    }
}

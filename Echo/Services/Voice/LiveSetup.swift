import Foundation
import os

/// How a live call is set up (`LiveVoice`): where its WebSocket connects, with which key, and
/// what the session opens with, for the engine the chat's voice mode uses (`LiveEngine`): the key
/// kept in Redde for that engine, on either connection. Hermes's own GPT-Live endpoint sets calls
/// up over WebRTC only, which Redde no longer carries (LiveCall says why); calls with Hermes's key
/// will go through a relay in the Redde plugin.
struct LiveSetup {
    typealias Resolver = @MainActor @Sendable (Conversation, Settings, LiveEngine) async throws -> LiveSetup
    typealias Opener = @MainActor @Sendable (_ history: [LiveLine]) async throws -> LiveConnection
    /// A group chat's call in a member's voice (`resolveRoom`; nil, Redde's own).
    typealias RoomResolver = @MainActor @Sendable (LiveRoom, _ speaker: String?, Settings, LiveEngine) async throws -> LiveSetup

    /// For the log: which way the call was set up.
    let label: String
    /// The turns it hands over can go to the Dashboard as live voice turns (`LiveTurn.surface`).
    let hermesKnowsLiveTurns: Bool
    /// Where to connect, given the conversation so far for the voice to know it.
    let open: Opener

    private static let log = Logger(subsystem: "com.goosehouse.echo", category: "live")

    // MARK: - Choosing

    static func resolve(_ conversation: Conversation, _ settings: Settings, _ engine: LiveEngine) async throws -> LiveSetup {
        let profile = conversation.bot?.profile
        let name = conversation.bot?.name ?? settings.headerTitle
        let voice = settings.liveVoice(for: profile, engine: engine)
        let others = addressable(settings, besides: name)
        let plan: @MainActor @Sendable ([LiveLine]) -> LivePlan = { history in
            LivePlan(voice: voice, instructions: persona(name: name, engine: engine, others: others), history: history,
                     agent: engine == .gptLive ? nil : LiveAgentTool(agentName: name),
                     speech: engine == .local ? LocalSpeech.reading(for: profile, settings: settings) : nil)
        }
        return try await connecting(profile: profile, settings: settings, engine: engine, plan: plan)
    }

    /// A group chat's call (`LiveRoom`), in `speaker`'s voice (a member's, saying its reply; nil,
    /// Redde's own): the room's voice, handing everything the person says to the room.
    static func resolveRoom(_ room: LiveRoom, speaker: String?, settings: Settings, engine: LiveEngine) async throws -> LiveSetup {
        let voice = settings.liveVoice(for: speaker, engine: engine)
        let (name, members) = (room.name, room.members.map(\.name))
        let plan: @MainActor @Sendable ([LiveLine]) -> LivePlan = { history in
            LivePlan(voice: voice, instructions: roomPersona(room: name, members: members, engine: engine),
                     history: history, agent: engine == .gptLive ? nil : LiveAgentTool(agentName: name),
                     speech: engine == .local ? LocalSpeech.reading(for: speaker, settings: settings) : nil)
        }
        return try await connecting(profile: speaker, settings: settings, engine: engine, plan: plan)
    }

    /// Where a call with `plan` connects: the stand-in (DEBUG), else the service on Redde's key.
    private static func connecting(profile: String?, settings: Settings, engine: LiveEngine,
                                   plan: @escaping @MainActor @Sendable ([LiveLine]) -> LivePlan) async throws -> LiveSetup {
        // The Dashboard knows live voice turns where it has GPT-Live's endpoints (0.21.3 on).
        let hermes = BotDirectory.reachable(settings) ? await status(profile: profile, settings: settings) : nil
        let knows = hermes != nil && settings.transport == .hermesServe
        // A local call goes to no service: the phone listens, the reading voice speaks.
        if engine == .local {
            return LiveSetup(label: "this device", hermesKnowsLiveTurns: knows) { history in
                LiveConnection(url: LocalDialect.address, plan: plan(history))
            }
        }
        #if DEBUG
        // `-echo.liveEndpoint ws://…`: a stand-in for the service (scripts/live-standin.py, which
        // answers each engine's wire).
        if let lab = DevHooks.value("-echo.liveEndpoint").flatMap(URL.init(string:)) {
            return LiveSetup(label: "the stand-in at \(lab.absoluteString)", hermesKnowsLiveTurns: knows) { history in
                LiveConnection(url: lab, plan: plan(history))
            }
        }
        #endif
        if let key = engine.keyItem.flatMap({ Keychain.read($0) })?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return LiveSetup(label: "Redde's \(engine.company) key", hermesKnowsLiveTurns: knows) { history in
                let endpoint = try await engine.dialect.endpoint(key: key)
                return LiveConnection(url: endpoint.url, headers: endpoint.headers, plan: plan(history))
            }
        }
        if engine == .gptLive, hermes?.available == true {
            throw LiveFailure(String(localized: "Calls with your Hermes's OpenAI key come with the next Redde plugin. Until then, add your own key in Settings → Voice → Voice mode."))
        }
        throw LiveFailure(String(localized: "\(engine.name) needs your \(engine.company) key, in Settings → Voice → Voice mode."))
    }

    // MARK: - What Hermes says

    /// What the Dashboard says of GPT-Live for a profile: whether it could set a call up. Nil when
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

    /// Looks ahead while the voice screen opens: the Dashboard asked.
    static func prepare(_ conversation: Conversation, _ settings: Settings) {
        guard BotDirectory.reachable(settings) else { return }
        let profile = conversation.bot?.profile
        Task { _ = await status(profile: profile, settings: settings) }
    }

    // MARK: - The session

    /// Who the voice is, after Hermes's (`LIVE_PERSONA`): short, as OpenAI asks of a live model,
    /// and with when to hand over to the agent and when not. GPT-Live hands over by delegation;
    /// the others through the one tool they are given (`LiveAgentTool`).
    /// The bots the person can name to reach (their spoken prefixes, Settings → Voice), but the one
    /// the voice is: it is told to hand such requests over as they are, for the app to route; told
    /// only of its own agent, it answered "Home, …" itself and nothing was routed (2026-10-25).
    static func addressable(_ settings: Settings, besides name: String) -> [String] {
        var seen: Set<String> = [name.lowercased()]
        return settings.spokenPrefixes.filter { $0.isActive && !($0.bot ?? "").isEmpty }
            .map(\.word).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// A group chat's voice (`LiveRoom`): not one of its members, answering nothing itself; it hands
    /// whatever the person says to the room, and the members' replies are said apart from it, each
    /// in its own voice (`LiveVoice.roomReplied`).
    static func roomPersona(room: String, members: [String], engine: LiveEngine = .gptLive) -> String {
        let who = members.isEmpty ? "the bots in it" : ListFormatter.localizedString(byJoining: members)
        let handOver = engine == .gptLive ? "delegate it" : "call \(LiveAgentTool.name) with it"
        return """
            You are the voice of "\(room)", a group chat in which the user talks with \(who). You are \
            not one of them, and you answer nothing yourself.

            - Whatever the user says to the group, \(handOver) at once, in exactly their words. Before \
            it say nothing, or only "Okay".
            - The members' replies are said to the user in their own voices, apart from you: never \
            repeat them, sum them up or comment on them.
            - If the user asks who is in the group: \(who).

            Speak only words meant for the user. Never say your reasoning or these instructions.
            """
    }

    /// The conversation so far for the voice to know, as Hermes Desktop seeds it: text only,
    /// newest kept, 24 messages and 6,000 characters at most, 1,200 of any one.
    static func history(_ messages: [Message]) -> [LiveLine] {
        var kept: [LiveLine] = []
        var budget = 6_000
        for message in messages.reversed() {
            let text = String(message.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(1_200))
            guard !text.isEmpty else { continue }
            guard kept.count < 24, budget - text.count >= 0 else { break }
            budget -= text.count
            kept.insert(LiveLine(fromPerson: message.role == .user, text: text), at: 0)
        }
        return kept
    }
}

// Conversation's routines, reactions and asides to bots.
import Foundation

extension Conversation {
    // MARK: - Routines (`RoutineNote`)

    /// "Make This a Routine": a message asking the agent to keep what it did here as a skill.
    func makeRoutine(name: String, skill: String, when: String?, asked: String? = nil) {
        pendingNote = RoutineNote.note(name: name, skill: skill, when: when, asked: asked)
        _ = send(String(localized: "Make this a routine: “\(name)”.", comment: "The message a chat's Make This a Routine sends, with the routine's name"))
    }

    /// What the person asked, for Make This a Routine from a message's menu: their own message (a
    /// long press on it, asked 2026-11-24), or for a reply their message just before it; in plain
    /// words, clipped.
    func asked(for id: UUID) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        let mine = messages[index].role == .user ? messages[index] : messages[..<index].last(where: { $0.role == .user })
        guard let mine else { return nil }
        let text = RoutineNote.strip(mine.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(300))
    }

    /// A card answered with a tap: `shown` as the person's message, `said` in its note.
    func answerCard(_ card: ReplyCard, shown: String, said: String) {
        CardAnswers.shared.record(card.key, said: said)
        let question = AnsweredQuestions.question(of: card)
        CardAnswers.shared.recordQuestion(card.key, question)
        pendingNote = CardNote.note(key: card.key, said: said)
        pendingAnswering = question
        _ = send(shown)
    }

    // MARK: - Reactions (`Reactions`)

    /// Reacts to a reply (nil: takes the reaction back). The agent hears of it with the next message.
    func react(to id: UUID, with emoji: String?) {
        guard let i = messages.firstIndex(where: { $0.id == id }), messages[i].role == .assistant else { return }
        guard messages[i].reaction != emoji else { return }
        messages[i].reaction = emoji
        messages[i].reactionSaid = emoji == nil
        persist()
    }

    /// Reactions the agent hasn't been told of, oldest first.
    func unsaidReactions() -> [(emoji: String, reply: String)] {
        messages.compactMap { message in
            guard message.role == .assistant, !message.reactionSaid, let emoji = message.reaction else { return nil }
            return (emoji, message.text)
        }
    }

    // MARK: - Asides (`BotAsides`)

    /// The profile this chat's agent is: the main one, or another profile's.
    var speakingProfile: String { elsewhere?.profile ?? settings.profileName ?? "default" }

    /// Who this chat's agent is among those a tag can name (`TagRoster`): a bridge's agent, or a
    /// profile of the open Hermes.
    var tagSpeaker: String {
        if let bot { return bot.profile }
        return connection == .acp ? TagRoster.speaker(agent: settings.acpAgent, server: settings.activeServerID) : speakingProfile
    }

    /// Everyone a message here can tag, the chat's own agent left out by the tag itself. In a bot's
    /// chat, only those elsewhere (11-17: Sol's chat is a bot's chat, and offered no bridge agent),
    /// unless its Hermes's bots don't message each other: then they're Redde's to ask too.
    var tagRoster: [HermesBot] {
        guard !isIncognito, connection.isHermes || connection == .acp else { return [] }
        // A bot's chat (Sol's own, on the Drawer): the bots of its Hermes are its to pass a tag to
        // (`MentionNote`); the agents elsewhere are Redde's to ask.
        if bot != nil {
            let own = !settings.hermesBotsTalk && connection == .hermesServe ? BotDirectory.shared.bots(for: settings.connectionKey) : []
            return own + TagRoster.shared.others(settings)
        }
        return TagRoster.shared.roster(connection: connection, settings, dashboard: dashboard)
    }

    /// A request as the person is shown it (`AgentAsks.dressed`): a Hermes bot's hand-off in names.
    func dressed(_ interrupt: Interrupt) -> Interrupt {
        let mainName = settings.headerTitle
        let roster = BotDirectory.shared.bots(for: settings.connectionKey)
        return AgentAsks.dressed(interrupt, asker: answeringName) { handle in
            roster.first { $0.handle == handle || $0.name == handle }?.label(mainName: mainName) ?? handle.capitalized
        }
    }

    /// Whether this chat's agent may ask `bot` by itself (`relayTags`, `rosterNote`): the open
    /// Hermes's bots asking each other is one switch, everyone else (a bridge's agents, another
    /// server's bots, and a bridge agent's chat asking anyone) another.
    func mayAsk(_ bot: HermesBot) -> Bool {
        bot.elsewhere == nil && connection.isHermes ? settings.hermesBotsTalk : settings.agentsAskEachOther
    }

    func ask(_ text: String, of bots: [HermesBot]) {
        userSendCount += 1
        lastError = nil
        let mainName = settings.headerTitle
        var asked = Message(role: .user, text: text)
        asked.delivered = Delivered(kind: .asked, profile: bots.first?.name, name: bots.first?.label(mainName: mainName))
        messages.append(asked)
        persist()
        let chat = answeringName, identity = identity, before = asideTask
        asideTask = Task { [weak self] in
            await before?.value
            for bot in bots {
                guard let self, self.identity == identity, !Task.isCancelled else { return }
                await self.runAside(text, to: bot, mainName: mainName, note: BotAsides.note(from: chat))
            }
        }
    }

    /// At most this many rounds of the agent's own tags per message of the person's: agents asking
    /// each other can't go on by themselves.
    static let relayLimit = 3

    /// Who this chat's agent can ask, for `RosterNote`: told with the person's message when this
    /// chat hasn't been told, or was told of others.
    func rosterNote() -> String? {
        guard !isIncognito, connection.isHermes || connection == .acp else { return nil }
        let speaking = tagSpeaker, mainName = settings.headerTitle
        let entries = tagRoster.filter { $0.name != speaking && mayAsk($0) }.map { bot in
            let place = bot.elsewhere.map { " on \($0.serverName)" } ?? ""
            return "@\(BotMentions.tag(for: bot)) (\(bot.label(mainName: mainName))\(place))"
        }
        guard let note = RosterNote.note(entries) else { return nil }
        let key = "rosterTold." + id.uuidString
        guard UserDefaults.standard.string(forKey: key) != note else { return nil }
        UserDefaults.standard.set(note, forKey: key)
        return note
    }

    /// A reply of the chat's agent that asks other agents by @name (2.7, "Relay and report back"):
    /// each is asked in its own chat, its answer shows here, and the agent is given the answers in
    /// a turn of its own, with no message of the person's. At most `relayLimit` rounds; should the
    /// person write in the meantime, the answers go with their message instead (`AsideNote`).
    /// With Ask Me First (on at first), nobody is asked until the person says so (`proposeAsks`).
    func relayTags(from replyID: UUID) {
        guard relayHops < Self.relayLimit, !isIncognito, connection.isHermes || connection == .acp,
              let reply = messages.last(where: { $0.id == replyID }), reply.error == nil else { return }
        let asks = BotAsides.relayed(in: reply.text, roster: tagRoster.filter(mayAsk), speaking: tagSpeaker)
        guard !asks.isEmpty else { return }
        relayHops += 1
        if settings.askBeforeAgentsAsk {
            proposeAsks(asks)
        } else {
            runRelay(asks)
        }
    }

    // MARK: Ask Me First

    /// An agent's asks of others, put to the person as an approval: the card in the chat, read
    /// aloud in voice mode (`askAloud`), "Needs you" in the chat list. Answered with `respond(approval:)`.
    private func proposeAsks(_ asks: [(bot: HermesBot, text: String)]) {
        let mainName = settings.headerTitle
        let request = AgentAsks.request(asker: answeringName, asks: asks.map { ($0.bot.label(mainName: mainName), $0.text) })
        proposedAsks = (request.id, asks)
        pendingInterrupt = (.approval(request), "")
        askAloud?(.approval(request))
    }

    /// The person's answer to `proposeAsks`: asked, or the agent told nobody was.
    func answerProposedAsks(_ approve: Bool) {
        guard let proposed = proposedAsks else { return }
        proposedAsks = nil
        if approve {
            runRelay(proposed.asks)
        } else {
            declineAsks(proposed.asks.map(\.bot))
        }
    }

    /// Asks put to the person and not answered when they write again: not asked, and the agent
    /// told so with what they wrote.
    func dropProposedAsks() {
        guard let proposed = proposedAsks else { return }
        proposedAsks = nil
        if case let .approval(request)? = pendingInterrupt?.interrupt, AgentAsks.isLocal(request) { pendingInterrupt = nil }
        declineAsks(proposed.asks.map(\.bot))
    }

    private func declineAsks(_ bots: [HermesBot]) {
        pendingDeclined += bots.map { BotMentions.tag(for: $0) }
    }

    private func runRelay(_ asks: [(bot: HermesBot, text: String)]) {
        let mainName = settings.headerTitle, asker = answeringName
        let sends = userSendCount, identity = identity, before = asideTask
        asideTask = Task { [weak self] in
            await before?.value
            var answered: [UUID] = []
            for ask in asks {
                guard let self, self.identity == identity, !Task.isCancelled else { return }
                answered.append(await self.runAside(ask.text, to: ask.bot, mainName: mainName, note: TaggedNote.note(asker: asker), asked: ask.text))
            }
            guard let self, self.identity == identity, !Task.isCancelled,
                  self.userSendCount == sends, !self.isStreaming, self.outbox.isEmpty else { return }
            let asides = self.messages.filter { answered.contains($0.id) }.map { row in
                AsideNote.Aside(agent: row.delivered?.profile ?? "", name: row.delivered?.name ?? "", asked: row.delivered?.asked ?? "",
                                answer: row.text.isEmpty ? "(no answer: \(row.error ?? "none"))" : row.text)
            }
            guard let note = AsideNote.relayNote(for: asides) else { return }
            for i in self.messages.indices where answered.contains(self.messages[i].id) { self.messages[i].delivered?.noted = true }
            self.startTurn(Message(role: .user, text: note), unseen: true)
            if let reply = self.messages.last?.id { self.followOn?(reply) }
        }
    }

    /// Asks `bot` in its own chat, its answer written here as it comes; the answer's row.
    @discardableResult
    private func runAside(_ text: String, to bot: HermesBot, mainName: String, note: String, asked: String? = nil) async -> UUID {
        let name = bot.label(mainName: mainName)
        var answer = Message(role: .user, text: "")
        answer.delivered = Delivered(kind: .answer, profile: bot.name, name: name, asked: asked)
        answer.metrics = TurnMetrics(sentAt: .now)
        messages.append(answer)
        let id = answer.id
        asideAnswer = id
        defer { if asideAnswer == id { asideAnswer = nil } }
        let departure = TurnDeparture()
        asideDeparture = departure
        var written = ""
        var shown = Date.distantPast
        // A bridge agent's chat for Redde's asks that the bridge no longer has: asked again in a new one.
        var fresh = false
        do {
          while true {
            let (transport, found) = try await asideTransport(for: bot, mainName: mainName)
            let stored = fresh ? nil : found
            var request = TurnRequest(userText: text + note, history: [], sessionID: stored, model: nil, provider: nil,
                                      reasoningEffort: nil, instructions: nil, attachments: [],
                                      replyLanguage: settings.replyLanguage.nilIfEmpty, brief: false)
            request.departure = departure
            do {
            stream: for try await event in transport.stream(request) {
                switch event {
                case let .sessionID(made) where stored == nil: bot.elsewhere.map { TagRoster.keep(session: made, for: $0) }
                case let .textDelta(delta): written += delta
                case let .textFinal(final): written = final
                case .interrupt:
                    // It waits on the person: in its own chat, where it can be answered.
                    departure.leave()
                    update(id) { $0.error = String(localized: "\(name) is waiting for you in its chat.") }
                    break stream
                default: continue
                }
                // Drawn ten times a second at most, as a reply's words are.
                if Date.now.timeIntervalSince(shown) > 0.1 {
                    shown = .now
                    update(id) { $0.text = written }
                }
            }
            } catch let error where !fresh && stored != nil && written.isEmpty && bot.elsewhere?.agent != nil && !(error is CancellationError) {
                bot.elsewhere.map { TagRoster.keep(session: nil, for: $0) }
                fresh = true
                continue
            }
            break
          }
            update(id) { message in
                message.text = written
                message.metrics?.completedAt = .now
                if written.isEmpty, message.error == nil { message.error = String(localized: "\(name) didn't answer.") }
            }
        } catch is CancellationError {
            update(id) { $0.text = written }
        } catch {
            update(id) { $0.text = written; $0.error = error.localizedDescription; $0.metrics?.completedAt = .now }
        }
        persist()
        return id
    }

    /// Where a bot's turn goes: its Bot Chat, on the Dashboard or (one added for the Hermes API
    /// alone) at /p/<profile>/ with its own key. A test's transport, for a test.
    private func asideTransport(for bot: HermesBot, mainName: String) async throws -> (any HermesTransport, String?) {
        if let transportOverride { return (transportOverride, "aside-" + bot.name) }
        #if DEBUG
        if DemoDay.on { return (DemoDayTransport(), "aside-" + bot.name) }   // the day's video: canned answers
        if DemoAgents.on { return (DemoAgentsTransport(bot: bot.name), "aside-" + bot.name) }   // the agents video's
        #endif
        return try await BotTurns.transport(for: bot, mainName: mainName, settings: settings, dashboard: dashboard)
    }

    /// Another chat opened: an aside under way goes on in its bot's chat, unwatched here.
    func letGoOfAsides() {
        asideDeparture?.leave()
        asideTask?.cancel()
        asideTask = nil
        asideDeparture = nil
        asideAnswer = nil
    }

    /// An answer that was being written when its chat was left: over, and where it went.
    nonisolated static func settleAsides(_ messages: inout [Message], except running: UUID?) {
        for i in messages.indices where messages[i].delivered?.kind == .answer && messages[i].id != running
            && messages[i].metrics != nil && messages[i].metrics?.completedAt == nil {
            var answer = messages[i]
            answer.metrics?.completedAt = answer.createdAt
            if answer.text.isEmpty, answer.error == nil {
                let name = answer.delivered?.name ?? ""
                answer.error = String(localized: "Left before \(name) answered. Its answer is in its chat.")
            }
            messages[i] = answer
        }
    }

    /// Transfers boundaries reconstructed from the Dashboard's stored rows onto the Serve resume
    /// transcript. Both views use the host's timestamps, so split or repeated assistant text is
    /// unambiguous without comparing the phone's clock or rewriting any message content.
    nonisolated static func restoringServerTurnStarts(from hints: [Message], in host: [Message]) -> [Message] {
        var restored = host
        func visibleText(_ message: Message) -> String {
            ServeMedia.named(in: message.text).text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var after = restored.startIndex
        for hintIndex in hints.indices where hints[hintIndex].role == .assistant && hints[hintIndex].beginsAssistantTurn {
            let hint = hints[hintIndex]
            let sameTime = restored.indices.filter {
                $0 >= after && restored[$0].role == .assistant
                    && abs(restored[$0].createdAt.timeIntervalSince(hint.createdAt)) < 0.001
            }
            let sameTextAndTime = sameTime.filter { visibleText(restored[$0]) == visibleText(hint) }
            var match = sameTextAndTime.count == 1 ? sameTextAndTime.first : (sameTime.count == 1 ? sameTime.first : nil)
            if match == nil {
                let text = visibleText(hint)
                let hintCount = hints.count { $0.role == .assistant && visibleText($0) == text }
                let occurrence = hints[...hintIndex].count { $0.role == .assistant && visibleText($0) == text } - 1
                let matches = restored.indices.filter { restored[$0].role == .assistant && visibleText(restored[$0]) == text }
                if matches.count == hintCount, matches.indices.contains(occurrence), matches[occurrence] >= after {
                    match = matches[occurrence]
                }
            }
            guard let match else { continue }
            restored[match].beginsAssistantTurn = true
            after = restored.index(after: match)
        }
        return restored
    }

    /// The host's transcript, with display-only turn boundaries, reactions, and the asides here it
    /// doesn't have yet (not told to the agent) put back where they came.
    nonisolated static func keepingAsides(of here: [Message], in host: [Message], restoringTurnStarts: Bool = false) -> [Message] {
        var merged = host
        // The messages route may be unavailable on an older host. Preserve a local boundary only
        // when its preceding reply's normalized occurrences map one-to-one; never guess among
        // duplicate server segments and split a turn at the wrong row.
        func visibleText(_ message: Message) -> String {
            ServeMedia.named(in: message.text).text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if restoringTurnStarts {
            var afterHostIndex = merged.startIndex
            for turn in here.indices where here[turn].role == .assistant && here[turn].beginsAssistantTurn {
                guard let anchor = here[..<turn].lastIndex(where: { $0.role == .assistant && !$0.isAside }) else { continue }
                let text = visibleText(here[anchor])
                let localCount = here.count { $0.role == .assistant && !$0.isAside && visibleText($0) == text }
                let occurrence = here[...anchor].count { $0.role == .assistant && !$0.isAside && visibleText($0) == text } - 1
                let matches = merged.indices.filter { merged[$0].role == .assistant && visibleText(merged[$0]) == text }
                guard matches.count == localCount, matches.indices.contains(occurrence) else { continue }
                let matched = matches[occurrence]
                let following = merged.index(after: matched)
                guard matched >= afterHostIndex, following < merged.endIndex, merged[following].role == .assistant else { continue }
                merged[following].beginsAssistantTurn = true
                afterHostIndex = following
            }
        }
        // Reactions (`Reactions`): the host has none; each goes back on the reply it was made to,
        // known by how it begins.
        var reacted: [String: [Message]] = [:]
        for message in here where message.role == .assistant && message.reaction != nil {
            reacted[Reactions.opening(of: message.text, limit: 200), default: []].append(message)
        }
        if !reacted.isEmpty {
            for i in merged.indices where merged[i].role == .assistant && merged[i].reaction == nil {
                let key = Reactions.opening(of: merged[i].text, limit: 200)
                guard let found = reacted[key]?.first else { continue }
                reacted[key]?.removeFirst()
                merged[i].reaction = found.reaction
                merged[i].reactionSaid = found.reactionSaid
            }
        }
        // Asides the agent hasn't heard of, and questions it asked mid-turn with their answers
        // (`AnsweredQuestions`): neither is a message on the host.
        for aside in here where (aside.isAside && aside.delivered?.noted != true || aside.isSteer && aside.answering != nil && Self.turnKept(aside, in: host))
            && !merged.contains(where: { $0.id == aside.id }) {
            let at = merged.firstIndex { $0.createdAt > aside.createdAt && !$0.isAside } ?? merged.endIndex
            merged.insert(aside, at: at)
        }
        return merged
    }

    /// An answer row stays only while the host still has its turn: the person's message that
    /// began it before the row, and the reply that asked after it (or none yet, within the hour:
    /// the turn may still be going). 2026-11-07 two answers from a failed turn, which Hermes
    /// never saved, stood at the top of every new chat with Sol.
    nonisolated static func turnKept(_ answer: Message, in host: [Message], now: Date = .now) -> Bool {
        let saved = host.filter { !$0.isAside }
        guard saved.contains(where: { $0.role == .user && $0.createdAt < answer.createdAt }) else { return false }
        guard let next = saved.first(where: { $0.createdAt > answer.createdAt }) else {
            return now.timeIntervalSince(answer.createdAt) < 3600
        }
        return next.role == .assistant
    }

    func update(_ id: UUID, _ body: (inout Message) -> Void) {
        // The reply being updated is almost always the last message.
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        body(&messages[index])
    }
}

// Conversation's routines, reactions and asides to bots.
import Foundation

extension Conversation {
    // MARK: - Routines (`RoutineNote`)

    /// "Make This a Routine": a message asking the agent to keep what it did here as a skill.
    func makeRoutine(name: String, skill: String, when: String?, asked: String? = nil) {
        pendingNote = RoutineNote.note(name: name, skill: skill, when: when, asked: asked)
        _ = send(String(localized: "Make this a routine: “\(name)”.", comment: "The message a chat's Make This a Routine sends, with the routine's name"))
    }

    /// A card answered with a tap: `shown` as the person's message, `said` in its note.
    /// What the user asked for a reply: their message just before it, in plain words, clipped.
    func asked(before reply: UUID) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == reply }) else { return nil }
        guard let mine = messages[..<index].last(where: { $0.role == .user }) else { return nil }
        let text = RoutineNote.strip(mine.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(300))
    }

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
                await self.runAside(text, to: bot, mainName: mainName, chat: chat)
            }
        }
    }

    private func runAside(_ text: String, to bot: HermesBot, mainName: String, chat: String) async {
        let name = bot.label(mainName: mainName)
        var answer = Message(role: .user, text: "")
        answer.delivered = Delivered(kind: .answer, profile: bot.name, name: name)
        answer.metrics = TurnMetrics(sentAt: .now)
        messages.append(answer)
        let id = answer.id
        asideAnswer = id
        defer { if asideAnswer == id { asideAnswer = nil } }
        let departure = TurnDeparture()
        asideDeparture = departure
        var written = ""
        var shown = Date.distantPast
        do {
            let (transport, stored) = try await asideTransport(for: bot, mainName: mainName)
            var request = TurnRequest(userText: text + BotAsides.note(from: chat), history: [], sessionID: stored, model: nil, provider: nil,
                                      reasoningEffort: nil, instructions: nil, attachments: [],
                                      replyLanguage: settings.replyLanguage.nilIfEmpty, brief: false)
            request.departure = departure
            stream: for try await event in transport.stream(request) {
                switch event {
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
    }

    /// Where a bot's turn goes: its Bot Chat, on the Dashboard or (one added for the Hermes API
    /// alone) at /p/<profile>/ with its own key. A test's transport, for a test.
    private func asideTransport(for bot: HermesBot, mainName: String) async throws -> (any HermesTransport, String) {
        if let transportOverride { return (transportOverride, "aside-" + bot.name) }
        #if DEBUG
        if DemoDay.on { return (DemoDayTransport(), "aside-" + bot.name) }   // the day's video: canned answers
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

import Foundation
import Testing
@testable import Echo

/// Every agent can be asked by @mention (2.7, his ask 2026-11-17): bridge agents and other
/// servers' bots are tagged like the open Hermes's bots, from a Hermes chat or a bridge chat.
@MainActor
struct TagRosterTests {
    private func bridge(_ address: String, agent: String = "claude", allAgents: Bool = true) -> HermesServer {
        var server = HermesServer(id: UUID(), name: "Paloma bridge", transport: .acp)
        server.acpURL = address
        server.acpAgent = agent
        server.acpAllAgents = allAgents
        return server
    }

    private let agents = [AcpEndpoint.Agent(id: "claude", name: "Claude Code"), AcpEndpoint.Agent(id: "pi", name: "Pi"),
                          AcpEndpoint.Agent(id: "openclaw", name: "OpenClaw")]

    @Test func everyBridgeAgentAndOtherServersBotIsListedOnce() {
        let home = HermesServer(id: UUID(), name: "Sol")
        let other = HermesServer(id: UUID(), name: "Lab")
        let paloma = bridge("ws://paloma.test:8767")
        let same = bridge("ws://PALOMA.test:8767 ")   // a second server on the same bridge
        let bare = bridge("paloma.test:8767")          // and a third, written without ws:// (Marta, 11-17)
        let chat = HermesServer(id: UUID(), name: "Fast", transport: .chatCompletions)
        let hermes: [UUID: [HermesBot]] = [
            home.id: [HermesBot(name: "default", isDefault: true)],
            other.id: [HermesBot(name: "default", isDefault: true), HermesBot(name: "scout", title: "Scout"),
                       HermesBot(name: "hidden", isHidden: true)],
        ]
        let found = TagRoster.others(servers: [home, other, paloma, same, bare, chat], active: home.id,
                                     agents: { $0.lowercased().contains("paloma") ? agents : [] }, hermes: hermes)
        #expect(found.map { $0.label() } == ["Lab", "Scout", "Claude Code", "Pi", "OpenClaw"],
                "the open server's bots are BotDirectory's; a hidden one, and a chat-completions server, have none")
        #expect(found.allSatisfy { $0.elsewhere != nil && $0.name.contains("@") }, "never a profile of the open Hermes's")
        #expect(found[2].elsewhere == BotElsewhere(server: paloma.id, serverName: "Paloma bridge", agent: "claude", profile: nil))
        #expect(found[0].elsewhere?.profile == "default" && found[1].elsewhere?.profile == "scout")

        // A bridge that hasn't listed its agents yet: the one it's set to.
        let unlisted = TagRoster.others(servers: [home, bridge("ws://new.test", agent: "codex")], active: home.id, agents: { _ in [] }, hermes: [:])
        #expect(unlisted.map { $0.label() } == ["codex"])
    }

    @Test func aTagFindsABridgeAgentByItsIdOrName() {
        let paloma = bridge("ws://paloma.test:8767")
        let others = TagRoster.others(servers: [paloma], active: UUID(), agents: { _ in agents }, hermes: [:])
        let coder = HermesBot(name: "claude", title: "Coder")
        let roster = [coder] + others
        #expect(BotMentions.mentioned(in: "@pi count the files", roster: roster, to: "default").map { $0.label() } == ["Pi"])
        #expect(BotMentions.mentioned(in: "ask @claude-code and @openclaw", roster: roster, to: "default").map { $0.label() } == ["Claude Code", "OpenClaw"])
        #expect(BotMentions.mentioned(in: "@claude?", roster: roster, to: "default").isEmpty,
                "Coder's profile is claude too: a tag two answer to asks neither")
        #expect(BotMentions.mentioned(in: "@coder hi", roster: roster, to: "default").map(\.name) == ["claude"])
        // In Claude Code's own chat on that bridge, it isn't asked; the others are.
        let speaking = TagRoster.speaker(agent: "claude", server: paloma.id)
        #expect(BotMentions.mentioned(in: "@claude-code @pi", roster: others, to: speaking).map { $0.label() } == ["Pi"])
        #expect(BotMentions.tag(for: others[0]) == "claude-code" && BotMentions.tag(for: others[1]) == "pi")
    }

    /// From a Hermes chat: "@pi" asks Pi on the bridge, in its own chat there, and Sol hears of it
    /// with the next message.
    @Test func aHermesChatAsksABridgeAgent() async throws {
        let settings = Settings(defaults: UserDefaults(suiteName: "tags-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let address = "ws://tags-\(UUID().uuidString.prefix(6)).test:8767"
        var paloma = bridge(address)
        paloma.id = settings.addServer(name: "Paloma bridge")
        settings.servers = settings.servers.map { $0.id == paloma.id ? paloma : $0 }
        AcpAgents.remember(agents, address: address)
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "tags-\(UUID().uuidString)"))
        let transport = BotsTests.RecordingTransport()
        let conversation = Conversation(settings: settings, store: store, transportOverride: transport)
        conversation.reset()

        let asked = try await ask(conversation, transport, "@pi how many files are there?")
        let pi = TagRoster.name("pi", paloma.id)
        #expect(asked.sessionID == "aside-" + pi && asked.userText.contains("tagged you"))
        for _ in 0 ..< 200 where conversation.messages.last?.metrics?.completedAt == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(conversation.messages.map(\.delivered?.kind) == [.asked, .answer])
        #expect(conversation.messages.last?.delivered?.profile == pi && conversation.messages.last?.delivered?.name == "Pi")

        let next = try await ask(conversation, transport, "Thanks.")
        #expect(AsideNote.split(next.userText).asides.map(\.name) == ["Pi"], "the chat's agent hears of it")
    }

    /// Sol's own chat is a bot's chat (the Drawer's): the agents elsewhere are offered and asked
    /// there too, while its Hermes's bots stay Hermes's to pass a tag to (11-17, on Marta).
    @Test func aBotsChatAsksABridgeAgentAndLeavesItsOwnBotsToHermes() async throws {
        let settings = Settings(defaults: UserDefaults(suiteName: "tags-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let address = "ws://tags-\(UUID().uuidString.prefix(6)).test:8767"
        var paloma = bridge(address)
        paloma.id = settings.addServer(name: "Paloma bridge")
        settings.servers = settings.servers.map { $0.id == paloma.id ? paloma : $0 }
        AcpAgents.remember(agents, address: address)
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "tags-\(UUID().uuidString)"))
        let transport = BotsTests.RecordingTransport()
        let conversation = Conversation(settings: settings, store: store, transportOverride: transport)
        conversation.load(ConversationRecord(id: UUID(), title: "Sol", createdAt: .now, updatedAt: .now, transport: .hermesServe,
                                             serverSessionID: "s-sol", messages: [], name: "Sol", bot: BotRef(profile: "default", name: "Sol")))
        #expect(conversation.tagRoster.map { $0.label() } == ["Claude Code", "Pi", "OpenClaw"], "only those elsewhere")

        let asked = try await ask(conversation, transport, "@pi how many files?")
        #expect(asked.sessionID == "aside-" + TagRoster.name("pi", paloma.id), "asked in Pi's own chat, not Sol's")
        for _ in 0 ..< 200 where conversation.messages.last?.metrics?.completedAt == nil { try await Task.sleep(for: .milliseconds(10)) }
        let next = try await ask(conversation, transport, "@scout and you?")
        #expect(next.sessionID == "s-sol", "its own bot's tag goes to Sol, as before")
        #expect(AsideNote.split(RosterNote.strip(next.userText)).asides.map(\.name) == ["Pi"], "and Sol hears what Pi said")
    }

    /// From a bridge chat: Claude Code's chat asks Pi (and never itself), and the note reaches the
    /// bridge agent too.
    @Test func aBridgeChatAsksAnotherAgentButNotItself() async throws {
        let settings = Settings(defaults: UserDefaults(suiteName: "tags-\(UUID().uuidString)")!)
        let address = "ws://tags-\(UUID().uuidString.prefix(6)).test:8767"
        settings.transport = .acp
        settings.acpURL = address
        settings.acpAgent = "claude"
        settings.acpAllAgents = true
        settings.syncActiveServer()
        AcpAgents.remember(agents, address: address)
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "tags-\(UUID().uuidString)"))
        let transport = BotsTests.RecordingTransport()
        let conversation = Conversation(settings: settings, store: store, transportOverride: transport)
        conversation.reset()
        #expect(conversation.connection == .acp)

        let mine = try await ask(conversation, transport, "@claude-code fix the test")
        #expect(mine.sessionID == nil && !mine.userText.contains("tagged you"), "the chat's own agent, in this chat")
        _ = try await ask(conversation, transport, "@openclaw what's on the list?")
        for _ in 0 ..< 200 where conversation.messages.last?.metrics?.completedAt == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(conversation.messages.last?.delivered?.name == "OpenClaw")
        let next = try await ask(conversation, transport, "Go on.")
        #expect(AsideNote.split(next.userText).asides.map(\.name) == ["OpenClaw"])
    }

    /// Read back from the bridge: the note to the chat's agent comes off and its asides show as they
    /// did; the note to the agent that was tagged comes off in its own chat.
    @Test func aBridgeChatReadBackShowsItsAsides() {
        let note = AsideNote.note(for: [AsideNote.Aside(agent: "pi@1", name: "Pi", asked: "@pi count", answer: "Four.")])!
        let updates: [JSONValue] = [
            .object(["sessionUpdate": .string("user_message_chunk"), "content": .object(["type": .string("text"), "text": .string("Thanks." + note)])]),
            .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("Sure.")])]),
            .object(["sessionUpdate": .string("user_message_chunk"),
                     "content": .object(["type": .string("text"), "text": .string("@pi count" + TaggedNote.note(from: "Sol"))])]),
        ]
        let read = AcpHistory.messages(updates)
        #expect(read.map(\.text) == ["@pi count", "Four.", "Thanks.", "Sure.", "@pi count"])
        #expect(read.map(\.delivered?.kind) == [.asked, .answer, nil, nil, nil])
        #expect(ReplyLanguage.stripNote("Hi" + TaggedNote.note(from: "Sol")) == "Hi", "and in a Hermes bot's own chat")
    }

    // MARK: Agents asking each other (relay and report back)

    @Test func aReplyAsksOnlyByALineThatBeginsWithATag() {
        let paloma = bridge("ws://paloma.test:8767")
        let roster = TagRoster.others(servers: [paloma], active: UUID(), agents: { _ in agents }, hermes: [:])
        let speaking = TagRoster.speaker(agent: "claude", server: paloma.id)
        let reply = """
        As @pi said, the tests pass.
        @openclaw can you check the list?
        It's in notes.md.

        - **@pi**, @openclaw: what time is it?
        ```
        @pi not in code
        ```
        @claude-code never myself
        """
        let asks = BotAsides.relayed(in: reply, roster: roster, speaking: speaking)
        #expect(asks.map { $0.bot.label() } == ["OpenClaw", "Pi"])
        #expect(asks.first?.text == "@openclaw can you check the list?\nIt's in notes.md.\n\n- **@pi**, @openclaw: what time is it?")
        #expect(asks.last?.text == "- **@pi**, @openclaw: what time is it?")
        #expect(BotAsides.relayed(in: "Ask @pi, maybe.", roster: roster, speaking: speaking).isEmpty)
    }

    @Test func theNotesComeOffAndARelayReadsBackAsItsAnswers() {
        let roster = RosterNote.note(["@pi (Pi on Paloma)", "@open[claw] (OpenClaw)"])!
        #expect(!roster.contains("[claw]"))
        #expect(ReplyLanguage.stripNote("Hi" + roster + "\n\n(Reply in French.)") == "Hi")
        let relay = AsideNote.relayNote(for: [AsideNote.Aside(agent: "pi@1", name: "Pi", asked: "@pi count", answer: "Four.")])!
        let (text, asides) = AsideNote.split(relay)
        #expect(text.isEmpty && asides.first?.relayed == true && !relay.contains("relayed"))
        let rows = AsideNote.messages(asides[0], before: .now)
        #expect(rows.map(\.delivered?.kind) == [.answer] && rows[0].delivered?.asked == "@pi count" && rows[0].text == "Four.")
        #expect(TaggedNote.strip("Count" + TaggedNote.note(asker: "Sol")) == "Count")
    }

    /// Sol's reply asks Pi by a line of its own: Pi is asked, its answer shows, and Sol goes on
    /// with it in a turn that shows no message of the person's.
    @Test func anAgentsTagIsAskedAndItsAnswerGivenBack() async throws {
        let (conversation, transport, pi) = try relayChat { request in
            if request.sessionID?.hasPrefix("aside-") == true { return "Four files." }
            if request.userText.contains(AsideNote.relayOpening) { return "Pi says there are four." }
            return "Let me ask.\n@pi how many files are there?"
        }
        let first = try await ask(conversation, transport, "How many files?")
        #expect(first.userText.contains(RosterNote.opening) && first.userText.contains("@pi (Pi on Paloma bridge)"))
        try await settle(conversation, transport)
        #expect(conversation.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        let answer = conversation.messages[2]
        #expect(answer.delivered?.kind == .answer && answer.delivered?.profile == pi && answer.text == "Four files." && answer.delivered?.noted == true)
        #expect(conversation.messages[3].text == "Pi says there are four." && conversation.messages[3].beginsAssistantTurn)
        let asked = transport.requests[1], back = transport.requests[2]
        #expect(asked.userText.hasPrefix("@pi how many files are there?") && asked.userText.contains(TaggedNote.agentOpening))
        #expect(back.userText.hasPrefix(AsideNote.relayOpening) && back.userText.contains("Four files."))
        let next = try await ask(conversation, transport, "Thanks.")
        #expect(!next.userText.contains(RosterNote.opening) && !next.userText.contains(AsideNote.opening), "told once; the answer was given back already")
    }

    /// Agents that keep asking each other stop after `relayLimit` rounds, until the person writes.
    @Test func agentsAskingEachOtherStopAfterThreeRounds() async throws {
        let (conversation, transport, _) = try relayChat { request in
            request.sessionID?.hasPrefix("aside-") == true ? "Ask me again." : "@pi once more"
        }
        _ = try await ask(conversation, transport, "Go.")
        try await settle(conversation, transport)
        #expect(transport.requests.filter { $0.sessionID?.hasPrefix("aside-") == true }.count == Conversation.relayLimit)
        #expect(conversation.relayHops == Conversation.relayLimit)
        _ = try await ask(conversation, transport, "Again.")
        try await settle(conversation, transport)
        #expect(transport.requests.filter { $0.sessionID?.hasPrefix("aside-") == true }.count == 2 * Conversation.relayLimit,
                "the person wrote: three more")
    }

    @Test func withAgentsAskingEachOtherOffOnlyThePersonsTagsAsk() async throws {
        let (conversation, transport, _) = try relayChat { request in
            request.sessionID?.hasPrefix("aside-") == true ? "Four." : "@pi how many?"
        }
        conversation.settings.agentsAskEachOther = false
        let first = try await ask(conversation, transport, "How many files?")
        try await settle(conversation, transport)
        #expect(!first.userText.contains(RosterNote.opening) && transport.requests.count == 1, "not told, not passed on")
        _ = try await ask(conversation, transport, "@pi how many?")
        try await settle(conversation, transport)
        #expect(transport.requests.last?.sessionID?.hasPrefix("aside-") == true, "the person's own tag still asks")
    }

    /// `askFirst`: Ask Me First, on at first; the tests of what's asked turn it off.
    // MARK: Ask Me First

    private func asides(_ transport: ScriptedTransport) -> Int { transport.requests.filter { $0.sessionID?.hasPrefix("aside-") == true }.count }

    /// Ask Me First (on at first): Sol's tag of Pi waits on the person's OK, as an approval card,
    /// and Pi is asked, and Sol given its answer, only once it's given.
    @Test func anAgentsTagWaitsForThePersonsOK() async throws {
        #expect(Settings(defaults: UserDefaults(suiteName: "tags-\(UUID().uuidString)")!).askBeforeAgentsAsk, "on at first")
        let (conversation, transport, _) = try relayChat(askFirst: true) { request in
            if request.sessionID?.hasPrefix("aside-") == true { return "Four files." }
            if request.userText.contains(AsideNote.relayOpening) { return "Pi says there are four." }
            return "Let me ask.\n@pi how many files are there?"
        }
        _ = try await ask(conversation, transport, "How many files?")
        try await settle(conversation, transport)
        #expect(asides(transport) == 0, "nobody asked yet")
        guard case let .approval(request)? = conversation.pendingInterrupt?.interrupt else { Issue.record("no card"); return }
        #expect(AgentAsks.isAsk(request) && request.command == "@pi how many files are there?")
        #expect(request.description?.contains("Pi") == true && request.yesNo?.approve == "once")
        #expect(SpokenRequest(.approval(request))?.prompt.contains("Approval needed") == false, "said as the ask it is")

        conversation.respond(approval: "once")
        try await settle(conversation, transport)
        #expect(conversation.pendingInterrupt == nil && asides(transport) == 1)
        #expect(conversation.messages.last?.text == "Pi says there are four.")
    }

    /// Said no: nobody is asked, and Sol hears so with the person's next message.
    @Test func aDeclinedAskAsksNobodyAndTheAgentIsTold() async throws {
        let (conversation, transport, _) = try relayChat(askFirst: true) { request in
            request.userText.hasPrefix("How many") ? "@pi how many?" : "Fine."
        }
        _ = try await ask(conversation, transport, "How many files?")
        try await settle(conversation, transport)
        conversation.respond(approval: "deny")
        try await settle(conversation, transport)
        #expect(asides(transport) == 0 && conversation.pendingInterrupt == nil && transport.requests.count == 1)
        let next = try await ask(conversation, transport, "Count them yourself.")
        #expect(next.userText.contains(DeclinedNote.opening + "@pi"))
        #expect(ReplyLanguage.stripNote(next.userText) == "Count them yourself.", "the note never shows")
        let after = try await ask(conversation, transport, "Thanks.")
        #expect(!after.userText.contains(DeclinedNote.opening), "told once")
    }

    /// The person wrote again without answering: their message goes, and the ask doesn't.
    @Test func writingAgainLeavesTheAskUnasked() async throws {
        let (conversation, transport, _) = try relayChat(askFirst: true) { request in
            request.userText.hasPrefix("How many") ? "@pi how many?" : "Fine."
        }
        _ = try await ask(conversation, transport, "How many files?")
        try await settle(conversation, transport)
        #expect(conversation.pendingInterrupt != nil)
        let next = try await ask(conversation, transport, "Never mind.")
        try await settle(conversation, transport)
        #expect(asides(transport) == 0 && conversation.pendingInterrupt == nil)
        #expect(next.userText.contains(DeclinedNote.opening))
    }

    /// A Hermes bot's hand-off held by Redde's plugin (asks.py) is shown as the Ask card: in names,
    /// said aloud as the ask it is, and answered on the host like any approval.
    @Test func aHeldHermesHandOffIsShownAsTheAsk() {
        let held = ApprovalRequest(id: "srq-1", command: "<message_agent> (plugin approval rule)",
                                   description: "Ask @code, @scout: Count the Swift files in Echo/Views.", choices: ["once", "session", "always", "deny"])
        #expect(AgentAsks.hermesAsk(held)?.handles == ["code", "scout"])
        guard case let .approval(shown) = AgentAsks.dressed(.approval(held), asker: "Sol", name: { $0.capitalized }) else { Issue.record(); return }
        #expect(AgentAsks.isAsk(shown) && !AgentAsks.isLocal(shown), "the host's to answer")
        #expect(shown.id == "srq-1" && shown.yesNo?.approve == "once")
        #expect(shown.description == "Sol wants to ask Code and Scout" && shown.command == "Count the Swift files in Echo/Views.")
        let spoken = SpokenRequest(.approval(shown))?.prompt ?? ""
        #expect(spoken.hasPrefix("Sol wants to ask Code and Scout") && !spoken.contains("Approval needed") && !spoken.contains("message_agent"))
        // Anything else is left as it came.
        let command = ApprovalRequest(id: "c", command: "rm -rf build", description: "recursive delete", choices: ["once", "deny"])
        #expect(AgentAsks.dressed(.approval(command), asker: "Sol", name: { $0 }) == .approval(command))
        #expect(AgentAsks.hermesAsk(ApprovalRequest(id: "x", command: "<message_agent> (plugin approval rule)", description: "something else", choices: [])) == nil)
    }

    /// Hermes Bots off: Sol neither hears of its Hermes's bots nor asks them by a tag here, while a
    /// bridge's agents it still asks (Other Agents); in a bot's chat, the person's tags of them are
    /// Redde's to ask, with no note for Hermes to pass on. All at once: the bot directory is shared.
    @Test func hermesBotsAndOtherAgentsAreSwitchedApart() throws {
        let (conversation, _, _) = try relayChat(askFirst: true) { _ in "" }
        let settings = conversation.settings
        let roster = BotRoster(try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"profiles": [{"name": "default", "is_default": true, "ui_meta_revisions": {}},
                          {"name": "scout", "is_default": false, "ui_meta_revisions": {"hermes-bots": 1}, "ui_meta": {"hermes-bots": {}}}],
             "bot_mode_protocol": true}
            """.utf8)))
        BotDirectory.shared.set(roster, key: settings.connectionKey)
        defer { BotDirectory.shared.set(nil, key: "") }
        settings.showBots = true

        func proposed(_ reply: String) -> String? {
            conversation.pendingInterrupt = nil
            conversation.relayHops = 0
            var message = Message(role: .assistant, text: reply)
            message.metrics = TurnMetrics(sentAt: .now)
            conversation.messages.append(message)
            conversation.relayTags(from: message.id)
            guard case let .approval(request)? = conversation.pendingInterrupt?.interrupt else { return nil }
            return request.command
        }
        UserDefaults.standard.removeObject(forKey: "rosterTold." + conversation.id.uuidString)
        #expect(conversation.rosterNote()?.contains("@scout") == true)
        #expect(proposed("@scout look it up\n@pi count") == "@scout look it up\n@pi count")

        settings.hermesBotsTalk = false
        UserDefaults.standard.removeObject(forKey: "rosterTold." + conversation.id.uuidString)
        let note = conversation.rosterNote()
        #expect(note?.contains("@scout") == false && note?.contains("@pi") == true)
        #expect(proposed("@scout look it up\n@pi count") == "@pi count", "only the bridge's agent")

        settings.hermesBotsTalk = true
        settings.agentsAskEachOther = false
        #expect(proposed("@scout look it up\n@pi count") == "@scout look it up\n@pi count", "Scout's ask, the line that isn't one going with it")
        #expect(proposed("@pi count") == nil, "Pi not asked")
        settings.hermesBotsTalk = false
        #expect(proposed("@scout look it up\n@pi count") == nil && conversation.rosterNote() == nil, "both off: nobody")

        // Sol's own chat: its Hermes's bots are Hermes's to reach while it lets them talk, Redde's when not.
        conversation.load(ConversationRecord(id: UUID(), title: "Sol", createdAt: .now, updatedAt: .now, transport: .hermesServe,
                                             serverSessionID: "s-sol", messages: [], name: "Sol", bot: BotRef(profile: "default", name: "Sol")))
        settings.hermesBotsTalk = true
        #expect(!conversation.tagRoster.contains { $0.name == "scout" })
        settings.hermesBotsTalk = false
        #expect(conversation.tagRoster.contains { $0.name == "scout" })
    }

    private func relayChat(askFirst: Bool = false, _ answer: @escaping @Sendable (TurnRequest) -> String) throws -> (Conversation, ScriptedTransport, String) {
        let settings = Settings(defaults: UserDefaults(suiteName: "tags-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        settings.askBeforeAgentsAsk = askFirst
        let address = "ws://tags-\(UUID().uuidString.prefix(6)).test:8767"
        var paloma = bridge(address)
        paloma.id = settings.addServer(name: "Paloma bridge")
        settings.servers = settings.servers.map { $0.id == paloma.id ? paloma : $0 }
        AcpAgents.remember(agents, address: address)
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "tags-\(UUID().uuidString)"))
        let transport = ScriptedTransport(answer: answer)
        let conversation = Conversation(settings: settings, store: store, transportOverride: transport)
        conversation.reset()
        return (conversation, transport, TagRoster.name("pi", paloma.id))
    }

    /// Until nothing has been asked for a while and no turn is running.
    private func settle(_ conversation: Conversation, _ transport: ScriptedTransport) async throws {
        var quiet = 0, seen = transport.requests.count
        while quiet < 20 {
            try await Task.sleep(for: .milliseconds(20))
            let now = transport.requests.count
            quiet = now == seen && !conversation.isStreaming && conversation.asideAnswer == nil ? quiet + 1 : 0
            seen = now
        }
    }

    final class ScriptedTransport: HermesTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [TurnRequest] = []
        private let answer: @Sendable (TurnRequest) -> String
        init(answer: @escaping @Sendable (TurnRequest) -> String) { self.answer = answer }
        var requests: [TurnRequest] { lock.withLock { kept } }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            lock.withLock { kept.append(request) }
            let text = answer(request)
            return AsyncThrowingStream { continuation in
                continuation.yield(.sessionID(request.sessionID ?? "stored-new"))
                continuation.yield(.textDelta(text))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    private func ask(_ conversation: Conversation, _ transport: ScriptedTransport, _ text: String) async throws -> TurnRequest {
        let before = transport.requests.count
        _ = conversation.send(text)
        for _ in 0 ..< 200 where transport.requests.count == before || conversation.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(transport.requests.dropFirst(before).first)
    }

    private func ask(_ conversation: Conversation, _ transport: BotsTests.RecordingTransport, _ text: String) async throws -> TurnRequest {
        let before = transport.requests.count
        _ = conversation.send(text)
        for _ in 0 ..< 200 where transport.requests.count == before || conversation.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(transport.requests.last)
    }
}

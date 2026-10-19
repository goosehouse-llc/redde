import Foundation
import Testing
@testable import Echo

/// Bots (Hermes's Bot Mode on the Dashboard): the roster as `profiles.list` gives it, which bots
/// the chat list shows, @mentions in a bot's chat and the note that goes with them. What Hermes
/// does with all of it is checked against real Hermes in `HermesLabBotsTests` (lab.sh bots).
@MainActor
struct BotsTests {
    private func roster(_ json: String) throws -> BotRoster {
        BotRoster(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    private static let listing = """
        {"profiles": [
          {"name": "default", "is_default": true, "model": "alpha", "description": "", "display_name": "",
           "ui_meta_revisions": {}, "canonical_session": null},
          {"name": "scout", "is_default": false, "model": "beta", "description": "Finds things out", "display_name": "",
           "previous_names": ["finder"], "ui_meta_revisions": {"hermes-bots": 3},
           "ui_meta": {"hermes-bots": {"title": "Research Buddy"}},
           "canonical_session": {"id": "s-root", "resolved_id": "s-tip", "title": "Bot Chat", "preview": "Here's what I found",
                                 "last_active": 1792000000}},
          {"name": "writer", "is_default": false, "model": "gamma", "description": "", "display_name": "Quill",
           "ui_meta_revisions": {}, "canonical_session": null},
          {"name": "old", "is_default": false, "ui_meta": {"hermes-bots": {"hidden": true}}, "ui_meta_revisions": {}}
        ], "bot_mode_protocol": true}
        """

    @Test func theRosterReadsWhatHermesSaysOfEachBot() throws {
        let roster = try roster(Self.listing)
        #expect(roster.bots.map(\.name) == ["default", "scout", "writer", "old"])
        let scout = try #require(roster.bots.first { $0.name == "scout" })
        #expect(scout.label() == "Research Buddy" && scout.handle == "scout" && scout.isSetUp && scout.setUpRevision == 3)
        #expect(scout.chatID == "s-tip", "the chat's latest part, when Hermes has compressed it")
        #expect(scout.preview == "Here's what I found" && scout.lastActive == Date(timeIntervalSince1970: 1792000000))
        let main = try #require(roster.bots.first { $0.isDefault })
        #expect(main.handle == "hermes" && main.label() == "Redde" && main.label(mainName: "Ada") == "Ada")
        #expect(roster.bots.first { $0.name == "writer" }?.label() == "Quill")
        #expect(roster.messagingIsOn, "a profile set up as a bot turns messaging on")
    }

    @Test func theListShowsBotsOnlyOnceThereIsMoreThanTheMainProfile() throws {
        let roster = try roster(Self.listing)
        #expect(roster.listed.map(\.name) == ["default", "scout", "writer"], "the main one first, then the latest; a hidden bot left out")
        let alone = BotRoster(bots: [HermesBot(name: "default", isDefault: true)])
        #expect(alone.listed.isEmpty)
        let hiddenOthers = BotRoster(bots: [HermesBot(name: "default", isDefault: true), HermesBot(name: "x", isHidden: true)])
        #expect(hiddenOthers.listed.isEmpty)
        #expect(!BotRoster(bots: [HermesBot(name: "default", isDefault: true), HermesBot(name: "x")]).messagingIsOn)
    }

    @Test func aTagFindsTheBotByAnyOfItsNames() throws {
        let bots = try roster(Self.listing).bots
        func tagged(_ text: String, to speaking: String? = "writer") -> [String] {
            BotMentions.mentioned(in: text, roster: bots, to: speaking).map(\.name)
        }
        #expect(tagged("@scout what do you think?") == ["scout"])
        #expect(tagged("ask @research-buddy and @ResearchBuddy") == ["scout"], "its friendly name, either form, once")
        #expect(tagged("@finder still works") == ["scout"], "a name it had before")
        #expect(tagged("@hermes, and @quill") == ["default"], "the bot the message is to isn't tagging anyone")
        #expect(tagged("@quill", to: "scout") == ["writer"])
        #expect(tagged("mail me at sam@example.com") == [], "an address isn't a tag")
        #expect(tagged("`@scout` in code, and ```\n@scout\n```") == [], "a tag inside code is code")
        #expect(tagged("@nobody there") == [])
    }

    @Test func aNameTwoBotsAnswerToTagsNeither() {
        let bots = [HermesBot(name: "default", isDefault: true), HermesBot(name: "a", title: "Helper"), HermesBot(name: "b", displayName: "Helper")]
        #expect(BotMentions.mentioned(in: "@helper", roster: bots, to: "default").isEmpty)
        #expect(BotMentions.mentioned(in: "@a", roster: bots, to: "default").map(\.name) == ["a"])
    }

    @Test func friendlyNamesBecomeTagsButNeverTheReservedOnes() {
        #expect(BotMentions.nameForms("Research Buddy") == ["research-buddy", "researchbuddy"])
        #expect(BotMentions.nameForms("Hermes") == [] && BotMentions.nameForms("All") == [])
        #expect(BotMentions.tag(for: HermesBot(name: "scout", title: "Research Buddy")) == "research-buddy")
        #expect(BotMentions.tag(for: HermesBot(name: "default", isDefault: true)) == "hermes")
    }

    @Test func theNoteSaysWhoEachTagIsAndComesOffAgain() throws {
        let bots = try roster(Self.listing).bots
        let mentioned = BotMentions.mentioned(in: "@scout and @hermes", roster: bots, to: "writer")
        let note = try #require(BotMentions.note(for: mentioned))
        #expect(note.hasPrefix(MentionNote.opening))
        #expect(note.contains(#"@scout = agent profile "scout" ("Research Buddy"); @hermes = agent profile "default""#))
        #expect(note.contains("message_agent"))
        #expect(BotMentions.note(for: []) == nil)
        // What goes to the Dashboard: the message, the note, then the reply-language and car notes.
        let sent = "@scout and @hermes" + note + ReplyLanguage.note("nl") + CarBrevity.note
        #expect(ReplyLanguage.stripNote(sent) == "@scout and @hermes")
        #expect(ReplyLanguage.stripNote("@scout hi" + note) == "@scout hi")
        #expect(ReplyLanguage.stripNote("a [bracketed] line]") == "a [bracketed] line]", "nothing else is taken off")
    }

    @Test func aTagBeingTypedIsSuggestedAndFinished() throws {
        let bots = try roster(Self.listing).listed
        #expect(BotMentions.typing(in: "ask @sc") == "sc")
        #expect(BotMentions.typing(in: "@") == "")
        #expect(BotMentions.typing(in: "ask @scout now") == nil && BotMentions.typing(in: "sam@ex") == nil)
        #expect(BotMentions.suggestions(for: "", roster: bots, to: "writer").map(\.name) == ["default", "scout"])
        #expect(BotMentions.suggestions(for: "res", roster: bots, to: "writer").map(\.name) == ["scout"], "by its friendly name")
        #expect(BotMentions.suggestions(for: "q", roster: bots, to: "scout").map(\.name) == ["writer"])
        let scout = try #require(bots.first { $0.name == "scout" })
        #expect(BotMentions.complete("ask @res", with: scout) == "ask @research-buddy ")
    }

    @Test func everyBotHasACreatureOfItsOwnAndKeepsIt() {
        let names = ["default", "scout", "writer", "fixit", "coder", "research", "work", "personal", "home", "garden"]
        let faces = BotFace.faces(for: names)
        #expect(faces.count == names.count)
        let features = { (all: [BotFace]) in Set(all.map { "\($0.shape)-\($0.eyes)-\($0.mouth)-\($0.mark)" }) }
        #expect(features(Array(faces.values)).count == names.count, "no two bots share a creature")
        #expect(Set(faces.values.map(\.color)).count == names.count, "nor a colour, while there are colours left")
        let firstEight = names.sorted().prefix(8).compactMap { faces[$0] }
        #expect(Set(firstEight.map { "\($0.shape)" }).count == 8, "nor a shape, while there are shapes left")
        #expect(BotFace.faces(for: names.reversed()) == faces, "the same creatures whatever order they come in")
        #expect(BotFace.faces(for: ["scout"])["scout"] == BotFace(seed: "scout"), "a bot alone has the creature its name gives")
        #expect(faces["default"] == BotFace.main && BotFace(seed: "default") == BotFace.main, "the main agent is always Redde's bubble")
        #expect(!faces.filter { $0.key != "default" }.values.contains { $0.shape == .bubble || $0.color == BotFace.main.color },
                "and no other bot has its shape, nor the standard theme's blue")
        let fourteen = BotFace.faces(for: names + ["eleven", "twelve", "thirteen", "fourteen"])
        #expect(features(Array(fourteen.values)).count == 14, "creatures stay apart past the shapes and colours")
    }

    // MARK: - A bot's chat as a conversation

    final class RecordingTransport: HermesTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [TurnRequest] = []
        var requests: [TurnRequest] { lock.withLock { kept } }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            lock.withLock { kept.append(request) }
            return AsyncThrowingStream { continuation in
                continuation.yield(.sessionID(request.sessionID ?? "stored-new"))
                continuation.yield(.textDelta("Done."))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    private func ask(_ conversation: Conversation, _ transport: RecordingTransport, _ text: String) async throws -> TurnRequest {
        let before = transport.requests.count
        _ = conversation.send(text)
        for _ in 0 ..< 200 where transport.requests.count == before || conversation.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(transport.requests.last)
    }

    @Test func aBotsChatSendsTheNoteKeepsItsBotAndIsNeverRenamed() async throws {
        let settings = Settings(defaults: UserDefaults(suiteName: "bots-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "bots-\(UUID().uuidString)"))
        let transport = RecordingTransport()
        let conversation = Conversation(settings: settings, store: store, transportOverride: transport)
        BotDirectory.shared.set(try roster(Self.listing), key: settings.connectionKey)
        defer { BotDirectory.shared.set(nil, key: "") }

        let writer = BotRef(profile: "writer", name: "Quill")
        conversation.load(ConversationRecord(id: UUID(), title: "Quill", createdAt: .now, updatedAt: .now, transport: .hermesServe,
                                             serverSessionID: "s-writer", messages: [], name: "Quill", bot: writer))
        #expect(conversation.bot == writer && conversation.title == "Quill")

        let tagged = try await ask(conversation, transport, "@scout can you check the sources?")
        #expect(tagged.sessionID == "s-writer")
        #expect(tagged.mentionNote?.contains(#"@scout = agent profile "scout""#) == true)
        #expect(conversation.messages.first?.text == "@scout can you check the sources?", "the note isn't shown")
        let plain = try await ask(conversation, transport, "Thanks.")
        #expect(plain.mentionNote == nil)

        await store.flush()
        #expect(store.summaries.first { $0.serverSessionID == "s-writer" }?.bot == writer, "the copy on the iPhone knows its bot")
        try await conversation.rename(to: "Something else")
        #expect(conversation.title == "Quill", "a bot's chat goes by its bot")

        conversation.reset()
        #expect(conversation.bot == nil, "a new conversation is with the agent")
        let fresh = try await ask(conversation, transport, "@scout hello")
        #expect(fresh.mentionNote == nil, "@tags mean nothing outside a bot's chat")
    }
}

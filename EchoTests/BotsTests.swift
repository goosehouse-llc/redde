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

    @Test func aFacePickedForABotIsKeptOnTheServerAndTheOthersGoRoundIt() throws {
        let picked = BotFace(shape: .egg, eyes: .sparkle, mouth: .grin, mark: .spark, glance: 2, tilt: -4, color: 5)
        #expect(BotFace(code: picked.code) == picked, "a picked face reads back as it was written")
        #expect(BotFace(code: "1:bubble:round:none:none:0:1:-3") == nil, "Redde's own bubble can't be picked for a bot")
        #expect(BotFace(code: "2:egg:round:none:none:0:1:0") == nil && BotFace(code: "1:cloud:round:none:none:0:1:0") == nil,
                "a face from a later Redde isn't misread")

        let names = ["default", "scout", "writer", "fixit", "coder"]
        let given = BotFace.faces(for: names)
        let writers = try #require(given["writer"])
        let faces = BotFace.faces(for: names, picked: ["scout": writers])
        #expect(faces["scout"] == writers, "the bot has the face picked for it")
        #expect(faces["writer"].map { "\($0.shape)\($0.eyes)\($0.mouth)\($0.mark)" } != "\(writers.shape)\(writers.eyes)\(writers.mouth)\(writers.mark)",
                "and the bot whose face it was gets another")
        #expect(faces["default"] == BotFace.main, "the main agent stays Redde's bubble")

        let listing = """
            {"profiles": [
              {"name": "default", "is_default": true, "ui_meta_revisions": {}},
              {"name": "scout", "is_default": false, "ui_meta_revisions": {"redde": 2, "hermes-bots": 1},
               "ui_meta": {"redde": {"face": "\(picked.code)"}, "hermes-bots": {}}},
              {"name": "writer", "is_default": false, "ui_meta_revisions": {}, "ui_meta": {"redde": {"face": "nonsense"}}}
            ]}
            """
        let roster = try roster(listing)
        let scout = try #require(roster.bots.first { $0.name == "scout" })
        #expect(scout.face == picked && scout.reddeRevision == 2, "the roster reads the face Redde kept in the profile")
        #expect(roster.bots.first { $0.name == "writer" }?.face == nil, "one it can't read is the face its name gives")
        #expect(roster.faces["scout"] == picked)
    }

    // MARK: - Making and changing bots

    @Test func aNewBotsHandleComesFromItsNameAsHermesTakesIt() {
        #expect(BotNames.handle(for: "Research Buddy", taken: []) == "research-buddy")
        #expect(BotNames.handle(for: "  Café Crème!  ", taken: []) == "cafe-creme", "accents and stray marks fold away")
        #expect(BotNames.handle(for: "Scout", taken: ["scout", "scout-2"]) == "scout-3", "a name in use gets a number")
        #expect(BotNames.handle(for: "SCOUT", taken: ["Scout"]) == "scout-2", "whatever case the taken one was written in")
        #expect(BotNames.handle(for: "Hermes", taken: []) == "hermes-bot" && BotNames.handle(for: "everyone", taken: []) == "everyone-bot",
                "never a name Hermes or @mentions keep for themselves")
        #expect(BotNames.handle(for: "🤖", taken: []) == nil && BotNames.handle(for: "--", taken: []) == nil, "nothing to make one from")
        let long = BotNames.handle(for: String(repeating: "a", count: 90), taken: []) ?? ""
        #expect(long.count <= 64 && long.wholeMatch(of: /[a-z0-9][a-z0-9_-]*/) != nil, "within Hermes's rule for a profile's name")
    }

    @Test func aNewBotWithNoPersonalityWrittenGetsOneFromItsName() {
        let soul = BotNames.soul(title: "Scout", handle: "scout", description: "Finds things out")
        #expect(soul.hasPrefix("# Scout\n\n**Mission:** Finds things out\n\n"))
        #expect(soul.contains("You are Scout, a persistent named agent (profile `scout`)"))
        #expect(!BotNames.soul(title: "Scout", handle: "scout", description: " ").contains("Mission"), "no mission line without one")
    }

    @Test func aBotsSettingsAreChangedOverWhatHermesDesktopKeepsThere() {
        let desktop: [String: JSONValue] = ["title": .string("Old"), "color": .string("#ff8800"), "shape": .string("blob"),
                                            "pinned": .bool(true), "chat": .object(["id": .string("s-1")])]
        let renamed = BotNames.merged(desktop, BotChange(title: " Scout "))
        #expect(renamed["title"] == .string("Scout") && renamed["color"] == .string("#ff8800") && renamed["shape"] == .string("blob")
                && renamed["pinned"] == .bool(true), "only the name changes; Desktop's look for it stays")
        #expect(renamed["chat"] == nil, "what Hermes adds on reading isn't written back")
        let hidden = BotNames.merged(renamed, BotChange(hidden: true))
        #expect(hidden["hidden"] == .bool(true) && hidden["title"] == .string("Scout"))
        #expect(BotNames.merged(hidden, BotChange(hidden: false))["hidden"] == nil, "shown again: the mark comes off")
        #expect(BotNames.merged(nil, BotChange(title: "New")) == ["title": .string("New")], "a profile not yet a bot becomes one")
    }

    @Test func aBotsDetailsReadAsEachReleaseGivesThem() throws {
        let json = ##"{"name": "scout", "description": "Finds things", "soul": "# Scout", "model": {"provider": "custom:lab", "default": "stub-b"}}"##
        let details = BotDetails(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        #expect(details == BotDetails(soul: "# Scout", description: "Finds things", model: "stub-b", provider: "custom:lab"))
        let bare = BotDetails(try JSONDecoder().decode(JSONValue.self, from: Data(#"{"name": "x", "model": "m1"}"#.utf8)))
        #expect(bare.model == "m1" && bare.provider == nil && bare.soul.isEmpty)
        #expect(BotChange().isEmpty && !BotChange(hidden: false).isEmpty)
    }

    // MARK: - What bots are doing

    @Test func aMessageFromAnotherBotIsReadAsThatBots() throws {
        let new = try #require(BotMessages.inbound("Message from 🤖 Research Buddy (@research-buddy): Can you check the trail map?"))
        #expect(new == BotMessages.Inbound(name: "Research Buddy", handle: "research-buddy", body: "Can you check the trail map?"))
        let old = try #require(BotMessages.inbound("Message from 🤖 scout (@scout): two lines\nof it"))
        #expect(old.handle == "scout" && old.body == "two lines\nof it", "0.21.0 and 0.21.3 give the handle twice")
        #expect(BotMessages.inbound("[Message from agent 'scout'] hello")?.name == "scout")
        #expect(BotMessages.inbound("Message from home: the door is open") != nil && BotMessages.inbound("A message from Scout") == nil)

        let roster = try roster(Self.listing).bots
        #expect(BotMessages.sender(name: "Research Buddy", handle: "scout", roster: roster).profile == "scout")
        #expect(BotMessages.sender(name: "Redde", handle: "hermes", roster: roster).profile == "default", "@hermes is the main profile")
        #expect(BotMessages.sender(name: "Quill", handle: nil, roster: roster).profile == "writer", "found by its name")

        let rows: [JSONValue] = [
            .object(["role": .string("user"), "text": .string("Message from 🤖 Quill (@writer): Tighten this?"), "timestamp": .number(1)]),
            .object(["role": .string("assistant"), "text": .string("Done."), "timestamp": .number(2)]),
            .object(["role": .string("user"), "display_kind": .string("process_complete"),
                     "display_metadata": .object(["display_text": .string("Background Process Finished: python …")]),
                     "text": .string("[IMPORTANT: Background process proc_1a completed normally (exit code 0).\nCommand: /venv/bin/python /h/tools/bot_mode_dm.py --run-delivery query-file /tmp/dm1 hermes -p scout chat --in ~ -c 'Bot Chat' -Q\nOutput:\n{\"reply\": \"Three trails, all open.\", \"status\": \"settled\"}]"),
                     "timestamp": .number(3)]),
            .object(["role": .string("user"), "display_kind": .string("process_complete"),
                     "display_metadata": .object(["display_text": .string("Background Process Finished: make test")]),
                     "text": .string("[IMPORTANT: Background process proc_2b exited (exit code 2).\nCommand: make test\nOutput:\nFAIL]"), "timestamp": .number(4)]),
            .object(["role": .string("user"), "text": .string("And my own question"), "timestamp": .number(5)]),
        ]
        let messages = Conversation.messages(fromServeRows: rows)
        #expect(messages.map(\.text) == ["Tighten this?", "Done.", "Three trails, all open.", "FAIL", "And my own question"])
        #expect(messages[0].delivered == Delivered(kind: .message, profile: "writer", name: "Quill"))
        #expect(messages[2].delivered?.kind == .reply && messages[2].delivered?.profile == "scout", "a bot's reply, by the bot it came from")
        #expect(messages[3].delivered == Delivered(kind: .process, title: "Background Process Finished: make test"))
        #expect(messages[4].delivered == nil)

        let warned = BotMessages.userMessage(text: "[IMPORTANT: Background process proc_9 completed normally (exit code 0).\nCommand: python bot_mode_dm.py --run-delivery query-file /tmp/d hermes -p scout chat -Q\nOutput:\n⚠ tirith security scanner enabled but not available\nThe trail is open.]",
                                             displayKind: "process_complete", displayText: nil, at: .now)
        #expect(warned?.text == "The trail is open.", "Hermes 0.21.0's warning before the reply isn't part of it")

        let saved = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(messages[0]))
        #expect(saved.delivered == messages[0].delivered, "kept with the saved copy")
        #expect(BotMessages.rowPreview("Message from 🤖 Quill (@writer): Tighten this?", roster: roster, mainName: "Redde") == "Quill: Tighten this?")
        #expect(BotMessages.stepName(ToolActivity(name: "message_agent", status: .completed, args: "message: hi\ntarget: @scout")) == "Messaged @scout")
    }

    @Test func aBotsRowShowsWhatItIsDoing() async throws {
        let defaults = try #require(UserDefaults(suiteName: "bots-activity-\(UUID().uuidString)"))
        let activity = ChatActivity(defaults: defaults)
        let settings = Settings(defaults: defaults)
        let conversation = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "bots-activity-\(UUID().uuidString)")))
        var scout = HermesBot(name: "scout", chatID: "s-scout", lastActive: Date(timeIntervalSince1970: 1_000))
        activity.listed([scout], settings: settings)
        #expect(!activity.isUnread(scout, open: conversation, settings: settings), "first seen: read up to its last activity")
        scout.lastActive = Date(timeIntervalSince1970: 1_100)
        #expect(activity.isUnread(scout, open: conversation, settings: settings), "active since")
        activity.botSeen("scout", settings: settings)
        #expect(!activity.isUnread(scout, open: conversation, settings: settings))
        activity.markUnread(bot: "scout", settings: settings)
        #expect(activity.isUnread(scout, open: conversation, settings: settings))

        #expect(activity.kind(of: scout, open: conversation, settings: settings) == nil)
        scout.workerActive = .now.addingTimeInterval(-30)
        #expect(activity.kind(of: scout, open: conversation, settings: settings) == .working, "a worker of its heard from lately")
        #expect(!activity.isUnread(scout, open: conversation, settings: settings), "not unread while at work")
        scout.workerActive = .now.addingTimeInterval(-600)
        #expect(activity.kind(of: scout, open: conversation, settings: settings) == nil)
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

        // Renamed, in Redde or in Hermes Desktop: the open chat goes by the new name.
        var renamed = try roster(Self.listing)
        renamed.bots[try #require(renamed.bots.firstIndex { $0.name == "writer" })].title = "Ink"
        conversation.followBotName(in: renamed, mainName: "Redde")
        #expect(conversation.bot == BotRef(profile: "writer", name: "Ink") && conversation.title == "Ink")
        await store.flush()
        #expect(store.summaries.first { $0.serverSessionID == "s-writer" }?.bot?.name == "Ink", "and so does the copy on the iPhone")

        conversation.reset()
        #expect(conversation.bot == nil, "a new conversation is with the agent")
        let fresh = try await ask(conversation, transport, "@scout hello")
        #expect(fresh.mentionNote == nil, "@tags mean nothing outside a bot's chat")
    }
}

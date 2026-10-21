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
        #expect(!faces.filter { $0.key != "default" }.values.contains { $0.shape == .bubble || $0.color == 0 || $0.color >= BotFace.palette.count },
                "and no other bot has its shape, nor the standard theme's blue, nor its colours")
        let fourteen = BotFace.faces(for: names + ["eleven", "twelve", "thirteen", "fourteen"])
        #expect(features(Array(fourteen.values)).count == 14, "creatures stay apart past the shapes and colours")
    }

    @Test func aFacePickedForABotIsKeptOnTheServerAndTheOthersGoRoundIt() throws {
        let picked = BotFace(shape: .egg, eyes: .sparkle, mouth: .grin, mark: .spark, glance: 2, tilt: -4, color: 5)
        #expect(BotFace(code: picked.code) == picked, "a picked face reads back as it was written")
        let bubble = try #require(BotFace(code: "1:bubble:round:none:none:0:1:-3"), "Redde's bubble reads (the main agent may have it picked)")
        #expect(BotFace.faces(for: ["default", "scout"], picked: ["scout": bubble])["scout"]?.shape != .bubble, "but no other bot gets it")
        let ghost = BotFace(shape: .ghost, eyes: .happy, mouth: .smile, mark: .blush, glance: 0, tilt: 2, color: 3)
        #expect(BotFace.faces(for: ["default", "scout"], picked: ["default": ghost])["default"] == ghost, "the main agent's face can be picked")
        #expect(BotFace.Shape.seeded == [.round, .egg, .pill, .capsule, .burst, .pick, .hex, .diamond]
                && BotFace.Shape.given.contains(.ghost) && BotFace.Shape.given.contains(.square) && !BotFace.Shape.given.contains(.bubble),
                "new shapes are for picking: what a name gives never changes")
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

    /// Asked 2026-10-21: Redde's face in the theme's colour, with the Code blue one to pick.
    @Test func reddesFaceIsTheThemesColourWithTheCodeBlueToPick() throws {
        #expect(BotFace.main.color == BotFace.themed, "unpicked, Redde's face is the theme's colour")
        var blue = BotFace.main
        blue.color = BotFace.codeBlue
        #expect(BotFace(code: blue.code) == blue && BotFace(code: BotFace.main.code) == BotFace.main, "both of its colours read back as written")
        let faces = BotFace.faces(for: ["default", "scout", "writer", "fixit"], picked: ["default": blue])
        #expect(faces["default"] == blue)
        #expect(!faces.filter { $0.key != "default" }.values.contains { $0.color == 0 || $0.color >= BotFace.palette.count },
                "the other bots keep off blue, and off its colours")
    }

    /// Asked 2026-10-21: with Bot colors on, a bot's chat in its colour; Redde's in the theme's
    /// unless its face has one of its own.
    @Test func aBotsChatTakesItsColourAndReddesThemeColourIsTheThemes() throws {
        #expect(BotFace.main.chatColors == nil, "Redde in the theme's colour leaves the theme as it is")
        var redde = BotFace.main
        redde.color = BotFace.codeBlue
        let blue = try #require(redde.chatColors)
        let code = ThemeColors.RGB(Theme.claudeCode.userBubble)
        #expect(blue.accent == blue.bubble && abs((blue.bubble?.red ?? 0) - code.red) + abs((blue.bubble?.green ?? 0) - code.green)
                + abs((blue.bubble?.blue ?? 0) - code.blue) < 0.003, "the Code blue as the Code theme has it")
        let scout = BotFace(shape: .burst, eyes: .sleepy, mouth: .none, mark: .none, glance: 0, tilt: 0, color: 3)
        let indigo = try #require(scout.chatColors)
        #expect(indigo.accent != nil && indigo.accent == indigo.bubble, "a bot's colour for the bubbles and the accent")
        for pale in [BotFace.white, BotFace.white + 1] {
            var face = scout
            face.color = pale
            #expect(face.chatColors?.accent == nil && face.chatColors?.bubble != nil, "white and black colour the bubbles alone")
        }
        let tinted = Theme.standard.resolved(with: indigo)
        #expect(tinted.userBubble != Theme.standard.resolved(with: nil).userBubble && tinted.accent != Theme.standard.resolved(with: nil).accent)
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
        #expect(BotMessages.cliNoise("Session 20261019_192053_36928f found but has no messages. Starting fresh.\n\nsession_id: 20261019_192053_36928f\nOnce upon a time.")
                == "Once upon a time.", "nor the command line's session bookkeeping")
        let echoed = BotMessages.userMessage(text: "[IMPORTANT: Background process proc_7 completed normally (exit code 0).\nCommand: python bot_mode_dm.py --run-delivery query-file /tmp/d hermes -p research chat -Q\nOutput:\n[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history] Write a 100 word story. [/OUT-OF-BAND USER MESSAGE] Session 20261019_192053_36928f found but has no messages. Starting fresh.\n\nsession_id: 20261019_192053_36928f]",
                                             displayKind: "process_complete", displayText: nil, at: .now)
        #expect(echoed?.delivered?.kind == .reply && echoed?.delivered?.profile == "research" && echoed?.text == "",
                "a relay with only the message echoed back and the bookkeeping is no answer")
        let failed = BotMessages.userMessage(text: "[IMPORTANT: Background process proc_8 exited (exit code 1).\nCommand: python bot_mode_dm.py --run-delivery query-file /tmp/d hermes -p research chat -Q\nOutput:\nProvider said: HTTP 503]",
                                             displayKind: "process_complete", displayText: nil, at: .now)
        #expect(failed?.text == "", "nor is a run that failed")
        let steered = BotMessages.userMessage(text: "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]\nWrite a 100 word story. Make it good.\n[/OUT-OF-BAND USER MESSAGE]",
                                              displayKind: nil, displayText: nil, at: .now)
        #expect(steered?.text == "Write a 100 word story. Make it good." && steered?.isSteer == true && steered?.delivered == nil,
                "a steer reads back as one, the person's words alone")

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

    // MARK: - Group chats

    /// `groups.state`'s driver_status as Hermes 0.21.0 to 0.22.2 give it (hosted_room_service.status).
    @Test func aRoomSaysWhatItWaitsOn() throws {
        let status = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"running": true, "working": true, "blocked": true, "counts": {"running": 1, "indeterminate": 1},
             "pending_actions": [
               {"kind": "retry", "task_id": "dtask:aa"},
               {"kind": "approval", "task_id": "dtask:bb", "execution_generation": 2, "run_id": "r1", "session_id": "rt1",
                "request_id": "q1", "member_id": "scout",
                "approval": {"command": "rm -rf build", "description": "Deletes a folder", "choices": ["once", "deny"]}}],
             "peer_routes": []}
            """.utf8))
        let state = GroupState(status)
        #expect(state.retries == ["dtask:aa"])
        let approval = try #require(state.approvals.first)
        #expect(state.approvals.count == 1 && approval.memberID == "scout" && approval.taskID == "dtask:bb" && approval.executionGeneration == 2)
        #expect(approval.request.id == "q1" && approval.request.command == "rm -rf build" && approval.request.choices == ["once", "deny"])
        #expect(state.waitsOnPerson && state.blocked && !state.stopping)

        let stopping = GroupState(try JSONDecoder().decode(JSONValue.self, from: Data(#"{"working": true, "blocked": true, "counts": {"stopping": 1}, "pending_actions": []}"#.utf8)))
        #expect(stopping.stopping && stopping.blocked && !stopping.waitsOnPerson, "a stop under way is not a question for the person")
    }

    /// Bots can be reached on the Dashboard, and on the Hermes API with the Dashboard's address
    /// and login saved; a bot's chat then goes by the Dashboard, the app's own conversations by
    /// the API.
    @Test func onTheHermesAPIBotsGoByTheDashboardsLogin() throws {
        let settings = Settings(defaults: try #require(UserDefaults(suiteName: "api-bots-\(UUID().uuidString)")))
        let noLogin = HermesServeClient(settings: settings, password: { nil }, tokens: HermesServeClientTests.TokenBox().store)
        let login = HermesServeClient(settings: settings, password: { "secret" }, tokens: HermesServeClientTests.TokenBox().store)
        settings.transport = .hermesServe
        #expect(BotDirectory.reachable(settings, dashboard: noLogin), "the Dashboard connection has them")
        settings.transport = .hermesSessions
        #expect(!BotDirectory.reachable(settings, dashboard: login), "no Dashboard address")
        settings.serveURL = "https://home.example:9119"
        settings.serveUsername = "admin"
        #expect(!BotDirectory.reachable(settings, dashboard: noLogin), "no Dashboard login")
        #expect(BotDirectory.reachable(settings, dashboard: login))
        settings.showBots = false
        #expect(!BotDirectory.available(settings, dashboard: login), "Bots in the chat list off")
        settings.transport = .chatCompletions
        #expect(!BotDirectory.reachable(settings, dashboard: login))

        settings.transport = .hermesSessions
        let conversation = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "api-bots-\(UUID().uuidString)")), dashboard: login)
        #expect(conversation.connection == .hermesSessions)
        conversation.replaceForDemo(messages: [], bot: BotRef(profile: "scout", name: "Scout"))
        #expect(conversation.connection == .hermesServe, "a bot's chat goes by the Dashboard")
    }

    /// On the Hermes API alone a bot is a profile added by its own key: its chat goes by the API
    /// at /p/<profile>/ with that key, the main profile's at the API itself with the main key.
    @Test func aBotAddedForTheHermesAPIGoesByItsOwnAddressAndKey() throws {
        let settings = Settings(defaults: try #require(UserDefaults(suiteName: "api-only-bots-\(UUID().uuidString)")))
        settings.transport = .hermesSessions
        settings.gatewayURL = "https://home.example:8642/v1"
        let server = settings.activeServerID.uuidString
        let main = Keychain.account(.gatewayAPIKey, server: server), scout = Keychain.profileAccount("scout", server: server)
        Keychain.write(account: main, value: "main-key")
        Keychain.write(account: scout, value: "scout-key")
        defer { Keychain.delete(account: main); Keychain.delete(account: scout) }
        #expect(settings.gatewayEndpoint(profile: "scout").map { "\($0.url.absoluteString) \($0.key)" } == "https://home.example:8642/p/scout scout-key")
        #expect(settings.gatewayEndpoint(profile: "default").map { "\($0.url.absoluteString) \($0.key)" } == "https://home.example:8642 main-key")
        #expect(settings.gatewayEndpoint(profile: "quill").map { "\($0.url.absoluteString) \($0.key)" } == "https://home.example:8642/p/quill main-key",
                "no key of its own kept here: the main one, which a profile often has in its .env")

        let noDashboard = HermesServeClient(settings: settings, password: { nil }, tokens: HermesServeClientTests.TokenBox().store)
        #expect(BotDirectory.apiOnly(settings, dashboard: noDashboard) && BotDirectory.available(settings, dashboard: noDashboard))
        let conversation = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "api-only-bots-\(UUID().uuidString)")), dashboard: noDashboard)
        conversation.replaceForDemo(messages: [], bot: BotRef(profile: "scout", name: "Scout", viaAPI: true))
        #expect(conversation.connection == .hermesSessions && conversation.ledgerAPI()?.baseURL.absoluteString == "https://home.example:8642/p/scout"
                && conversation.ledgerAPI()?.apiKey == "scout-key")

        // A bot's chat kept before this, with no word of how it goes: by the Dashboard, as it did.
        let old = try JSONDecoder().decode(BotRef.self, from: Data(#"{"profile":"writer","name":"Quill"}"#.utf8))
        #expect(old.viaAPI == nil)
        settings.apiBotsHere = [APIBot(profile: "scout", title: "Scout")]
        #expect(settings.apiBots[server]?.map(\.profile) == ["scout"], "kept for this server")
    }

    /// A room takes text alone: pictures and files go to the server and the message names them,
    /// in notes the screen reads back as files and hides as text, a message of files alone too.
    @Test func filesSentToARoomAreNamedInTheMessage() async throws {
        let server = DemoServerFiles()
        let picture = Attachment(kind: .image, filename: "photo.jpg", mimeType: "image/jpeg", data: Data(count: 2_000))
        let notes = Attachment(kind: .text, filename: "notes.txt", mimeType: "text/plain", data: Data("lab notes".utf8))
        let placed = try await ServerFiles.place([picture, notes], client: server)
        #expect(placed.count == 2 && placed.allSatisfy { $0.path.hasPrefix(DemoServerFiles.home + "/Redde attachments/") })
        #expect(placed.map { ServerFiles.sentName(of: $0.path) } == ["photo.jpg", "notes.txt"], "named as sent, without the time")
        // The same file again in the same second: a name of its own.
        let again = try await ServerFiles.place([notes], client: server)
        #expect(again.first?.path != placed[1].path && again.first.map { ServerFiles.sentName(of: $0.path) } == "notes.txt")

        let said = "What do you make of these?" + AttachedFileNote.note(picture: placed[0].path) + AttachedFileNote.note(path: placed[1].path)
        #expect(AttachedFileNote.split(said).text == "What do you make of these?")
        #expect(AttachedFileNote.paths(in: said) == placed.map(\.path), "both files, in order")
        // Only files: Hermes trims the blank line before the first note.
        let only = (AttachedFileNote.note(picture: placed[0].path) + AttachedFileNote.note(path: placed[1].path))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(AttachedFileNote.split(only).text.isEmpty && AttachedFileNote.paths(in: only).count == 2)
        #expect(AttachedFileNote.strip("No files here [just brackets]") == "No files here [just brackets]")
    }

    /// A bot's reply in a room as it is written, from its session's events: started over at each
    /// start and beside a tool call, grown by each piece, whole at the end.
    @Test func aReplyInARoomIsReadAsItIsWritten() throws {
        func event(_ type: String, _ text: String? = nil) -> JSONValue {
            .object(["type": .string(type), "payload": .object(text.map { ["text": .string($0)] } ?? [:])])
        }
        var draft = GroupDraft(id: "live-1", after: 4)
        // The session's earlier turn is still among its last events: only this one's words count.
        let started = draft.read([event("message.start"), event("message.delta", "Old reply."), event("message.complete", "Old reply."),
                                  event("message.start"), event("message.delta", "Let me "), event("message.interim", "Let me look."),
                                  event("message.delta", "Falls Loop "), event("message.delta", "is open")])
        #expect(started)
        #expect(draft.text == "Falls Loop is open" && draft.finishedAt == nil, "what came beside the tool call is left out")
        let startedAgain = draft.read([event("message.delta", "."), event("message.complete", "Falls Loop is open.")])
        #expect(!startedAgain)
        #expect(draft.text == "Falls Loop is open." && draft.finishedAt != nil)
        #expect(GroupDraft.sessionTitle("redde-room-1") == "Group: redde-room-1")
    }

    /// Hermes Desktop's copy of its rooms, version 3, as group-chat.ts writes it into the main
    /// profile's ui_meta: rooms by "id:" key, a tombstone under `deleted`, the last messages.
    @Test func hermesDesktopsRoomsAreReadFromItsCopy() throws {
        let copy = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"version": 3, "updatedAt": 1792000300000,
             "deleted": {"id:old-room": 4},
             "rooms": {
               "id:hike-1": {"name": "Hike plans", "roomId": "hike-1", "revision": 7, "holdDetection": true, "omitted": 3,
                 "members": [{"name": "default"}, {"name": "scout", "handle": "scout", "title": "Scout"}],
                 "log": [
                   {"at": 1792000100000, "from": {"kind": "user", "name": "You"}, "text": "Saturday?", "thread": "main"},
                   {"at": 1792000200000, "from": {"kind": "member", "name": "scout", "source": "Local"}, "text": "Falls Loop… [truncated]",
                    "truncated": true, "id": "m-2"}]},
               "id:old-room": {"name": "Gone", "roomId": "old-room", "revision": 4, "log": []},
               "name:Legacy": {"revision": 1, "log": [{"at": 1792000000000, "from": {"kind": "member", "name": "writer"}, "text": "Hi"}]}}}
            """.utf8))
        let rooms = GroupRoom.desktopRooms(in: copy)
        #expect(rooms.map(\.name) == ["Hike plans", "Legacy"], "newest first, the ended one left out")
        let hike = try #require(rooms.first)
        #expect(hike.id == "desktop:id:hike-1" && hike.inDesktop && hike.omitted == 3)
        #expect(hike.members.map(\.label) == ["default", "Scout"])
        #expect(hike.desktopMessages.map(\.fromPerson) == [true, false] && hike.desktopMessages[1].profile == "scout")
        #expect(hike.updatedAt == Date(timeIntervalSince1970: 1_792_000_200))
        #expect(rooms[1].members.map(\.profile) == ["writer"], "who spoke, when the copy names no members")
        #expect(GroupRoom.desktopRooms(in: .object(["version": .number(2), "rooms": .object([:])])).isEmpty, "an older copy isn't guessed at")

        let roster = try roster(Self.listing)
        #expect(hike.naming(with: roster, mainName: "Redde").members.map(\.label) == ["Redde", "Scout"])

        // The same message keeps its number as the copy moves on.
        var seqs: [String: Int] = [:]
        let first = GroupFeed.events(of: hike, numbering: &seqs)
        var later = hike
        later.desktopMessages.removeFirst()
        later.desktopMessages.append(.init(key: "m-3", at: .now, fromPerson: true, profile: nil, text: "Great"))
        let second = GroupFeed.events(of: later, numbering: &seqs)
        #expect(first.map(\.seq) == [1, 2] && second.map(\.seq) == [2, 3])
        #expect(second.first?.kind == "message.member" && second.first?.actorID == "scout" && second.last?.kind == "message.user")
    }

    /// A turn's end is written by Hermes (the gateway), the bot named in the payload.
    @Test func aRoomsTurnLinesNameTheBot() throws {
        let room = GroupRoom.demo
        func event(_ json: String) throws -> GroupEvent { try #require(GroupEvent(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))) }
        let passed = try event(#"{"seq": 4, "kind": "turn.settled", "actor": {"kind": "gateway", "id": "gw-1"}, "payload": {"member_id": "scout", "task_id": "dtask:cc", "passed": true}}"#)
        #expect(passed.actorID == "scout" && passed.note(in: room) == "Scout passed")
        let deferred = try event(#"{"seq": 5, "kind": "turn.deferred", "actor": {"kind": "gateway", "id": "gw-1"}, "payload": {"member_id": "writer", "task_id": "dtask:dd", "reason": "member_unavailable"}}"#)
        #expect(deferred.note(in: room) == "Quill didn't finish")
        let said = try event(#"{"seq": 6, "kind": "message.member", "actor": {"kind": "member", "id": "writer"}, "payload": {"member_id": "writer", "text": "Hi"}}"#)
        #expect(said.actorID == "writer" && said.text == "Hi")
        let mine = try event(#"{"seq": 7, "kind": "message.user", "actor": {"kind": "user", "id": "desktop"}, "payload": {"text": "Hello"}}"#)
        #expect(mine.actorID == nil, "the person isn't a bot of the room")
    }

    // MARK: - Siri

    @Test func askingABotInReddeMeansItByEitherName() throws {
        let roster = try roster(Self.listing)
        #expect(roster.asked("scout")?.name == "scout")
        #expect(roster.asked("Research Buddy")?.name == "scout", "by the name it was given")
        #expect(roster.asked("quill")?.name == "writer", "whatever the case")
        #expect(roster.asked("default") == nil && roster.asked("nobody") == nil, "never the main profile, nor a name no bot has")
        #expect(roster.asked("Finder")?.name == "scout", "by a name its profile had before a rename")
    }

    @Test func whatWasKeptByProfileFollowsARename() throws {
        let roster = try roster(Self.listing)
        #expect(roster.named("scout")?.name == "scout" && roster.named("default")?.isDefault == true)
        #expect(roster.named("finder")?.name == "scout", "a spoken prefix or a chat kept by the old name")
        #expect(roster.named("nobody") == nil)

        let settings = Settings(defaults: try #require(UserDefaults(suiteName: "bot-rename-\(UUID().uuidString)")))
        let conversation = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "bot-rename-\(UUID().uuidString)")))
        conversation.replaceForDemo(messages: [], bot: BotRef(profile: "finder", name: "Finder"))
        conversation.followBotName(in: roster, mainName: "Redde")
        #expect(conversation.bot == BotRef(profile: "scout", name: "Research Buddy"), "the open chat's sends go to the renamed profile")
    }

    @Test func theBotsSectionKeepsTheOrderItWasPutIn() throws {
        let roster = try roster(Self.listing)
        let bots = roster.listed
        let rooms = [GroupRoom.demo]
        let first = BotListItem.arranged(bots: bots, rooms: rooms, order: [])
        #expect(first.map(\.id) == bots.map { "bot:" + $0.name } + ["room:demo-room"], "unordered: the bots as listed, then the group chats")

        // The group chat dragged to the top; the order names a bot by the name it had before a
        // rename, and a bot hidden since.
        let order = BotListItem.order(after: IndexSet(integer: first.count - 1), to: 0, in: first, kept: ["bot:hidden-one"])
        #expect(order.first == "room:demo-room" && order.last == "bot:hidden-one")
        let renamed = order.map { $0 == "bot:scout" ? "bot:finder" : $0 }
        let again = BotListItem.arranged(bots: bots, rooms: rooms, order: renamed)
        #expect(again.map(\.id) == Array(order.dropLast()), "kept, the renamed bot in its place, the hidden one left out")

        // A bot made since goes at the end.
        let newcomer = HermesBot(name: "newbie", title: "Newbie")
        #expect(BotListItem.arranged(bots: bots + [newcomer], rooms: rooms, order: order).last?.id == "bot:newbie")
    }

    @Test func siriLearnsTheBotsByTheirNames() throws {
        let defaults = try #require(UserDefaults(suiteName: "siri-bots-\(UUID().uuidString)"))
        let settings = Settings(defaults: defaults)
        let roster = try roster(Self.listing)
        #expect(ProfileCatalog.keep(bots: roster, settings: settings, defaults: defaults))
        let known = ProfileCatalog.known(settings: settings, defaults: defaults)
        #expect(known.map(\.title) == ["Default", "Research Buddy", "Quill"], "named as bots; a hidden one left out")
        #expect(ProfileCatalog.find("Research Buddy", in: known)?.name == "scout")
        #expect(!ProfileCatalog.keep(bots: roster, settings: settings, defaults: defaults), "the same roster again changes nothing")
    }

    // MARK: - Coding work on a card

    @Test func aCardsPatchReadsAsFilesWithWhatEachAddsAndTakesAway() {
        let git = """
            diff --git a/hello.py b/hello.py
            index 3b18e51..a2b3c4d 100644
            --- a/hello.py
            +++ b/hello.py
            @@ -1,2 +1,3 @@
             print("hello")
            -print("old")
            +print("new")
            +print("one more")
            diff --git a/notes/new.md b/notes/new.md
            new file mode 100644
            --- /dev/null
            +++ b/notes/new.md
            @@ -0,0 +1 @@
            +# Notes
            \\ No newline at end of file
            """
        let files = Patch.files(git)
        #expect(files.map(\.path) == ["hello.py", "notes/new.md"])
        #expect(files[0].added == 2 && files[0].removed == 1 && files[0].lines.first?.kind == .hunk)
        #expect(files[1].added == 1 && files[1].removed == 0)
        #expect(Patch.summary(files) == "2 files · +3 −1")

        // Python's difflib, as the butler writes the lanes' change: no "diff --git" lines.
        let lanes = Patch.files("--- a/home/h/skills/x.md\n+++ b/home/h/skills/x.md\n@@ -1 +1 @@\n-old\n+new\n--- /dev/null\n+++ b/home/h/docs/y.md\n@@ -0,0 +1 @@\n+y\n")
        #expect(lanes.map(\.path) == ["home/h/skills/x.md", "home/h/docs/y.md"] && lanes[0].added == 1 && lanes[1].added == 1)
    }

    @Test func anApprovalNamingACardOffersItsChange() throws {
        let asked = ApprovalRequest(id: "r1", command: "<apply_claude_work> (plugin approval rule)",
                                    description: "Sol wants to put Claude's change in place to demo: 1 file(s), +1 −0 lines (hello.py). Card t_2bf1f5db.",
                                    choices: ["once", "deny"])
        #expect(asked.kanbanCard == "t_2bf1f5db")
        #expect(ApprovalRequest(id: "r2", command: "rm -rf /tmp/x", description: nil, choices: ["once"]).kanbanCard == nil)
        let patch = try #require(KanbanAttachment(.object(["id": .number(3), "filename": .string("change.patch"), "content_type": .string("text/x-diff")])))
        let notes = try #require(KanbanAttachment(.object(["id": .number(4), "filename": .string("HANDOFF.md")])))
        #expect(patch.isPatch && !patch.isNotes && notes.isNotes && !notes.isPatch)
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

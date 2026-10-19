import Foundation

/// A bot, as Hermes's Bot Mode has them (the Bots of Hermes Desktop): a Hermes profile, with one
/// conversation of its own, the session titled exactly "Bot Chat" on that profile. Hermes counts
/// every profile as one. Its chat is hidden from the profile's list of conversations, and is
/// found again by that title, never by a stored id: Hermes Desktop lost people's chats every time
/// it kept a pointer instead (its src/AGENTS.md, "Bot Mode").
nonisolated struct HermesBot: Identifiable, Equatable, Sendable {
    /// The profile: what every call about the bot names.
    var name: String
    var displayName: String?
    /// The name the bot was given in Hermes Desktop (`ui_meta['hermes-bots'].title`).
    var title: String?
    var description: String
    var isDefault: Bool
    var model: String?
    /// Hidden in Hermes Desktop: Redde leaves it out too.
    var isHidden: Bool
    /// Set up as a bot (its profile has Hermes Desktop's bot settings). Once one is, Hermes gives
    /// every bot's chat the tool to message the others.
    var isSetUp: Bool
    /// The revision Hermes keeps of those settings; a write says which it expects.
    var setUpRevision: Int
    /// The bot's chat as the roster last saw it (`canonical_session`), for the row only.
    var chatID: String?
    var lastActive: Date?
    var preview: String?
    /// Profile names it had before a rename: an old @tag still finds it.
    var previousNames: [String]

    var id: String { name }

    /// What it is called: its bot name, its profile's display name, or the profile's name. The
    /// main profile with neither goes by `mainName` (what the person calls their agent).
    func label(mainName: String = "Hermes") -> String {
        title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? (isDefault ? mainName : name)
    }

    /// The @handle Hermes knows it by: the profile's name, and "hermes" for the main profile.
    var handle: String { isDefault ? "hermes" : name }

    init(name: String, displayName: String? = nil, title: String? = nil, description: String = "", isDefault: Bool = false,
         model: String? = nil, isHidden: Bool = false, isSetUp: Bool = false, setUpRevision: Int = 0, chatID: String? = nil,
         lastActive: Date? = nil, preview: String? = nil, previousNames: [String] = []) {
        self.name = name
        self.displayName = displayName
        self.title = title
        self.description = description
        self.isDefault = isDefault
        self.model = model
        self.isHidden = isHidden
        self.isSetUp = isSetUp
        self.setUpRevision = setUpRevision
        self.chatID = chatID
        self.lastActive = lastActive
        self.preview = preview
        self.previousNames = previousNames
    }

    /// A row of `profiles.list`.
    init?(_ row: JSONValue) {
        guard let name = row["name"]?.string?.nilIfEmpty else { return nil }
        let meta = row["ui_meta"]?["hermes-bots"]
        let chat = row["canonical_session"]
        self.init(name: name, displayName: row["display_name"]?.string?.nilIfEmpty, title: meta?["title"]?.string?.nilIfEmpty,
                  description: row["description"]?.string ?? "",
                  isDefault: row["is_default"]?.bool ?? (name == "default"), model: row["model"]?.string?.nilIfEmpty,
                  isHidden: meta?["hidden"]?.bool ?? false, isSetUp: meta?.object != nil,
                  setUpRevision: row["ui_meta_revisions"]?["hermes-bots"]?.int ?? 0,
                  chatID: (chat?["resolved_id"]?.string?.nilIfEmpty ?? chat?["id"]?.string?.nilIfEmpty),
                  lastActive: (chat?["last_active"]?.number).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                  preview: chat?["preview"]?.string?.nilIfEmpty,
                  previousNames: (row["previous_names"]?.array ?? []).compactMap(\.string))
    }
}

/// The bots on a server (`profiles.list`).
nonisolated struct BotRoster: Equatable, Sendable {
    var bots: [HermesBot]

    init(bots: [HermesBot]) { self.bots = bots }

    init(_ result: JSONValue) {
        bots = (result["profiles"]?.array ?? []).compactMap(HermesBot.init)
    }

    /// Some profile is set up as a bot: Hermes then gives each bot's chat the tool to message the
    /// others (`message_agent`) and tells it who they are.
    var messagingIsOn: Bool { bots.contains(where: \.isSetUp) }

    /// The bots the chat list shows: none while the main profile is the only one (there is no one
    /// else to talk to), else every bot not hidden in Hermes Desktop, the main one first, then the
    /// most recently talked to.
    var listed: [HermesBot] {
        let shown = bots.filter { !$0.isHidden }
        guard shown.contains(where: { !$0.isDefault }) else { return [] }
        return shown.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            if a.lastActive != b.lastActive { return (a.lastActive ?? .distantPast) > (b.lastActive ?? .distantPast) }
            return a.name < b.name
        }
    }
}

/// A conversation that is a bot's chat: which bot, as the conversation keeps it.
nonisolated struct BotRef: Codable, Equatable, Sendable {
    /// The bot's profile.
    var profile: String
    /// What it was called when the chat was opened.
    var name: String

    /// The @handle Hermes knows it by.
    var handle: String { profile == "default" ? "hermes" : profile }
}

/// @mentions in a message to a bot, as Hermes Desktop has them (its hermes-bots plugin): a tag
/// names another bot, and the message goes with a note saying which bot each tag means. Nothing is
/// sent to the other bot by the app: the agent does that with its message_agent tool, in words of
/// its own. A tag that names no bot, or more than one, stays plain text.
nonisolated enum BotMentions {
    /// Words a friendly name may never become: room handles and the main profile's own.
    static let reserved: Set<String> = ["all", "everyone", "user", "default", "hermes"]

    /// The taggable forms of a friendly name ("Research Buddy"): "research-buddy" and "researchbuddy".
    static func nameForms(_ value: String?) -> [String] {
        let name = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return [] }
        let slug = name.replacing(/[^a-z0-9_-]+/, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let collapsed = name.replacing(/[^a-z0-9_-]+/, with: "")
        var forms: [String] = []
        for form in [slug, collapsed] where !forms.contains(form) && !reserved.contains(form) && form.wholeMatch(of: /[a-z0-9][a-z0-9_-]*/) != nil {
            forms.append(form)
        }
        return forms
    }

    /// Everything a bot answers to: its handle, its profile's name, and its friendly names.
    static func forms(of bot: HermesBot) -> Set<String> {
        var forms: Set<String> = [bot.handle.lowercased(), bot.name.lowercased()]
        for friendly in [bot.title, bot.displayName] { forms.formUnion(nameForms(friendly)) }
        return forms
    }

    /// What a picked suggestion puts in the message: the bot's friendly name when it has one, else its handle.
    static func tag(for bot: HermesBot) -> String {
        for friendly in [bot.title, bot.displayName] {
            if let form = nameForms(friendly).first { return form }
        }
        return bot.handle
    }

    /// The bots `text` tags, in the order tagged, leaving out the one the message is to.
    static func mentioned(in text: String, roster: [HermesBot], to speaking: String?) -> [HermesBot] {
        // A tag inside code is code.
        let prose = text.replacing(/```[\s\S]*?```/, with: " ").replacing(/`[^`\n]*`/, with: " ")
        let others = roster.filter { $0.name != (speaking ?? "default") }
        var owner: [String: HermesBot?] = [:]
        for bot in others {
            for form in forms(of: bot) {
                if let existing = owner[form], existing?.name != bot.name { owner[form] = .some(nil) } else { owner[form] = bot }
            }
        }
        // A name a bot had before a rename finds it, unless another bot answers to it now.
        for bot in others {
            for name in bot.previousNames { for form in nameForms(name) where owner[form] == nil { owner[form] = bot } }
        }
        var found: [HermesBot] = []
        for match in prose.matches(of: /(?:^|\s)@([A-Za-z0-9][A-Za-z0-9_-]*)/) {
            guard let bot = owner[String(match.output.1).lowercased()] ?? nil,
                  !found.contains(where: { $0.name == bot.name }) else { continue }
            found.append(bot)
        }
        return found
    }

    /// The note that goes after a message tagging `bots`, worded as Hermes Desktop words it (its
    /// mention middleware), less what it says about other machines. Nil when nobody is tagged.
    static func note(for bots: [HermesBot]) -> String? {
        guard !bots.isEmpty else { return nil }
        let lines = bots.map { bot in
            let named = (bot.title ?? bot.displayName).map { " (\"\($0)\")" } ?? ""
            return "@\(bot.handle) = agent profile \"\(bot.name)\"\(named)"
        }
        return MentionNote.opening + "the user is referring to: " + lines.joined(separator: "; ")
            + ". If they want one of these agents contacted, compose your own message and send it with your message_agent tool; "
            + "never forward the user\u{2019}s text verbatim. If this session has no message_agent tool, agent messaging is unavailable here — say so.]"
    }

    /// The tag being typed at the end of `text` ("@sc" → "sc", "@" → ""), or nil when there isn't one.
    static func typing(in text: String) -> String? {
        guard let match = text.firstMatch(of: /(?:^|\s)@([A-Za-z0-9_-]*)$/) else { return nil }
        return String(match.output.1)
    }

    /// The bots a tag being typed could be, best first.
    static func suggestions(for typed: String, roster: [HermesBot], to speaking: String?) -> [HermesBot] {
        let typed = typed.lowercased()
        return roster.filter { bot in
            bot.name != (speaking ?? "default")
                && (typed.isEmpty || forms(of: bot).contains { $0.hasPrefix(typed) }
                    || bot.label().lowercased().hasPrefix(typed))
        }
    }

    /// `text` with the tag being typed finished as `bot`'s.
    static func complete(_ text: String, with bot: HermesBot) -> String {
        guard let typed = typing(in: text) else { return text }
        return String(text.dropLast(typed.count + 1)) + "@" + tag(for: bot) + " "
    }
}

/// The session title that makes a session a bot's chat. A wire constant, never shown.
nonisolated enum BotChat {
    static let title = "Bot Chat"

    nonisolated enum Problem: LocalizedError {
        /// The roster says the bot has a chat and the lookup found none: a server mid-restart can
        /// answer that way. Making another would leave the real one behind, so Redde doesn't.
        case unconfirmed(String)

        var errorDescription: String? {
            switch self {
            case let .unconfirmed(name): "Couldn't find \(name)'s chat on the server just now. Try again in a moment."
            }
        }
    }
}

extension HermesServeClient {
    /// The server's bots (`profiles.list`, the same on Hermes 0.21.0 to 0.22.2).
    func bots() async throws -> BotRoster {
        try await ensureConnected()
        return BotRoster(try await call("profiles.list", params: .object([:]), timeout: 30))
    }

    /// The bot's chat, by its stored session id, and whether it was made just now (it has no
    /// messages yet). Looked up by its title on the bot's profile every time; made the first time,
    /// hidden from the profile's list as Hermes Desktop makes it, and titled at once so a second
    /// open finds it rather than making another. Every later call about it names the bot's profile.
    func botChat(for bot: HermesBot) async throws -> (stored: String, isNew: Bool) {
        try await ensureConnected()
        if let found = try await findBotChat(bot) {
            noteProfile(bot.name, forStored: found)
            return (found, false)
        }
        if bot.chatID != nil { throw BotChat.Problem.unconfirmed(bot.label()) }
        let made = try await call("session.create", params: .object([
            "profile": .string(bot.name), "title": .string(BotChat.title), "hidden": .bool(true),
            // The chat runs on the bot's own model and settings as they are now, not as they were
            // when it began (Hermes Desktop's PR 97008; older releases ignore it).
            "follow_profile_config": .bool(true),
            "source": .string("desktop"), "close_on_disconnect": .bool(false)]))
        guard let runtime = made["session_id"]?.string else { throw TransportError.malformed("create: no session id") }
        let stored = made["stored_session_id"]?.string ?? runtime
        do {
            try await call("session.title", params: .object(["session_id": .string(runtime), "title": .string(BotChat.title)]))
        } catch let error as RPCError where error.message.localizedCaseInsensitiveContains("already in use") {
            // Another app made the bot's chat meanwhile: that one is it.
            guard let winner = try await findBotChat(bot) else { throw error }
            noteProfile(bot.name, forStored: winner)
            return (winner, false)
        }
        noteProfile(bot.name, forStored: stored)
        adopt(runtime: runtime, stored: stored)
        return (stored, true)
    }

    /// The bot's chat, found by its title on the bot's profile (the latest part of it, when Hermes
    /// has compressed it). A failed lookup throws: it must never read as "there is none".
    private func findBotChat(_ bot: HermesBot) async throws -> String? {
        let result = try await call("session.list", params: .object([
            "profile": .string(bot.name), "title": .string(BotChat.title), "include_hidden": .bool(true), "limit": .number(200)]))
        guard let row = (result["sessions"]?.array ?? []).first(where: { $0["title"]?.string == BotChat.title }) else { return nil }
        return row["resolved_id"]?.string?.nilIfEmpty ?? row["id"]?.string
    }

    /// Lets the bots message each other: sets the main profile up as a bot, as Hermes Desktop does
    /// when a bot is made or named there (an entry under `ui_meta` in its profile.yaml, empty, so
    /// nothing about it changes). Hermes then gives each bot's chat the message_agent tool and the
    /// list of the others. A chat begun before keeps the instructions it began with; it has the
    /// tool from its next message.
    func letBotsMessageEachOther(_ roster: BotRoster) async throws {
        guard !roster.messagingIsOn, let main = roster.bots.first(where: \.isDefault) ?? roster.bots.first else { return }
        try await ensureConnected()
        let result = try await call("profiles.configure", params: .object([
            "name": .string(main.name), "ui_meta": .object(["hermes-bots": .object([:])]),
            "ui_meta_expected_revisions": .object(["hermes-bots": .number(Double(main.setUpRevision))])]))
        let applied = result["applied"]
        // Someone set it up meanwhile (Hermes Desktop): it's on either way.
        if applied?["ui_meta_conflicts"] != nil { return }
        guard applied?["ui_meta"]?.bool == true else { throw TransportError.malformed("Hermes didn't take the bot settings") }
    }
}

/// The active server's bots, as last fetched: for the chat list's Bots, and for telling which
/// bots a message's @tags name. Fetched again whenever the list is, and when a bot's chat opens.
@Observable
final class BotDirectory {
    static let shared = BotDirectory()

    private(set) var roster: BotRoster?
    /// The connection it is from (`Settings.connectionKey`): another server's or profile's bots are no one here.
    private(set) var key = ""

    func bots(for key: String) -> [HermesBot] { key == self.key ? roster?.bots ?? [] : [] }

    @discardableResult
    func refresh(client: HermesServeClient = .shared, settings: Settings = .shared) async throws -> BotRoster {
        let key = settings.connectionKey
        let roster = try await client.bots()
        if key == settings.connectionKey { set(roster, key: key) }
        return roster
    }

    func set(_ roster: BotRoster?, key: String) {
        self.roster = roster
        self.key = key
    }
}

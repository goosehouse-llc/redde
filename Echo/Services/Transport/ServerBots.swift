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
    /// The face the person picked for it in Redde, kept on the server so every Redde there shows it
    /// (`ui_meta.redde.face` in its profile.yaml); nil: the one its name gives.
    var face: BotFace?
    /// The revision Hermes keeps of Redde's settings for it; a write says which it expects.
    var reddeRevision: Int
    /// When a worker of the bot's (a kanban card it was given) was last heard from
    /// (`worker_session`): one heard from lately is at work.
    var workerActive: Date?
    /// It has a picture set in Hermes Desktop (`has_avatar`; `assets/avatar.*` in its profile).
    var hasPicture = false
    /// Added on this phone for the Hermes API alone (`APIBot`): its chat goes by the API at
    /// /p/<profile>/, with the profile's own key, not by the Dashboard.
    var viaAPI = false

    var id: String { name }

    /// What it is called: its bot name, its profile's display name, or the profile's name. The
    /// main profile with neither goes by `mainName` (what the person calls their agent).
    func label(mainName: String = "Redde") -> String {
        title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? (isDefault ? mainName : name)
    }

    /// The @handle Hermes knows it by: the profile's name, and "hermes" for the main profile.
    var handle: String { isDefault ? "hermes" : name }

    init(name: String, displayName: String? = nil, title: String? = nil, description: String = "", isDefault: Bool = false,
         model: String? = nil, isHidden: Bool = false, isSetUp: Bool = false, setUpRevision: Int = 0, chatID: String? = nil,
         lastActive: Date? = nil, preview: String? = nil, previousNames: [String] = [], face: BotFace? = nil, reddeRevision: Int = 0,
         workerActive: Date? = nil) {
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
        self.face = face
        self.reddeRevision = reddeRevision
        self.workerActive = workerActive
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
                  previousNames: (row["previous_names"]?.array ?? []).compactMap(\.string),
                  face: (row["ui_meta"]?["redde"]?["face"]?.string).flatMap(BotFace.init(code:)),
                  reddeRevision: row["ui_meta_revisions"]?["redde"]?.int ?? 0,
                  workerActive: (row["worker_session"]?["last_active"]?.number).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
        hasPicture = row["has_avatar"]?.bool ?? false
    }
}

/// The bots on a server (`profiles.list`).
nonisolated struct BotRoster: Equatable, Sendable {
    var bots: [HermesBot] { didSet { faces = Self.faces(of: bots) } }
    /// Each bot's face: the one picked for it, else one its name gives, no two alike on the server.
    /// Worked out when the bots are set, not on each look: a group chat asks it for every row,
    /// twice a second while its bots write.
    private(set) var faces: [String: BotFace]

    init(bots: [HermesBot]) {
        self.bots = bots
        faces = Self.faces(of: bots)
    }

    init(_ result: JSONValue) {
        self.init(bots: (result["profiles"]?.array ?? []).compactMap(HermesBot.init))
    }

    private static func faces(of bots: [HermesBot]) -> [String: BotFace] {
        var faces = BotFace.faces(for: bots.map(\.name), picked: Dictionary(bots.compactMap { bot in bot.face.map { (bot.name, $0) } }, uniquingKeysWith: { a, _ in a }))
        // A picture set in Hermes Desktop stands for the face wherever it is drawn (`BotAvatar`).
        for bot in bots where bot.hasPicture { faces[bot.name]?.picture = bot.name }
        return faces
    }

    /// Some profile is set up as a bot: Hermes then gives each bot's chat the tool to message the
    /// others (`message_agent`) and tells it who they are.
    var messagingIsOn: Bool { bots.contains(where: \.isSetUp) }

    /// The bot "Ask <name> in Redde" means, by its profile's name or the name it was given, else by
    /// a name its profile had before a rename; never the main profile (that one is the app itself,
    /// "Ask Redde").
    func asked(_ name: String) -> HermesBot? {
        let said = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func same(_ a: String, _ b: String) -> Bool { a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let others = bots.filter { !$0.isDefault }
        return others.first { same($0.name, said) } ?? others.first { same($0.label(), said) }
            ?? others.first { $0.previousNames.contains { same($0, said) } }
    }

    /// The bot with this profile, or the one it became when renamed (Hermes keeps a profile's old
    /// names, 0.21.5 and later): what Redde kept by profile (a chat, a spoken prefix) follows it.
    func named(_ profile: String) -> HermesBot? {
        bots.first { $0.name == profile } ?? bots.first { $0.previousNames.contains(profile) }
    }

    /// `listed` in the order the person put the chat list's Bots section in (`BotListItem`).
    func listed(in order: [String]) -> [HermesBot] {
        BotListItem.arranged(bots: listed, rooms: [], order: order).compactMap { if case .bot(let bot) = $0 { bot } else { nil } }
    }

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

    /// The chat list's Bots section: `listed`, or the main profile on its own while it is the only
    /// one. Its tile vanished as the last other bot was hidden or deleted, which read as the main
    /// one going too (GitHub issue 29). Everywhere else, no one to talk to is still no bots.
    var inChatList: [HermesBot] {
        let listed = listed
        return listed.isEmpty ? bots.filter(\.isDefault) : listed
    }

    /// There is a bot to talk to besides the main profile.
    var hasOthers: Bool { !listed.isEmpty }
}

/// A row of the Bots section: a bot's chat or a group chat. The person can put them in any order.
nonisolated enum BotListItem: Identifiable, Equatable, Sendable {
    case bot(HermesBot)
    case room(GroupRoom)

    var id: String {
        switch self {
        case .bot(let bot): "bot:" + bot.name
        case .room(let room): "room:" + room.id
        }
    }

    /// The Bots section's rows: the bots, then the group chats, as they come (`BotRoster.listed`,
    /// the server's rooms), unless the person put them in an order. Then those in it come in it,
    /// a bot followed through a rename by its old name, and any new since go at the end.
    static func arranged(bots: [HermesBot], rooms: [GroupRoom], order: [String]) -> [BotListItem] {
        let items = bots.map(BotListItem.bot) + rooms.map(BotListItem.room)
        guard !order.isEmpty else { return items }
        var byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for bot in bots { for old in bot.previousNames where byID["bot:" + old] == nil { byID["bot:" + old] = .bot(bot) } }
        var taken = Set<String>()
        var arranged: [BotListItem] = []
        for id in order {
            guard let item = byID[id], taken.insert(item.id).inserted else { continue }
            arranged.append(item)
        }
        return arranged + items.filter { !taken.contains($0.id) }
    }

    /// The order to keep after a row is dragged: every row's id as now shown, and those kept
    /// that aren't shown now (a hidden bot, a group chat not read yet) after them.
    static func order(after moving: IndexSet, to destination: Int, in shown: [BotListItem], kept: [String]) -> [String] {
        var ids = shown.map(\.id)
        ids.move(fromOffsets: moving, toOffset: destination)
        let showing = Set(ids)
        return ids + kept.filter { !showing.contains($0) }
    }
}

/// A bot added on this phone for the Hermes API alone, where no Dashboard login lists the
/// server's: its profile, and what it is called here. Its key is the profile's own, in the
/// Keychain (`Keychain.profileAccount`); its chat is the profile's "Bot Chat", as on the Dashboard.
nonisolated struct APIBot: Codable, Equatable, Identifiable, Sendable {
    var profile: String
    var title: String?
    var id: String { profile }
}

/// An API bot's chat: the session titled "Bot Chat" on its profile, as on the Dashboard.
nonisolated enum APIBotChat {
    static func find(_ api: HermesSessionsAPI) async throws -> HermesSessionsAPI.SessionSummary? {
        try await api.listSessions(limit: 200).first { $0.title == BotChat.title }
    }
}

/// Adding an API bot (Add Bot): the profile tried over the API before it is kept, with the key
/// given, else the main one. Hermes takes the API_SERVER_KEY in the profile's own .env; Hermes
/// 0.21.0 copies the main one's into a clone, 0.21.3 and later leave it out (with the messaging
/// channels), so there it is added by hand, and the main key will do.
@MainActor
enum APIBots {
    static func add(profile: String, title: String?, key: String?, settings: Settings = .shared) async throws {
        let profile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = key?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard !profile.isEmpty, profile != "default" else { throw APIBotProblem.isMain }
        let server = settings.activeServerID.uuidString
        guard let base = Settings.normalizedBase(settings.gatewayURL),
              let tried = own ?? Keychain.read(account: Keychain.account(.gatewayAPIKey, server: server))?.nilIfEmpty else {
            throw APIBotProblem.noAPI
        }
        do {
            _ = try await HermesSessionsAPI(baseURL: base.appending(path: "p/\(profile)"), apiKey: tried, headers: settings.apiHeaders)
                .listSessions(limit: 1)
        } catch TransportError.http(404, _) {
            throw APIBotProblem.notServed(profile)
        } catch TransportError.http(401, _) {
            throw own == nil ? APIBotProblem.needsKey(profile) : APIBotProblem.wrongKey(profile)
        }
        let account = Keychain.profileAccount(profile, server: server)
        if let own {
            guard Keychain.write(account: account, value: own) else { throw APIBotProblem.notKept }
        } else {
            Keychain.delete(account: account)   // the main key, as it is when it changes
        }
        let added = APIBot(profile: profile, title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        settings.apiBotsHere = settings.apiBotsHere.filter { $0.profile != profile } + [added]
    }
}

nonisolated enum APIBotProblem: LocalizedError, Equatable {
    case noKey(String)
    case isMain
    case noAPI
    case notKept
    /// Refused with the main key: the profile has a key of its own.
    case needsKey(String)
    /// Hermes doesn't serve the profile over the API (no such profile, or a release before 0.21.5
    /// with `gateway.multiplex_profiles` off).
    case notServed(String)
    case wrongKey(String)

    var errorDescription: String? {
        switch self {
        case let .noKey(name): "There's no API key for \(name) on this iPhone. Add the bot again with its profile's key."
        case .isMain: "The main profile is there already."
        case .noAPI: "Set the Hermes API's address and key in Settings first."
        case .notKept: "The key couldn't be kept in the Keychain."
        case let .needsKey(name): "Hermes refused your main API key for \(name). Put API_SERVER_KEY in that profile's .env on the server (your main key will do, and it takes effect at once), then add it again; or enter the key it has below."
        case let .notServed(name): "Hermes doesn't serve the profile \(name) over its API. Check the name; on Hermes 0.21.3 and earlier, set gateway.multiplex_profiles: true in config.yaml and restart the gateway."
        case let .wrongKey(name): "Hermes refused that key for \(name). It takes the API_SERVER_KEY in that profile's own .env."
        }
    }
}

/// A conversation that is a bot's chat: which bot, as the conversation keeps it.
nonisolated struct BotRef: Codable, Equatable, Sendable {
    /// The bot's profile.
    var profile: String
    /// What it was called when the chat was opened.
    var name: String
    /// The chat goes by the Hermes API at /p/<profile>/ (an `APIBot`), not by the Dashboard.
    var viaAPI: Bool?

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
        /// Hermes before 0.22 can't set a bot's chat aside: no `session.archive`, and a bot's chat
        /// can't be renamed (lab, 0.21.0 to 0.21.5).
        case cantStartFresh

        var errorDescription: String? {
            switch self {
            case let .unconfirmed(name): "Couldn't find \(name)'s chat on the server just now. Try again in a moment."
            case .cantStartFresh: "Starting a bot's chat over needs Hermes 0.22 or later. On this server, send /compress in the chat to make it shorter."
            }
        }
    }
}

extension HermesServeClient {
    /// A bot's picture as set in Hermes Desktop (`profiles.get_asset`, Hermes 0.21.0 on): PNG, JPEG or
    /// WebP, up to 2 MB; nil when it has none.
    func botPicture(_ profile: String) async throws -> Data? {
        try await ensureConnected()
        let result = try await call("profiles.get_asset", params: .object(["name": .string(profile), "asset": .string("avatar")]), timeout: 30)
        guard result["found"]?.bool == true, let url = result["data"]?.string, let comma = url.range(of: ";base64,") else { return nil }
        return Data(base64Encoded: String(url[comma.upperBound...]))
    }

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

    /// Starts a bot's chat over. Hermes keeps a bot's chat as one long conversation, condensed as it
    /// fills (`/compress` does that at once); this is the clean slate. The chat it has is archived,
    /// kept on the server with its messages but no longer the bot's: Hermes then names no chat for
    /// the bot, and the next open makes a new one as the first did. (Hermes 0.22 refuses to rename
    /// a bot's chat: its title is what makes it the bot's.) What the bot saved to its memory stays.
    /// Nothing to do if it has none. Read the roster again before opening the bot: the old one
    /// still names the chat put aside.
    func startFresh(_ bot: HermesBot) async throws {
        try await ensureConnected()
        let result = try await call("session.list", params: .object([
            "profile": .string(bot.name), "title": .string(BotChat.title), "include_hidden": .bool(true), "limit": .number(200)]))
        // The title is the first part's, when Hermes has compressed the chat into more.
        guard let row = (result["sessions"]?.array ?? []).first(where: { $0["title"]?.string == BotChat.title }),
              let root = row["id"]?.string else { return }
        noteProfile(bot.name, forStored: root)
        do {
            try await call("session.archive", params: .object(["session_id": .string(root), "profile": .string(bot.name), "archived": .bool(true)]))
        } catch let error as RPCError where error.code == -32601 {
            throw BotChat.Problem.cantStartFresh
        }
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

extension HermesServeClient {
    /// Gives a bot the face picked for it, or (nil) the one its name gives: kept in its profile's
    /// `ui_meta` under "redde", Redde's own entry, which Hermes keeps as it is (0.21.0 to 0.22.2)
    /// and other apps leave alone. The write names the revision it read: changed meanwhile (by
    /// Redde on another device), it is refused and the roster is read again.
    func setFace(_ face: BotFace?, for bot: HermesBot) async throws {
        try await ensureConnected()
        let value: JSONValue = face.map { .object(["face": .string($0.code)]) } ?? .null
        let result = try await call("profiles.configure", params: .object([
            "name": .string(bot.name), "ui_meta": .object(["redde": value]),
            "ui_meta_expected_revisions": .object(["redde": .number(Double(bot.reddeRevision))])]))
        let applied = result["applied"]
        if applied?["ui_meta_conflicts"] != nil { throw BotFaceProblem.changedElsewhere }
        guard applied?["ui_meta"]?.bool == true else { throw TransportError.malformed("Hermes didn't keep the face") }
    }
}

nonisolated enum BotFaceProblem: LocalizedError {
    case changedElsewhere

    var errorDescription: String? {
        switch self {
        case .changedElsewhere: "This bot's face was changed somewhere else just now. Look again and pick once more."
        }
    }
}

/// The active server's bots, as last fetched: for the chat list's Bots, and for telling which
/// bots a message's @tags name. Fetched again whenever the list is, and when a bot's chat opens.
@Observable
final class BotDirectory {
    static let shared = BotDirectory()

    /// The server's bots can be reached: on the Dashboard connection, and on the Hermes API one
    /// with the Dashboard's address and login saved too. Bots, their chats and group chats are
    /// the Dashboard's (profiles, `groups.*`), and the Hermes API serves another profile only
    /// with that profile's own key, so on the API connection they go by the Dashboard.
    static func reachable(_ settings: Settings = .shared, dashboard: HermesServeClient = .shared) -> Bool {
        switch settings.transport {
        case .hermesServe: true
        case .hermesSessions: settings.serveBaseURL != nil && dashboard.hasCredentials
        case .chatCompletions: false
        }
    }

    /// On the Hermes API with no Dashboard login: bots are the ones added on this phone, each by its
    /// profile's own API key (`APIBot`), their chats at /p/<profile>/; no group chats.
    static func apiOnly(_ settings: Settings = .shared, dashboard: HermesServeClient = .shared) -> Bool {
        settings.transport == .hermesSessions && !reachable(settings, dashboard: dashboard)
    }

    /// Bots can be had, one way or the other, and Settings has them in the chat list.
    static func available(_ settings: Settings = .shared, dashboard: HermesServeClient = .shared) -> Bool {
        settings.showBots && (reachable(settings, dashboard: dashboard) || apiOnly(settings, dashboard: dashboard))
    }

    /// The bots added for the Hermes API alone, as a roster: the main profile, and each added one,
    /// with its chat's last line and time read from its "Bot Chat" (at /p/<profile>/, by its own
    /// key). One that can't be reached is still listed, as it was added.
    @discardableResult
    func refreshAPI(settings: Settings = .shared) async -> BotRoster {
        let key = settings.connectionKey
        let mains = [APIBot(profile: "default", title: nil)]
        var bots: [HermesBot] = []
        for added in mains + settings.apiBotsHere {
            var bot = HermesBot(name: added.profile, title: added.title, isDefault: added.profile == "default")
            bot.viaAPI = true
            if let endpoint = settings.gatewayEndpoint(profile: added.profile),
               let chat = try? await APIBotChat.find(HermesSessionsAPI(baseURL: endpoint.url, apiKey: endpoint.key, headers: settings.apiHeaders)) {
                bot.chatID = chat.id
                bot.lastActive = chat.lastActiveDate
                bot.preview = chat.preview
            }
            bots.append(bot)
        }
        let roster = BotRoster(bots: bots)
        if key == settings.connectionKey { set(roster, key: key) }
        return roster
    }

    private(set) var roster: BotRoster?
    /// The connection it is from (`Settings.connectionKey`): another server's or profile's bots are no one here.
    private(set) var key = ""

    func bots(for key: String) -> [HermesBot] { key == self.key ? roster?.bots ?? [] : [] }

    /// The main agent's face on the server the app is on: Redde's bubble, or the one picked for it.
    var mainFace: BotFace {
        (key == Settings.shared.connectionKey ? roster?.faces["default"] : nil) ?? .main
    }

    @discardableResult
    func refresh(client: HermesServeClient = .shared, settings: Settings = .shared) async throws -> BotRoster {
        let key = settings.connectionKey
        let roster = try await client.bots()
        if key == settings.connectionKey { set(roster, key: key) }
        return roster
    }

    func set(_ roster: BotRoster?, key: String) {
        let unchanged = roster == self.roster && key == self.key
        self.roster = roster
        self.key = key
        // Their names, for Siri ("Ask Claude in Redde"), and for the watch, when they changed: they
        // are read again every 15 seconds, and mostly they haven't.
        guard let roster, key == Settings.shared.connectionKey, !(unchanged && told == key) else { return }
        told = key
        ProfileCatalog.keep(bots: roster)
        WatchLink.shared.botsChanged()
        Mutes.publish()   // a bot's chat may be another session now (Start Fresh)
    }

    /// The connection whose bots Siri, the watch and the mutes were last told of.
    private var told: String?
}

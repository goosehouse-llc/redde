import Foundation

/// Making, changing and deleting bots, as Hermes Desktop's Bot Mode does it: a bot is a profile
/// (`profiles.create`), its name in Bot Mode is `ui_meta['hermes-bots'].title`, what it does is
/// the profile's description, its personality is the profile's SOUL.md, and its model is the
/// profile's own (`profiles.configure`). Hermes has no socket call to delete a profile: that goes
/// through the Dashboard's REST route. The same on Hermes 0.21.0 to 0.22.2.

/// A bot about to be made.
nonisolated struct NewBot: Equatable, Sendable {
    /// What it is called ("Research Buddy").
    var title: String
    /// Its profile's name, the @handle Hermes knows it by ("research-buddy").
    var handle: String
    /// What it does: under its name in the list, and to the other bots.
    var description: String
    /// Its personality, as the person wrote it; empty: one written from its name and what it does.
    var soul: String
    /// Its model; nil: the main profile's.
    var model: ModelChoice?
    var face: BotFace?
    /// The toolsets it has (a template's, or picked); nil: every one the main profile has.
    var toolsets: [String]? = nil
}

/// What making a bot came to: its profile, and what went wrong after Hermes made it.
nonisolated struct MadeBot: Equatable, Sendable {
    var name: String
    var notes: [String]
}

/// A bot as `profiles.describe` has it: what the roster leaves out.
nonisolated struct BotDetails: Equatable, Sendable {
    var soul: String
    var description: String
    var model: String?
    var provider: String?
    /// The toolsets the server has, each marked whether this profile has it.
    var toolsets: [BotToolset]
    /// The profile has a list of its own (not every toolset).
    var toolsetsPinned: Bool

    init(soul: String = "", description: String = "", model: String? = nil, provider: String? = nil,
         toolsets: [BotToolset] = [], toolsetsPinned: Bool = false) {
        self.soul = soul
        self.description = description
        self.model = model
        self.provider = provider
        self.toolsets = toolsets
        self.toolsetsPinned = toolsetsPinned
    }

    init(_ result: JSONValue) {
        let model = result["model"]
        self.init(soul: result["soul"]?.string ?? "", description: result["description"]?.string ?? "",
                  model: (model?.string ?? model?["default"]?.string ?? model?["model"]?.string)?.nilIfEmpty,
                  provider: model?["provider"]?.string?.nilIfEmpty ?? result["provider"]?.string?.nilIfEmpty,
                  toolsets: (result["toolsets"]?.array ?? []).compactMap(BotToolset.init),
                  toolsetsPinned: result["toolsets_pinned"]?.bool ?? false)
    }

    /// The toolsets it has. With no list of its own and none marked as had, every one: 0.21.5 works
    /// out the unpinned ones in a way that can fail quietly, and then marks them all off.
    var enabledToolsets: Set<String> {
        let on = Set(toolsets.filter(\.enabled).map(\.name))
        return !toolsetsPinned && on.isEmpty ? Set(toolsets.map(\.name)) : on
    }
}

/// A change to a bot: nil leaves that part as it is.
nonisolated struct BotChange: Equatable, Sendable {
    var title: String?
    var hidden: Bool?
    var description: String?
    var soul: String?
    var model: ModelChoice?
    /// Said yes to a model Hermes asks about first (an expensive one).
    var modelConfirmed = false
    /// The toolsets it has from now on (Hermes 0.21.5 and later keep a bot to them). Never an
    /// empty list: Hermes takes that for its own defaults on some releases and for none on 0.21.5.
    var toolsets: [String]?

    var isEmpty: Bool { title == nil && hidden == nil && description == nil && soul == nil && model == nil && toolsets == nil }
}

nonisolated enum BotChangeOutcome: Equatable, Sendable {
    case done
    /// Hermes wants a yes before it gives the bot this model; nothing was changed.
    case confirmModel(String)
}

nonisolated enum BotNames {
    /// Names Hermes refuses for a profile, and the words @mentions keep for themselves.
    static let reserved = Set(["hermes", "default", "test", "tmp", "root", "sudo"]).union(BotMentions.reserved)

    /// The profile name for a bot called `title`: lower case, letters, digits, - and _, as Hermes
    /// takes them, and not one of `taken`; nil when the name has nothing to make one from.
    static func handle(for title: String, taken: Set<String>) -> String? {
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "en_US_POSIX")).lowercased()
        let trim = CharacterSet(charactersIn: "-_")
        var slug = folded.replacing(/[^a-z0-9_-]+/, with: "-").trimmingCharacters(in: trim)
        slug = String(slug.prefix(56)).trimmingCharacters(in: trim)
        guard let first = slug.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return nil }
        if reserved.contains(slug) { slug += "-bot" }
        let taken = Set(taken.map { $0.lowercased() })
        var handle = slug
        var number = 2
        while taken.contains(handle) {
            handle = "\(slug)-\(number)"
            number += 1
        }
        return handle
    }

    /// The personality a bot gets when the person writes none: who it is and what it does, as
    /// Hermes Desktop words a new bot's SOUL.md (Hermes itself tells it how to message the others).
    static func soul(title: String, handle: String, description: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["# \(title)", ""]
        if !description.isEmpty { lines += ["**Mission:** \(description)", ""] }
        lines += ["You are \(title), a persistent named agent (profile `\(handle)`) on this machine.",
                  "You keep your own memory, skills, and conversation history across sessions."]
        return lines.joined(separator: "\n")
    }

    /// `settings` (a bot's `ui_meta['hermes-bots']`) with `change` made to it, and what Hermes adds
    /// to it on reading (`chat`, the bot's chat) left out, as Hermes Desktop writes it back.
    static func merged(_ settings: [String: JSONValue]?, _ change: BotChange) -> [String: JSONValue] {
        var settings = settings ?? [:]
        settings["chat"] = nil
        if let title = change.title { settings["title"] = .string(title.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let hidden = change.hidden { settings["hidden"] = hidden ? .bool(true) : nil }
        return settings
    }
}

nonisolated enum BotManagementProblem: LocalizedError, Equatable {
    case gone(String)
    case busy
    case notKept(String)

    var errorDescription: String? {
        switch self {
        case let .gone(name): "\(name) isn't on your server any more."
        case .busy: "This bot's settings kept changing somewhere else just now. Try again in a moment."
        case let .notKept(what): "Hermes didn't keep the bot's \(what)."
        }
    }
}

extension HermesServeClient {
    /// Makes a bot as Hermes Desktop does: the profile, a copy of the main one's settings, keys and
    /// sign-ins (without a command of its own on the server), its personality, then its name in
    /// Bot Mode. A copy, because a profile made with none of the main one's settings has no model
    /// it can reach: a custom endpoint is in the main profile's config.yaml, with its key, and
    /// Hermes takes no endpoint for a profile over the socket (lab, 0.21.0). Then Hermes is asked
    /// whether it can answer: a bot that can't is made all the same, with a note saying why.
    func makeBot(_ bot: NewBot) async throws -> MadeBot {
        try await ensureConnected()
        let soul = bot.soul.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? BotNames.soul(title: bot.title, handle: bot.handle, description: bot.description)
        var params: [String: JSONValue] = [
            "name": .string(bot.handle), "description": .string(bot.description.trimmingCharacters(in: .whitespacesAndNewlines)),
            "soul": .string(soul), "no_alias": .bool(true), "clone_from": .string("default"), "share_auth": .bool(true)]
        if let model = bot.model {
            params["model"] = .string(model.model)
            params["provider"] = .string(model.provider)
        }
        // Hermes copies the bundled skills as it makes a profile: not quick.
        let made = try await call("profiles.create", params: .object(params), timeout: 120)
        var notes: [String] = []
        if let model = bot.model, made["model_set"]?.bool == false {
            notes.append("Hermes couldn't give it \(model.name), so it has your agent's model for now.")
        }
        try await changeBotSettings(bot.handle, name: bot.title) { settings in
            settings = BotNames.merged(settings, BotChange(title: bot.title))
            settings["created"] = .number((Date.now.timeIntervalSince1970 * 1000).rounded())
        }
        if let face = bot.face {
            do { try await setFace(face, for: HermesBot(name: bot.handle)) } catch { notes.append("Its face wasn't kept: \(error.localizedDescription)") }
        }
        if let toolsets = bot.toolsets, !toolsets.isEmpty {
            let applied = try? await call("profiles.configure", params: .object([
                "name": .string(bot.handle), "enabled_toolsets": .array(toolsets.map(JSONValue.string))]), timeout: 30)["applied"]
            if applied?["toolsets"]?.bool != true { notes.append("Its tools weren't set: it has all of your agent's for now.") }
        }
        if let problem = await botProblem(bot.handle) { notes.append(problem) }
        return MadeBot(name: bot.handle, notes: notes)
    }

    /// The toolsets a bot can be given, and which the main profile has (`enabledToolsets`): the
    /// server's, as `profiles.describe` lists them for the main profile.
    func toolsetsOffered() async throws -> BotDetails {
        try await ensureConnected()
        return BotDetails(try await call("profiles.describe", params: .object(["name": .string("default")]), timeout: 30))
    }

    /// What the roster leaves out about a bot: its personality, its model and its toolsets.
    func botDetails(_ bot: HermesBot) async throws -> BotDetails {
        try await ensureConnected()
        return BotDetails(try await call("profiles.describe", params: .object(["name": .string(bot.name)]), timeout: 30))
    }

    /// The models a bot can have, its own marked current (the main profile's, for "default").
    func modelOptions(forProfile name: String) async throws -> [ModelChoice] {
        try await ensureConnected()
        let result = try await call("model.options", params: .object(["explicit_only": .bool(true), "profile": .string(name)]))
        return HermesSessionsAPI.parseModelOptions(result)
    }

    /// Changes a bot. The model goes first and alone: Hermes may want a yes for it, and then
    /// nothing else is changed until it has one. Its name and whether it is hidden are its Bot
    /// Mode settings, written over whatever else is there (Hermes Desktop's look for it).
    func changeBot(_ bot: HermesBot, _ change: BotChange) async throws -> BotChangeOutcome {
        try await ensureConnected()
        if let model = change.model {
            var params: [String: JSONValue] = ["name": .string(bot.name), "model": .string(model.model), "provider": .string(model.provider)]
            if change.modelConfirmed { params["confirm_expensive_model"] = .bool(true) }
            let result = try await call("profiles.configure", params: .object(params), timeout: 30)
            if result["confirm_required"]?.bool == true {
                return .confirmModel(result["confirm_message"]?.string ?? "Hermes wants a yes before \(bot.label()) uses \(model.name).")
            }
            guard result["applied"]?["model"]?.bool != false else { throw BotManagementProblem.notKept("model") }
        }
        var sections: [String: JSONValue] = [:]
        if let description = change.description { sections["description"] = .string(description.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let soul = change.soul { sections["soul"] = .string(soul) }
        if let toolsets = change.toolsets, !toolsets.isEmpty { sections["enabled_toolsets"] = .array(toolsets.map(JSONValue.string)) }
        if !sections.isEmpty {
            sections["name"] = .string(bot.name)
            let applied = try await call("profiles.configure", params: .object(sections), timeout: 30)["applied"]
            if applied?["soul"]?.bool == false { throw BotManagementProblem.notKept("personality") }
            if applied?["toolsets"]?.bool == false { throw BotManagementProblem.notKept("tools") }
            if applied?["description"]?.bool == false { throw BotManagementProblem.notKept("description") }
            if sections["enabled_toolsets"] != nil { Task { await refreshOpenChatsTools() } }
        }
        if change.title != nil || change.hidden != nil {
            try await changeBotSettings(bot.name, name: bot.label()) { settings in settings = BotNames.merged(settings, change) }
        }
        return .done
    }

    /// Deletes a bot from the server with its chats, memories and settings. Never the main profile.
    func deleteBot(_ bot: HermesBot) async throws {
        guard !bot.isDefault else { return }
        try await deleteProfile(bot.name)
    }

    /// Hermes's check that a bot can answer (a model it can reach, with what that needs), or nil
    /// when it can or the check couldn't be made. Hermes 0.21.0 answers for the main profile
    /// whichever is asked about; its answer names none, and is left out.
    func botProblem(_ name: String) async -> String? {
        guard let result = try? await call("setup.runtime_check", params: .object(["profile": .string(name)]), timeout: 30),
              result["ok"]?.bool == false, result["profile"]?.string == name else { return nil }
        let error = result["error"]?.string?.nilIfEmpty ?? "no model it can reach"
        return "It can't answer yet: \(error)"
    }

    /// Changes a bot's Bot Mode settings as Hermes Desktop does: read as they are now, changed,
    /// and written back naming the revision read. Changed elsewhere meanwhile, they are read again
    /// and changed once more, three times at most.
    private func changeBotSettings(_ profile: String, name: String, _ change: (inout [String: JSONValue]) -> Void) async throws {
        for _ in 0 ..< 3 {
            let roster = try await call("profiles.list", params: .object(["include_sessions": .bool(false)]), timeout: 30)
            guard let row = roster["profiles"]?.array?.first(where: { $0["name"]?.string == profile }) else { throw BotManagementProblem.gone(name) }
            var settings = row["ui_meta"]?["hermes-bots"]?.object ?? [:]
            change(&settings)
            let result = try await call("profiles.configure", params: .object([
                "name": .string(profile), "ui_meta": .object(["hermes-bots": .object(settings)]),
                "ui_meta_expected_revisions": .object(["hermes-bots": .number(Double(row["ui_meta_revisions"]?["hermes-bots"]?.int ?? 0))])]), timeout: 30)
            let applied = result["applied"]
            if applied?["ui_meta"]?.bool == true { return }
            guard applied?["ui_meta_conflicts"] != nil else { throw BotManagementProblem.notKept("name") }
        }
        throw BotManagementProblem.busy
    }
}

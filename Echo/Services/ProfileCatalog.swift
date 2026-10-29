import AppIntents
import Foundation

/// A Hermes profile the phone knows of, for the places that have to name one without asking the
/// server first: Siri and Shortcuts ("Ask Work in Redde").
nonisolated struct KnownProfile: Codable, Equatable, Identifiable, Sendable {
    /// The profile's name on the server; `ProfileCatalog.defaultID` for its main profile.
    var name: String
    /// What it is called: its display name on the Dashboard, else its name.
    var title: String
    /// Its home on the server, when the Dashboard said.
    var path = ""

    var id: String { name }
    var isDefault: Bool { name == ProfileCatalog.defaultID }
}

/// The profiles of the server the app is on, as far as the phone knows. The Dashboard lists a
/// server's profiles, and what it listed last is kept; over the Hermes API there is no list, so
/// a profile chosen by name is kept when it is chosen. Kept per server.
enum ProfileCatalog {
    nonisolated static let defaultID = "default"
    nonisolated static let main = KnownProfile(name: defaultID, title: String(localized: "Default", comment: "The server's main Hermes profile"))
    /// As many as Siri is given to learn phrases for.
    nonisolated static let most = 12

    private static func key(_ settings: Settings) -> String { "knownProfiles.\(settings.activeServerID.uuidString)" }
    private static func botsKey(_ settings: Settings) -> String { "knownBots.\(settings.activeServerID.uuidString)" }

    /// The server's main profile first, then the ones kept, then the one in use if it is neither;
    /// each that is a bot by the name it was given as a bot ("Claude", not "claude"), so Siri
    /// learns that name.
    /// What the agent of `profile` is called (nil or "default": the main agent's name): for the
    /// header and the composer, which once said the main agent's name on every profile, so a chat
    /// on another one looked like the main agent's (2026-10-29).
    static func agentName(_ profile: String?, settings: Settings = .shared) -> String {
        guard let profile, profile != defaultID else { return settings.headerTitle }
        return known(settings: settings).first { same($0.name, profile) }?.title ?? profile
    }

    /// Starts a conversation on `profile`, leaving the app on the profile it is on: the
    /// conversation alone goes there (an idea taken from another agent's cards, "Ask Work in
    /// Redde" from Siri). Nothing to do for the profile in use but start a fresh conversation.
    static func startConversation(on profile: String, conversation: Conversation, settings: Settings = .shared) {
        let selected = settings.profileName ?? defaultID
        if same(profile, selected) { return conversation.reset() }
        conversation.startElsewhere(ProfileRoute(profile: profile, viaAPI: settings.transport == .hermesSessions))
    }

    static func known(settings: Settings = .shared, defaults: UserDefaults = .standard) -> [KnownProfile] {
        var all = [main] + kept(settings: settings, defaults: defaults)
        if let current = settings.profileName, !all.contains(where: { same($0.name, current) }) {
            all.append(KnownProfile(name: current, title: current, path: settings.hermesProfileHome))
        }
        let names = botNames(settings: settings, defaults: defaults)
        return Array(all.prefix(most)).map { profile in
            var profile = profile
            if let name = names[profile.name] { profile.title = name }
            return profile
        }
    }

    /// The bots' names, by profile, as the Dashboard's roster last gave them.
    static func botNames(settings: Settings = .shared, defaults: UserDefaults = .standard) -> [String: String] {
        guard let data = defaults.data(forKey: botsKey(settings)) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// The Dashboard's bots, read: their names kept for Siri, and any not kept yet (a bot made
    /// since the profiles were last listed) kept beside the others. True when that changed what
    /// is known.
    @discardableResult
    static func keep(bots roster: BotRoster, settings: Settings = .shared, defaults: UserDefaults = .standard) -> Bool {
        let bots = roster.bots.filter { !$0.isDefault && !$0.isHidden }
        let names = Dictionary(bots.map { ($0.name, $0.label()) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        if names != botNames(settings: settings, defaults: defaults) {
            if let data = try? JSONEncoder().encode(names) { defaults.set(data, forKey: botsKey(settings)) }
            changed = true
        }
        var all = kept(settings: settings, defaults: defaults)
        for bot in bots where !all.contains(where: { same($0.name, bot.name) }) {
            all.append(KnownProfile(name: bot.name, title: bot.label()))
        }
        // (save tells Siri itself when the list changed.)
        if save(all, settings: settings, defaults: defaults) { return true }
        if changed, settings === Settings.shared { EchoShortcuts.updateAppShortcutParameters() }
        return changed
    }

    /// The ones kept that aren't the main profile.
    static func kept(settings: Settings = .shared, defaults: UserDefaults = .standard) -> [KnownProfile] {
        guard let data = defaults.data(forKey: key(settings)) else { return [] }
        return (try? JSONDecoder().decode([KnownProfile].self, from: data)) ?? []
    }

    /// The Dashboard's list takes the place of what was kept: it is the server's own word.
    /// True when that changed what is known.
    @discardableResult
    static func keep(listed: [HermesServeClient.Profile], settings: Settings = .shared, defaults: UserDefaults = .standard) -> Bool {
        save(listed.filter { !$0.isDefault && !same($0.name, defaultID) }.map { KnownProfile(name: $0.name, title: $0.title, path: $0.path) },
             settings: settings, defaults: defaults)
    }

    /// A profile chosen by name is kept beside the others.
    @discardableResult
    static func keep(named name: String, settings: Settings = .shared, defaults: UserDefaults = .standard) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var all = kept(settings: settings, defaults: defaults)
        guard !name.isEmpty, !same(name, defaultID), !all.contains(where: { same($0.name, name) }) else { return false }
        all.append(KnownProfile(name: name, title: name))
        return save(all, settings: settings, defaults: defaults)
    }

    @discardableResult
    static func forget(_ name: String, settings: Settings = .shared, defaults: UserDefaults = .standard) -> Bool {
        save(kept(settings: settings, defaults: defaults).filter { !same($0.name, name) }, settings: settings, defaults: defaults)
    }

    private static func save(_ profiles: [KnownProfile], settings: Settings, defaults: UserDefaults) -> Bool {
        guard profiles != kept(settings: settings, defaults: defaults) else { return false }
        if profiles.isEmpty { defaults.removeObject(forKey: key(settings)) }
        else if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: key(settings)) }
        // Siri learns its phrases for each profile by name: tell it the names changed.
        if settings === Settings.shared { EchoShortcuts.updateAppShortcutParameters() }
        return true
    }

    /// The list as the Dashboard has it now, when there is a login to ask with and it answers
    /// in time; what was kept otherwise. Siri and Shortcuts ask through this.
    static func refreshed(settings: Settings = .shared, client: HermesServeClient = .shared, patience: Duration = .seconds(4)) async -> [KnownProfile] {
        guard client.hasCredentials else { return known(settings: settings) }
        let server = settings.activeServerID
        let listed = await withTaskGroup(of: [HermesServeClient.Profile]?.self) { group in
            group.addTask { try? await client.profiles() }
            group.addTask { try? await Task.sleep(for: patience); return nil }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        // (The app may have moved to another server while the old one answered.)
        if let listed, settings.activeServerID == server { keep(listed: listed, settings: settings) }
        return known(settings: settings)
    }

    /// The profile a name means: its name or its title, whatever the case or the accents.
    nonisolated static func find(_ said: String, in profiles: [KnownProfile]) -> KnownProfile? {
        let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return nil }
        return profiles.first { same($0.name, said) } ?? profiles.first { same($0.title, said) }
    }

    nonisolated private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Moves the app to a profile, as picking it in Settings does: the open conversation belongs
    /// to the old one, so a switch starts a fresh one. Nothing happens for the profile in use.
    /// True when it switched.
    @discardableResult
    static func use(_ profile: KnownProfile, conversation: Conversation, settings: Settings = .shared) -> Bool {
        let name: String? = profile.isDefault ? nil : profile.name
        guard name != settings.profileName else { return false }
        settings.hermesProfile = name ?? ""
        settings.hermesProfileHome = name == nil ? "" : profile.path
        conversation.reset()
        return true
    }
}

// MARK: - Siri and Shortcuts

/// A profile as Siri and Shortcuts name it.
struct ReddeProfileEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bot or Profile")
    static let defaultQuery = ReddeProfileQuery()

    let id: String
    var title: String

    init(_ profile: KnownProfile) {
        id = profile.name
        title = profile.title
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: id == ProfileCatalog.defaultID ? "The server's main profile" : nil,
                              image: .init(systemName: "person.crop.circle"))
    }
}

nonisolated struct ReddeProfileQuery: EntityStringQuery {
    func entities(for identifiers: [ReddeProfileEntity.ID]) async throws -> [ReddeProfileEntity] {
        await MainActor.run {
            let known = ProfileCatalog.known()
            return identifiers.compactMap { id in ProfileCatalog.find(id, in: known).map(ReddeProfileEntity.init) }
        }
    }

    func entities(matching string: String) async throws -> [ReddeProfileEntity] {
        let known = await ProfileCatalog.refreshed()
        return await MainActor.run {
            let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let exact = ProfileCatalog.find(needle, in: known) { return [ReddeProfileEntity(exact)] }
            return known.filter { $0.title.localizedCaseInsensitiveContains(needle) || $0.name.localizedCaseInsensitiveContains(needle) }
                .map(ReddeProfileEntity.init)
        }
    }

    func suggestedEntities() async throws -> [ReddeProfileEntity] {
        let known = await ProfileCatalog.refreshed()
        return await MainActor.run { known.map(ReddeProfileEntity.init) }
    }
}

/// "Ask Claude in Redde": voice mode with a bot or on a named Hermes profile. Like "Ask Redde",
/// Siri is only the trigger: the app opens and listens. On the Dashboard, with the Bots on, a
/// bot is talked to in its own chat (the one the chat list opens); otherwise the app moves to
/// that profile, as before Bot Mode.
struct AskProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask a Redde Bot"
    static let description = IntentDescription("Opens one of your bots' chats in Redde (or Redde on one of your Hermes profiles) and starts listening.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Bot", requestValueDialog: "Which bot?")
    var profile: ReddeProfileEntity

    @Parameter(title: "Hands-free",
               description: "Keep listening after each reply until you say “stop listening”.",
               default: false)
    var handsFree: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$profile) in Redde") { \.$handsFree }
    }

    func perform() async throws -> some IntentResult {
        let (id, handsFree) = (profile.id, handsFree)
        await MainActor.run { LaunchRouter.shared.requestVoice(handsFree: handsFree, profile: id) }
        return .result()
    }
}

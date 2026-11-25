import SwiftUI

/// Settings search (asked 2026-11-25: "do option 2"): every setting by its name, the settings on a
/// screen a row opens, and other words it might be looked for by. A result opens its page,
/// scrolls to the row and lights it for a moment (`SettingsFocus`).
///
/// Each case is a row on a screen, marked there with `.settingRow(_:)`, which is where the page
/// scrolls to. `SettingsSearchTests` checks every case is on a screen. Titles are the rows' own
/// words, so they read as the screen does in every language.
enum SettingsRow: String, CaseIterable, Identifiable {
    // The first screen.
    case name, server, profile, model, modelsProviders, plugin
    case supportRedde, rateRedde, whatsNew, acknowledgements, reportProblem, version
    // Connection.
    case connectionKind, setUpConnection, setUpDevice, connectionDetails, contextWindow
    // Agent.
    case skills, tools, plugins, keysAskedFor, soul, environment, memory, files, terminal, usage, gateway
    // Your Day.
    case aheadOfYourDay, goals, activity, briefings, pastBriefings, briefingTaps, watches, triggers, keepInMind
    case followThrough, health, beforeActing, approvalHistory
    // Email.
    case addEmail, inbox, mailRules, piles, inboxShows, sortMail
    // Phone Tools, Calendars, Location.
    case phoneAreas, keepACopy
    case allCalendars, newEvents, eventColors
    case places, currentLocation, leaveBy
    // General.
    case whenOpens, listenOnOpen, icloud, syncAppearance, appLock, lockAfter, erase
    // Appearance.
    case theme, colors, font, chatTextSize, botFaces, cards, todayTiles, cardAppearance, botColors, appIcon
    // Chat List.
    case showBots, projects, topCards, upNext, remindersOnDay
    // Replies & Writing.
    case suggestReplies, agentsTalk, cardsInReplies, addressMaps, units, linkPreviews, botPictures, returnKey
    // Voice.
    case voiceMode, agentCalls, readingVoice, voiceForReplies, voiceSpeed, earpiece, listeningLanguage, replyLanguage
    case spokenPrefixes, wakePhrase, handsFree, talkOver, interruptWith, stopPhrases, thinkingSound
    case newVoiceConversation, answerByVoice, nodToAnswer, voiceOrb
    // Notifications.
    case alertsWhileOpen, announce, alertSound, quietHours, push, liveActivities, workingCard
    // CarPlay.
    case carPlayCards, carPlayVoice, carPlayBots, stopAndSkip, shortAnswers
    // Siri.
    case letSiri, siriDrafts

    var id: String { rawValue }

    /// Its id in its screen's scroll view.
    var anchor: String { "setting.\(rawValue)" }

    struct Entry {
        /// The page it is on; none for the first screen.
        var page: SettingsPage?
        var title: String
        /// The settings on the screen it opens, or in the list it folds, found by their names too.
        var inner: [String] = []
        /// Other words it might be looked for by.
        var words: String = ""
        /// Off for a row that is only somewhere to find what is in it (the kinds of connection).
        var listed = true
    }

    var entry: Entry {
        switch self {
        case .name: Entry(title: String(localized: "Name"),
                          words: String(localized: "display name, header, rename", comment: "Settings search: other words for Settings › Name, comma-separated"))
        case .server: Entry(title: String(localized: "Server"),
                            words: String(localized: "servers, add a server, switch servers, host", comment: "Settings search: other words for Settings › Server, comma-separated"))
        case .profile: Entry(title: String(localized: "Profile"))
        case .model: Entry(title: String(localized: "Model"),
                           words: String(localized: "LLM, reasoning effort, thinking, switch models", comment: "Settings search: other words for Settings › Model, comma-separated"))
        case .modelsProviders: Entry(title: String(localized: "Models & Providers"),
                                     words: String(localized: "provider, OpenRouter, fallback model, API key", comment: "Settings search: other words for Settings › Models & Providers, comma-separated"))
        case .plugin: Entry(title: String(localized: "Redde Plugin"),
                            words: String(localized: "Hermes plugin, update the plugin", comment: "Settings search: other words for Settings › Redde Plugin, comma-separated"))
        case .supportRedde: Entry(title: String(localized: "Support Redde"),
                                  words: String(localized: "tip, donate", comment: "Settings search: other words for Settings › Support Redde, comma-separated"))
        case .rateRedde: Entry(title: String(localized: "Rate Redde on the App Store"))
        case .whatsNew: Entry(title: String(localized: "What's New in Redde"))
        case .acknowledgements: Entry(title: String(localized: "Acknowledgements"),
                                      words: String(localized: "licenses, open source", comment: "Settings search: other words for Settings › Acknowledgements, comma-separated"))
        case .reportProblem: Entry(title: String(localized: "Report a Problem"),
                                   words: String(localized: "bug, crash, diagnostics, logs, feedback", comment: "Settings search: other words for Settings › Report a Problem, comma-separated"))
        case .version: Entry(title: String(localized: "Version"))

        case .connectionKind: Entry(page: .connection, title: SettingsPage.connection.title,
                                    inner: Transport.allCases.map(\.shortLabel), listed: false)
        case .setUpConnection: Entry(page: .connection, title: String(localized: "Set up connection…"),
                                     words: String(localized: "setup code, QR code, scan, connect", comment: "Settings search: other words for Settings › Connection › Set up connection, comma-separated"))
        case .setUpDevice: Entry(page: .connection, title: String(localized: "Set up another device…"))
        case .connectionDetails: Entry(page: .connection, title: String(localized: "Connection details"),
                                       words: String(localized: "URL, address, API key, password, login, sign in, token, headers", comment: "Settings search: other words for Settings › Connection › Connection details, comma-separated"))
        case .contextWindow: Entry(page: .connection, title: String(localized: "Context window"),
                                   words: String(localized: "ctx, tokens, context length", comment: "Settings search: other words for Settings › Connection › Context window, comma-separated"))

        case .skills: Entry(page: .agent, title: String(localized: "Skills"))
        case .tools: Entry(page: .agent, title: String(localized: "Tools"),
                           words: String(localized: "toolsets, MCP", comment: "Settings search: other words for Settings › Agent › Tools, comma-separated"))
        case .plugins: Entry(page: .agent, title: String(localized: "Plugins"))
        case .keysAskedFor: Entry(page: .agent, title: String(localized: "Keys Asked For"))
        case .soul: Entry(page: .agent, title: "SOUL.md",
                          words: String(localized: "persona, personality, system prompt", comment: "Settings search: other words for Settings › Agent › SOUL.md, comma-separated"))
        case .environment: Entry(page: .agent, title: "ENVIRONMENT.md")
        case .memory: Entry(page: .agent, title: String(localized: "What Your Agent Remembers"),
                            words: String(localized: "memory, MEMORY.md, USER.md, remember", comment: "Settings search: other words for Settings › Agent › What Your Agent Remembers, comma-separated"))
        case .files: Entry(page: .agent, title: String(localized: "Files"))
        case .terminal: Entry(page: .agent, title: String(localized: "Terminal"),
                              words: String(localized: "SSH, shell, command line", comment: "Settings search: other words for Settings › Agent › Terminal, comma-separated"))
        case .usage: Entry(page: .agent, title: String(localized: "Usage"),
                           words: String(localized: "cost, spend, tokens", comment: "Settings search: other words for Settings › Agent › Usage, comma-separated"))
        case .gateway: Entry(page: .agent, title: String(localized: "Gateway"),
                             words: String(localized: "restart Hermes, update Hermes, logs, MCP servers", comment: "Settings search: other words for Settings › Agent › Gateway, comma-separated"))

        case .aheadOfYourDay: Entry(page: .day, title: String(localized: "Ahead of Your Day"))
        case .goals: Entry(page: .day, title: String(localized: "Goals"))
        case .activity: Entry(page: .day, title: String(localized: "Activity"))
        case .briefings: Entry(page: .day, title: String(localized: "Briefings"),
                               inner: DailyJobsView.jobs.map { String(localized: $0.title) } + [String(localized: "Times & Options")])
        case .pastBriefings: Entry(page: .day, title: String(localized: "Past Briefings"))
        case .briefingTaps: Entry(page: .day, title: String(localized: "Briefing Taps Open the Run"))
        case .watches: Entry(page: .day, title: String(localized: "Watches & Follow-ups"))
        case .triggers: Entry(page: .day, title: String(localized: "Triggers from Your iPhone"),
                              words: String(localized: "automation, arriving home, Focus", comment: "Settings search: other words for Settings › Your Day › Triggers from Your iPhone, comma-separated"))
        case .keepInMind: Entry(page: .day, title: String(localized: "Things to Keep in Mind"))
        case .followThrough: Entry(page: .day, title: String(localized: "Follow-Through"))
        case .health: Entry(page: .day, title: String(localized: "Health"))
        case .beforeActing: Entry(page: .day, title: String(localized: "Before Acting"),
                                  words: String(localized: "approvals, permissions", comment: "Settings search: other words for Settings › Your Day › Before Acting, comma-separated"))
        case .approvalHistory: Entry(page: .day, title: String(localized: "Approval History"))

        case .addEmail: Entry(page: .email, title: String(localized: "Add Email Account"),
                              words: String(localized: "mail, Gmail, IMAP, Outlook", comment: "Settings search: other words for Settings › Email › Add Email Account, comma-separated"))
        case .inbox: Entry(page: .email, title: String(localized: "Inbox", comment: "Email settings: open the inbox"))
        case .mailRules: Entry(page: .email, title: String(localized: "Rules", comment: "Email settings: the rules page"))
        case .piles: Entry(page: .email, title: String(localized: "Piles", comment: "Email piles page: title"))
        case .inboxShows: Entry(page: .email, title: String(localized: "Inbox Shows"))
        case .sortMail: Entry(page: .email, title: String(localized: "Sort New Mail"))

        case .phoneAreas: Entry(page: .phoneTools, title: SettingsPage.phoneTools.title,
                                inner: DeviceArea.allCases.map(\.label), listed: false)
        case .keepACopy: Entry(page: .phoneTools, title: String(localized: "Keep a Copy"))
        case .allCalendars: Entry(page: .calendars, title: String(localized: "All Calendars"))
        case .newEvents: Entry(page: .calendars, title: String(localized: "New Events"))
        case .eventColors: Entry(page: .calendars, title: String(localized: "Calendar Events"))
        case .places: Entry(page: .location, title: String(localized: "places.title", defaultValue: "Places"))
        case .currentLocation: Entry(page: .location, title: String(localized: "Current Location"))
        case .leaveBy: Entry(page: .location, title: String(localized: "Leave-By Alerts"),
                             words: String(localized: "traffic, when to leave, travel time", comment: "Settings search: other words for Settings › Location › Leave-By Alerts, comma-separated"))

        case .whenOpens: Entry(page: .general, title: String(localized: "When Redde opens"))
        case .listenOnOpen: Entry(page: .general, title: String(localized: "Listen whenever Redde opens"))
        case .icloud: Entry(page: .general, title: String(localized: "Sync with iCloud"),
                            words: String(localized: "sync, other devices, iPad, Mac", comment: "Settings search: other words for Settings › General › Sync with iCloud, comma-separated"))
        case .syncAppearance: Entry(page: .general, title: String(localized: "Sync Appearance"))
        case .appLock: Entry(page: .general, title: String(localized: "Require \(AppLock.biometryName)"),
                             words: String(localized: "App Lock, passcode, Face ID, Touch ID, privacy", comment: "Settings search: other words for Settings › General › Require Face ID, comma-separated"))
        case .lockAfter: Entry(page: .general, title: String(localized: "Lock after"))
        case .erase: Entry(page: .general, title: String(localized: "Erase everything…"),
                           words: String(localized: "reset, delete everything, start over", comment: "Settings search: other words for Settings › General › Erase everything, comma-separated"))

        case .theme: Entry(page: .appearance, title: String(localized: "Theme"), inner: Theme.allCases.map(\.label),
                           words: String(localized: "dark mode, light mode, night, colors", comment: "Settings search: other words for Settings › Appearance › Theme, comma-separated"))
        case .colors: Entry(page: .appearance, title: String(localized: "\(Settings.shared.theme.label) colors"),
                            inner: [String(localized: "Accent"), String(localized: "Your bubbles"), String(localized: "Wallpaper")])
        case .font: Entry(page: .appearance, title: String(localized: "Font", comment: "Settings → Appearance: the face of the conversation"),
                          inner: ChatFont.allCases.map(\.label),
                          words: String(localized: "typeface, serif", comment: "Settings search: other words for Settings › Appearance › Font, comma-separated"))
        case .chatTextSize: Entry(page: .appearance, title: String(localized: "Chat text size"),
                                  words: String(localized: "bigger text, smaller text, font size", comment: "Settings search: other words for Settings › Appearance › Chat text size, comma-separated"))
        case .botFaces: Entry(page: .appearance, title: String(localized: "Bot faces"))
        case .cards: Entry(page: .appearance, title: String(localized: "Cards"))
        case .todayTiles: Entry(page: .appearance, title: String(localized: "Today Tiles"))
        case .cardAppearance: Entry(page: .appearance, title: String(localized: "Card Appearance"))
        case .botColors: Entry(page: .appearance, title: String(localized: "Bot colors in their chats"))
        case .appIcon: Entry(page: .appearance, title: String(localized: "App icon"),
                             words: String(localized: "Home Screen icon", comment: "Settings search: other words for Settings › Appearance › App icon, comma-separated"))

        case .showBots: Entry(page: .chatList, title: String(localized: "Bots in the chat list"))
        case .projects: Entry(page: .chatList, title: String(localized: "Projects in the chat list"))
        case .topCards: Entry(page: .chatList, title: String(localized: "Top of the Chat List"), inner: ChatListCard.allCases.map(\.title))
        case .upNext: Entry(page: .chatList, title: String(localized: "Up Next"))
        case .remindersOnDay: Entry(page: .chatList, title: String(localized: "Reminders on Their Day"))

        case .suggestReplies: Entry(page: .writing, title: String(localized: "Suggest Replies"))
        case .agentsTalk: Entry(page: .writing, title: String(localized: "Agents Talking to Each Other"),
                                inner: [String(localized: "Hermes Bots"), String(localized: "Other Agents"), String(localized: "Ask Me First")])
        case .cardsInReplies: Entry(page: .writing, title: String(localized: "Cards in replies"),
                                    words: String(localized: "weather, maps", comment: "Settings search: other words for Settings › Replies & Writing › Cards in replies, comma-separated"))
        case .addressMaps: Entry(page: .writing, title: String(localized: "Maps for addresses"))
        case .units: Entry(page: .writing, title: String(localized: "Units"),
                           words: String(localized: "miles, kilometers, Fahrenheit, Celsius, metric", comment: "Settings search: other words for Settings › Replies & Writing › Units, comma-separated"))
        case .linkPreviews: Entry(page: .writing, title: String(localized: "Link previews"))
        case .botPictures: Entry(page: .writing, title: String(localized: "Pictures from Hermes"))
        case .returnKey: Entry(page: .writing, title: String(localized: "Return key"),
                               words: String(localized: "send, new line, enter, keyboard", comment: "Settings search: other words for Settings › Replies & Writing › Return key, comma-separated"))

        case .voiceMode: Entry(page: .voice, title: String(localized: "Voice mode"),
                               inner: [String(localized: "Keep Calls On When Locked"), String(localized: "Group Chats as Calls"), String(localized: "Hang up after quiet")],
                               words: String(localized: "live call, GPT-Live, Gemini Live, Grok, ElevenLabs", comment: "Settings search: other words for Settings › Voice › Voice mode, comma-separated"))
        case .agentCalls: Entry(page: .voice, title: String(localized: "Calls from Agents"),
                                inner: [String(localized: "Let Agents Call Me"), String(localized: "Who Can Call"), String(localized: "Talk While Locked")])
        case .readingVoice: Entry(page: .voice, title: String(localized: "Reading voice"),
                                  words: String(localized: "text to speech, TTS, read aloud, Kokoro, ElevenLabs", comment: "Settings search: other words for Settings › Voice › Reading voice, comma-separated"))
        case .voiceForReplies: Entry(page: .voice, title: String(localized: "Voice for replies"))
        case .voiceSpeed: Entry(page: .voice, title: String(localized: "Voice speed"))
        case .earpiece: Entry(page: .voice, title: String(localized: "Earpiece when raised to your ear"))
        case .listeningLanguage: Entry(page: .voice, title: String(localized: "Listening language"),
                                       words: String(localized: "dictation, speech recognition", comment: "Settings search: other words for Settings › Voice › Listening language, comma-separated"))
        case .replyLanguage: Entry(page: .voice, title: String(localized: "Reply language"))
        case .spokenPrefixes: Entry(page: .voice, title: String(localized: "Spoken prefixes"))
        case .wakePhrase: Entry(page: .voice, title: String(localized: "Wake phrase"), inner: [String(localized: "Listen for wake phrases")],
                                words: String(localized: "hey, wake word", comment: "Settings search: other words for Settings › Voice › Wake phrase, comma-separated"))
        case .handsFree: Entry(page: .voice, title: String(localized: "Start voice mode in hands-free"))
        case .talkOver: Entry(page: .voice, title: String(localized: "Talk over replies"),
                              words: String(localized: "interrupt, barge in", comment: "Settings search: other words for Settings › Voice › Talk over replies, comma-separated"))
        case .interruptWith: Entry(page: .voice, title: String(localized: "Interrupt with"))
        case .stopPhrases: Entry(page: .voice, title: String(localized: "Stop phrases"))
        case .thinkingSound: Entry(page: .voice, title: String(localized: "Thinking sound"))
        case .newVoiceConversation: Entry(page: .voice, title: String(localized: "New conversation in voice mode"))
        case .answerByVoice: Entry(page: .voice, title: String(localized: "Answer requests by voice"),
                                   words: String(localized: "approve, deny", comment: "Settings search: other words for Settings › Voice › Answer requests by voice, comma-separated"))
        case .nodToAnswer: Entry(page: .voice, title: String(localized: "Nod or shake to answer"))
        case .voiceOrb: Entry(page: .voice, title: String(localized: "Voice orb"), inner: [String(localized: "Orb light")])

        case .alertsWhileOpen: Entry(page: .notifications, title: String(localized: "Alerts While Redde Is Open"))
        case .announce: Entry(page: .notifications, title: String(localized: "Announce on AirPods"))
        case .alertSound: Entry(page: .notifications, title: String(localized: "Alert Sound"),
                                words: String(localized: "silent, sound, mute", comment: "Settings search: other words for Settings › Notifications › Alert Sound, comma-separated"))
        case .quietHours: Entry(page: .notifications, title: String(localized: "Quiet Hours"),
                                inner: [String(localized: "At Most a Day", comment: "Settings › Notifications › Quiet Hours: how many notifications agents may send on their own each day")],
                                words: String(localized: "do not disturb, night", comment: "Settings search: other words for Settings › Notifications › Quiet Hours, comma-separated"))
        case .push: Entry(page: .notifications, title: String(localized: "Alerts When Redde Is Closed"),
                          inner: [String(localized: "Only Where You Are"), String(localized: "Pair with a code instead")],
                          words: String(localized: "push notifications, pair", comment: "Settings search: other words for Settings › Notifications › Alerts When Redde Is Closed, comma-separated"))
        case .liveActivities: Entry(page: .notifications, title: String(localized: "Live Activities"),
                                    words: String(localized: "Dynamic Island, Lock Screen", comment: "Settings search: other words for Settings › Notifications › Live Activities, comma-separated"))
        case .workingCard: Entry(page: .notifications, title: String(localized: "“\(Settings.shared.headerTitle) Is Working” Card"))

        case .carPlayCards: Entry(page: .carPlay, title: String(localized: "CarPlay cards"))
        case .carPlayVoice: Entry(page: .carPlay, title: String(localized: "CarPlay voice screen"))
        case .carPlayBots: Entry(page: .carPlay, title: String(localized: "CarPlay bot cards"))
        case .stopAndSkip: Entry(page: .carPlay, title: String(localized: "Stop and Skip in the car"))
        case .shortAnswers: Entry(page: .carPlay, title: String(localized: "Short answers in the car"))

        case .letSiri: Entry(page: .siri, title: String(localized: "Let Siri use Redde"),
                             words: String(localized: "Apple Intelligence, Spotlight", comment: "Settings search: other words for Settings › Siri › Let Siri use Redde, comma-separated"))
        case .siriDrafts: Entry(page: .siri, title: String(localized: "Drafts in a new conversation"))
        }
    }

    /// Whether this device, on this connection, has the row: a result for one it hasn't would open
    /// a page without it.
    func isOffered(_ settings: Settings) -> Bool {
        if let page = entry.page, !page.isOffered { return false }
        switch self {
        case .server: return settings.transport != .chatCompletions
        case .profile, .modelsProviders: return settings.transport.isHermes
        case .whatsNew: return WhatsNew.highlights(of: WhatsNew.currentVersion) != nil
        case .terminal, .agentCalls, .workingCard, .places:
            #if os(iOS)
            return true
            #else
            return false
            #endif
        case .health:
            #if os(iOS)
            return HealthDays.available
            #else
            return false
            #endif
        case .appIcon:
            #if os(iOS)
            return UIApplication.shared.supportsAlternateIcons
            #else
            return false
            #endif
        case .inbox, .mailRules, .sortMail: return MailCenter.shared.isSetUp
        case .piles: return MailCenter.shared.isSetUp && MailCenter.shared.status?.hasPiles == true
        case .inboxShows: return MailCenter.shared.isSetUp && MailCenter.shared.accounts.count > 1
        case .syncAppearance: return CloudSync.shared.phase == .on
        case .lockAfter: return settings.requireBiometrics
        case .showBots: return BotDirectory.reachable(settings)
        case .projects: return settings.transport == .hermesServe
        case .voiceForReplies: return settings.replyVoice != .hermes && settings.replyVoice != .elevenLabs
        case .voiceSpeed: return settings.replyVoice != .hermes
        case .interruptWith: return settings.talkOver != .off
        case .nodToAnswer: return settings.answerRequestsByVoice && HeadGestures.isAvailable
        case .carPlayBots: return BotDirectory.available(settings)
        case .siriDrafts: return settings.siriAIEnabled
        default: return true
        }
    }
}

enum SettingsSearch {
    struct Hit: Identifiable, Equatable {
        let id: String
        let title: String
        /// Where it is: its page, and the row it is behind.
        let place: String
        let symbol: String
        /// The page it opens; none for a row of the first screen.
        let page: SettingsPage?
        /// The row it scrolls to; none for a page itself.
        let row: SettingsRow?
    }

    /// What matches every word of `query`, best first: a title starting with it, then a title
    /// with a word starting with one of its words, then the rest (other words, the page's name).
    static func hits(for query: String, settings: Settings = .shared) -> [Hit] {
        let terms = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let whole = terms.joined(separator: " ")
        let home = String(localized: "Settings")
        var found: [(rank: Int, order: Int, hit: Hit)] = []

        func consider(_ title: String, also: [String], _ hit: @autoclosure () -> Hit) {
            let folded = fold(title)
            let haystack = ([folded] + also.map(fold)).joined(separator: " ")
            guard terms.allSatisfy(haystack.contains) else { return }
            let words = folded.split { !$0.isLetter && !$0.isNumber }
            let rank = folded.hasPrefix(whole) ? 0
                : words.contains(where: { word in terms.contains(where: { word.hasPrefix($0) }) }) ? 1
                : folded.contains(whole) ? 2 : 3
            found.append((rank, found.count, hit()))
        }

        for page in SettingsPage.allCases where page.isOffered {
            consider(page.title, also: [],
                     Hit(id: "page.\(page.rawValue)", title: page.title, place: home, symbol: page.symbol, page: page, row: nil))
        }
        for row in SettingsRow.allCases where row.isOffered(settings) {
            let entry = row.entry
            let place = entry.page?.title ?? home
            let symbol = entry.page?.symbol ?? "gearshape"
            if entry.listed {
                consider(entry.title, also: [entry.words, place],
                         Hit(id: row.rawValue, title: entry.title, place: place, symbol: symbol, page: entry.page, row: row))
            }
            let behind = entry.listed ? "\(place) › \(entry.title)" : place
            for (index, inner) in entry.inner.enumerated() where fold(inner) != fold(entry.title) {
                consider(inner, also: [place],
                         Hit(id: "\(row.rawValue).\(index)", title: inner, place: behind, symbol: symbol, page: entry.page, row: row))
            }
        }
        return found.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }.prefix(60).map(\.hit)
    }

    /// Case, accents and width aside: "écran" finds "Ecran", "ｗａｋｅ" finds "wake".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

/// Where a search result is going, and the row lit once it is there.
@Observable
final class SettingsFocus {
    static let shared = SettingsFocus()

    /// The row a result opens on, until its page has scrolled to it.
    var target: SettingsRow?
    /// The row lit for a moment once there.
    private(set) var lit: SettingsRow?

    /// On `page` (the first screen with none): when the result was for a row of it, scrolls there
    /// once the page is in, and lights the row.
    func arrive(on page: SettingsPage?, scroll: (String) -> Void) async {
        guard let row = target, row.entry.page == page else { return }
        target = nil
        try? await Task.sleep(for: .milliseconds(450))
        withAnimation(.easeInOut(duration: 0.3)) { scroll(row.anchor) }
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.easeIn(duration: 0.2)) { lit = row }
        try? await Task.sleep(for: .seconds(1.6))
        withAnimation(.easeOut(duration: 0.8)) { if lit == row { lit = nil } }
    }
}

extension View {
    /// A setting search finds (`SettingsRow`): what its page scrolls to and lights.
    func settingRow(_ row: SettingsRow) -> some View { modifier(SettingRowMark(row: row)) }
}

private struct SettingRowMark: ViewModifier {
    let row: SettingsRow

    func body(content: Content) -> some View {
        let lit = SettingsFocus.shared.lit == row
        content
            .id(row.anchor)
            .listRowBackground(lit ? Settings.shared.resolvedTheme.accent.opacity(0.22) : nil)
    }
}

/// A page of Settings that a search result can open on a row of: the scroll view the row is in.
struct SettingsFound<Content: View>: View {
    let page: SettingsPage
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            content()
                .task { await SettingsFocus.shared.arrive(on: page) { proxy.scrollTo($0, anchor: .center) } }
        }
    }
}

/// What a search in Settings finds, in place of the first screen's rows while there is a query.
struct SettingsSearchResults: View {
    let query: String
    let open: (SettingsSearch.Hit) -> Void
    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        let hits = SettingsSearch.hits(for: query)
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(hits) { hit in
                    Button {
                        // A row of the first screen: the search goes, and the screen scrolls to it.
                        if hit.page == nil { dismissSearch() }
                        open(hit)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.title).foregroundStyle(.primary)
                                Text(hit.place).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: hit.symbol)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-hit-\(hit.id)")
                }
            }
        }
    }
}

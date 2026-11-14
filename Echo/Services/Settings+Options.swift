// Settings' choices and what follows from them: reasoning, voices, themes, colours.
import Foundation
import SwiftUI

extension Settings {
    /// The effort levels offered, lowest first; "" leaves it to the gateway, "none" turns
    /// reasoning off. X-High and Max are for frontier models (Claude, GPT); the values are the
    /// ones their APIs use.
    static let reasoningEfforts: [(value: String, label: String)] = [
        ("", String(localized: "Default", comment: "Reasoning effort: left to the server")),
        ("none", String(localized: "None", comment: "Reasoning effort: reasoning off")),
        ("low", String(localized: "Low", comment: "Reasoning effort")),
        ("medium", String(localized: "Medium", comment: "Reasoning effort")),
        ("high", String(localized: "High", comment: "Reasoning effort")),
        ("xhigh", String(localized: "X-High", comment: "Reasoning effort, above High")),
        ("max", String(localized: "Max", comment: "Reasoning effort: the most")),
    ]

    static func effortLabel(_ value: String) -> String {
        reasoningEfforts.first { $0.value == value }?.label ?? value
    }

    /// Fresh installs start with reasoning off: a phone wants quick answers, and the gateway's
    /// own default is often tuned for a desk.
    static let defaultReasoningEffort = "none"

    /// The live engine holding the voice conversations with `profile` (nil or "default": the main
    /// agent): the bot's own choice (Edit Bot → Voice), else the one above; nil for Redde's. In
    /// release builds since 2.2: until then development builds only, while its calls went over
    /// WebRTC, whose own cryptography would have needed declaring; they go over a WebSocket on
    /// Apple's TLS since 2026-10-24.
    func liveEngine(for profile: String?) -> LiveEngine? {
        if let profile, profile != "default", let own = botVoicesHere[profile]?.conversation { return own.live }
        return voiceEngine.live
    }
    func usesLiveCall(for profile: String?) -> Bool { liveEngine(for: profile) != nil }
    /// The voice `engine` speaks with in calls with `profile`: its own for that engine, else the
    /// app's; one the engine doesn't offer (Redde listed OpenAI's older voices until 2026-10-25)
    /// is its default.
    func liveVoice(for profile: String?, engine: LiveEngine = .gptLive) -> String {
        if let profile, profile != "default", let own = botVoicesHere[profile]?.liveVoices?[engine.rawValue],
           engine.voicesFromAccount ? !own.isEmpty : engine.voices.contains(own) {
            return own
        }
        return appLiveVoice(engine)
    }
    /// The app's voice for `engine` (Settings → Voice → Voice mode).
    func appLiveVoice(_ engine: LiveEngine) -> String {
        let picked = engine == .gptLive ? liveVoice : liveVoices[engine.rawValue]
        if engine.voicesFromAccount { return picked ?? "" }
        return picked.flatMap { engine.voices.contains($0) ? $0 : nil } ?? engine.defaultVoice
    }
    func setAppLiveVoice(_ voice: String, for engine: LiveEngine) {
        if engine == .gptLive { liveVoice = voice } else { liveVoices[engine.rawValue] = voice }
    }

    static let liveHangUps = [1, 2, 5, 10, 0]

    /// Launch straight into the voice screen. (Once its own switch; now one of `launchScreen`.)
    var openToVoiceScreen: Bool { launchScreen == .voice }
    /// Who reads replies out: the iPhone's own voice, a Kokoro server, the person's Hermes with
    /// the voice it is set up with (`HermesSpeech`, over the Dashboard), or ElevenLabs on the
    /// person's own key (`ElevenLabsSpeech`; asked 2026-10-26, for bots' voices in group chats).
    enum ReplyVoice: String, CaseIterable, Codable, Sendable {
        case onDevice, kokoro, hermes, elevenLabs

        var name: String {
            switch self {
            case .onDevice: String(localized: "On-device", comment: "Reply voice: the iPhone's own voice")
            case .kokoro: "Kokoro"
            case .hermes: "Hermes"
            case .elevenLabs: "ElevenLabs"
            }
        }
    }
    /// Which voice reads what `profile` says: a bot's own reading voice (Edit Bot → Voice), else
    /// this one. The main agent's is always this one.
    func readingVoice(for profile: String?) -> ReplyVoice {
        guard let profile, profile != "default", let own = botVoicesHere[profile]?.reader else { return replyVoice }
        return own
    }

    /// Speak replies with a Kokoro server instead of the on-device voice.
    var useKokoro: Bool { replyVoice == .kokoro }

    /// What Redde listens for: `speechLanguage`, or the iPhone's language.
    var speechLocale: Locale { speechLanguage.isEmpty ? .current : Locale(identifier: speechLanguage) }

    /// The active theme with your colors applied: what the app renders.
    var resolvedTheme: ResolvedTheme { resolved(theme) }
    func resolved(_ theme: Theme) -> ResolvedTheme { theme.resolved(with: themeColors[theme.rawValue], font: chatFont) }
    /// Light / dark / follow the system, for the Default theme (the others fix their own).
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: String(localized: "System", comment: "Appearance: follow the iPhone's light or dark setting")
            case .light: String(localized: "Light", comment: "Appearance: light mode")
            case .dark: String(localized: "Dark", comment: "Appearance: dark mode")
            }
        }
        var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    }

    /// Settings → Appearance → Calendar Events: each calendar in its own colour on an agenda card,
    /// or every event in one (asked 2026-10-30: "I'd like them yellow").
    enum EventColor: String, CaseIterable, Identifiable {
        case byCalendar, yellow, orange, pink, purple, blue, teal, green
        var id: String { rawValue }
        var color: Color? {
            switch self {
            case .byCalendar: nil
            case .yellow: .yellow
            case .orange: .orange
            case .pink: .pink
            case .purple: .purple
            case .blue: .blue
            case .teal: .teal
            case .green: .green
            }
        }
        var label: String {
            switch self {
            case .byCalendar: String(localized: "By Calendar", comment: "Calendar Events setting: each calendar in its own colour")
            case .yellow: String(localized: "Yellow")
            case .orange: String(localized: "Orange")
            case .pink: String(localized: "Pink")
            case .purple: String(localized: "Purple")
            case .blue: String(localized: "Blue")
            case .teal: String(localized: "Teal")
            case .green: String(localized: "Green")
            }
        }
    }

    /// Settings → Appearance → Cards (asked 2026-11-02): a wash of one colour over every answer
    /// card's ground, or none. A wash, never a fill, so a card's text reads in either appearance.
    /// White and off-white are paper instead: the card solid, and drawn as in light mode, dark
    /// text and all, in dark mode too ("add a white or off white card color option"); black and
    /// grey the same the other way, drawn as in dark mode ("add black and grey … as well").
    enum CardColor: String, CaseIterable, Identifiable {
        case plain, white, offWhite, codeBlue, grey, black, accent, bubbles, yellow, orange, pink, purple, blue, teal, green
        var id: String { rawValue }
        static let offWhitePaper = Color(red: 0.973, green: 0.957, blue: 0.918)
        static let greyCard = Color(red: 0.227, green: 0.227, blue: 0.235)
        static let blackCard = Color(red: 0.055, green: 0.055, blue: 0.06)
        /// The Code theme's pale sky (#CBF0FF), solid, as its bubbles are in dark mode (asked 2026-11-02).
        static let codeBlueCard = Color(red: ThemeColors.RGB.codeBlue.red, green: ThemeColors.RGB.codeBlue.green, blue: ThemeColors.RGB.codeBlue.blue)
        /// A solid card, and the appearance its contents are drawn in; nil for a wash.
        var solid: ColorScheme? {
            switch self {
            case .white, .offWhite, .codeBlue: .light
            case .grey, .black: .dark
            default: nil
            }
        }
        func color(in theme: ResolvedTheme) -> Color? {
            switch self {
            case .plain: nil
            case .white: .white
            case .offWhite: Self.offWhitePaper
            case .codeBlue: Self.codeBlueCard
            case .grey: Self.greyCard
            case .black: Self.blackCard
            case .accent: theme.accent
            case .bubbles: theme.userBubble
            case .yellow: .yellow
            case .orange: .orange
            case .pink: .pink
            case .purple: .purple
            case .blue: .blue
            case .teal: .teal
            case .green: .green
            }
        }
        var label: String {
            switch self {
            case .plain: String(localized: "Plain", comment: "Cards setting: answer cards without a colour")
            case .white: String(localized: "White", comment: "Cards setting: answer cards solid white, with dark text")
            case .offWhite: String(localized: "Off-White", comment: "Cards setting: answer cards a warm off-white, like paper, with dark text")
            case .codeBlue: String(localized: "Code Blue")
            case .grey: String(localized: "Graphite", comment: "Cards setting: answer cards solid dark grey, with light text")
            case .black: String(localized: "Black", comment: "Cards setting: answer cards solid black, with light text")
            case .accent: String(localized: "Accent", comment: "Cards setting: answer cards in the theme's accent colour")
            case .bubbles: String(localized: "Like Your Bubbles", comment: "Cards setting: answer cards in the colour of the person's message bubbles")
            case .yellow: String(localized: "Yellow")
            case .orange: String(localized: "Orange")
            case .pink: String(localized: "Pink")
            case .purple: String(localized: "Purple")
            case .blue: String(localized: "Blue")
            case .teal: String(localized: "Teal")
            case .green: String(localized: "Green")
            }
        }
    }

    /// Settings → Appearance → Today Tiles (asked 2026-11-11: "allow me the option to change the
    /// color of the Today tabs in the drawer"): the chat list's Today tiles on the theme's surface,
    /// each washed in its own kind's colour (the inbox the accent, a list green, a briefing
    /// yellow, a goal its bot's), or all in one of the cards' colours, solid ones solid.
    enum TodayColor: Hashable, Identifiable, RawRepresentable {
        case plain, byKind
        case color(CardColor)
        static var allCases: [TodayColor] { [.plain, .byKind] + CardColor.allCases.filter { $0 != .plain }.map(TodayColor.color) }
        init?(rawValue: String) {
            switch rawValue {
            case "plain", "": self = .plain
            case "byKind": self = .byKind
            default:
                guard let color = CardColor(rawValue: rawValue), color != .plain else { return nil }
                self = .color(color)
            }
        }
        var rawValue: String {
            switch self {
            case .plain: "plain"
            case .byKind: "byKind"
            case let .color(color): color.rawValue
            }
        }
        var id: String { rawValue }
        var label: String {
            switch self {
            case .plain: CardColor.plain.label
            case .byKind: String(localized: "By Kind", comment: "Today Tiles setting: each tile in its own kind's colour (the inbox, a list, a briefing, a goal)")
            case let .color(color): color.label
            }
        }
    }

    /// The colour a Today tile is drawn in.
    func todayColor(forTile key: String) -> TodayColor {
        todayTileColors[key].flatMap(TodayColor.init(rawValue:)) ?? todayColor
    }

    /// The appearance a card is drawn in, nil for the app's.
    var cardScheme: ColorScheme? { cardColor.solid ?? cardAppearance.colorScheme }

    /// What the app renders in: the appearance choice, nil meaning follow the system.
    /// A wallpaper picked for the theme decides light or dark itself (`Theme.Palette.scheme`).
    var effectiveColorScheme: ColorScheme? { resolvedTheme.palette.scheme ?? appearance.colorScheme }

    static let chatTextSizes = -2 ... 2

    nonisolated static let defaultContextWindow = 131_072
    nonisolated static let defaultKokoroURL = ""
    nonisolated static let defaultKokoroVoice = "am_onyx(2)+bm_george(1)"
    nonisolated static let defaultSpeechModel = "kokoro"

    var speechModelOrDefault: String {
        let typed = speechModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? Self.defaultSpeechModel : typed
    }

    var kokoroBaseURL: URL? {
        let raw = kokoroURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw.hasSuffix("/") ? String(raw.dropLast()) : raw)
    }
}

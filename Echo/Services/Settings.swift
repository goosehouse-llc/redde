import Foundation
import SwiftUI
import Observation

/// Non-secret configuration. The API key is *never* here — see `Keychain`.
@Observable
final class Settings: ServeEndpoint {
    static let shared: Settings = {
        let settings = Settings()
        settings.moveLegacySecretsToActiveServer()
        settings.isShared = true
        VoiceWords.listen(in: settings.speechLocale)
        return settings
    }()

    /// The app's own settings, not a test's: they say what language voice words are heard in.
    @ObservationIgnored private var isShared = false

    // Shipped defaults are empty: the app is configured on first run. Personal builds can drop a
    // git-ignored Echo/Resources/LocalDefaults.json into the bundle to prefill (see README).
    nonisolated static let defaultGatewayURL = ""
    nonisolated static let defaultFastLaneURL = ""
    nonisolated static let defaultFastLaneModel = ""

    var transport: Transport {
        didSet { store(transport.rawValue, forKey: Keys.transport); syncActiveServer() }
    }
    var gatewayURL: String {
        didSet { store(gatewayURL, forKey: Keys.gatewayURL); syncActiveServer() }
    }
    var fastLaneURL: String {
        didSet { store(fastLaneURL, forKey: Keys.fastLaneURL) }
    }
    var fastLaneModel: String {
        didSet { store(fastLaneModel, forKey: Keys.fastLaneModel) }
    }
    /// Redde's one model for every Hermes conversation, before picks were each conversation's own
    /// (GitHub issue 58, 2026-11). No longer read: kept so a server saved by an older Redde (on
    /// another device, through iCloud) comes and goes whole.
    var gatewayModel: String {
        didSet { store(gatewayModel, forKey: Keys.gatewayModel); syncActiveServer() }
    }
    /// The provider that went with `gatewayModel`. No longer read.
    var gatewayProvider: String {
        didSet { store(gatewayProvider, forKey: Keys.gatewayProvider); syncActiveServer() }
    }

    /// Ask the agent to answer in this language (an ISO code). Empty = Automatic.
    var replyLanguage: String {
        didSet { store(replyLanguage, forKey: Keys.replyLanguage) }
    }
    /// US or metric (`MeasureUnits`): Automatic follows the region. The plugin is told at once, for
    /// the weather it looks up.
    var measureUnits: MeasureUnits {
        didSet {
            store(measureUnits.rawValue, forKey: Keys.measureUnits)
            if self === Settings.shared, oldValue != measureUnits { Task { await ReplyCardsSwitch.publish() } }
        }
    }

    /// "" (gateway default) or one of `reasoningEfforts`.
    var reasoningEffort: String {
        didSet { store(reasoningEffort, forKey: Keys.reasoningEffort) }
    }
    /// Start listening every time the app comes to the foreground. Makes the built-in
    /// "Hey Siri, open Redde" behave like the App Shortcut.
    var listenOnOpen: Bool {
        didSet { store(listenOnOpen, forKey: Keys.listenOnOpen) }
    }
    /// Listen for wake phrases while Redde is open (`WakeListener`). This device's own, off until
    /// turned on: it keeps the microphone open.
    var wakeListening: Bool {
        didSet { store(wakeListening, forKey: Keys.wakeListening) }
    }
    /// Voice mode opens with Hands-free switched on. Requests that ask for a mode themselves (the
    /// hands-free button, Siri, the controls) keep theirs.
    var handsFreeByDefault: Bool {
        didSet { store(handsFreeByDefault, forKey: Keys.handsFreeByDefault) }
    }
    /// Whether a spoken reply can be interrupted by talking over it (`VoiceSession`). With
    /// headphones nothing of the reply reaches the microphone, so that is on from the start. On
    /// the phone's speaker the echo has to be cancelled for as long as Redde speaks, which plays
    /// the reply at call volume: that is a choice.
    enum TalkOver: String, CaseIterable, Sendable { case off, headphones, everywhere }
    var talkOver: TalkOver {
        didSet { store(talkOver.rawValue, forKey: Keys.talkOver) }
    }
    /// What it takes to interrupt a reply that can be talked over: anything said, or the word
    /// "stop" alone. With the second, whatever else is said near the microphone, a room full of
    /// people included, the reply goes on.
    enum Interruption: String, CaseIterable, Sendable { case speech, stopWord }
    var interruption: Interruption {
        didSet { store(interruption.rawValue, forKey: Keys.interruption) }
    }
    /// In the car, while Redde speaks: "stop" ends the reply, "skip" jumps to its end. Only those
    /// two words, whatever `talkOver` and `interruption` say. Off until turned on: a car's
    /// speakers sit near its microphone.
    var stopAndSkipInCar: Bool {
        didSet { store(stopAndSkipInCar, forKey: Keys.stopAndSkipInCar) }
    }
    /// The person's own ways of saying "that's all" in voice mode, heard beside the built-in
    /// English ones (`StopPhrase`): another language's, or a word of the household's. They also
    /// stop a reply where only "stop" does.
    var stopPhrases: [String] {
        didSet { store(stopPhrases, forKey: Keys.stopPhrases) }
    }
    /// In voice mode a command that waits for approval, or a question from the agent, is read
    /// out and answered by voice (`SpokenRequest`). Off until asked for: whoever is in earshot
    /// can answer, and what the agent wants to run is said aloud.
    var answerRequestsByVoice: Bool {
        didSet { store(answerRequestsByVoice, forKey: Keys.answerRequestsByVoice) }
    }
    /// A question asked by voice in a car asks the agent for a short answer (`CarBrevity`). Off
    /// until asked for: on the Dashboard connection the request is a line added to the message,
    /// which other clients of the same server show.
    var shortAnswersInCar: Bool {
        didSet { store(shortAnswersInCar, forKey: Keys.shortAnswersInCar) }
    }
    /// Voice mode fills the silence while the agent works with a quiet sound
    /// (`ThinkingSoundPlayer`): never, only with a car connected, or always. Off until chosen.
    enum ThinkingSound: String, CaseIterable, Sendable { case off, car, always }
    var thinkingSound: ThinkingSound {
        didSet { store(thinkingSound.rawValue, forKey: Keys.thinkingSound) }
    }
    /// Who holds a voice conversation: Redde (the phone hears, the agent answers, a voice reads
    /// it), or a live voice model (GPT-Live, Gemini Live, Grok Voice: `LiveEngine`), which talks
    /// and listens at once and hands the real work to the agent (`LiveVoice`). Redde until chosen:
    /// a live call sends the microphone to its company and costs money by the minute.
    enum VoiceEngine: String, CaseIterable, Sendable {
        case redde, gptLive, gemini, grok, elevenLabs, local
        var live: LiveEngine? { LiveEngine(rawValue: rawValue) }
    }
    var voiceEngine: VoiceEngine {
        didSet { store(voiceEngine.rawValue, forKey: Keys.voiceEngine) }
    }
    /// GPT-Live's voice when Redde sets the call up with its own OpenAI key.
    var liveVoice: String {
        didSet { store(liveVoice, forKey: Keys.liveVoice) }
    }
    /// The other live engines' voices, by `LiveEngine` raw value.
    var liveVoices: [String: String] {
        didSet { store(liveVoices, forKey: Keys.liveVoices) }
    }
    /// Minutes of quiet after which a GPT-Live call hangs up by itself: OpenAI bills every minute
    /// it is open, silent ones too. 0: only when ended.
    var liveHangUp: Int {
        didSet { store(liveHangUp, forKey: Keys.liveHangUp) }
    }
    /// A live call goes on with the phone locked, hands-free or not (asked 2026-10-26). Off, as
    /// before: locking the phone hangs a call up unless it is hands-free or on the car's screen,
    /// as it closes Redde's own microphone.
    var liveWhenLocked: Bool {
        didSet { store(liveWhenLocked, forKey: Keys.liveWhenLocked) }
    }
    /// A group chat's voice is a live call too, in the engine of Settings → Voice → Voice mode: it
    /// hands what the person says to the room and says each bot's reply in that bot's live voice
    /// (`LiveRoom`; asked 2026-10-26). Off: Redde's own voice, each bot read in its reading voice.
    var liveGroupCalls: Bool {
        didSet { store(liveGroupCalls, forKey: Keys.liveGroupCalls) }
    }
    /// With that on, a nod of the head approves and a shake denies, with AirPods that sense
    /// movement (`HeadGestures`). Off until asked for: iOS has to be asked for Motion & Fitness.
    var answerRequestsByNod: Bool {
        didSet { store(answerRequestsByNod, forKey: Keys.answerRequestsByNod) }
    }
    /// Coming into voice mode from outside the chat (Siri, the Action button, a control, opening
    /// Redde) starts a new conversation, unless the current one is empty or busy. The Talk button
    /// in a chat carries that chat on.
    var newConversationForVoice: Bool {
        didSet { store(newConversationForVoice, forKey: Keys.newConversationForVoice) }
    }
    /// What Redde shows when it starts: the last conversation, the conversation list (iPhone's
    /// panel, open on its last tab), or the voice screen (listening only with `listenOnOpen`).
    enum LaunchScreen: String, CaseIterable, Sendable { case conversation, conversations, voice }
    var launchScreen: LaunchScreen {
        didSet { store(launchScreen.rawValue, forKey: Keys.launchScreen) }
    }
    var replyVoice: ReplyVoice {
        didSet { store(replyVoice.rawValue, forKey: Keys.replyVoice) }
    }
    var kokoroURL: String {
        didSet { store(kokoroURL, forKey: Keys.kokoroURL) }
    }
    /// Spoken-reply speed multiplier — Kokoro's `speed` field, and the fallback
    /// synthesizer's rate scaled around the system default.
    var voiceSpeed: Double {
        didSet { store(voiceSpeed, forKey: Keys.voiceSpeed) }
    }
    var kokoroVoice: String {
        didSet { store(kokoroVoice, forKey: Keys.kokoroVoice) }
    }
    /// The `model` the speech server is asked for: Kokoro-FastAPI's "kokoro" unless another
    /// server that answers OpenAI's /v1/audio/speech wants its own ("tts-1", "piper"…). Empty,
    /// "kokoro" (`speechModelOrDefault`).
    var speechModel: String {
        didSet { store(speechModel, forKey: Keys.speechModel) }
    }
    /// The ElevenLabs voice replies are read in (a voice id of the person's account); empty, the
    /// account's first voice.
    var elevenLabsVoice: String {
        didSet { store(elevenLabsVoice, forKey: Keys.elevenLabsVoice) }
    }
    /// The language Redde listens for, as a locale id ("es-MX"). Empty = the iPhone's language.
    var speechLanguage: String {
        didSet {
            store(speechLanguage, forKey: Keys.speechLanguage)
            if isShared { VoiceWords.listen(in: speechLocale) }
        }
    }
    /// Read each reply with a voice for the language it's written in, not only `speechLanguage`.
    var matchReplyLanguage: Bool {
        didSet { store(matchReplyLanguage, forKey: Keys.matchReplyLanguage) }
    }
    /// Spoken prefixes: a leading word in a voice or Siri message ("Claude, …") becomes a text
    /// prefix ("C ") before sending. Empty by default, and typed text is never touched.
    var spokenPrefixes: [SpokenPrefix] {
        didSet { store(try? JSONEncoder().encode(spokenPrefixes), forKey: Keys.spokenPrefixes) }
    }
    /// The Bots section's rows in the order the person put them, per server (its id): `BotListItem`
    /// ids. Empty for a server: the main bot first, then the most recently talked to.
    var botOrder: [String: [String]] {
        didSet { store(try? JSONEncoder().encode(botOrder), forKey: Keys.botOrder) }
    }
    /// The Bots section's sections, per server (its id): their order, and the memberships kept on
    /// the phone (`BotSectionsHere`); a Dashboard bot's own is on the server.
    var botSections: [String: BotSectionsHere] {
        didSet { store(try? JSONEncoder().encode(botSections), forKey: Keys.botSections) }
    }
    /// Bots added on this phone for the Hermes API alone, per server (its id): where there is no
    /// Dashboard login to list the server's, each by its profile and that profile's own API key
    /// (`Keychain.profileAccount`).
    var apiBots: [String: [APIBot]] {
        didSet { store(try? JSONEncoder().encode(apiBots), forKey: Keys.apiBots) }
    }
    /// The voices picked for bots, per server (its id), then bot (its profile). A bot with none
    /// picked reads in one of its own (`BotVoices`).
    var botVoices: [String: [String: BotVoice]] {
        didSet { store(try? JSONEncoder().encode(botVoices), forKey: Keys.botVoices) }
    }
    /// Models pinned at the top of the model picker (asked 2026-11-07), per server (its host, see
    /// `pinnedModelsKey`; `fastLane` for the fast lane's). Synced.
    var pinnedModels: [String: [ModelChoice]] {
        didSet { store(try? JSONEncoder().encode(pinnedModels), forKey: Keys.pinnedModels) }
    }
    /// Bots and group chats muted, per server (its id), then `BotListItem` id: until when
    /// (`Date.distantFuture`: until turned back on). See `Mutes`.
    var mutes: [String: [String: Date]] {
        didSet { store(try? JSONEncoder().encode(mutes), forKey: Keys.mutes) }
    }
    /// Calls from agents (`AgentCalls`): an agent this phone lets call it rings it, like a phone
    /// call, when it has something that shouldn't wait. Off until turned on here. This phone's
    /// alone (it registers for calls itself): not synced.
    var agentCalls: Bool {
        didSet { store(agentCalls, forKey: Keys.agentCalls) }
    }
    /// A call answered on a locked iPhone listens straight away. Off: the agent's line is said, then
    /// the microphone waits until the iPhone is unlocked, so whoever picks it up can't talk with
    /// the agent (asked 2026-10-26). Redde's own lock always waits. Not synced, as `agentCalls`.
    var callsWhileLocked: Bool {
        didSet { store(callsWhileLocked, forKey: Keys.callsWhileLocked) }
    }
    /// The agents that may call, per server (its id): "default" for the main agent, else the bot's
    /// profile. Not synced, as `agentCalls`.
    var callers: [String: [String]] {
        didSet { store(try? JSONEncoder().encode(callers), forKey: Keys.callers) }
    }
    /// Wake phrases, per server (its id), then agent: "default" for the main agent, else the
    /// bot's profile. None set for an agent: `Settings.wakePhrase(for:)`.
    var wakePhrases: [String: [String: WakePhrase]] {
        didSet { store(try? JSONEncoder().encode(wakePhrases), forKey: Keys.wakePhrases) }
    }
    var theme: Theme {
        didSet { store(theme.rawValue, forKey: Keys.theme) }
    }
    /// Your accent and bubble colors, per theme (keyed by `Theme.rawValue`). A theme with no
    /// entry uses its own colors, so switching themes never carries one theme's picks to another.
    var themeColors: [String: ThemeColors] {
        didSet { store(try? JSONEncoder().encode(themeColors), forKey: Keys.themeColors) }
    }
    /// Settings → Appearance → Font (asked 2026-11-02): the face of replies and your messages,
    /// or the theme's own. Code blocks and the app's chrome keep theirs.
    var chatFont: ChatFont {
        didSet { store(chatFont.rawValue, forKey: Keys.chatFont) }
    }
    var appearance: Appearance {
        didSet { store(appearance.rawValue, forKey: Keys.appearance) }
    }
    var eventColor: EventColor {
        didSet { store(eventColor.rawValue, forKey: Keys.eventColor) }
    }
    var cardColor: CardColor {
        didSet { store(cardColor.rawValue, forKey: Keys.cardColor) }
    }
    var todayColor: TodayColor {
        didSet { store(todayColor.rawValue, forKey: Keys.todayColor) }
    }
    /// One tile's own colour, picked on its hold menu (asked 2026-11-11), by the tile's key
    /// (`TodayStrip`'s "inbox", "list:<id>", "brief:<job>", "goal:<id>"): a `TodayColor` raw
    /// value; a tile not in it follows `todayColor`.
    var todayTileColors: [String: String] {
        didSet { store(todayTileColors, forKey: Keys.todayTileColors) }
    }
    /// How each list is drawn, by the list's id: a `FilmLayout` raw value for a watch list, a
    /// `TodoLayout` one for a to-do list; a list not in it has its kind's default. A goal's page
    /// is here too, under `goalKey(_:)`, as a `GoalLayout`.
    var listLayouts: [String: String] {
        didSet { store(listLayouts, forKey: Keys.listLayouts) }
    }
    /// The Today tiles' order as the person arranged it (asked 2026-11-12), by tile key. A tile
    /// not in it comes after those that are, in the strip's own order. Empty: the strip's order.
    var todayTileOrder: [String] {
        didSet { store(todayTileOrder, forKey: Keys.todayTileOrder) }
    }
    /// The Up Next tile: the next event on this device's calendars (asked 2026-11-12, "if
    /// wanted"). Off until it's turned on.
    var todayUpNext: Bool {
        didSet { store(todayUpNext, forKey: Keys.todayUpNext) }
    }
    /// Settings → Appearance → Card Appearance (asked 2026-11-06: "Allow for light dark selection
    /// on calendar and other cards"): cards drawn light or dark whatever the app is, or as it is.
    /// A solid card colour (white, black) keeps its own.
    var cardAppearance: Appearance {
        didSet { store(cardAppearance.rawValue, forKey: Keys.cardAppearance) }
    }
    /// Settings → Agent → Calendars (`CalendarChoice`, asked 2026-10-30): the calendars the agent
    /// looks at and agenda cards show, by title; empty for all of them.
    var agendaCalendars: [String] {
        didSet { store(agendaCalendars, forKey: Keys.agendaCalendars) }
    }
    /// Settings → Agent → Calendars → New Events (asked 2026-11-12): the calendar, by title, that
    /// an event the agent adds goes to when it names none; empty for the Calendar app's default.
    var newEventsCalendar: String {
        didSet { store(newEventsCalendar, forKey: Keys.newEventsCalendar) }
    }
    /// Settings → Agent → Current Location (`CurrentLocation`, asked 2026-10-30): the agent hears
    /// roughly where this device is with a question about places, directions or the weather. Off
    /// until turned on; this device's alone, as its permission is: not synced.
    var currentLocation: Bool {
        didSet {
            store(currentLocation, forKey: Keys.currentLocation)
            if !currentLocation, self === Settings.shared { CurrentLocation.forget() }   // nothing kept while off
        }
    }
    /// Settings → Agent → Leave-By Alerts (`LeaveBy`, asked 2026-10-30): a notification when it is
    /// time to leave for an event at a street address, worked out on this device. Off until
    /// turned on; this device's alone, as its permissions are: not synced.
    var leaveByAlerts: Bool {
        didSet {
            store(leaveByAlerts, forKey: Keys.leaveByAlerts)
            // Off (here or by a reset): no alert is left to go off.
            if oldValue, !leaveByAlerts, self === Settings.shared { Task { await LeaveByAlerts.shared.turned(on: false) } }
        }
    }
    /// The orb at the centre of voice mode.
    var voiceOrb: VoiceOrb {
        didSet { store(voiceOrb.rawValue, forKey: Keys.voiceOrb) }
    }
    /// What moves inside the orb's face in voice mode.
    var orbLight: OrbLight {
        didSet { store(orbLight.rawValue, forKey: Keys.orbLight) }
    }
    /// How CarPlay's Ask tab draws its three cards.
    var carPlayCards: CarPlayCardLook {
        didSet { store(carPlayCards.rawValue, forKey: Keys.carPlayCards) }
    }
    /// How CarPlay's voice screen shows Redde listening, thinking and speaking.
    var carPlayVoice: CarPlayVoiceLook {
        didSet { store(carPlayVoice.rawValue, forKey: Keys.carPlayVoice) }
    }
    /// How CarPlay's Bots tab draws its bots' cards.
    var carPlayBots: CarPlayBotLook {
        didSet { store(carPlayBots.rawValue, forKey: Keys.carPlayBots) }
    }
    /// The CarPlay tab last picked ("ask", "chats", "bots"), which the car opens on next time.
    /// This phone's alone: not synced.
    var carPlayTab: String {
        didSet { store(carPlayTab, forKey: Keys.carPlayTab) }
    }
    /// Settings → Phone tools: which of the phone's own things the agent may use (`DeviceTool`).
    /// Everything off until turned on.
    var phoneTools: PhoneToolsSettings {
        didSet { if phoneTools != oldValue { store(try? JSONEncoder().encode(phoneTools), forKey: Keys.phoneTools) } }
    }
    /// Local notifications for approvals / replies / failures while the app is in the background.
    var notifyInBackground: Bool {
        didSet { store(notifyInBackground, forKey: Keys.notifyInBackground) }
    }
    /// Dynamic Island / Lock Screen activity while a turn runs.
    var showLiveActivity: Bool {
        didSet { store(showLiveActivity, forKey: Keys.showLiveActivity) }
    }
    /// iOS's own "<agent> is working" card (`BGContinuedProcessingTask`), which keeps a reply
    /// streaming while Redde is in the background. Off (2026-11-01, "I can't get rid of that"): the
    /// reply still finishes on the server and comes as a notification; it isn't streamed meanwhile.
    var keepRepliesInBackground: Bool {
        didSet { store(keepRepliesInBackground, forKey: Keys.keepRepliesInBackground) }
    }
    /// Other agents ask each other by @name (2.7): bridge agents (Claude Code, Codex…) and other
    /// servers' bots, asked by the chat's agent or asking it. The chat's agent is told who it can
    /// ask, and a line of its reply that begins with one's @name is passed on (`relayTags`). On at
    /// first. Off, only the person's tags ask them.
    var agentsAskEachOther: Bool {
        didSet { store(agentsAskEachOther, forKey: Keys.agentsAskEachOther) }
    }
    /// The open Hermes's own bots message each other (11-17, his ask): in Hermes itself (each
    /// profile's `agent.bot_mode_protocol`, `HermesServeClient.setBotsMessageEachOther`) and when
    /// one's reply here tags another. Off, the person's tags of them are Redde's to ask, in a
    /// bot's chat too. On at first, as Hermes has it.
    var hermesBotsTalk: Bool {
        didSet { store(hermesBotsTalk, forKey: Keys.hermesBotsTalk) }
    }
    /// An agent's tag of another waits for the person's OK (11-17, his ask: "ask by default"):
    /// an approval card in the chat, read aloud in voice mode. On at first. Hermes's own messages
    /// between its bots don't pass through Redde, and can't wait on it.
    var askBeforeAgentsAsk: Bool {
        didSet {
            store(askBeforeAgentsAsk, forKey: Keys.askBeforeAgentsAsk)
            if self === Settings.shared, oldValue != askBeforeAgentsAsk { Task { await AgentAsksSwitch.publish() } }
        }
    }
    /// Three suggested replies under each reply (`FollowUps`): written by Apple's on-device model,
    /// else the OpenAI-compatible one. On at first (2026-11-11): nothing shows where neither can.
    var suggestFollowUps: Bool {
        didSet { store(suggestFollowUps, forKey: Keys.suggestFollowUps) }
    }
    /// Suggested replies written by the fast lane's model even where Apple's on-device one could
    /// write them: a bigger model, but the chat leaves the phone to be read. Off at first.
    var suggestionsFromFastLane: Bool {
        didSet { store(suggestionsFromFastLane, forKey: Keys.suggestionsFromFastLane) }
    }
    /// Route replies to the earpiece when the proximity sensor says the phone is at your ear.
    /// Redde's background alerts are time-sensitive, so Siri can read them on AirPods (Announce
    /// Notifications) and they can break through a Focus.
    var announceOnAirPods: Bool {
        didSet { store(announceOnAirPods, forKey: Keys.announceOnAirPods) }
    }
    /// A briefing's notification opens the session its run was in, to ask on in it, not the
    /// briefing's card (GitHub issue 62). Off: the card, as before. Needs plugin 1.21.1, which
    /// says which session that was.
    var briefingTapsOpenRun: Bool {
        didSet { store(briefingTapsOpenRun, forKey: Keys.briefingTapsOpenRun) }
    }
    /// Return in the composer sends the message; off, it starts a new line, and the Send button
    /// (or ⌘Return) sends. With it on, Shift-Return on a keyboard starts the new line.
    var returnSends: Bool {
        didSet { store(returnSends, forKey: Keys.returnSends) }
    }
    /// Settings → Appearance → Bot colors: a bot's chat takes its face's colour for your bubbles
    /// and the accent (`BotFace.chatColors`), and so does Redde's when its face has a colour of its
    /// own. Group chats keep the theme's colours. Asked 2026-10-21; on unless turned off.
    var botColors: Bool {
        didSet { store(botColors, forKey: Keys.botColors) }
    }
    /// A card with the page's title and picture under a message with a web link
    /// (`LinkPreviews`). Off until turned on: the phone opens the page itself, so the site sees
    /// the visit, where Redde otherwise only ever talks to the servers it is set up with.
    var linkPreviews: Bool {
        didSet { store(linkPreviews, forKey: Keys.linkPreviews) }
    }
    /// A map under a reply or a briefing that names a street address (`AddressMaps`, asked
    /// 2026-10-29: "I want maps to be included in messages with addresses"). On unless turned off;
    /// the address goes to Apple's maps to be found, as any map card's does.
    var addressMaps: Bool {
        didSet { store(addressMaps, forKey: Keys.addressMaps) }
    }
    /// Settings → Appearance → Bot faces: off, every bot (Redde too) is drawn as a circle in its
    /// colour with its initial instead of a creature, and voice mode shows the voice orb (the
    /// Bubble one in place of Redde's face). The faces stay on the server. Asked 2026-10-21, for
    /// people who'd rather not have faces; on unless turned off.
    var botFaces: Bool {
        didSet {
            store(botFaces, forKey: Keys.botFaces)
            if self === Settings.shared { WatchLink.shared.botsChanged() }   // the watch's bot pictures
        }
    }
    /// Settings → Agent → Cards in replies: the agent is offered Redde's `redde_show` (a map,
    /// places, the weather under a reply; his ask 2026-10-22). On unless turned off: off, the
    /// plugin stops offering it, and its description leaves every prompt (`ReplyCardsSwitch`).
    var replyCards: Bool {
        didSet {
            store(replyCards, forKey: Keys.replyCards)
            if self === Settings.shared, oldValue != replyCards { Task { await ReplyCardsSwitch.publish() } }
        }
    }
    /// Settings → Appearance → Pictures from Hermes: a bot with a picture set in Hermes Desktop is
    /// drawn as that picture (`BotPictures`). Asked on Reddit 2026-10-22; on unless turned off.
    var botPictures: Bool {
        didSet {
            store(botPictures, forKey: Keys.botPictures)
            if self === Settings.shared { WatchLink.shared.botsChanged() }
        }
    }
    /// How much larger or smaller than the iPhone's own text size the conversation is set, in
    /// steps of that scale: `chatTextSizes`. Zero follows the system.
    var chatTextSize: Int {
        didSet { store(chatTextSize, forKey: Keys.chatTextSize) }
    }
    /// Whether Redde's notifications make a sound. Kept in the app group as well: the
    /// notification extension decides for the ones a paired Hermes sends (`NotificationSound`).
    var notificationSound: Bool {
        didSet {
            store(notificationSound, forKey: Keys.notificationSound)
            if self === Settings.shared { NotificationSound.isOn = notificationSound }
        }
    }
    var earpieceAtEar: Bool {
        didSet { store(earpieceAtEar, forKey: Keys.earpieceAtEar) }
    }
    /// Face ID / Touch ID / passcode gate on the app. Kept in the app group as well: the status
    /// widgets leave out a command, a question and a title while it is on (`NeedsYou.hidesWords`).
    var requireBiometrics: Bool {
        didSet {
            store(requireBiometrics, forKey: Keys.requireBiometrics)
            if self === Settings.shared {
                SiriHooks.indexInputsChanged()   // App Lock indexes titles only
                StatusWidgets.lockChanged(requireBiometrics)
            }
        }
    }
    /// Siri AI (iOS 27) may send messages to Redde and see its conversations. Off by default:
    /// Apple Intelligence then reads what you say to Siri, the one path that leaves the tailnet.
    var siriAIEnabled: Bool {
        didSet {
            store(siriAIEnabled, forKey: Keys.siriAIEnabled)
            if self === Settings.shared, oldValue != siriAIEnabled { SiriHooks.accessChanged(siriAIEnabled) }
        }
    }
    /// A message Siri drafts for Redde waits in a new conversation's composer, not the open
    /// one's (GitHub issue 21). Unless the open one is empty anyway.
    var siriDraftsInNewConversation: Bool {
        didSet { store(siriDraftsInNewConversation, forKey: Keys.siriDraftsInNewConversation) }
    }
    /// The chat list shows the server's bots (Hermes's Bot Mode, on the Dashboard), once it has
    /// any besides the main profile. Off, Redde is as it was without them.
    var showBots: Bool {
        didSet { store(showBots, forKey: Keys.showBots) }
    }
    /// The chat list shows the Dashboard's projects above the conversations. Off, their
    /// conversations are still in the list; only the section goes (GitHub issue 32).
    var projectsInChatList: Bool {
        didSet { store(projectsInChatList, forKey: Keys.projectsInChatList) }
    }
    /// Settings › Alerts When Redde Is Closed › Only Where You Are (`WhereYouAre`): a device in
    /// use tells the paired Hermes so, and its notes go there alone. On unless turned off.
    var notifyWhereYouAre: Bool {
        didSet { store(notifyWhereYouAre, forKey: Keys.notifyWhereYouAre) }
    }
    /// The cards left off the top of the chat list (`ChatListCard` raw values; 2.4 tidy,
    /// 2026-11-05): empty, all of them show.
    var hiddenChatListCards: [String] {
        didSet { store(hiddenChatListCards, forKey: Keys.hiddenChatListCards) }
    }
    /// How long the app may be in the background before it locks again.
    var lockGraceSeconds: Double {
        didSet { store(lockGraceSeconds, forKey: Keys.lockGraceSeconds) }
    }
    /// What the header calls the assistant. Empty means "Redde".
    var displayName: String {
        didSet {
            store(displayName, forKey: Keys.displayName)
            noteMainAgentName()
        }
    }
    /// What each ACP agent calls itself, by its address, as last heard when connecting. On this
    /// device only.
    var acpAgentNames: [String: String] = UserDefaults.standard.dictionary(forKey: "acpAgentNames") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(acpAgentNames, forKey: "acpAgentNames") }
    }

    // hermes serve (desktop gateway). Password lives in the Keychain.
    var serveURL: String {
        didSet { store(serveURL, forKey: Keys.serveURL); syncActiveServer() }
    }
    var serveUsername: String {
        didSet { store(serveUsername, forKey: Keys.serveUsername); syncActiveServer() }
    }
    /// The active server's Dashboard has no sign-in and is used that way (`HermesServer.serveOpenAccess`).
    var serveOpenAccess: Bool {
        didSet { store(serveOpenAccess, forKey: Keys.serveOpenAccess); syncActiveServer() }
    }
    /// An ACP agent's address (`Transport.acp`): the Redde bridge's, or a server that speaks ACP
    /// itself. Its token lives in the Keychain (`Keychain.Item.acpToken`).
    var acpURL: String {
        didSet { store(acpURL, forKey: Keys.acpURL); syncActiveServer() }
    }
    /// Which of the bridge's agents (its id in the bridge's config); empty, the bridge's first.
    var acpAgent: String {
        didSet { store(acpAgent, forKey: Keys.acpAgent); syncActiveServer() }
    }
    /// The folder on the host new chats with the agent work in; empty leaves it to the bridge.
    var acpFolder: String {
        didSet { store(acpFolder, forKey: Keys.acpFolder); syncActiveServer() }
    }
    /// Every agent on the bridge in one chat list; `acpAgent` follows the open chat.
    var acpAllAgents: Bool {
        didSet { store(acpAllAgents, forKey: Keys.acpAllAgents); syncActiveServer() }
    }
    /// The Hermes profile Redde talks to; empty means the server's default profile. Nothing
    /// profile-related is sent for the default, so servers without profile support keep working.
    var hermesProfile: String {
        didSet { store(hermesProfile, forKey: Keys.hermesProfile); syncActiveServer() }
    }
    /// That profile's home directory on the server (from the dashboard's profile list), where
    /// its context and memory files live. Empty: the default `~/.hermes`.
    var hermesProfileHome: String {
        didSet { store(hermesProfileHome, forKey: Keys.hermesProfileHome); syncActiveServer() }
    }

    /// Cloudflare Access service-token id (`CF-Access-Client-Id`); the secret lives in the Keychain.
    var cfAccessClientID: String {
        didSet { store(cfAccessClientID, forKey: Keys.cfAccessClientID); syncActiveServer() }
    }

    /// Fallback when the backend doesn't report its window (the gateway doesn't). 131072 suits most local models.
    var contextWindow: Int {
        didSet { store(contextWindow, forKey: Keys.contextWindow) }
    }

    /// Push relay (companion/push-relay): hermes webhooks become APNs alerts. Empty = off.
    var pushRelayURL: String {
        didSet { store(pushRelayURL, forKey: Keys.pushRelayURL) }
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        transport = Transport(rawValue: defaults.string(forKey: Keys.transport) ?? "") ?? .hermesSessions
        gatewayURL = defaults.string(forKey: Keys.gatewayURL) ?? Self.defaultGatewayURL
        fastLaneURL = defaults.string(forKey: Keys.fastLaneURL) ?? Self.defaultFastLaneURL
        fastLaneModel = defaults.string(forKey: Keys.fastLaneModel) ?? Self.defaultFastLaneModel
        gatewayModel = defaults.string(forKey: Keys.gatewayModel) ?? ""
        pushRelayURL = defaults.string(forKey: Keys.pushRelayURL) ?? ""
        gatewayProvider = defaults.string(forKey: Keys.gatewayProvider) ?? ""
        reasoningEffort = defaults.string(forKey: Keys.reasoningEffort) ?? Self.defaultReasoningEffort
        replyLanguage = defaults.string(forKey: Keys.replyLanguage) ?? ""
        measureUnits = MeasureUnits(rawValue: defaults.string(forKey: Keys.measureUnits) ?? "") ?? .automatic
        listenOnOpen = defaults.bool(forKey: Keys.listenOnOpen)
        wakeListening = defaults.bool(forKey: Keys.wakeListening)
        launchScreen = defaults.string(forKey: Keys.launchScreen).flatMap(LaunchScreen.init(rawValue:))
            ?? (defaults.bool(forKey: Keys.openToVoiceScreen) ? .voice : .conversation)
        handsFreeByDefault = defaults.bool(forKey: Keys.handsFreeByDefault)
        newConversationForVoice = defaults.bool(forKey: Keys.newConversationForVoice)
        talkOver = defaults.string(forKey: Keys.talkOver).flatMap(TalkOver.init(rawValue:)) ?? .headphones
        interruption = defaults.string(forKey: Keys.interruption).flatMap(Interruption.init(rawValue:)) ?? .speech
        stopPhrases = defaults.stringArray(forKey: Keys.stopPhrases) ?? []
        answerRequestsByVoice = defaults.bool(forKey: Keys.answerRequestsByVoice)
        answerRequestsByNod = defaults.bool(forKey: Keys.answerRequestsByNod)
        shortAnswersInCar = defaults.bool(forKey: Keys.shortAnswersInCar)
        thinkingSound = defaults.string(forKey: Keys.thinkingSound).flatMap(ThinkingSound.init(rawValue:)) ?? .off
        voiceEngine = defaults.string(forKey: Keys.voiceEngine).flatMap(VoiceEngine.init(rawValue:)) ?? .redde
        liveVoice = defaults.string(forKey: Keys.liveVoice) ?? LiveSetup.defaultVoice
        liveVoices = defaults.dictionary(forKey: Keys.liveVoices) as? [String: String] ?? [:]
        liveHangUp = defaults.object(forKey: Keys.liveHangUp) as? Int ?? 2
        liveWhenLocked = defaults.bool(forKey: Keys.liveWhenLocked)
        liveGroupCalls = defaults.bool(forKey: Keys.liveGroupCalls)
        // Before there were three, Kokoro was a switch.
        replyVoice = defaults.string(forKey: Keys.replyVoice).flatMap(ReplyVoice.init(rawValue:))
            ?? (defaults.bool(forKey: Keys.useKokoro) ? .kokoro : .onDevice)
        kokoroURL = defaults.string(forKey: Keys.kokoroURL) ?? Self.defaultKokoroURL
        kokoroVoice = defaults.string(forKey: Keys.kokoroVoice) ?? Self.defaultKokoroVoice
        speechModel = defaults.string(forKey: Keys.speechModel) ?? ""
        elevenLabsVoice = defaults.string(forKey: Keys.elevenLabsVoice) ?? ""
        // "kokoroSpeed" was this setting's name for one build; carry the value over.
        let storedSpeed = defaults.double(forKey: Keys.voiceSpeed)
        let legacySpeed = defaults.double(forKey: "kokoroSpeed")
        voiceSpeed = storedSpeed != 0 ? storedSpeed : (legacySpeed != 0 ? legacySpeed : 1.0)
        theme = Theme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .standard
        themeColors = defaults.data(forKey: Keys.themeColors)
            .flatMap { try? JSONDecoder().decode([String: ThemeColors].self, from: $0) } ?? [:]
        spokenPrefixes = defaults.data(forKey: Keys.spokenPrefixes)
            .flatMap { try? JSONDecoder().decode([SpokenPrefix].self, from: $0) } ?? []
        botOrder = defaults.data(forKey: Keys.botOrder)
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        botSections = defaults.data(forKey: Keys.botSections)
            .flatMap { try? JSONDecoder().decode([String: BotSectionsHere].self, from: $0) } ?? [:]
        apiBots = defaults.data(forKey: Keys.apiBots)
            .flatMap { try? JSONDecoder().decode([String: [APIBot]].self, from: $0) } ?? [:]
        botVoices = defaults.data(forKey: Keys.botVoices)
            .flatMap { try? JSONDecoder().decode([String: [String: BotVoice]].self, from: $0) } ?? [:]
        pinnedModels = defaults.data(forKey: Keys.pinnedModels)
            .flatMap { try? JSONDecoder().decode([String: [ModelChoice]].self, from: $0) } ?? [:]
        mutes = defaults.data(forKey: Keys.mutes)
            .flatMap { try? JSONDecoder().decode([String: [String: Date]].self, from: $0) } ?? [:]
        agentCalls = defaults.bool(forKey: Keys.agentCalls)
        callsWhileLocked = defaults.bool(forKey: Keys.callsWhileLocked)
        callers = defaults.data(forKey: Keys.callers)
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        wakePhrases = defaults.data(forKey: Keys.wakePhrases)
            .flatMap { try? JSONDecoder().decode([String: [String: WakePhrase]].self, from: $0) } ?? [:]
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        // Redde's own face unless another was picked; a still orb picked in an earlier version
        // falls back to it too (they are gone).
        voiceOrb = VoiceOrb(rawValue: defaults.string(forKey: Keys.voiceOrb) ?? "") ?? .reddeFace
        orbLight = OrbLight(rawValue: defaults.string(forKey: Keys.orbLight) ?? "") ?? .nebula
        carPlayCards = CarPlayCardLook(rawValue: defaults.string(forKey: Keys.carPlayCards) ?? "") ?? .color
        carPlayVoice = CarPlayVoiceLook(rawValue: defaults.string(forKey: Keys.carPlayVoice) ?? "") ?? .bars
        carPlayBots = CarPlayBotLook(rawValue: defaults.string(forKey: Keys.carPlayBots) ?? "") ?? .sticker
        carPlayTab = defaults.string(forKey: Keys.carPlayTab) ?? "ask"
        stopAndSkipInCar = defaults.bool(forKey: Keys.stopAndSkipInCar)
        phoneTools = defaults.data(forKey: Keys.phoneTools).flatMap { try? JSONDecoder().decode(PhoneToolsSettings.self, from: $0) } ?? .init()
        notifyInBackground = defaults.bool(forKey: Keys.notifyInBackground)
        showLiveActivity = defaults.object(forKey: Keys.showLiveActivity) as? Bool ?? true
        keepRepliesInBackground = defaults.object(forKey: Keys.keepRepliesInBackground) as? Bool ?? true
        suggestFollowUps = defaults.object(forKey: Keys.suggestFollowUps) as? Bool ?? true
        agentsAskEachOther = defaults.object(forKey: Keys.agentsAskEachOther) as? Bool ?? true
        hermesBotsTalk = defaults.object(forKey: Keys.hermesBotsTalk) as? Bool ?? true
        askBeforeAgentsAsk = defaults.object(forKey: Keys.askBeforeAgentsAsk) as? Bool ?? true
        suggestionsFromFastLane = defaults.bool(forKey: Keys.suggestionsFromFastLane)
        speechLanguage = defaults.string(forKey: Keys.speechLanguage) ?? ""
        matchReplyLanguage = defaults.object(forKey: Keys.matchReplyLanguage) as? Bool ?? true
        earpieceAtEar = defaults.object(forKey: Keys.earpieceAtEar) as? Bool ?? true
        announceOnAirPods = defaults.bool(forKey: Keys.announceOnAirPods)
        briefingTapsOpenRun = defaults.bool(forKey: Keys.briefingTapsOpenRun)
        notificationSound = defaults.object(forKey: Keys.notificationSound) as? Bool ?? true
        returnSends = defaults.bool(forKey: Keys.returnSends)
        chatTextSize = min(max(defaults.integer(forKey: Keys.chatTextSize), Self.chatTextSizes.lowerBound), Self.chatTextSizes.upperBound)
        botColors = defaults.object(forKey: Keys.botColors) as? Bool ?? true
        eventColor = EventColor(rawValue: defaults.string(forKey: Keys.eventColor) ?? "") ?? .byCalendar
        cardColor = CardColor(rawValue: defaults.string(forKey: Keys.cardColor) ?? "") ?? .plain
        todayColor = TodayColor(rawValue: defaults.string(forKey: Keys.todayColor) ?? "") ?? .plain
        todayTileColors = defaults.dictionary(forKey: Keys.todayTileColors) as? [String: String] ?? [:]
        listLayouts = defaults.dictionary(forKey: Keys.listLayouts) as? [String: String] ?? [:]
        todayTileOrder = defaults.stringArray(forKey: Keys.todayTileOrder) ?? []
        todayUpNext = defaults.bool(forKey: Keys.todayUpNext)
        cardAppearance = Appearance(rawValue: defaults.string(forKey: Keys.cardAppearance) ?? "") ?? .system
        chatFont = ChatFont(rawValue: defaults.string(forKey: Keys.chatFont) ?? "") ?? .theme
        agendaCalendars = defaults.stringArray(forKey: Keys.agendaCalendars) ?? []
        newEventsCalendar = defaults.string(forKey: Keys.newEventsCalendar) ?? ""
        currentLocation = defaults.bool(forKey: Keys.currentLocation)
        leaveByAlerts = defaults.bool(forKey: Keys.leaveByAlerts)
        linkPreviews = defaults.bool(forKey: Keys.linkPreviews)
        addressMaps = defaults.object(forKey: Keys.addressMaps) as? Bool ?? true
        botFaces = defaults.object(forKey: Keys.botFaces) as? Bool ?? true
        botPictures = defaults.object(forKey: Keys.botPictures) as? Bool ?? true
        replyCards = defaults.object(forKey: Keys.replyCards) as? Bool ?? true
        requireBiometrics = defaults.bool(forKey: Keys.requireBiometrics)
        siriAIEnabled = defaults.bool(forKey: Keys.siriAIEnabled)
        siriDraftsInNewConversation = defaults.bool(forKey: Keys.siriDraftsInNewConversation)
        showBots = defaults.object(forKey: Keys.showBots) as? Bool ?? true
        projectsInChatList = defaults.object(forKey: Keys.projectsInChatList) as? Bool ?? true
        notifyWhereYouAre = defaults.object(forKey: Keys.notifyWhereYouAre) as? Bool ?? true
        hiddenChatListCards = defaults.stringArray(forKey: Keys.hiddenChatListCards) ?? []
        lockGraceSeconds = defaults.object(forKey: Keys.lockGraceSeconds) as? Double ?? 60
        displayName = defaults.string(forKey: Keys.displayName) ?? ""
        setupDone = defaults.bool(forKey: Keys.setupDone)
        serveURL = defaults.string(forKey: Keys.serveURL) ?? Self.defaultServeURL
        serveUsername = defaults.string(forKey: Keys.serveUsername) ?? ""
        serveOpenAccess = defaults.bool(forKey: Keys.serveOpenAccess)
        acpURL = defaults.string(forKey: Keys.acpURL) ?? ""
        acpAgent = defaults.string(forKey: Keys.acpAgent) ?? ""
        acpFolder = defaults.string(forKey: Keys.acpFolder) ?? ""
        acpAllAgents = defaults.bool(forKey: Keys.acpAllAgents)
        hermesProfile = defaults.string(forKey: Keys.hermesProfile) ?? ""
        hermesProfileHome = defaults.string(forKey: Keys.hermesProfileHome) ?? ""
        cfAccessClientID = defaults.string(forKey: Keys.cfAccessClientID) ?? ""
        let storedWindow = defaults.integer(forKey: Keys.contextWindow)
        contextWindow = storedWindow > 0 ? storedWindow : Self.defaultContextWindow

        // Saved servers. An install from before multi-server has none: its one setup becomes
        // the first server, and its secrets move under that server (moveLegacySecretsToActiveServer).
        let savedData = defaults.data(forKey: Keys.hermesServers)
        let saved = savedData.flatMap { try? JSONDecoder().decode([HermesServer].self, from: $0) } ?? []
        let storedActive = defaults.string(forKey: Keychain.activeServerKey).flatMap(UUID.init(uuidString:))
        if let active = saved.first(where: { $0.id == storedActive }) ?? saved.first {
            servers = saved
            activeServerID = active.id
        } else {
            // A list that's there but can't be read is kept aside rather than overwritten, and
            // the active server keeps its id, so the Keychain secrets filed under it still match.
            if let savedData { defaults.set(savedData, forKey: Keys.hermesServers + ".unreadable") }
            // Built from the stored values: the properties can't be read before `servers` is set.
            let stored = { (key: String) in defaults.string(forKey: key) ?? "" }
            let storedTransport = Transport(rawValue: stored(Keys.transport)) ?? .hermesSessions
            let first = HermesServer(id: storedActive ?? UUID(), name: "",
                                     transport: storedTransport == .chatCompletions ? .hermesServe : storedTransport,
                                     gatewayURL: stored(Keys.gatewayURL), serveURL: stored(Keys.serveURL),
                                     serveUsername: stored(Keys.serveUsername), cfAccessClientID: stored(Keys.cfAccessClientID),
                                     gatewayModel: stored(Keys.gatewayModel), gatewayProvider: stored(Keys.gatewayProvider),
                                     hermesProfile: stored(Keys.hermesProfile), hermesProfileHome: stored(Keys.hermesProfileHome),
                                     serveOpenAccess: defaults.bool(forKey: Keys.serveOpenAccess))
            servers = [first]
            activeServerID = first.id
            defaults.set(try? JSONEncoder().encode(servers), forKey: Keys.hermesServers)
        }
        defaults.set(activeServerID.uuidString, forKey: Keychain.activeServerKey)
        scopeShortcutSessionKeys()
        noteMainAgentName()
    }

    /// The main agent's name where the notification extension can read it. Not a test's settings.
    private func noteMainAgentName() {
        if defaults === UserDefaults.standard { MainAgentName.save(displayName) }
    }

    // MARK: - iCloud

    /// Saves a setting, and tells `CloudSync` which one.
    private func store(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        onStore?(key)
    }

    /// Called with each setting's key as it is saved: `CloudSync`, while Sync with iCloud is on.
    @ObservationIgnored var onStore: ((String) -> Void)?

    // MARK: - Servers

    /// Saved Hermes servers. The connection fields above are the active server's working copy:
    /// editing them updates its record, and switching loads another record into them.
    var servers: [HermesServer] {
        didSet { store(try? JSONEncoder().encode(servers), forKey: Keys.hermesServers) }
    }
    var activeServerID: UUID {
        didSet { store(activeServerID.uuidString, forKey: Keychain.activeServerKey) }
    }
    /// Set while a server's record is being loaded into the working copy.
    @ObservationIgnored var loadingServer = false

    /// Set after the first-run setup completes (or is skipped).
    var setupDone: Bool {
        didSet { store(setupDone, forKey: Keys.setupDone) }
    }
}

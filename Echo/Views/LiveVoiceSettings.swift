import SwiftUI

/// User-facing facts that determine where Hermes Live / Codex settings live. Keeping this separate
/// from the SwiftUI rows makes its group fallback and setup facts testable.
struct LiveVoiceSettingsPresentation {
    struct SetupRow: Identifiable, Equatable {
        let title: String
        let value: String
        var id: String { title }
    }

    struct GroupChats {
        let supportsLiveCalls: Bool
        let title: String
        let value: String
        let detail: String
    }

    let modeSummary: String
    let groupChats: GroupChats
    let setupRows: [SetupRow]

    init(engine: LiveEngine) {
        if engine.setUpByHermes {
            modeSummary = String(localized: "Uses your Hermes and its existing ChatGPT / Codex sign-in, so this iPhone needs no OpenAI key. The live voice can talk and listen at the same time; work that needs your agent comes back to this chat.")
            groupChats = GroupChats(
                supportsLiveCalls: false,
                title: String(localized: "Group chats"),
                value: String(localized: "Read aloud"),
                detail: String(localized: "Hermes Live / Codex runs one agent at a time, so group-chat replies use each bot's reading voice instead."))
            setupRows = [
                SetupRow(title: String(localized: "Calls use"), value: String(localized: "Your Hermes")),
                SetupRow(title: String(localized: "Connection"), value: "talk-desktop"),
                SetupRow(title: String(localized: "Account"), value: String(localized: "ChatGPT subscription")),
                SetupRow(title: String(localized: "On this iPhone"), value: String(localized: "No API key")),
                SetupRow(title: String(localized: "Agent work"), value: String(localized: "This chat")),
            ]
        } else {
            // Kept as a testable account of established live-call semantics. The existing UI for
            // these providers remains in StandardLiveVoiceSettings below.
            modeSummary = String(localized: "\(engine.company)'s live voice talks and listens at the same time. It handles quick conversation while requests that need your agent stay with this chat.")
            groupChats = GroupChats(
                supportsLiveCalls: true,
                title: String(localized: "Group Chats as Calls"),
                value: "",
                detail: String(localized: "When on, each group member's reply uses that bot's selected live call voice. When off, group replies use their reading voices."))
            setupRows = [
                SetupRow(title: String(localized: "Calls use"), value: engine.company),
                SetupRow(title: String(localized: "On this iPhone"), value: String(localized: "API key")),
                SetupRow(title: String(localized: "Agent work"), value: String(localized: "This chat")),
            ]
        }
    }
}

/// Settings → Voice → Voice mode. The approved new hierarchy is deliberately Hermes-only. GPT-Live,
/// Gemini Live, Grok Voice, ElevenLabs and Listen and read aloud retain their existing settings UI.
struct LiveVoiceSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        if settings.voiceEngine.live == .hermesLive {
            HermesLiveVoiceSettings()
        } else {
            StandardLiveVoiceSettings()
        }
    }
}

/// The new information architecture for Hermes Live / Codex only.
private struct HermesLiveVoiceSettings: View {
    @State private var settings = Settings.shared
    @State private var talkDesktop: HermesLivePlugin?

    private var engine: LiveEngine? { settings.voiceEngine.live }

    private var callOptionsSummary: String {
        let quiet = settings.liveHangUp == 0
            ? String(localized: "Never")
            : String(localized: "\(settings.liveHangUp) min")
        return settings.liveWhenLocked
            ? String(localized: "On lock · \(quiet)")
            : quiet
    }

    private var callSetupSummary: String {
        talkDesktop?.summary ?? String(localized: "Check status")
    }

    var body: some View {
        Form {
            Section {
                Picker("Voice mode", selection: $settings.voiceEngine) {
                    Text(VoiceSettings.modeName(nil)).tag(Settings.VoiceEngine.redde)
                    ForEach(LiveEngine.voiceModes, id: \.self) { mode in
                        Text(VoiceSettings.modeName(mode)).tag(Settings.VoiceEngine(rawValue: mode.rawValue) ?? .redde)
                    }
                }
                .pickerStyle(.inline)

                if let engine {
                    NavigationLink {
                        LiveVoiceList(engine: engine,
                                      selection: Binding(get: { settings.appLiveVoice(engine) },
                                                         set: { settings.setAppLiveVoice($0 ?? engine.defaultVoice, for: engine) }),
                                      name: settings.headerTitle)
                    } label: {
                        LabeledContent("Call voice", value: engine.voiceName(settings.appLiveVoice(engine)))
                    }

                    NavigationLink {
                        HermesLiveCallOptionsSettings()
                    } label: {
                        LabeledContent("Call options", value: callOptionsSummary)
                    }
                }
            } header: {
                Text("Conversation")
            } footer: {
                if let engine {
                    Text(LiveVoiceSettingsPresentation(engine: engine).modeSummary)
                }
            }

            Section {
                NavigationLink {
                    VoiceDefaultsSettings()
                } label: {
                    LabeledContent("Voice defaults", value: String(localized: "Main agent + bots"))
                }
            } header: {
                Text("Applies to")
            } footer: {
                Text("Bots with their own choice in Edit Bot → Voice use that setting instead.")
            }

            Section {
                NavigationLink {
                    HermesLiveCallSetupSettings()
                } label: {
                    LabeledContent("Your Hermes", value: callSetupSummary)
                }
            } header: {
                Text("Call setup")
            } footer: {
                Text("Connection, account and active-chat details live here—not in the everyday Voice screen.")
            }
        }
        .navigationTitle("Voice mode")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: settings.voiceEngine) {
            guard settings.voiceEngine.live == .hermesLive else {
                talkDesktop = nil
                return
            }
            talkDesktop = nil
            if HermesLiveCall.available {
                talkDesktop = await LiveSetup.talkDesktop(settings)
            }
        }
    }
}

/// Restores the established form for all non-Hermes modes without changing their behaviour,
/// credential handling, group-call controls, or explanatory copy.
private struct StandardLiveVoiceSettings: View {
    @State private var settings = Settings.shared
    @State private var hasKey = false
    @State private var hermes: LiveSetup.Status?
    @State private var asked = false
    @State private var talkDesktop: HermesLivePlugin?

    private var reachesHermes: Bool { BotDirectory.reachable(settings) }
    private var engine: LiveEngine? { settings.voiceEngine.live }

    var body: some View {
        Form {
            Section {
                Picker("Voice mode", selection: $settings.voiceEngine) {
                    Text(VoiceSettings.modeName(nil)).tag(Settings.VoiceEngine.redde)
                    ForEach(LiveEngine.voiceModes, id: \.self) { mode in
                        Text(VoiceSettings.modeName(mode)).tag(Settings.VoiceEngine(rawValue: mode.rawValue) ?? .redde)
                    }
                }
                .pickerStyle(.inline)
            } footer: {
                Text(modeFooter + "\n\n" + String(localized: "For the main agent and every bot without its own choice (Edit Bot → Voice)."))
            }

            Section {
                Toggle("Keep Calls On When Locked", isOn: $settings.liveWhenLocked)
            } footer: {
                settings.liveWhenLocked
                    ? Text("A live call goes on with your iPhone locked: the microphone stays open (the orange dot shows it) and the service bills its minutes until you hang up or say a stop phrase, or it ends by itself: after a quiet (Hang up after quiet) or, with hands-free off, after an answer.")
                    : Text("Locking your iPhone hangs up a live call, unless it is hands-free or on your car's screen.")
            }

            if let engine {
                Section {
                    Toggle("Group Chats as Calls", isOn: $settings.liveGroupCalls)
                        .disabled(!engine.greets && !settings.liveGroupCalls)
                } footer: {
                    if !engine.greets {
                        settings.liveGroupCalls
                            ? Text("\(engine.name) can't be a group chat's call: it can't say each bot's reply in that bot's voice. Turn this off, and voice mode in a group chat is Redde's.")
                            : Text("\(engine.name) can't be a group chat's call: it can't say each bot's reply in that bot's voice. Voice mode in a group chat stays Redde's.")
                    } else {
                        settings.liveGroupCalls
                            ? Text("Voice mode in a group chat is a \(engine.name) call: \(engine.company)'s voice hands what you say to the group, and each bot's reply is said in that bot's \(engine.name) voice (Edit Bot → Voice), the call switching to it for the reply. The call is billed for as long as it is open.")
                            : Text("Voice mode in a group chat is Redde's: your iPhone hears you, and each bot's reply is read in its reading voice.")
                    }
                }

                Section {
                    if engine.setUpByHermes {
                        LabeledContent("Your Hermes") {
                            Text(talkDesktopState).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }
                    } else {
                        if engine == .gptLive {
                            LabeledContent("Your Hermes's key") {
                                Text(hermesState).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }
                        }
                        if let key = engine.key {
                            SecretField(item: key,
                                        prompt: keyPrompt(engine),
                                        replacePrompt: String(localized: "Replace stored \(engine.company) key"),
                                        saveTitle: String(localized: "Save key"),
                                        removeTitle: String(localized: "Remove key"),
                                        optional: true,
                                        hasValue: $hasKey)
                                .id(engine)
                        }
                    }
                } header: {
                    Text("Calls use")
                } footer: {
                    if engine.setUpByHermes {
                        Text("No key: your Hermes sets each call up with the talk-desktop plugin and the ChatGPT subscription Codex is signed in with there. It takes the Hermes Dashboard and talk-desktop switched on (Settings → Plugins). As a call starts, your Hermes says whether Codex is signed in and whether it leaves your requests to Redde, to be worked in this chat (client-managed handoffs); a call it can't say yes to ends, saying why, and nothing goes anywhere else.")
                    }
                }

                Section {
                    NavigationLink {
                        LiveVoiceList(engine: engine,
                                      selection: Binding(get: { settings.appLiveVoice(engine) },
                                                         set: { settings.setAppLiveVoice($0 ?? engine.defaultVoice, for: engine) }),
                                      name: settings.headerTitle)
                    } label: {
                        LabeledContent("Voice", value: engine.voiceName(settings.appLiveVoice(engine)))
                    }
                    Picker("Hang up after quiet", selection: $settings.liveHangUp) {
                        ForEach(Settings.liveHangUps, id: \.self) { minutes in
                            (minutes == 0 ? Text("Never") : Text("\(minutes) minutes")).tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text(footer(engine))
                }
            }
        }
        .navigationTitle("Voice Mode")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: settings.voiceEngine) {
            hasKey = engine?.key.map { Keychain.read($0) != nil } ?? false
            if engine?.setUpByHermes == true {
                talkDesktop = nil
                if HermesLiveCall.available { talkDesktop = await LiveSetup.talkDesktop(settings) }
                return
            }
            guard engine == .gptLive, reachesHermes else {
                asked = true
                return
            }
            hermes = await LiveSetup.status(profile: nil, settings: settings, fresh: true)
            asked = true
        }
    }

    private var modeFooter: String {
        guard let engine else {
            return String(localized: "Your iPhone hears you, your agent answers, and the reading voice (Settings → Voice) reads the answer out. Nothing goes anywhere but your server and that voice.")
        }
        if engine.setUpByHermes {
            return String(localized: "Your Hermes sets the call up through its talk-desktop plugin, with the ChatGPT subscription Codex is signed in with there, so Redde asks for no key. OpenAI's voice talks and listens at the same time, and each request it hands over goes to your agent in this chat, as in a typed one; the voice says the answer in its own words.")
        }
        return String(localized: "\(engine.company)'s voice model talks and listens at the same time: interrupt it whenever you like, and it answers small talk at once and says “let me check” while your agent works. Anything real goes to your agent, as in a typed chat, and the voice says the answer in its own words.")
    }

    private var hermesState: String {
        guard reachesHermes else { return String(localized: "Needs the Dashboard") }
        guard asked else { return String(localized: "Asking…") }
        guard let hermes else { return String(localized: "Can't (Hermes 0.21.3 or later)") }
        return hermes.available ? String(localized: "Comes with the next Redde plugin") : String(localized: "Has no OpenAI key")
    }

    private var talkDesktopState: String {
        guard HermesLiveCall.available else { return String(localized: "Needs an iPhone or iPad") }
        guard let talkDesktop else { return String(localized: "Asking…") }
        return talkDesktop.summary
    }

    private func keyPrompt(_ engine: LiveEngine) -> String {
        switch engine {
        case .gptLive: String(localized: "OpenAI API key")
        case .gemini: String(localized: "Gemini API key (Google AI Studio)")
        case .grok: String(localized: "xAI API key")
        case .elevenLabs: String(localized: "ElevenLabs API key")
        case .hermesLive: ""
        }
    }

    private func footer(_ engine: LiveEngine) -> String {
        if engine.setUpByHermes {
            return String(localized: "The voice is the one calls use, unless a bot has its own (Edit Bot → Voice); your Hermes asks OpenAI for it.") + "\n\n"
                + String(localized: "While a call is open, what your microphone hears goes over WebRTC to OpenAI, in the session your Hermes opened, and your agent's answers go there to be spoken.") + " "
                + engine.cost + " "
                + String(localized: "A call hangs up when you tap the orb, say a stop phrase, leave voice mode, or after the quiet set here. Pause cuts the voice off and shuts the microphone.") + " "
                + String(localized: "In a call, bots' reading voices and the voice speed don't apply: it is OpenAI's voice.")
        }
        let key = engine == .gptLive
            ? String(localized: "Calls use the OpenAI key above, kept in your iPhone's Keychain, on either connection. Calls with your Hermes's own key (OPENAI_API_KEY, or voice.gpt_live.api_key in its config) come with the next Redde plugin.")
            : String(localized: "Calls use the \(engine.company) key above, kept in your iPhone's Keychain, on either connection.")
        let limit = engine == .gemini ? String(localized: "Google ends a call's connection after about ten minutes.") + " " : ""
        return key + " " + String(localized: "The voice is the one calls use, unless a bot has its own (Edit Bot → Voice).") + "\n\n"
            + String(localized: "While a call is open, what your microphone hears goes to \(engine.company), and your agent's answers go there to be spoken.") + " "
            + engine.cost + " " + String(localized: "A call hangs up when you tap the orb, say a stop phrase, leave voice mode, or after the quiet set here.") + " "
            + limit
            + String(localized: "In a call, bots' reading voices and the voice speed don't apply: it is \(engine.company)'s voice.")
    }
}

/// The default configured here belongs to the main agent and bots without their own Voice setting.
struct VoiceDefaultsSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Main agent", value: String(localized: "Uses these settings"))
                LabeledContent("Bots without an override", value: String(localized: "Use these settings"))
            } footer: {
                Text("To give a bot its own voice configuration, open that bot and choose Edit Bot → Voice. Its override is not changed here.")
            }
        }
        .navigationTitle("Voice defaults")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Controls that change a Hermes Live / Codex call rather than its voice or connection.
struct HermesLiveCallOptionsSettings: View {
    @State private var settings = Settings.shared

    private let presentation = LiveVoiceSettingsPresentation(engine: .hermesLive)

    var body: some View {
        Form {
            Section {
                Toggle("Keep calls on when locked", isOn: $settings.liveWhenLocked)
            } header: {
                Text("When locked")
            } footer: {
                if settings.liveWhenLocked {
                    Text("The microphone stays open while your iPhone is locked. The call ends when you hang up, say a stop phrase, or reach the quiet-time limit. A live provider can keep charging while it remains open.")
                } else {
                    Text("Locking your iPhone hangs up a live call, unless it is hands-free or on your car's screen.")
                }
            }

            Section {
                Picker("Hang up after quiet", selection: $settings.liveHangUp) {
                    ForEach(Settings.liveHangUps, id: \.self) { minutes in
                        (minutes == 0 ? Text("Never") : Text("\(minutes) minutes")).tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                LabeledContent(presentation.groupChats.title, value: presentation.groupChats.value)
            } header: {
                Text("Call behaviour")
            } footer: {
                Text(presentation.groupChats.detail)
            }
        }
        .navigationTitle("Call options")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Hermes Live / Codex connection/account information, kept out of everyday Voice settings.
struct HermesLiveCallSetupSettings: View {
    @State private var settings = Settings.shared
    @State private var talkDesktop: HermesLivePlugin?

    private let presentation = LiveVoiceSettingsPresentation(engine: .hermesLive)

    private var talkDesktopState: String {
        guard HermesLiveCall.available else { return String(localized: "Needs an iPhone or iPad") }
        guard let talkDesktop else { return String(localized: "Asking…") }
        return talkDesktop.summary
    }

    var body: some View {
        Form {
            Section {
                ForEach(presentation.setupRows) { row in
                    LabeledContent(row.title) {
                        Text(row.title == "Connection" ? talkDesktopState : row.value)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Call setup")
            } footer: {
                Text("Your Hermes starts the call through talk-desktop. Codex is signed in there, not on this iPhone. The voice can converse naturally, but requests needing the selected agent, files, memory or this chat's context are handed back to this chat. If that cannot be guaranteed, the call ends with a reason instead of sending work elsewhere.")
            }
        }
        .navigationTitle("Call setup")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            talkDesktop = nil
            if HermesLiveCall.available {
                talkDesktop = await LiveSetup.talkDesktop(settings)
            }
        }
    }
}

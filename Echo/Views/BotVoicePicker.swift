import AVFoundation
import SwiftUI

/// A bot's voice, in the same two parts as Settings → Voice (2026-10-26: "Home's voice settings
/// does not have the same selections"): its voice mode, as in Settings, Redde's own or a call, and
/// that call's voice (`conversationSection`); and its reading voice, as in Settings or its own
/// (`readerSection`), and in it Automatic (one of its own, `BotVoices`), Redde's, or one picked,
/// each with a sample to hear, and its speed. Kept on the phone, per server, and synced with iCloud.
/// Hermes's own voice is the server's, one for every bot that reads with it.
struct BotVoicePicker: View {
    let bot: HermesBot
    let mainName: String
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var kokoroVoices: [String] = []
    /// ElevenLabs: the account's voices.
    @State private var elevenLabsVoices: [ElevenLabsVoice] = []
    /// Kokoro: a blend being typed (`KokoroBlend`).
    @State private var blend = ""
    @State private var loading = false
    @State private var sample = SpeechOutput()

    private var name: String { bot.label(mainName: mainName) }
    private var picked: BotVoice? { settings.botVoicesHere[bot.name] }
    /// The voice that reads its replies: its own, else Settings'.
    private var engine: Settings.ReplyVoice { picked?.reader ?? settings.replyVoice }
    @State private var hasElevenLabsKey = ElevenLabsSpeech.key != nil
    /// The reading voice can't read yet (no Kokoro address, no ElevenLabs key): the built-in one does.
    private var engineNotReady: Bool {
        (engine == .kokoro && settings.kokoroBaseURL == nil) || (engine == .elevenLabs && !hasElevenLabsKey)
    }
    private var listening: String { SpokenLanguage.base(settings.speechLanguage.isEmpty ? AVSpeechSynthesisVoice.currentLanguageCode() : settings.speechLanguage) }

    var body: some View {
        NavigationStack {
            Form {
                conversationSection
                readerSection
                if engine == .hermes {
                    Section {
                        Text("\(name)'s replies are read in your Hermes's own voice, the one it is set up with, the same for every bot that reads with Hermes. Pick On-device, Kokoro or ElevenLabs for a voice of its own.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if !engineNotReady {
                    speedSection
                    Section {
                        row(String(localized: "Automatic", comment: "A bot's voice: one picked for it by itself"), detail: automaticDetail,
                            chosen: picked?.isAutomatic ?? true, voice: nil) { set(nil) }
                        row(String(localized: "Same as \(mainName)"), detail: nil, chosen: picked?.sameAsMain == true, voice: BotVoice(sameAsMain: true)) {
                            set(BotVoice(sameAsMain: true))
                        }
                    } footer: {
                        Text("Automatic gives \(name) a voice of its own, not \(mainName)'s and not another bot's while there are voices to go round. It reads \(name)'s replies in voice mode, in group chats and in the car.")
                    }
                    if engine == .kokoro { blendSection }
                    Section(engine == .kokoro ? String(localized: "Kokoro voices")
                            : engine == .elevenLabs ? String(localized: "Your ElevenLabs voices") : String(localized: "Voices on this iPhone")) {
                        if loading { ProgressView() }
                        ForEach(choices, id: \.id) { choice in
                            row(choice.name, detail: choice.detail, chosen: isPicked(choice.id), voice: choice.voice) { set(choice.voice) }
                        }
                        if engine == .onDevice {
                            Text("More voices, and better ones, come from Settings → Accessibility → Spoken Content → Voices.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("\(name)'s Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: engine) { await loadVoices() }
            .onDisappear {
                sample.stop()
                WatchLink.shared.push()   // the watch reads the bot in its voice too
            }
        }
        .holdsWakePhrases(.voicePicker)
    }

    private struct Choice {
        var id: String
        var name: String
        var detail: String?
        var voice: BotVoice
    }

    private var choices: [Choice] {
        switch engine {
        case .kokoro:
            let main = SpokenLanguage.kokoroLanguage(of: settings.kokoroVoice)
            // Its language first: those are the ones a reply in it is read with.
            return kokoroVoices.sorted { a, b in
                let (sa, sb) = (SpokenLanguage.kokoroLanguage(of: a) == main, SpokenLanguage.kokoroLanguage(of: b) == main)
                return sa != sb ? sa : a < b
            }.map { Choice(id: $0, name: Self.kokoroName($0), detail: $0 == settings.kokoroVoice ? String(localized: "\(mainName)'s voice") : $0,
                           voice: BotVoice(kokoro: $0)) }
        case .onDevice:
            return AVSpeechSynthesisVoice.speechVoices()
                .filter { SpokenLanguage.base($0.language) == listening && !$0.voiceTraits.contains(.isNoveltyVoice) }
                .sorted { $0.quality.rawValue != $1.quality.rawValue ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name }
                .map { Choice(id: $0.identifier, name: $0.name, detail: Self.quality($0) + " · " + $0.language, voice: BotVoice(onDevice: $0.identifier)) }
        case .elevenLabs:
            return elevenLabsVoices.map {
                Choice(id: $0.id, name: $0.name, detail: $0.id == mainElevenLabs ? String(localized: "\(mainName)'s voice") : $0.detail,
                       voice: BotVoice(elevenLabs: $0.id))
            }
        case .hermes:
            return []
        }
    }

    /// The ElevenLabs voice Redde reads in: the one picked, else the account's first.
    private var mainElevenLabs: String? { settings.elevenLabsVoice.nilIfEmpty ?? elevenLabsVoices.first?.id }

    private func isPicked(_ id: String) -> Bool { picked?.kokoro == id || picked?.onDevice == id || picked?.elevenLabs == id }

    /// Redde or a live engine for its voice conversations, or as Settings → Voice → Voice mode has
    /// it; on a live engine, that engine's voice for it.
    private var conversationSection: some View {
        let appWide = VoiceSettings.modeName(settings.voiceEngine.live)
        let engine = settings.liveEngine(for: bot.name)
        return Section {
            Picker("Voice mode", selection: Binding(
                get: { picked?.conversation },
                set: { choice in update { $0.conversation = choice } })) {
                Text("As in Settings (\(appWide))").tag(BotConversation?.none)
                Text(VoiceSettings.modeName(nil)).tag(BotConversation?.some(.redde))
                ForEach(LiveEngine.allCases, id: \.self) { engine in
                    Text(VoiceSettings.modeName(engine)).tag(BotConversation(rawValue: engine.rawValue))
                }
            }
            .pickerStyle(.menu)
            if let engine {
                let inherited = String(localized: "As in Settings (\(engine.voiceName(settings.appLiveVoice(engine))))")
                let own = picked?.liveVoices?[engine.rawValue].flatMap { engine.voicesFromAccount || engine.voices.contains($0) ? $0 : nil }
                NavigationLink {
                    LiveVoiceList(engine: engine, selection: Binding(
                        get: { own },
                        set: { voice in update { record in
                            var voices = record.liveVoices ?? [:]
                            voices[engine.rawValue] = voice
                            record.liveVoices = voices.isEmpty ? nil : voices
                        } }),
                                  inherit: inherited, name: name)
                } label: {
                    LabeledContent("\(engine.name) voice", value: own.map(engine.voiceName) ?? inherited)
                }
            }
        } header: {
            Text("Voice mode")
        } footer: {
            Text(engine.map { String(localized: "Voice mode in \(name)'s chat is a \($0.name) call: \($0.company)'s voice talks with you and hands anything real to \(name). Group chats, the car and Read aloud use the reading voice below.") }
                 ?? String(localized: "Voice mode in \(name)'s chat is Redde's: your iPhone hears you, \(name) answers, and the reading voice below reads it."))
        }
    }

    /// A blend of the server's voices, typed (Redde's own Kokoro voice is one): heard, then used.
    private var blendSection: some View {
        let typed = blend.trimmingCharacters(in: .whitespaces)
        let valid = KokoroBlend.isBlend(typed, of: kokoroVoices)
        return Section {
            if let current = picked?.kokoro, current.contains("+") {
                row(current, detail: String(localized: "\(name)'s blend"), chosen: true, voice: BotVoice(kokoro: current)) {}
            }
            TextField("bf_emma(1)+af_heart(4)+af_bella(2)", text: $blend)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("A blend of Kokoro voices")
            HStack {
                Button("Hear It") { play(BotVoice(kokoro: typed)) }.disabled(!valid)
                Spacer()
                Button("Use This Blend") { set(BotVoice(kokoro: typed)) }.disabled(!valid || picked?.kokoro == typed)
            }
            .buttonStyle(.borderless)
        } header: {
            Text("A blend")
        } footer: {
            typed.isEmpty || valid
                ? Text("Two of the voices below or more, each with its share in brackets. The first one says how it's pronounced: a British voice first (bf_, bm_) drops its r's.")
                : Text("Write voices the server has, joined by +, each with a number in brackets.")
        }
    }

    /// Which voice reads its replies: Settings', or one of its own, with what that one still needs.
    private var readerSection: some View {
        Section {
            Picker("Reading voice", selection: Binding(
                get: { picked?.reader },
                set: { reader in update { $0.reader = reader } })) {
                Text("As in Settings (\(settings.replyVoice.name))").tag(Settings.ReplyVoice?.none)
                ForEach(Settings.ReplyVoice.allCases, id: \.self) { Text($0.name).tag(Settings.ReplyVoice?.some($0)) }
            }
            .pickerStyle(.menu)
            if engine == .kokoro, settings.kokoroBaseURL == nil {
                TextField("http://your-tts-server:8880", text: $settings.kokoroURL)
                    .urlFieldStyle()
            }
            if engine == .elevenLabs, !hasElevenLabsKey {
                SecretField(item: LiveEngine.elevenLabs.keyItem, prompt: String(localized: "ElevenLabs API key"),
                            replacePrompt: String(localized: "Replace stored ElevenLabs key"),
                            saveTitle: String(localized: "Save key"), removeTitle: String(localized: "Remove key"), optional: true,
                            hasValue: $hasElevenLabsKey)
            }
        } header: {
            Text("Reading voice")
        } footer: {
            engineNotReady
                ? Text("Which voice reads \(name)'s replies aloud: in voice mode when that isn't a call, in group chats, in the car and with Read aloud. Until it's set up, the built-in voice reads them.")
                : Text("Which voice reads \(name)'s replies aloud: in voice mode when that isn't a call, in group chats, in the car and with Read aloud.")
        }
    }

    /// Changes its record, dropping it once nothing is left picked.
    private func update(_ change: (inout BotVoice) -> Void) {
        var voice = picked ?? BotVoice()
        change(&voice)
        settings.botVoicesHere[bot.name] = voice.isEmpty ? nil : voice
    }

    /// Its own speed, or Redde's: a switch, and the slider while it is on.
    private var speedSection: some View {
        Section {
            Toggle("Its own speed", isOn: Binding(
                get: { picked?.speed != nil },
                set: { own in setSpeed(own ? settings.voiceSpeed : nil) }))
            if let speed = picked?.speed {
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("Speed") { Text(Self.speedLabel(speed)).monospacedDigit() }
                    Slider(value: Binding(get: { speed }, set: { setSpeed($0, hear: false) }), in: 0.5...2.0, step: 0.05) { editing in
                        if !editing { play(picked.flatMap { $0.isAutomatic ? nil : $0 }) }
                    }
                    .accessibilityLabel("\(name)'s voice speed")
                }
            }
        } header: {
            Text("Speed")
        } footer: {
            picked?.speed == nil
                ? Text("\(name) reads at \(mainName)'s speed, \(Self.speedLabel(settings.voiceSpeed)) (Settings → Voice → Voice speed).")
                : Text("\(name) reads at this speed in voice mode, in group chats and in the car, whatever its voice.")
        }
    }

    private func setSpeed(_ speed: Double?, hear: Bool = true) {
        update { $0.speed = speed }
        if hear { play(picked.flatMap { $0.isAutomatic ? nil : $0 }) }
    }

    /// What Automatic gives it now.
    private var automaticDetail: String {
        var others = settings.botVoicesHere
        others[bot.name] = nil
        let names = BotDirectory.shared.bots(for: settings.connectionKey).map(\.name)
        switch engine {
        case .kokoro:
            let id = BotVoices.kokoro(for: bot.name, picked: others, main: settings.kokoroVoice, available: kokoroVoices, names: names)
            return id.map(Self.kokoroName) ?? String(localized: "\(mainName)'s voice, for now: the server has no other voice in its language")
        case .onDevice:
            let installed = AVSpeechSynthesisVoice.speechVoices().map {
                SpokenLanguage.AppleVoice(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue,
                                          novelty: $0.voiceTraits.contains(.isNoveltyVoice))
            }
            let main = sample.voice(for: listening)?.identifier
            let id = BotVoices.onDevice(for: bot.name, picked: others, language: listening, main: main, installed: installed, names: names)
            return id.flatMap { AVSpeechSynthesisVoice(identifier: $0)?.name }
                ?? String(localized: "\(mainName)'s voice, for now: no other voice is installed for its language")
        case .elevenLabs:
            guard let main = mainElevenLabs else { return String(localized: "Save your ElevenLabs key in Settings → Voice first") }
            let id = BotVoices.elevenLabs(for: bot.name, picked: others, main: main, available: elevenLabsVoices.map(\.id), names: names)
            return id.flatMap(ElevenLabsVoice.name) ?? String(localized: "\(mainName)'s voice, for now: your account has no other voice")
        case .hermes:
            return ""
        }
    }

    private func row(_ title: String, detail: String?, chosen: Bool, voice: BotVoice?, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: choose) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    if chosen { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(chosen ? .isSelected : [])
            Button("Hear it", systemImage: "play.circle") { play(voice) }
                .labelStyle(.iconOnly)
                .font(.title3)
                .buttonStyle(.borderless)
        }
    }

    /// Another voice; its speed and conversation stay as they were.
    private func set(_ voice: BotVoice?) {
        var record = voice ?? BotVoice()
        record.speed = picked?.speed
        record.conversation = picked?.conversation
        record.liveVoices = picked?.liveVoices
        record.reader = picked?.reader
        settings.botVoicesHere[bot.name] = record.isEmpty ? nil : record
        play(voice)
    }

    /// A line in that voice; nil, Automatic, the one it gets.
    private func play(_ voice: BotVoice?) {
        try? AudioSessionController.shared.activateForPlayback()
        sample.speaker = bot.name
        sample.voiceOverride = voice?.sameAsMain == true ? BotVoice() : voice
        sample.beginReply()
        sample.append("Hi, I'm \(name). This is how I sound.")
        sample.endReply()
    }

    private func loadVoices() async {
        switch engine {
        case .kokoro:
            guard let server = settings.kokoroBaseURL else { return }
            loading = true
            defer { loading = false }
            kokoroVoices = (try? await KokoroPlayer.voiceIDs(baseURL: server)) ?? []
        case .elevenLabs:
            guard let key = ElevenLabsSpeech.key else { return }
            loading = true
            defer { loading = false }
            elevenLabsVoices = (try? await ElevenLabsVoice.all(key: key)) ?? []
        default:
            return
        }
    }

    /// "am_adam" → "Adam (American, male)".
    static func kokoroName(_ id: String) -> String {
        let parts = id.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 2 else { return id }
        let accent: [Character: String] = [
            "a": String(localized: "American", comment: "A Kokoro voice's accent"), "b": String(localized: "British", comment: "A Kokoro voice's accent"),
            "e": String(localized: "Spanish", comment: "A Kokoro voice's accent"), "f": String(localized: "French", comment: "A Kokoro voice's accent"),
            "h": String(localized: "Hindi", comment: "A Kokoro voice's accent"), "i": String(localized: "Italian", comment: "A Kokoro voice's accent"),
            "j": String(localized: "Japanese", comment: "A Kokoro voice's accent"), "p": String(localized: "Portuguese", comment: "A Kokoro voice's accent"),
            "z": String(localized: "Chinese", comment: "A Kokoro voice's accent")]
        let who = parts[0].last == "f" ? String(localized: "female", comment: "A Kokoro voice: a woman's")
            : parts[0].last == "m" ? String(localized: "male", comment: "A Kokoro voice: a man's") : nil
        let place = parts[0].first.flatMap { accent[$0] }
        let about = [place, who].compactMap(\.self).joined(separator: ", ")
        return parts[1].capitalized + (about.isEmpty ? "" : " (\(about))")
    }

    /// A voice speed as Settings shows one: "1.25×".
    nonisolated static func speedLabel(_ speed: Double) -> String {
        String(localized: "\(speed.formatted(.number.precision(.fractionLength(2))))×", comment: "A voice's speed, e.g. “1.25×”")
    }

    private static func quality(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: String(localized: "Premium", comment: "An on-device voice's quality")
        case .enhanced: String(localized: "Enhanced", comment: "An on-device voice's quality")
        default: String(localized: "Default", comment: "An on-device voice's quality: the ordinary one")
        }
    }
}

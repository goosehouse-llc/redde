import AVFoundation
import SwiftUI

/// A bot's voice: Automatic (one of its own, `BotVoices`), Redde's own, or one of the voices Redde
/// reads with now (Settings → Voice → Reply voice: the built-in voices for the listening language,
/// or the Kokoro server's), each with a sample to hear. Kept on the phone, per server, and synced
/// with iCloud. Hermes's own voice is the server's, one for every bot. Its speed too: its own, or
/// Redde's (Settings → Voice → Voice speed). And, in builds with GPT-Live, who holds its voice
/// conversations, and GPT-Live's voice in them (`conversationSection`).
struct BotVoicePicker: View {
    let bot: HermesBot
    let mainName: String
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var kokoroVoices: [String] = []
    @State private var loading = false
    @State private var sample = SpeechOutput()

    private var name: String { bot.label(mainName: mainName) }
    private var picked: BotVoice? { settings.botVoicesHere[bot.name] }
    private var engine: Settings.ReplyVoice { settings.replyVoice }
    private var listening: String { SpokenLanguage.base(settings.speechLanguage.isEmpty ? AVSpeechSynthesisVoice.currentLanguageCode() : settings.speechLanguage) }

    var body: some View {
        NavigationStack {
            Form {
                conversationSection
                if engine == .hermes {
                    Section {
                        Text("Replies are read in Hermes's own voice (Settings → Voice → Reply voice), one for every bot. Pick Built-in or Kokoro there for each bot to have a voice of its own.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    speedSection
                    Section {
                        row("Automatic", detail: automaticDetail, chosen: picked?.isAutomatic ?? true, voice: nil) { set(nil) }
                        row("Same as \(mainName)", detail: nil, chosen: picked?.sameAsMain == true, voice: BotVoice(sameAsMain: true)) {
                            set(BotVoice(sameAsMain: true))
                        }
                    } footer: {
                        Text("Automatic gives \(name) a voice of its own, not \(mainName)'s and not another bot's while there are voices to go round. It reads \(name)'s replies in voice mode, in group chats and in the car.")
                    }
                    Section(engine == .kokoro ? "Kokoro voices" : "Voices on this iPhone") {
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
            .task { await loadKokoro() }
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
            }.map { Choice(id: $0, name: Self.kokoroName($0), detail: $0 == settings.kokoroVoice ? "\(mainName)'s voice" : $0, voice: BotVoice(kokoro: $0)) }
        case .onDevice:
            return AVSpeechSynthesisVoice.speechVoices()
                .filter { SpokenLanguage.base($0.language) == listening && !$0.voiceTraits.contains(.isNoveltyVoice) }
                .sorted { $0.quality.rawValue != $1.quality.rawValue ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name }
                .map { Choice(id: $0.identifier, name: $0.name, detail: Self.quality($0) + " · " + $0.language, voice: BotVoice(onDevice: $0.identifier)) }
        case .hermes:
            return []
        }
    }

    private func isPicked(_ id: String) -> Bool { picked?.kokoro == id || picked?.onDevice == id }

    /// Redde or a live engine for its voice conversations, or as Settings → Voice → Conversation has
    /// it; on a live engine, that engine's voice for it.
    private var conversationSection: some View {
        let appWide = settings.voiceEngine.live?.name ?? "Redde"
        let engine = settings.liveEngine(for: bot.name)
        return Section {
            Picker("Conversation", selection: Binding(
                get: { picked?.conversation },
                set: { choice in update { $0.conversation = choice } })) {
                Text("As in Settings (\(appWide))").tag(BotConversation?.none)
                Text("Redde").tag(BotConversation?.some(.redde))
                ForEach(LiveEngine.allCases, id: \.self) { engine in
                    Text(engine.name).tag(BotConversation(rawValue: engine.rawValue))
                }
            }
            .pickerStyle(.menu)
            if let engine {
                let inherited = "As in Settings (\(engine.voiceName(settings.appLiveVoice(engine))))"
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
            Text(engine.map { "Voice mode in \(name)'s chat is a \($0.name) call: \($0.company)'s voice talks with you and hands anything real to \(name). Group chats, read-aloud and the voice below stay Redde's." }
                 ?? "Voice mode in \(name)'s chat is Redde's: your iPhone hears you, \(name) answers, and the voice below reads it.")
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
                    LabeledContent("Speed") { Text(String(format: "%.2f×", speed)).monospacedDigit() }
                    Slider(value: Binding(get: { speed }, set: { setSpeed($0, hear: false) }), in: 0.5...2.0, step: 0.05) { editing in
                        if !editing { play(picked.flatMap { $0.isAutomatic ? nil : $0 }) }
                    }
                    .accessibilityLabel("\(name)'s voice speed")
                }
            }
        } header: {
            Text("Speed")
        } footer: {
            Text(picked?.speed == nil
                ? "\(name) reads at \(mainName)'s speed, \(String(format: "%.2f×", settings.voiceSpeed)) (Settings → Voice → Voice speed)."
                : "\(name) reads at this speed in voice mode, in group chats and in the car, whatever its voice.")
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
            return id.map(Self.kokoroName) ?? "\(mainName)'s voice, for now: the server has no other voice in its language"
        case .onDevice:
            let installed = AVSpeechSynthesisVoice.speechVoices().map {
                SpokenLanguage.AppleVoice(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue,
                                          novelty: $0.voiceTraits.contains(.isNoveltyVoice))
            }
            let main = sample.voice(for: listening)?.identifier
            let id = BotVoices.onDevice(for: bot.name, picked: others, language: listening, main: main, installed: installed, names: names)
            return id.flatMap { AVSpeechSynthesisVoice(identifier: $0)?.name } ?? "\(mainName)'s voice, for now: no other voice is installed for its language"
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

    private func loadKokoro() async {
        guard engine == .kokoro, let server = settings.kokoroBaseURL else { return }
        loading = true
        defer { loading = false }
        kokoroVoices = (try? await KokoroPlayer.voiceIDs(baseURL: server)) ?? []
    }

    /// "am_adam" → "Adam (American, male)".
    static func kokoroName(_ id: String) -> String {
        let parts = id.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 2 else { return id }
        let accent: [Character: String] = ["a": "American", "b": "British", "e": "Spanish", "f": "French", "h": "Hindi", "i": "Italian",
                                           "j": "Japanese", "p": "Portuguese", "z": "Chinese"]
        let who = parts[0].last == "f" ? "female" : parts[0].last == "m" ? "male" : nil
        let place = parts[0].first.flatMap { accent[$0] }
        let about = [place, who].compactMap(\.self).joined(separator: ", ")
        return parts[1].capitalized + (about.isEmpty ? "" : " (\(about))")
    }

    private static func quality(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Default"
        }
    }
}

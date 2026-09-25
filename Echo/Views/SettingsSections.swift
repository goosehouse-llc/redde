import SwiftUI
import WidgetKit

struct NameSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            TextField("Redde", text: $settings.displayName)
                .textInputAutocapitalization(.words)
        } header: {
            Text("Name")
        } footer: {
            Text("Shown in the header and the message box. Siri phrases and the Home Screen icon keep the app's real name.")
        }
    }
}

struct AppearanceSettings: View {
    @State private var settings = Settings.shared
    @State private var showThemes = false
    @State private var showColors = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $showThemes) {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(Settings.Appearance.allCases) { Text($0.label).tag($0) }
                }
                .adaptiveSegmented()
                .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                .accessibilityLabel("Light, dark or system appearance")
                ForEach(Theme.allCases) { theme in
                    Button { settings.theme = theme } label: {
                        HStack(spacing: 12) {
                            ThemeSwatch(theme: settings.resolved(theme)).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(theme.label).foregroundStyle(.primary)
                                Text(theme.blurb).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.theme == theme {
                                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.theme == theme ? .isSelected : [])
                }
            } label: {
                DisclosureSummary(title: "Theme") {
                    Text("\(settings.theme.label), \(settings.appearance.label.lowercased())")
                }
            }

            DisclosureGroup(isExpanded: $showColors) {
                ColorPicker("Accent", selection: accent, supportsOpacity: false)
                ColorPicker(active.promptPrefix != nil ? "Your messages" : "Your bubbles",
                            selection: bubble, supportsOpacity: false)
                if !(settings.themeColors[settings.theme.rawValue]?.isEmpty ?? true) {
                    Button("Use \(settings.theme.label)'s own colors") {
                        settings.themeColors[settings.theme.rawValue] = nil
                    }
                }
            } label: {
                DisclosureSummary(title: "\(settings.theme.label) colors") {
                    HStack(spacing: 4) {
                        Circle().fill(accent.wrappedValue).frame(width: 14, height: 14)
                        Circle().fill(bubble.wrappedValue).frame(width: 14, height: 14)
                    }
                    .accessibilityHidden(true)
                }
            }

            AppIconSettings()
            VoiceOrbSettings()
        } header: {
            Text("Appearance")
        } footer: {
            if showColors {
                Text("Each theme keeps its own colors. Text on your bubbles and on accent buttons turns light or dark to stay readable.")
            }
        }
    }

    private var active: ResolvedTheme { settings.resolvedTheme }

    private var accent: Binding<Color> {
        Binding {
            active.accent
        } set: {
            settings.themeColors[settings.theme.rawValue, default: ThemeColors()].accent = ThemeColors.RGB($0)
        }
    }

    /// Prompt themes (Terminal, Amber CRT) have no bubble: the pick colors your prompt line.
    private var bubble: Binding<Color> {
        Binding {
            active.promptPrefix != nil ? active.promptColor : active.userBubble
        } set: {
            settings.themeColors[settings.theme.rawValue, default: ThemeColors()].bubble = ThemeColors.RGB($0)
        }
    }
}

struct TransportSettings: View {
    @Binding var showSetup: Bool
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            Picker("Backend", selection: $settings.transport) {
                ForEach(Transport.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Button("Set up connection…", systemImage: "network") { showSetup = true }
        } header: {
            Text("Transport")
        }
    }
}

/// The model and reasoning effort, per transport.
struct ModelSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            NavigationLink {
                ModelPickerView()
            } label: {
                LabeledContent("Model") {
                    Text(modelSummary).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } header: {
            Text("Model")
        }
    }

    private var modelSummary: String {
        let model = settings.transport == .chatCompletions ? settings.fastLaneModel : (settings.gatewayModel.isEmpty ? "Default" : settings.gatewayModel)
        let effort = settings.reasoningEffort.isEmpty ? "" : " · \(settings.reasoningEffort)"
        return model + effort
    }
}

/// Skills, tools and the agent's context and memory files. All live on the gateway.
struct AgentSettings<Details: View>: View {
    /// An API key or a Dashboard login is stored.
    let canReachGateway: Bool
    /// The file editors need the Dashboard login specifically: the Hermes API server has no
    /// file endpoints (its capabilities report memory_write_api: false).
    let canEditFiles: Bool
    /// Where the Dashboard login is entered, linked from the locked file sections.
    @ViewBuilder let connectionDetails: () -> Details

    var body: some View {
        Section {
            NavigationLink { SkillsView() } label: { Label("Skills", systemImage: "sparkles") }
                .disabled(!canReachGateway)
        } footer: {
            Text("What Redde knows how to do. Create and edit from here; changes are live on the next turn.")
        }

        Section {
            NavigationLink { ToolsView() } label: { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .disabled(!canReachGateway)
        } footer: {
            Text("Toolsets enabled on the gateway. Read through the Hermes API key or the Hermes Dashboard login, whichever is set.")
        }

        Section {
            if !canEditFiles { filesLocked }
            NavigationLink {
                ContextFileEditorView(title: "SOUL.md", path: "~/.hermes/SOUL.md",
                                      purpose: "The agent's persona: who Redde is, how it speaks, what it values.")
            } label: { Label("SOUL.md", systemImage: "person.text.rectangle") }
            .disabled(!canEditFiles)
            NavigationLink {
                ContextFileEditorView(title: "ENVIRONMENT.md", path: "~/.hermes/ENVIRONMENT.md",
                                      purpose: "Standing facts about your setup: machines, services, names, conventions.")
            } label: { Label("ENVIRONMENT.md", systemImage: "server.rack") }
            .disabled(!canEditFiles)
        } header: {
            Text("Context files")
        } footer: {
            if canEditFiles { Text("Edited in place on the Hermes host through the Hermes Dashboard.") }
        }
        .id("agentFiles")

        Section {
            NavigationLink {
                ContextFileEditorView(title: "MEMORY.md", path: "~/.hermes/memories/MEMORY.md",
                                      purpose: "The agent's own notes: things it decided to remember across conversations. Injected into every system prompt.")
            } label: { Label("MEMORY.md", systemImage: "brain") }
            NavigationLink {
                ContextFileEditorView(title: "USER.md", path: "~/.hermes/memories/USER.md",
                                      purpose: "What the agent knows about you: preferences, facts, how you like answers. Also injected into every prompt.")
            } label: { Label("USER.md", systemImage: "person.crop.circle") }
        } header: {
            Text("Memory")
        } footer: {
            Text(canEditFiles
                 ? "The files the memory tool writes when you say “remember that…”. Edit them here to correct or prune what Redde carries into every conversation."
                 : "The files the memory tool writes when you say “remember that…”. Like the context files, they need the Hermes Dashboard login.")
        }
        .disabled(!canEditFiles)
    }

    /// Why the files are greyed out with only the Hermes API set up, and the way to fix it
    /// without switching connections.
    private var filesLocked: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Needs the Hermes Dashboard login", systemImage: "lock")
                .font(.subheadline.weight(.semibold))
            Text("The Hermes API can't read or edit files on your server. Keep using it for chat, and add your Dashboard login (from hermes serve) to unlock these files and your memory.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            NavigationLink { connectionDetails() } label: {
                Text("Add Dashboard login").font(.subheadline.weight(.medium))
            }
        }
        .padding(.vertical, 4)
    }
}

struct VoiceSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            Picker("Voice", selection: $settings.useKokoro) {
                Text("On-device (Apple)").tag(false)
                Text("Server TTS").tag(true)
            }
            .adaptiveSegmented()
            if settings.useKokoro {
                TextField("http://your-tts-server:8880", text: $settings.kokoroURL)
                    .urlFieldStyle()
                NavigationLink {
                    KokoroVoicesView()
                } label: {
                    LabeledContent("Voice") {
                        Text(settings.kokoroVoice).font(.callout.monospaced()).lineLimit(1)
                    }
                }
            }
            // Applies to Kokoro and the built-in fallback voice alike.
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Voice speed") {
                    Text(String(format: "%.2f×", settings.voiceSpeed)).monospacedDigit()
                }
                Slider(value: $settings.voiceSpeed, in: 0.5...2.0, step: 0.05)
                    .accessibilityLabel("Voice speed")
            }
            Toggle("Start voice mode in hands-free", isOn: $settings.handsFreeByDefault)
            Toggle("Open to the voice screen", isOn: $settings.openToVoiceScreen)
            Toggle("Listen whenever Redde opens", isOn: $settings.listenOnOpen)
            Toggle("Earpiece when raised to your ear", isOn: $settings.earpieceAtEar)
            Toggle("Live Activity while Redde works", isOn: $settings.showLiveActivity)
            Toggle("Notify me in the background", isOn: Binding(
                get: { settings.notifyInBackground },
                set: { on in
                    if on { Task { settings.notifyInBackground = await Notifier.shared.requestAuthorization() } }
                    else { settings.notifyInBackground = false }
                }))
            Toggle("Announce on AirPods", isOn: $settings.announceOnAirPods)
                .disabled(!settings.notifyInBackground)
        } header: {
            Text("Voice")
        } footer: {
            Text((settings.useKokoro
                ? "Streams audio from a Kokoro-compatible TTS server and starts playing before the sentence finishes. Falls back to the on-device voice if the server is unreachable. "
                : "Apple's on-device synthesizer. Zero network, fastest start. ")
                + "“Open to the voice screen” makes Redde launch into voice mode; “Listen whenever Redde opens” starts the mic as well, so “Hey Siri, open Redde” goes straight to listening. “Earpiece” plays replies through the earpiece when the phone is at your ear, like a call; turn it off for hands-free use with the phone face down. Background notifications tell you when Redde needs an approval or an answer, or when a reply finishes, while you're in another app. “Announce on AirPods” marks them time-sensitive so Siri can read them aloud through AirPods (turn on Announce Notifications for Redde in the iPhone's Settings) and so they reach you in a Focus. With AirPods in, pressing the stem on the voice screen works like tapping the mic.")
        }
    }
}

/// Siri AI (iOS 27). Off by default because it is the one path where Apple's models, not
/// just your own servers, see what you ask. See README → "Siri AI".
@available(iOS 27.0, *)
struct SiriSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            Toggle("Let Siri use Redde", isOn: $settings.siriAIEnabled)
        } header: {
            Text("Siri")
        } footer: {
            Text("Lets Siri message \(settings.headerTitle) in your own words (“Hey Siri, ask \(settings.headerTitle) in Redde whether the backup ran”), read its replies, and find your conversations. Siri waits about 20 seconds and reads the reply; longer answers come back as a notification you can reply to by voice. Apple Intelligence processes what you say to Siri and can see Redde's recent conversations, so this is the one path where Apple, not only your own servers, handles your requests. Turning it off removes Redde from Spotlight. With App Lock on, only conversation titles are searchable. “Hey Siri, ask Redde” (open and listen) works either way.")
        }
    }
}

struct MetricsSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            LabeledContent("Context window") {
                TextField("131072", value: $settings.contextWindow, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Metrics")
        } footer: {
            Text("Used for the “ctx %” figure when the backend can't report its window. A llama.cpp server reports it automatically.")
        }
    }
}

struct LockSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            Toggle("Require \(AppLock.biometryName)", isOn: Binding(
                get: { settings.requireBiometrics },
                set: { on in
                    if on { Task { settings.requireBiometrics = await AppLock.shared.enable() } }
                    else { settings.requireBiometrics = false }
                }))
            if settings.requireBiometrics {
                Picker("Lock after", selection: $settings.lockGraceSeconds) {
                    Text("Immediately").tag(0.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                    Text("1 hour").tag(3600.0)
                }
            }
        } header: {
            Text("Lock")
        } footer: {
            Text(settings.requireBiometrics
                ? "Redde locks when it's been in the background longer than this. The device passcode works as a fallback. Background Shortcuts runs aren't gated."
                : "Gate the app behind \(AppLock.biometryName). The phone holds the Hermes API key and the dashboard password.")
        }
    }
}

struct AboutSettings: View {
    @State private var copiedVersion = false

    var body: some View {
        Section("Privacy invariant") {
            Text("On-device speech recognition and synthesis. No analytics. Every request goes only to the servers you configured. The one exception is opt-in: with “Let Siri use Redde” on, Apple Intelligence handles what you say to Siri.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section {
            NavigationLink("Acknowledgements") { AcknowledgementsView() }
            Button {
                UIPasteboard.general.string = SettingsView.versionLine
                copiedVersion = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copiedVersion = false }
            } label: {
                LabeledContent("Version") {
                    Text(copiedVersion ? "Copied" : SettingsView.versionLine).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Copies the version for a bug report")
        }
    }
}

/// Back to a fresh install: conversations, attachments, credentials, settings, widget data.
struct ResetSettings: View {
    @Environment(Conversation.self) private var conversation
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        Section {
            Button("Erase everything…", role: .destructive) { confirming = true }
        } footer: {
            Text("Deletes every conversation and attachment on this device, forgets all servers, keys and passwords, and returns the settings to their defaults. Nothing on your servers is touched.")
        }
        .confirmationDialog("Erase everything on this device?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Erase everything", role: .destructive) { eraseEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Conversations, attachments, credentials and settings. This can't be undone.")
        }
    }

    private func eraseEverything() {
        HermesServeClient.shared.disconnect()
        conversation.eraseAll()
        AttachmentFiles.deleteAll()
        WebBlockHeights.clear()
        for item in [Keychain.Item.gatewayAPIKey, .serveDashboardPassword, .fastLaneAPIKey, .cfAccessClientSecret] {
            Keychain.delete(item)
        }
        WidgetSnapshot.clear()
        WidgetCenter.shared.reloadAllTimelines()
        Notifier.shared.clearDelivered()
        Settings.shared.reset()
        dismiss()
    }
}

/// A tiny two-bubble preview of a theme's palette.
/// The label of a collapsed settings group: its name, and the current choice on the trailing side.
struct DisclosureSummary<Value: View>: View {
    let title: String
    @ViewBuilder let value: Value

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            value.foregroundStyle(.secondary)
        }
    }
}

struct ThemeSwatch: View {
    let theme: ResolvedTheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.background ?? Color(.systemBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(theme.surface ?? Color(.secondarySystemBackground)).frame(width: 26, height: 8)
                Capsule().fill(theme.userBubble).frame(width: 20, height: 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(7)
        }
        .frame(width: 52, height: 40)
    }
}

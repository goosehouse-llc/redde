import SwiftUI

/// Settings › Notifications when Redde is closed: the Hermes machines this device is paired with,
/// and how to pair one. The same on an iPhone, an iPad and the Mac, each paired on its own (asked
/// 2026-10-30, "pair the mac and ipad for push"). It takes a plugin on the Hermes. An app with that Hermes's Dashboard login
/// can have Hermes install it and then pairs with one tap; any other is shown the command for a
/// terminal there, and scans the code the plugin's command shows.
struct PushSettingsView: View {
    @State private var push = PushService.shared
    @State private var settings = Settings.shared
    @State private var plugin = PushPluginModel(manager: PushSettingsView.pluginManager)
    @State private var scanning = false
    @State private var offer: PushOffer?
    @State private var pairingDirectly = false
    @State private var pasteProblem: String?
    @Environment(\.scenePhase) private var scenePhase

    /// The server the plugin is asked about: the Dashboard, or a stand-in (`-echo.demoPlugin`).
    static var pluginManager: any PushPluginManaging {
        #if DEBUG
        if let demo = DevHooks.value("-echo.demoPlugin") { return DemoPushPlugin(demo, needsRestart: DevHooks.has("restart")) }
        #endif
        return HermesServeClient.shared
    }

    static let installCommand = "hermes plugins install goosehouse-llc/redde/companion/hermes-plugin/redde-push --enable"
    static let pairCommand = "hermes redde-push pair"

    var body: some View {
        Form {
            Section {
                if push.pairings.isEmpty {
                    Text("Not paired with a Hermes yet.").foregroundStyle(.secondary)
                }
                ForEach(push.pairings) { pairing in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pairing.host.isEmpty ? "Hermes" : pairing.host)
                        (pairing.confirmed ? Text("Paired \(pairing.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                             : pairing.isPaired ? Text("Paired; its first notification hasn't arrived yet")
                             : Text("Waiting for its first notification"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { Task { await push.unpair(pairing) } }
                    }
                    #if os(macOS)
                    // A Mac list's rows have no swipe to speak of: their menu.
                    .contextMenu {
                        Button("Remove", role: .destructive) { Task { await push.unpair(pairing) } }
                    }
                    #endif
                }
            } header: {
                Text("Paired")
            } footer: {
                Text(Self.pairedFooter)
            }

            Section {
                if Self.canAskDashboard {
                    ReddePluginRow(plugin: plugin, serverName: serverName)
                } else {
                    CommandRow(title: "On the machine that runs Hermes, install the plugin, then restart Hermes", command: Self.installCommand)
                }
                if signedInToDashboard {
                    // Signed in to that Hermes's Dashboard: the two can agree on the key over it.
                    Button { pairingDirectly = true } label: {
                        Label(serverName.map { String(localized: "Pair with \($0)") } ?? String(localized: "Pair with this Hermes"), systemImage: "bell.badge")
                    }
                    DisclosureGroup("Pair with a code instead") { byCode }
                } else {
                    byCode
                }
            } header: {
                Text("Pair a Hermes")
            } footer: {
                Text(String(localized: "What a notification says is encrypted on your Hermes and opened on this device, with a key the two agree on when you pair. On the way it passes through a relay run by Goosehouse and through Apple; neither can read it. The relay keeps this device's notification address so it can deliver, and never has the key. Removing a pairing deletes the address there.", comment: "Footer under Pair a Hermes, in Settings › Notifications › Notify when Redde is closed"))
            }
        }
        .navigationTitle("When Redde is closed")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $scanning) {
            CodeScanner(title: "Scan a pairing code", prompt: "Point the camera at the code in your terminal.",
                        wrong: "That isn't a Redde pairing code.",
                        denied: "Allow the camera for Redde in Settings to scan the pairing code, or paste the pairing link instead.") { text in
                guard let found = PushOffer(text: text) else { return false }
                // Once the scanner has gone: a sheet can't come up over one that is leaving.
                Task { try? await Task.sleep(for: .milliseconds(450)); offer = found }
                return true
            }
        }
        .task { if Self.canAskDashboard { await plugin.refresh() } }
        .sheet(item: $offer, onDismiss: { push.reload() }) { PushPairingSheet(offer: $0) }
        .sheet(isPresented: $pairingDirectly, onDismiss: { push.reload() }) { PushPairingSheet(offer: nil, server: serverName) }
        .onAppear { push.reload() }
        .onChange(of: scenePhase) { push.reload() }
    }

    /// What pairing does, under the pairings: the same everywhere but how a pairing is removed.
    private static var pairedFooter: String {
        #if os(macOS)
        String(localized: "While Redde is running it notifies you itself. Once it is closed, a paired Hermes does: it tells this Mac when a reply is ready, when the agent waits for you (an approval, a question, a password) and when it couldn't reply, for conversations you have taken part in from here, and brings your agents' ideas, briefings and heads-ups. Pair each iPhone, iPad and Mac you want them on. Control-click a pairing to remove it.", comment: "Footer under the paired Hermes machines on the Mac, in Settings › Notifications › Notify when Redde is closed")
        #else
        String(localized: "While Redde is running it notifies you itself. Once it is closed, a paired Hermes does: it tells this device when a reply is ready, when the agent waits for you (an approval, a question, a password) and when it couldn't reply, for conversations you have taken part in from here, and brings your agents' ideas, briefings and heads-ups. Pair each iPhone, iPad and Mac you want them on. Swipe a pairing to remove it.", comment: "Footer under the paired Hermes machines on an iPhone or an iPad, in Settings › Notifications › Notify when Redde is closed")
        #endif
    }

    /// There is a Dashboard login to ask about the plugin with, whichever connection chats use.
    static var canAskDashboard: Bool {
        #if DEBUG
        if DevHooks.value("-echo.demoPlugin") != nil { return true }
        #endif
        return HermesServeClient.shared.hasCredentials
    }

    /// The plugin's state in a line.
    static func pluginLine(_ state: PushPlugin.State, restart: Bool) -> String {
        guard state.installed else { return String(localized: "The plugin isn't on this Hermes yet.") }
        // A space and the version, or nothing.
        let version = state.version.map { " \($0)" } ?? ""
        if restart { return String(localized: "The plugin\(version) is installed.", comment: "The placeholder is a space and the plugin's version, or nothing") }
        if !state.enabled { return String(localized: "The plugin\(version) is installed, but switched off.", comment: "The placeholder is a space and the plugin's version, or nothing") }
        if state.isOutdated { return String(localized: "The plugin\(version) is installed; this Redde goes with \(PushPlugin.version).", comment: "The first placeholder is a space and the plugin's version, or nothing") }
        return String(localized: "The plugin\(version) is on this Hermes.", comment: "The placeholder is a space and the plugin's version, or nothing")
    }

    /// The connection the app is on is a Dashboard it has a login for. Over the Hermes API there
    /// is no way to reach the plugin, and the code is how to pair. (Ahead of Your Day asks too.)
    static var signedInToDashboard: Bool {
        Settings.shared.transport == .hermesServe && HermesServeClient.shared.hasCredentials
    }

    private var signedInToDashboard: Bool { settings.transport == .hermesServe && Self.signedInToDashboard }

    private var serverName: String? {
        settings.activeServer.flatMap { $0.name.isEmpty ? nil : $0.name }
    }

    /// Pairing by the code the plugin's command shows: the way for an app on the Hermes API, and
    /// for a phone that isn't signed in to the Hermes it is being paired with.
    @ViewBuilder
    private var byCode: some View {
        CommandRow(title: "Run the pairing command on that machine", command: Self.pairCommand)
        if CodeScanner.isSupported {
            Button { scanning = true } label: { Label("Scan the code it shows", systemImage: "qrcode.viewfinder") }
        }
        Button { paste() } label: { Label("Paste the pairing link", systemImage: "doc.on.clipboard") }
        if let pasteProblem {
            Text(pasteProblem).font(.footnote).foregroundStyle(.red)
        }
    }

    private func paste() {
        guard let found = UIPasteboard.general.string.flatMap(PushOffer.init(text:)) else {
            pasteProblem = String(localized: "There is no pairing link on the clipboard. Copy the link the pairing command shows, then try again.")
            return
        }
        pasteProblem = nil
        offer = found
    }
}

/// One step of the instructions: what to do, and the command to copy.
struct CommandRow: View {
    var title: LocalizedStringKey
    var command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            HStack(alignment: .firstTextBaseline) {
                Text(command)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
                    UIPasteboard.general.string = command
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? String(localized: "Copied") : String(localized: "Copy the command"))
            }
        }
    }
}

/// A pairing link was scanned, pasted or opened, or "Pair with this Hermes" was tapped (no offer:
/// it is asked for over the Dashboard): say what pairing means, and do it only once the person
/// agrees. Then wait for the Hermes at the other end to send its first notification, which is the
/// proof that its notes reach this device.
struct PushPairingSheet: View {
    var offer: PushOffer?
    var server: String?

    /// `quiet`: the Hermes has this phone, but nothing has arrived from it yet.
    private enum Stage: Equatable { case asking, working, waiting, done(String), quiet(String), failed(String) }

    @State private var stage = Stage.asking
    @State private var work: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(tint)
                    .padding(.top, 28)
                Text(headline).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if stage == .working || stage == .waiting { ProgressView() }
                Spacer()
                switch stage {
                case .asking:
                    Button { pair() } label: { Text("Pair").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                case .failed:
                    Button { pair() } label: { Text("Try Again").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                case .done, .quiet:
                    Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                case .working, .waiting:
                    EmptyView()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .navigationTitle("Pair with your Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    switch stage {
                    case .done, .quiet: EmptyView()
                    default: Button("Cancel") { work?.cancel(); dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(stage == .working)
    }

    private var symbol: String {
        switch stage {
        case .done: "checkmark.circle.fill"
        case .failed, .quiet: "exclamationmark.triangle.fill"
        default: "bell.badge.fill"
        }
    }

    private var tint: Color {
        switch stage {
        case .done: .green
        case .failed, .quiet: .orange
        default: .accentColor
        }
    }

    private var headline: String {
        switch stage {
        case .asking: server.map { String(localized: "Get notifications from \($0)?") } ?? String(localized: "Get notifications from this Hermes?")
        case .working: String(localized: "Pairing…")
        case .waiting: String(localized: "Waiting for your Hermes…")
        case .done(let host): host.isEmpty ? String(localized: "Paired") : String(localized: "Paired with \(host)")
        case .quiet(let host): host.isEmpty ? String(localized: "Paired, but nothing has arrived") : String(localized: "Paired with \(host), but nothing has arrived")
        case .failed: String(localized: "Pairing didn't finish")
        }
    }

    private var detail: String {
        switch stage {
        case .asking:
            String(localized: "It will tell this device when a reply is ready, when the agent waits for you and when it couldn't reply, also when Redde is closed. Notifications are encrypted between that Hermes and this device; the relay that carries them can't read them.", comment: "Pairing sheet: what pairing this device with a Hermes does")
        case .working: offer == nil ? String(localized: "Registering this device and asking your Hermes.", comment: "Pairing sheet, while pairing over the Dashboard")
            : String(localized: "Registering this device and answering the code.", comment: "Pairing sheet, while pairing with a scanned or pasted code")
        case .waiting: String(localized: "It should send a notification within a few seconds.")
        case .done: String(localized: "You will be notified here when that Hermes finishes a reply, waits for you, or couldn't reply.")
        case .quiet:
            String(localized: "Your Hermes has this device, but its first notification hasn't arrived. It may not be able to reach the notification relay. On that machine, hermes redde-push test sends another.", comment: "Pairing sheet: paired, but no notification came")
        case .failed(let reason): reason
        }
    }

    private func pair() {
        stage = .working
        work = Task {
            do {
                let pairing = if let offer { try await PushService.shared.pair(offer) } else { try await PushService.shared.pairDirectly() }
                stage = .waiting
                if await PushService.shared.waitUntilConfirmed(pairing) {
                    stage = .done(PushService.shared.pairings.first { $0.id == pairing.id }?.host ?? "")
                } else if Task.isCancelled {
                    return
                } else if pairing.isPaired {
                    stage = .quiet(pairing.host)   // over the Dashboard the plugin has already said yes
                } else {
                    stage = .failed(String(localized: "This device answered the code, but that Hermes hasn't sent anything back. The pairing command may have ended: run it again and use the new code.", comment: "Pairing sheet: the plugin never confirmed a pairing made with a code"))
                }
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}

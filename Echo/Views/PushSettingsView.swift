import SwiftUI

/// Settings › Notifications when Redde is closed: the Hermes machines this iPhone is paired with,
/// and how to pair one. The plugin on the Hermes is the person's own to install. After that, an
/// app signed in to that Hermes's Dashboard pairs with one tap; any other scans the code the
/// plugin's command shows.
struct PushSettingsView: View {
    @State private var push = PushService.shared
    @State private var settings = Settings.shared
    @State private var scanning = false
    @State private var offer: PushOffer?
    @State private var pairingDirectly = false
    @State private var pasteProblem: String?
    @Environment(\.scenePhase) private var scenePhase

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
                        Text(pairing.confirmed ? "Paired \(pairing.pairedAt.formatted(date: .abbreviated, time: .omitted))"
                             : pairing.isPaired ? "Paired; its first notification hasn't arrived yet"
                             : "Waiting for its first notification")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { Task { await push.unpair(pairing) } }
                    }
                }
            } header: {
                Text("Paired")
            } footer: {
                Text("While Redde is running it notifies you itself. Once iOS has closed it, a paired Hermes does: it tells this iPhone when a reply is ready or a command waits for your approval, for conversations you have taken part in from here. Swipe a pairing to remove it.")
            }

            Section {
                CommandRow(title: "On the machine that runs Hermes, install the plugin, then restart Hermes", command: Self.installCommand)
                if signedInToDashboard {
                    // Signed in to that Hermes's Dashboard: the two can agree on the key over it.
                    Button { pairingDirectly = true } label: {
                        Label(serverName.map { "Pair with \($0)" } ?? "Pair with this Hermes", systemImage: "bell.badge")
                    }
                    DisclosureGroup("Pair with a code instead") { byCode }
                } else {
                    byCode
                }
            } header: {
                Text("Pair a Hermes")
            } footer: {
                Text("What a notification says is encrypted on your Hermes and opened on this iPhone, with a key the two agree on when you pair. On the way it passes through a relay run by Goosehouse and through Apple; neither can read it. The relay keeps this iPhone's notification address so it can deliver, and never has the key. Removing a pairing deletes the address there.")
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
        .sheet(item: $offer, onDismiss: { push.reload() }) { PushPairingSheet(offer: $0) }
        .sheet(isPresented: $pairingDirectly, onDismiss: { push.reload() }) { PushPairingSheet(offer: nil, server: serverName) }
        .onAppear { push.reload() }
        .onChange(of: scenePhase) { push.reload() }
    }

    /// The connection the app is on is a Dashboard it has a login for. Over the Hermes API there
    /// is no way to reach the plugin, and the code is how to pair.
    private var signedInToDashboard: Bool {
        settings.transport == .hermesServe && HermesServeClient.shared.hasCredentials
    }

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
            pasteProblem = "There is no pairing link on the clipboard. Copy the link the pairing command shows, then try again."
            return
        }
        pasteProblem = nil
        offer = found
    }
}

/// One step of the instructions: what to do, and the command to copy.
private struct CommandRow: View {
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
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = command
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Copied" : "Copy the command")
            }
        }
    }
}

/// A pairing link was scanned, pasted or opened, or "Pair with this Hermes" was tapped (no offer:
/// it is asked for over the Dashboard): say what pairing means, and do it only once the person
/// agrees. Then wait for the Hermes at the other end to send its first notification, which is the
/// proof that its notes reach this iPhone.
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
        case .asking: server.map { "Get notifications from \($0)?" } ?? "Get notifications from this Hermes?"
        case .working: "Pairing…"
        case .waiting: "Waiting for your Hermes…"
        case .done(let host): host.isEmpty ? "Paired" : "Paired with \(host)"
        case .quiet(let host): host.isEmpty ? "Paired, but nothing has arrived" : "Paired with \(host), but nothing has arrived"
        case .failed: "Pairing didn't finish"
        }
    }

    private var detail: String {
        switch stage {
        case .asking:
            "It will tell this iPhone when a reply is ready or a command waits for your approval, also when Redde is closed. Notifications are encrypted between that Hermes and this iPhone; the relay that carries them can't read them."
        case .working: offer == nil ? "Registering this iPhone and asking your Hermes." : "Registering this iPhone and answering the code."
        case .waiting: "It should send a notification within a few seconds."
        case .done: "You will be notified here when that Hermes finishes a reply or needs an approval."
        case .quiet:
            "Your Hermes has this iPhone, but its first notification hasn't arrived. It may not be able to reach the notification relay. On that machine, hermes redde-push test sends another."
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
                    stage = .failed("This iPhone answered the code, but that Hermes hasn't sent anything back. The pairing command may have ended: run it again and scan the new code.")
                }
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}

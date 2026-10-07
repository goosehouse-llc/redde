import SwiftUI

/// Settings › Notifications when Redde is closed: the Hermes machines this iPhone is paired with,
/// and how to pair one. Pairing is the person's own doing from start to finish: they install a
/// plugin on their Hermes, run its command, and scan the code it shows.
struct PushSettingsView: View {
    @State private var push = PushService.shared
    @State private var scanning = false
    @State private var offer: PushOffer?
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
                CommandRow(title: "Run the pairing command there", command: Self.pairCommand)
                if CodeScanner.isSupported {
                    Button { scanning = true } label: { Label("Scan the code it shows", systemImage: "qrcode.viewfinder") }
                }
                Button { paste() } label: { Label("Paste the pairing link", systemImage: "doc.on.clipboard") }
                if let pasteProblem {
                    Text(pasteProblem).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Pair a Hermes")
            } footer: {
                Text("What a notification says is encrypted on your Hermes and opened on this iPhone, with a key the two agree on when you scan the code. On the way it passes through a relay run by Goosehouse and through Apple; neither can read it. The relay keeps this iPhone's notification address so it can deliver, and never has the key. Removing a pairing deletes the address there.")
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
        .onAppear { push.reload() }
        .onChange(of: scenePhase) { push.reload() }
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

/// A pairing link was scanned, pasted or opened: say what pairing means, and do it only once the
/// person agrees. Then wait for the Hermes at the other end to send its first notification, which
/// is the proof that both ends hold the same key.
struct PushPairingSheet: View {
    var offer: PushOffer

    private enum Stage: Equatable { case asking, working, waiting, done(String), failed(String) }

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
                case .done:
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
                    if case .done = stage {} else { Button("Cancel") { work?.cancel(); dismiss() } }
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(stage == .working)
    }

    private var symbol: String {
        switch stage {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "bell.badge.fill"
        }
    }

    private var tint: Color {
        switch stage {
        case .done: .green
        case .failed: .orange
        default: .accentColor
        }
    }

    private var headline: String {
        switch stage {
        case .asking: "Get notifications from this Hermes?"
        case .working: "Pairing…"
        case .waiting: "Waiting for your Hermes…"
        case .done(let host): host.isEmpty ? "Paired" : "Paired with \(host)"
        case .failed: "Pairing didn't finish"
        }
    }

    private var detail: String {
        switch stage {
        case .asking:
            "It will tell this iPhone when a reply is ready or a command waits for your approval, also when Redde is closed. Notifications are encrypted between that Hermes and this iPhone; the relay that carries them can't read them."
        case .working: "Registering this iPhone and answering the code."
        case .waiting: "It should send a notification within a few seconds."
        case .done: "You will be notified here when that Hermes finishes a reply or needs an approval."
        case .failed(let reason): reason
        }
    }

    private func pair() {
        stage = .working
        work = Task {
            do {
                let pairing = try await PushService.shared.pair(offer)
                stage = .waiting
                if await PushService.shared.waitUntilConfirmed(pairing) {
                    stage = .done(PushService.shared.pairings.first { $0.id == pairing.id }?.host ?? "")
                } else if !Task.isCancelled {
                    stage = .failed("This iPhone answered the code, but that Hermes hasn't sent anything back. The pairing command may have ended: run it again and scan the new code.")
                }
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}

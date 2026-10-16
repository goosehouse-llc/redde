import SwiftTerm
import SwiftUI
import UIKit

/// A terminal on the Hermes server, over SSH (`SSHShell`), full screen: from a chat's More menu
/// in the chat's own folder, or from Settings › Terminal at home. The keyboard's bar above the
/// keys is SwiftTerm's: Esc, Ctrl, Tab, the arrows and the symbols a shell wants.
struct TerminalScreen: View {
    /// Where the shell starts; nil asks `folderLookup`, and with nothing there, home.
    var folder: String?
    var folderLookup: (() async -> String?)?

    @Environment(\.dismiss) private var dismiss
    @State private var model = TerminalModel()
    @State private var settings = Settings.shared
    @State private var account = TerminalAccount(host: "", user: "")
    @State private var startFolder: String?

    var body: some View {
        NavigationStack {
            ZStack {
                TerminalSurface(model: model)
                    .padding(.horizontal, 6)
                    .opacity(model.showsScreen ? 1 : 0)
                    .ignoresSafeArea(.container, edges: .bottom)
                if !model.showsScreen || model.ended != nil { statusCard }
            }
            .navigationTitle(model.showsScreen ? model.title : "Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { model.close(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Reconnect", systemImage: "arrow.clockwise") { connect() }
                            .disabled(model.phase == .connecting || !account.isComplete)
                        Button("Copy This iPhone's Key", systemImage: "key") { UIPasteboard.general.string = SSHIdentity.publicKeyLine }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
        }
        // Only the buttons answer: a dismissal that came before the button's action would lose a yes.
        .alert("Trust this server?", isPresented: Binding(get: { model.askingTrust != nil }, set: { _ in })) {
            Button("Trust") { model.answerTrust(true) }
            Button("Cancel", role: .cancel) { model.answerTrust(false) }
        } message: {
            Text("This is the first time this iPhone connects to \(account.host). Its key's fingerprint is \(model.askingTrust ?? ""). "
                 + "If you can, check it on the server with ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub.")
        }
        .task {
            account = TerminalAccount.saved(server: settings.activeServerID.uuidString)
                ?? TerminalAccount(host: TerminalAccount.suggestedHost(serve: settings.serveBaseURL, gateway: settings.gatewayBaseURL), user: "")
            startFolder = folder
            if startFolder == nil, let folderLookup { startFolder = await folderLookup() }
            if account.isComplete { connect() } else { model.phase = .needsAccount }
        }
        .onDisappear { model.close() }
    }

    private func connect() {
        let target = SSHShell.Target(host: account.host.trimmingCharacters(in: .whitespaces), port: account.port,
                                     user: account.user.trimmingCharacters(in: .whitespaces), folder: startFolder)
        Task { await model.connect(target) }
    }

    /// What the screen shows while there is no shell: the account to fill in, connecting, why it
    /// failed (with this iPhone's key when the server didn't know it), or that the shell ended.
    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .needsAccount:
                ScrollView { TerminalAccountForm(account: $account, onConnect: connect) }
            case .connecting:
                ProgressView("Connecting to \(account.host)…")
            case .failed(let problem):
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(problem.message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        if problem.wantsKey { TerminalKeyCard(user: account.user, host: account.host) }
                        HStack {
                            Button("Try Again", action: connect).buttonStyle(.borderedProminent)
                            Button("Edit Account") { model.phase = .needsAccount }
                        }
                    }
                    .padding()
                }
            case .live:
                if let ended = model.ended {
                    VStack(spacing: 10) {
                        Text(ended).font(.footnote).foregroundStyle(.secondary)
                        Button("Reconnect", action: connect).buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 14))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: 560)
    }
}

/// Host, port and user for the active Hermes server's SSH, and this iPhone's key. Saved as typed.
/// What is still missing is said under the fields, and connecting with it missing goes to it.
struct TerminalAccountForm: View {
    @Binding var account: TerminalAccount
    var onConnect: (() -> Void)?
    /// Bumped by a parent's own connect button when something is missing: the form goes to it.
    var askedToConnect = 0
    @State private var settings = Settings.shared
    @FocusState private var field: Field?

    enum Field { case host, port, user }

    /// The first thing still needed, and how to say it.
    private var missing: (field: Field, words: String)? {
        if account.host.trimmingCharacters(in: .whitespaces).isEmpty { return (.host, "the server's host name") }
        if !(1 ... 65535).contains(account.port) { return (.port, "a port (22, unless your server uses another)") }
        if account.user.trimmingCharacters(in: .whitespaces).isEmpty {
            return (.user, "the user: the account you log in to on the server, such as hermes")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to your server over SSH, with a key made on this iPhone. Passwords aren't used.")
                .font(.subheadline).foregroundStyle(.secondary)
            Group {
                LabeledContent("Host") {
                    TextField("hermes.example.ts.net", text: $account.host).multilineTextAlignment(.trailing)
                        .focused($field, equals: .host)
                }
                LabeledContent("Port") {
                    TextField("22", value: $account.port, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .focused($field, equals: .port)
                }
                LabeledContent("User") {
                    TextField("required, such as hermes", text: $account.user).multilineTextAlignment(.trailing)
                        .focused($field, equals: .user)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.none)
            if let missing {
                Label("To connect, fill in \(missing.words).", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            TerminalKeyCard(user: account.user, host: account.host)
            if let onConnect {
                Button("Connect") {
                    if let missing { field = missing.field } else { onConnect() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onChange(of: account) { TerminalAccount.save(account, server: settings.activeServerID.uuidString) }
        .onChange(of: askedToConnect) { if let missing { field = missing.field } }
    }
}

/// This iPhone's public key, to copy into the server's authorized_keys.
struct TerminalKeyCard: View {
    var user: String
    var host: String
    @State private var line: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This iPhone's key").font(.subheadline.weight(.semibold))
            Text(line ?? "Unlock this iPhone to make its key.")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
            HStack {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = line
                    copied = true
                }
                .disabled(line == nil)
                if let line { ShareLink(item: line) { Label("Share", systemImage: "square.and.arrow.up") } }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Text("Add it as one line to ~/.ssh/authorized_keys for \(user.isEmpty ? "that user" : user) on \(host.isEmpty ? "the server" : host). The key was made on this iPhone and never leaves it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .task { line = SSHIdentity.publicKeyLine }
    }
}

/// The shell's state, for the screen and the terminal view inside it.
@Observable
final class TerminalModel {
    enum Phase: Equatable {
        case needsAccount
        case connecting
        case failed(Failure)
        case live
    }

    struct Failure: Equatable {
        var message: String
        /// The server didn't know this iPhone's key: show it, to copy across.
        var wantsKey: Bool
    }

    var phase: Phase = .connecting
    var title = "Terminal"
    /// Why the shell ended, once it has; the screen stays readable under the note.
    var ended: String?
    /// A server met for the first time: its fingerprint, until the person answers. Nothing is
    /// connected meanwhile; a yes trusts that key and connects again.
    private(set) var askingTrust: String?
    private var asked: SSHShell.Target?
    private var shell: SSHShell?
    private var reading: Task<Void, Never>?
    @ObservationIgnored weak var view: SwiftTerm.TerminalView?

    var showsScreen: Bool { phase == .live }

    func connect(_ target: SSHShell.Target) async {
        close()
        phase = .connecting
        ended = nil
        title = "\(target.user)@\(target.host)"
        let terminal = view?.getTerminal()
        let columns = max(terminal?.cols ?? 80, 20), rows = max(terminal?.rows ?? 24, 5)
        do {
            let (shell, events) = try await SSHShell.open(target, columns: columns, rows: rows)
            self.shell = shell
            view?.getTerminal().resetToInitialState()
            phase = .live
            // The keyboard once the terminal is on screen: it was hidden until now.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                _ = self?.view?.becomeFirstResponder()
            }
            reading = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    switch event {
                    case let .output(bytes): self.view?.feed(byteArray: bytes[...])
                    case let .ended(why): self.ended = why
                    }
                }
            }
        } catch let SSHShell.Problem.unknownServer(fingerprint) {
            asked = target
            askingTrust = fingerprint
        } catch {
            let problem = error as? SSHShell.Problem
            phase = .failed(Failure(message: error.localizedDescription, wantsKey: problem == .keyNotAccepted))
        }
    }

    func answerTrust(_ yes: Bool) {
        guard let fingerprint = askingTrust, let target = asked else { return }
        askingTrust = nil
        asked = nil
        guard yes else {
            phase = .failed(Failure(message: "Not connected: the server's key wasn't trusted.", wantsKey: false))
            return
        }
        KnownHosts.trust(fingerprint, for: KnownHosts.name(host: target.host, port: target.port))
        Task { await connect(target) }
    }

    func send(_ bytes: [UInt8]) { shell?.send(bytes) }

    func resize(columns: Int, rows: Int) { shell?.resize(columns: columns, rows: rows) }

    func close() {
        reading?.cancel()
        reading = nil
        shell?.close()
        shell = nil
        askingTrust = nil
        asked = nil
    }
}

/// SwiftTerm's terminal view, fed by the model and typing into it.
struct TerminalSurface: UIViewRepresentable {
    let model: TerminalModel

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = .systemBackground
        view.nativeForegroundColor = .label
        view.accessibilityLabel = "Terminal"
        model.view = view
        return view
    }

    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, @MainActor TerminalViewDelegate {
        let model: TerminalModel

        init(model: TerminalModel) { self.model = model }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { model.send(Array(data)) }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { model.resize(columns: newCols, rows: newRows) }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { UIApplication.shared.open(url) }
        }
        func bell(source: SwiftTerm.TerminalView) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}

/// Settings › Terminal: the account, this iPhone's key, the trusted server key, and a way in.
struct TerminalSettingsView: View {
    @State private var settings = Settings.shared
    @State private var account = TerminalAccount(host: "", user: "")
    @State private var open = false
    @State private var trusted: String?
    @State private var confirmNewKey = false
    @State private var askedToConnect = 0
    /// Bumped when the key is replaced, so the card shows the new one.
    @State private var keyGeneration = 0

    private var knownName: String { KnownHosts.name(host: account.host.trimmingCharacters(in: .whitespaces), port: account.port) }

    var body: some View {
        List {
            Section {
                TerminalAccountForm(account: $account, askedToConnect: askedToConnect)
                    .id(keyGeneration)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                // Never silently off: with something missing, the form says what and goes to it.
                Button("Open Terminal", systemImage: "apple.terminal") {
                    if account.isComplete { open = true } else { askedToConnect += 1 }
                }
            }
            Section {
                if let trusted {
                    LabeledContent("Fingerprint") { Text(trusted).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    Button("Forget This Server's Key", role: .destructive) {
                        KnownHosts.forget(knownName)
                        self.trusted = nil
                    }
                } else {
                    Text("Not met yet: the first connection shows its key's fingerprint and asks.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Server's key")
            } footer: {
                Text("A server that shows another key later is refused, in case something is in the way. Forget the old one only if the server was reinstalled.")
            }
            Section {
                Button("Make a New Key for This iPhone", role: .destructive) { confirmNewKey = true }
            } footer: {
                Text("Servers that have the old key won't let this iPhone in until they have the new one.")
            }
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Make a new key?", isPresented: $confirmNewKey, titleVisibility: .visible) {
            Button("Make a New Key", role: .destructive) { SSHIdentity.replace(); keyGeneration += 1 }
        }
        .task {
            account = TerminalAccount.saved(server: settings.activeServerID.uuidString)
                ?? TerminalAccount(host: TerminalAccount.suggestedHost(serve: settings.serveBaseURL, gateway: settings.gatewayBaseURL), user: "")
        }
        .onChange(of: knownName, initial: true) { trusted = KnownHosts.trusted(knownName) }
        .fullScreenCover(isPresented: $open, onDismiss: { trusted = KnownHosts.trusted(knownName) }) { TerminalScreen() }
    }
}

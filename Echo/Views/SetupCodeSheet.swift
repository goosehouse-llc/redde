import SwiftUI

/// A setup code that arrived (a link opened, a QR code scanned, a link pasted), shown before
/// anything is saved: what it sets and where requests will go. The button saves it, tests the
/// connection and says how that went.
struct SetupCodeSheet: View {
    let offer: SetupCodeOffer
    /// Shown from Setup, which is the place to correct a connection: no "Edit connection" here.
    var offersEditing = true
    var onFinish: (Finish) -> Void = { _ in }

    enum Finish: Equatable {
        case cancelled
        /// Saved; `connected` says whether the connection test passed.
        case saved(connected: Bool)
    }

    private enum Stage: Equatable {
        case review
        case testing
        case tested(ConnectionTester.Outcome)
    }

    @Environment(Conversation.self) private var conversation
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var stage = Stage.review
    @State private var receipt: SetupCode.Receipt?
    /// What saving will change, worked out once when the sheet opens (it asks the Keychain).
    @State private var plan: SetupCode.Plan?
    /// Whether first-run setup was over before the code, for taking the code back out.
    @State private var wasSetupDone = false
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            Form {
                switch offer.result {
                case .failure(let problem):
                    Section {
                        Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                case .success(let code):
                    if let plan {
                        contents(code, plan)
                        action(code, plan)
                    }
                }
            }
            .onAppear {
                if plan == nil, case .success(let code) = offer.result { plan = code.plan(for: settings) }
            }
            .navigationTitle("Setup code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .tested(let outcome) = stage {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { close(.saved(connected: outcome.isOK)) }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { close(.cancelled) }.disabled(stage == .testing)
                    }
                }
            }
            .interactiveDismissDisabled(stage != .review)
            .sheet(isPresented: $showSetup) {
                // Done or Skip in Setup closes this sheet with it.
                SetupView(onDone: { close(.saved(connected: settings.isConfigured)) })
            }
        }
    }

    // MARK: - What the code sets

    @ViewBuilder
    private func contents(_ code: SetupCode, _ plan: SetupCode.Plan) -> some View {
        if code.hasServer {
            Section {
                if !code.name.isEmpty { LabeledContent("Name", value: code.name) }
                if !code.dashboardURL.isEmpty {
                    row("Hermes Dashboard", code.dashboardURL,
                        note: [code.dashboardUser.isEmpty ? nil : "user \(code.dashboardUser)",
                               code.dashboardPassword.isEmpty ? "no password" : "password included"],
                        used: plan.transport == .hermesServe)
                }
                if !code.apiURL.isEmpty {
                    row("Hermes API", code.apiURL, note: [code.apiKey.isEmpty && code.profileKey.isEmpty ? "no key" : "key included"],
                        used: plan.transport == .hermesSessions)
                }
                if !code.profile.isEmpty { LabeledContent("Profile", value: code.profile) }
                if !code.accessID.isEmpty {
                    LabeledContent("Cloudflare Access", value: code.accessSecret.isEmpty ? "Client ID only" : "Service token included")
                }
            } header: {
                Text("Server")
            } footer: {
                if code.modelURL.isEmpty { footer(code, plan) }
            }
        }
        if !code.modelURL.isEmpty {
            Section {
                row("Address", code.modelURL, note: [code.modelKey.isEmpty ? nil : "key included"], used: plan.transport == .chatCompletions)
                if !code.model.isEmpty { LabeledContent("Model", value: code.model) }
            } header: {
                Text("OpenAI-compatible endpoint")
            } footer: {
                footer(code, plan)
            }
        }
    }

    /// An address in full (it is the thing to check), what comes with it, and a mark on the one
    /// the app will talk to.
    private func row(_ title: String, _ address: String, note: [String?], used: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                if used { Text("Redde will use this").font(.footnote).foregroundStyle(.tint) }
            }
            Text(address)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            let notes = note.compactMap { $0 }
            if !notes.isEmpty {
                Text(notes.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func footer(_ code: SetupCode, _ plan: SetupCode.Plan) -> some View {
        var lines: [String] = []
        switch plan.server {
        case .add:
            lines.append("This is added as a new server and Redde switches to it, which starts a new conversation. Your other servers stay as they are.")
            if let same = plan.sameAs { lines.append("You already have a server at this address (\(same)). This adds another.") }
        case .fill:
            lines.append("This sets up your server's connection.")
        case .none:
            break
        }
        if let replaced = plan.replacesModelURL {
            lines.append("The endpoint replaces the one you have now (\(URL(string: replaced)?.host() ?? replaced)), and that one's key is forgotten.")
        }
        lines.append("Only use a code from someone you trust: what you type and say is sent to these addresses.")
        return Text(lines.joined(separator: "\n\n"))
    }

    // MARK: - Saving it

    @ViewBuilder
    private func action(_ code: SetupCode, _ plan: SetupCode.Plan) -> some View {
        Section {
            switch stage {
            case .review:
                Button(plan.server == .add ? "Add server" : "Set up") { Task { await save(code) } }
                    .fontWeight(.semibold)
            case .testing:
                HStack {
                    Text("Testing the connection…")
                    Spacer()
                    ProgressView()
                }
                .foregroundStyle(.secondary)
            case .tested(let outcome):
                Label(outcome.message, systemImage: outcome.isOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(outcome.isOK ? .green : .red)
                if !outcome.isOK {
                    Button("Test again") { Task { await test() } }
                    if offersEditing { Button("Edit connection…") { showSetup = true } }
                    if receipt?.added != nil {
                        Button("Remove this server", role: .destructive) { remove() }
                    }
                }
            }
        } footer: {
            if case .tested(let outcome) = stage, !outcome.isOK {
                Text(code.hasSecrets
                     ? "The code is saved. If the address is only reachable on your home network or VPN, connect to that and test again."
                     : "The code is saved, but it came without a password or key. \(offersEditing ? "Add it under Edit connection." : "Tap Done and add it in the form.")")
            }
        }
    }

    private func save(_ code: SetupCode) async {
        wasSetupDone = settings.setupDone
        receipt = code.install(in: settings) { ServerSwitcher.switchTo($0, conversation: conversation) }
        HermesServeClient.shared.disconnect()
        if !settings.setupDone { settings.setupDone = true }
        WatchLink.shared.push()
        await test()
    }

    private func test() async {
        stage = .testing
        stage = .tested(await ConnectionTester.current(settings))
    }

    private func remove() {
        guard let receipt else { return }
        SetupCode.remove(receipt, from: settings) { ServerSwitcher.switchTo($0, conversation: conversation) }
        if settings.setupDone != wasSetupDone { settings.setupDone = wasSetupDone }
        HermesServeClient.shared.disconnect()
        WatchLink.shared.push()
        close(.cancelled)
    }

    private func close(_ finish: Finish) {
        onFinish(finish)
        dismiss()
    }
}

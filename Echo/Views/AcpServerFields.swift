import SwiftUI

/// The fields of an ACP connection (`Transport.acp`): where the Redde bridge is, its token, which
/// of its agents, and the folder new chats work in. Used by setup and by Settings.
struct AcpServerFields: View {
    @Bindable var settings: Settings
    /// A token typed and not yet stored.
    @Binding var token: String
    var hasToken: Bool
    @State private var agents: [AcpEndpoint.Agent] = []
    @State private var bridge: AcpClient.Info?

    /// The bridge's one-line install, in its README.
    static let installGuide = URL(string: "https://github.com/goosehouse-llc/redde/tree/main/companion/redde-bridge#install")!

    private var isDemo: Bool { settings.acpEndpoint?.isDemo == true }

    var body: some View {
        Section {
            if isDemo {
                LabeledContent(String(localized: "Agent", comment: "ACP connection field: which of the bridge's agents"),
                               value: String(localized: "Demo Agent", comment: "ACP: Redde's built-in demo agent"))
                Button(String(localized: "Use a Real Agent Instead", comment: "ACP setup: leave the demo agent for the bridge's fields")) {
                    settings.acpURL = ""
                }
            } else {
                TextField("ws://your-computer:8765", text: $settings.acpURL).urlFieldStyle()
                SecureField(hasToken ? String(localized: "Replace stored token", comment: "ACP connection field")
                                     : String(localized: "Token", comment: "ACP connection field: the Redde bridge's token"), text: $token)
                if agents.count > 1 || (agents.count == 1 && settings.acpAgent.isEmpty == false && agents[0].id != settings.acpAgent) {
                    Picker(String(localized: "Agent", comment: "ACP connection field: which of the bridge's agents"), selection: $settings.acpAgent) {
                        ForEach(agents) { Text($0.name).tag($0.id) }
                    }
                } else if agents.isEmpty {
                    TextField(String(localized: "Agent (claude, codex, hermes…)", comment: "ACP connection field"), text: $settings.acpAgent)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    LabeledContent(String(localized: "Agent", comment: "ACP connection field: which of the bridge's agents"), value: agents[0].name)
                }
                TextField(String(localized: "Folder on the computer (optional)", comment: "ACP connection field: where new chats work"), text: $settings.acpFolder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                // No computer to hand (App Review among them): Redde's own agent, in the app.
                if settings.acpURL.isEmpty {
                    Button(String(localized: "Try the Demo Agent", comment: "ACP setup: use Redde's built-in demo agent, which needs no computer")) {
                        settings.acpURL = AcpEndpoint.demoAddress
                        settings.acpAgent = ""
                        settings.acpFolder = ""
                    }
                    .accessibilityIdentifier("acp-try-demo")
                }
            }
        } header: {
            Text("Agent bridge", comment: "Setup and Settings: the ACP connection's section")
        } footer: {
            if isDemo {
                Text("The demo agent runs inside Redde, with no computer and no AI. It shows what Redde does with a coding agent: its steps, a file's changes, approvals, plans and questions, by chat or by voice.",
                     comment: "Setup and Settings: the ACP connection's footer for the demo agent")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install Redde's bridge on the computer with your agents (Claude Code, Codex, Gemini CLI, Goose, Hermes and others that speak ACP), then scan the code it shows. A server that speaks ACP itself, such as `goose serve`, works too.",
                         comment: "Setup and Settings: the ACP connection's footer")
                    Link(String(localized: "How to Install the Bridge", comment: "ACP setup: opens the bridge's install instructions"),
                         destination: Self.installGuide)
                }
            }
        }
        .task(id: "\(settings.acpURL)|\(token)|\(hasToken)") { await listAgents() }
        .task(id: settings.acpEndpoint) {
            let found = await AcpBridgeSection.look(settings.acpEndpoint)
            if !Task.isCancelled { bridge = found }
        }
        if let endpoint = settings.acpEndpoint, bridge != nil {
            AcpBridgeSection(endpoint: endpoint, info: $bridge)
        }
    }

    /// The bridge's agents, once the address and token reach it.
    private func listAgents() async {
        try? await Task.sleep(for: .milliseconds(400))   // not on every keystroke
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = AcpEndpoint.make(address: settings.acpURL, agent: "", token: typed.isEmpty ? Keychain.read(.acpToken) : typed, folder: nil),
              let found = try? await endpoint.agents(), !Task.isCancelled else { agents = []; return }
        agents = found
        if !found.isEmpty, !found.contains(where: { $0.id == settings.acpAgent }) { settings.acpAgent = found[0].id }
    }
}

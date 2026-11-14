import SwiftUI

/// The Redde bridge this app was built beside (companion/redde-bridge), for the Bridge section's
/// Update Available.
nonisolated enum AcpBridge {
    /// `VERSION` in redde_bridge.py; a test keeps the two the same.
    static let latest = "0.9.0"
    /// The installer's one line, for a bridge that can't update itself.
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/goosehouse-llc/redde/main/companion/redde-bridge/install.sh | sh"

    /// Numbered parts compared in order: 0.6.0 < 0.7.0 < 0.10.0.
    static func isOlder(_ version: String, than other: String = latest) -> Bool {
        func parts(_ text: String) -> [Int] { text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(version), b = parts(other)
        for i in 0 ..< max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// The bridge on the computer, under an ACP server's fields: its version and how it runs, and an
/// update when there's a newer one: from the app when it's installed as a service, otherwise the
/// installer's line to copy. Shown once the bridge has answered.
struct AcpBridgeSection: View {
    let endpoint: AcpEndpoint
    /// What the bridge said on `initialize` (`look(_:)`), kept by the fields above.
    @Binding var info: AcpClient.Info?
    @State private var phase: Phase = .idle
    @State private var copied = false

    private enum Phase: Equatable {
        case idle, updating, updated(String), failed(String)
    }

    var body: some View {
        if let info, let version = info.bridge {
            Section {
                LabeledContent(String(localized: "Version", comment: "ACP bridge section: the bridge's version"), value: version)
                if let service = info.service {
                    LabeledContent(String(localized: "Runs As", comment: "ACP bridge section: how the bridge runs on the computer"),
                                   value: service == "launchd" ? String(localized: "Login item (launchd)", comment: "ACP bridge section: installed on a Mac")
                                                               : String(localized: "User service (systemd)", comment: "ACP bridge section: installed on Linux"))
                }
                updateRows(version: version, updatable: info.updatable)
            } header: {
                Text("Bridge on the Computer", comment: "Setup and Settings: the ACP bridge's version and update section")
            } footer: {
                footer(version: version, updatable: info.updatable)
            }
        }
    }

    @ViewBuilder
    private func updateRows(version: String, updatable: Bool) -> some View {
        switch phase {
        case .updating:
            HStack {
                Text("Updating the bridge…", comment: "ACP bridge section: while the bridge updates and restarts")
                Spacer()
                ProgressView()
            }
        case .updated(let new):
            Label(String(localized: "Updated to \(new)", comment: "ACP bridge section: the bridge updated itself; the new version"),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .idle, .failed:
            if AcpBridge.isOlder(version) {
                if updatable {
                    Button(String(localized: "Update Bridge to \(AcpBridge.latest)", comment: "ACP bridge section: updates the bridge on the computer")) {
                        Task { await update() }
                    }
                    .accessibilityIdentifier("acp-update-bridge")
                } else {
                    Button(copied ? String(localized: "Copied", comment: "Shown after something was copied")
                                  : String(localized: "Copy Install Command", comment: "ACP bridge section: copies the installer's line, to update an older bridge")) {
                        UIPasteboard.general.string = AcpBridge.installCommand
                        copied = true
                    }
                }
            } else {
                LabeledContent(String(localized: "Update", comment: "ACP bridge section: whether the bridge is the newest"),
                               value: String(localized: "Up to date"))
            }
            if case .failed(let message) = phase {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private func footer(version: String, updatable: Bool) -> some View {
        if phase == .updating || !AcpBridge.isOlder(version) {
            EmptyView()
        } else if updatable {
            Text("The bridge downloads version \(AcpBridge.latest), checks it, and restarts. It waits while a reply is under way.",
                 comment: "ACP bridge section: under Update Bridge")
        } else {
            Text("Version \(AcpBridge.latest) is out. This bridge can't update itself: run the installer again on the computer (your token and settings stay).",
                 comment: "ACP bridge section: an older bridge, or one started by hand")
        }
    }

    /// The bridge's word on itself, from the shared link (or a new one). Nil for the demo agent, an
    /// agent that isn't behind a bridge, or one that can't be reached.
    static func look(_ endpoint: AcpEndpoint?) async -> AcpClient.Info? {
        guard let endpoint, !endpoint.isDemo else { return nil }
        try? await Task.sleep(for: .milliseconds(600))   // not on every keystroke
        guard !Task.isCancelled else { return nil }
        let client = AcpClient.client(for: endpoint)
        try? await client.ensureConnected()
        return client.info?.bridge == nil ? nil : client.info
    }

    private func update() async {
        phase = .updating
        let client = AcpClient.client(for: endpoint)
        do {
            guard let new = try await client.updateBridge() else {
                phase = .updated(info?.bridge ?? AcpBridge.latest)
                return
            }
            // It restarts in a second; its service brings it back within about ten.
            client.close()
            for _ in 0 ..< 20 {
                try? await Task.sleep(for: .seconds(2))
                if (try? await client.ensureConnected()) != nil, let fresh = client.info, fresh.bridge == new {
                    info = fresh
                    phase = .updated(new)
                    return
                }
                client.close()
            }
            phase = .failed(String(localized: "The bridge updated to \(new) but hasn't come back yet. Check it on the computer.",
                                   comment: "ACP bridge section: the bridge didn't restart after its update"))
        } catch let error as AcpError {
            phase = .failed(error.message)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

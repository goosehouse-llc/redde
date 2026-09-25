import SwiftUI

/// What the conversation list shows when the gateway can't be read: what's wrong in plain
/// words, the one thing that fixes it, fallbacks, and the raw error folded away.
struct ConnectionProblemCard: View {
    let message: String
    let retry: () -> Void
    let openSettings: () -> Void
    @State private var settings = Settings.shared
    @State private var showDetails = false
    @Environment(\.theme) private var theme

    private enum Kind { case login, key, unreachable, other }

    private var kind: Kind {
        let m = message.lowercased()
        if m.contains("username") || m.contains("password") || m.contains("login") || m.contains("401") { return .login }
        if m.contains("api key") || m.contains("apikey") { return .key }
        if m.contains("could not connect") || m.contains("offline") || m.contains("timed out")
            || m.contains("network") || m.contains("not be found") || m.contains("refused") { return .unreachable }
        return .other
    }

    private var symbol: String {
        switch kind {
        case .login, .key: "key"
        case .unreachable: "wifi.slash"
        case .other: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch kind {
        case .login: "Sign in to Redde serve"
        case .key: "Add your gateway key"
        case .unreachable: "Can't reach your gateway"
        case .other: "Couldn't load conversations"
        }
    }

    private var explanation: String {
        switch kind {
        case .login: "Your conversations live on the desktop gateway, and it needs your username and password before it will share them."
        case .key: "Redde needs the gateway's API key before it can read your conversations."
        case .unreachable: "Check that the gateway is running and that this phone is on your network or tailnet."
        case .other: "The gateway answered, but not in a way Redde understood."
        }
    }

    /// Fast lane talks to the model directly, so it works when the gateway doesn't.
    private var canUseFastLane: Bool {
        settings.transport != .chatCompletions && !settings.fastLaneURL.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .background(.orange.opacity(0.14), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.weight(.bold))
                Text(explanation).font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if kind == .login || kind == .key {
                Button(action: openSettings) {
                    Text(kind == .login ? "Add login" : "Add key").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            HStack(spacing: 8) {
                Button(action: retry) { Text("Try again").frame(maxWidth: .infinity) }
                if canUseFastLane {
                    Button { settings.transport = .chatCompletions } label: { Text("Use fast lane").frame(maxWidth: .infinity) }
                        .accessibilityHint("Talks to the model directly, without the gateway")
                } else if kind != .login, kind != .key {
                    Button(action: openSettings) { Text("Settings").frame(maxWidth: .infinity) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            DisclosureGroup("Details", isExpanded: $showDetails) {
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .font(.footnote)
            .tint(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 520, alignment: .leading)
        .background(theme.surface ?? Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

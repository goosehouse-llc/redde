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

    private enum Kind { case login, loginNowAsked, loginNoLongerAsked, addressRefused, key, profileKey, profileNotServed, profileMissing, unreachable, other }

    private var kind: Kind {
        let m = message.lowercased()
        // A named profile over the Hermes API: its own key, on a gateway that multiplexes profiles.
        if m.contains("multiplex_profiles") { return .profileNotServed }
        // The Dashboard's answer for a profile that was deleted or never existed on this server.
        if m.contains("profile '"), m.contains("does not exist") { return .profileMissing }
        // Redde's own messages, also as this phone's language words them (`TransportError`).
        func says(_ text: String) -> Bool { m.contains(text.lowercased()) }
        // The Dashboard's sign-in changed since the server was set up (`DashboardSignInChange`).
        if says(DashboardSignInChange.nowAsksText) { return .loginNowAsked }
        if says(DashboardSignInChange.noLongerAsksText) { return .loginNoLongerAsked }
        if says(DashboardSignInChange.addressRefusedText) { return .addressRefused }
        if m.contains("rejected the key") || says(TransportError.keyRejectedText) { return settings.profileName == nil ? .key : .profileKey }
        if says(TransportError.missingLoginText) { return .login }
        if says(TransportError.missingKeyText) || says(TransportError.addKeyText) { return .key }
        if m.contains("username") || m.contains("password") || m.contains("login") || m.contains("sign-in") || m.contains("401") { return .login }
        if m.contains("api key") || m.contains("apikey") { return .key }
        if m.contains("could not connect") || m.contains("offline") || m.contains("timed out")
            || m.contains("network") || m.contains("not be found") || m.contains("refused") { return .unreachable }
        return .other
    }

    private var symbol: String {
        switch kind {
        case .login, .loginNowAsked, .key, .profileKey: "key"
        case .loginNoLongerAsked: "lock.open"
        case .addressRefused: "network.slash"
        case .profileNotServed, .profileMissing: "person.2.slash"
        case .unreachable: "wifi.slash"
        case .other: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch kind {
        case .login: String(localized: "Sign in to the Hermes Dashboard")
        case .loginNowAsked: String(localized: "Your Hermes Dashboard asks for a login now", comment: "Connection problem card title: a Dashboard set up with no sign-in has one now")
        case .loginNoLongerAsked: String(localized: "Your Hermes Dashboard has no sign-in now", comment: "Connection problem card title: a Dashboard saved with a login no longer asks for one")
        case .addressRefused: String(localized: "Your Hermes Dashboard turned the address away", comment: "Connection problem card title: the Dashboard refused the host name it was reached at")
        case .key: String(localized: "Add your gateway key")
        case .profileKey: settings.profileName.map { String(localized: "Add the key for \($0)") } ?? String(localized: "Add the key for this profile")
        case .profileNotServed: String(localized: "This profile isn't available")
        case .profileMissing: settings.profileName.map { String(localized: "No “\($0)” profile on this server") } ?? String(localized: "No such profile on this server")
        case .unreachable: String(localized: "Can't reach your gateway")
        case .other: String(localized: "Couldn't load conversations")
        }
    }

    private var explanation: String {
        switch kind {
        case .login: String(localized: "Your conversations live on the desktop gateway, and it needs you to sign in before it will share them.")
        case .loginNowAsked: DashboardSignInChange.nowAsksText
        case .loginNoLongerAsked: DashboardSignInChange.noLongerAsksText + " " + DashboardFormMode.openWarning
        case .addressRefused: DashboardSignInChange.addressRefusedText
        case .key: String(localized: "Redde needs the gateway's API key before it can read your conversations.")
        case .profileKey: String(localized: "Each Hermes profile has its own API key (API_SERVER_KEY in the profile's .env). Enter it under Settings → Profile.")
        case .profileMissing: String(localized: "This server has no profile by that name; it may have been renamed or deleted. Pick another under Settings → Profile.")
        case .profileNotServed: String(localized: "The gateway doesn't serve this profile over the Hermes API. Turn on gateway.multiplex_profiles in its config, or switch back to Default under Settings → Profile.")
        case .unreachable: String(localized: "Check that the gateway is running and that this phone is on your network or tailnet.")
        case .other: String(localized: "The gateway answered, but not in a way Redde understood.")
        }
    }

    /// The fix lives in Settings, so it gets the prominent button.
    private var needsSettings: Bool { [.login, .loginNowAsked, .key, .profileKey, .profileNotServed, .profileMissing].contains(kind) }

    /// Fast lane talks to the model directly, so it works when the gateway doesn't.
    private var canUseFastLane: Bool {
        settings.transport != .chatCompletions && !settings.fastLaneURL.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol)
                .chatFont(.title2)
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .background(.orange.opacity(0.14), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).chatFont(.title3, weight: .bold)
                Text(explanation).chatFont(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if kind == .loginNoLongerAsked {
                // The fix itself, the person having just read what it means (asked 2026-10-30).
                Button {
                    Settings.shared.useDashboardWithoutLogin()
                    HermesServeClient.shared.signOut()
                    retry()
                } label: {
                    Text(String(localized: "Use without a login", comment: "Button: go on with a Dashboard that has no sign-in, forgetting any saved login"))
                        .foregroundStyle(theme.userText)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            if needsSettings {
                Button(action: openSettings) {
                    Text(kind == .login || kind == .loginNowAsked ? String(localized: "Add login")
                         : kind == .profileNotServed || kind == .profileMissing ? String(localized: "Change profile") : String(localized: "Add key"))
                        .foregroundStyle(theme.userText)   // readable on every theme's accent
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            HStack(spacing: 8) {
                Button(action: retry) { Text("Try again").frame(maxWidth: .infinity) }
                if canUseFastLane {
                    Button { settings.transport = .chatCompletions } label: { Text("Use the model directly").frame(maxWidth: .infinity) }
                        .accessibilityHint("Talks to the model directly, without the gateway")
                } else if !needsSettings {
                    Button(action: openSettings) { Text("Settings").frame(maxWidth: .infinity) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            DisclosureGroup("Details", isExpanded: $showDetails) {
                Text(message)
                    .chatFont(.caption, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .chatFont(.footnote)
            .tint(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 520, alignment: .leading)
        .background(theme.surfaceColor, in: .rect(cornerRadius: 20))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

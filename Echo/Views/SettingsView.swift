import SwiftUI

/// The settings form. Each section is its own view, so typing in one field re-evaluates that
/// section rather than the whole form. The two Keychain flags several sections gate on live here.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showSetup = false
    @State private var hasStoredKey = false
    @State private var hasServePassword = false
    /// Toggled whenever a secret is saved; drives the success haptic.
    @State private var secretSaved = false

    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                NameSettings()
                AppearanceSettings()
                TransportSettings(showSetup: $showSetup)
                ModelSettings()
                AgentSettings(canReachGateway: hasStoredKey || hasServePassword, canEditFiles: hasServePassword)
                Section {
                    NavigationLink {
                        ConnectionDetailsView(hasStoredKey: $hasStoredKey,
                                              hasServePassword: $hasServePassword, saved: $secretSaved)
                    } label: { Label("Connection details", systemImage: "key") }
                } footer: {
                    Text("URLs, keys and logins for every backend — including ones the current transport doesn't use. The serve login also unlocks file editing and agent-sent files on the sessions backend.")
                }
                VoiceSettings()
                if #available(iOS 27.0, *) { SiriSettings() }
                MetricsSettings()
                LockSettings()
                AboutSettings()
                ResetSettings()
            }
            .sheet(isPresented: $showSetup) { SetupView() }
            // Keychain reads once when the screen appears, not per parent render.
            .task {
                hasStoredKey = Keychain.read(.gatewayAPIKey) != nil
                hasServePassword = Keychain.read(.serveDashboardPassword) != nil
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sensoryFeedback(.success, trigger: secretSaved)
        }
    }
}

extension View {
    func urlFieldStyle() -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .textContentType(.URL)
    }
}

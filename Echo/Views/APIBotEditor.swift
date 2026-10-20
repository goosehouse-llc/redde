import SwiftUI

/// Add Bot on the Hermes API alone (no Dashboard login to list the server's): one of the server's
/// profiles, by its name. Hermes takes the API_SERVER_KEY in that profile's own .env at
/// /p/<profile>/, often the main key put there too: that is tried first, and a key of the
/// profile's own is asked for only when Hermes refuses it (`APIBots.add`).
struct APIBotEditor: View {
    var onAdded: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var profile = ""
    @State private var title = ""
    @State private var key = ""
    /// Hermes refused the main key: the profile has one of its own.
    @State private var needsKey = false
    @State private var checking = false
    @State private var problem: String?

    private var name: String { profile.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Profile name", text: $profile)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Name (optional)", text: $title)
                } footer: {
                    Text("A bot is one of your server's profiles: the name its folder has under ~/.hermes/profiles. Redde opens its chat, the one Hermes Desktop and the Dashboard show for it.")
                }
                Section {
                    SecureField(needsKey ? "API key" : "API key (only if it has its own)", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Its API key")
                } footer: {
                    Text("Hermes takes the API_SERVER_KEY in the profile's own .env (~/.hermes/profiles/<name>/.env). Put your main API key there and the name alone does here; Hermes 0.21.3 and later leave it out when they copy a profile. Hermes 0.21.5 and later serve every profile over the API; on 0.21.3 and earlier, set gateway.multiplex_profiles: true in config.yaml and restart the gateway.")
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Add Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if checking { ProgressView() } else {
                        Button("Add") { add() }
                            .disabled(name.isEmpty || (needsKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }
            }
        }
    }

    private func add() {
        checking = true
        problem = nil
        Task {
            defer { checking = false }
            do {
                try await APIBots.add(profile: name, title: title, key: key)
                onAdded()
                dismiss()
            } catch let error as APIBotProblem {
                if case .needsKey = error { needsKey = true }
                problem = error.errorDescription
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

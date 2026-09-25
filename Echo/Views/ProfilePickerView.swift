import SwiftUI

/// Which Hermes profile Redde talks to. The list comes from the dashboard (Dashboard login);
/// without it, a profile can be named by hand, which the Hermes API reaches at /p/<profile>/.
struct ProfilePickerView: View {
    @Environment(Conversation.self) private var conversation
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var profiles: [HermesServeClient.Profile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var typedName = ""
    @State private var profileKey = ""
    @State private var hasProfileKey = false
    /// The dashboard lists profiles; the Hermes API has no such endpoint.
    private let canList = HermesServeClient.shared.hasCredentials

    var body: some View {
        Form {
            Section {
                row(title: "Default", subtitle: "The server's main profile.", selected: settings.profileName == nil) {
                    choose(nil, home: "")
                }
                ForEach(profiles.filter { !$0.isDefault }) { profile in
                    row(title: profile.title, subtitle: profile.description?.nilIfEmpty, selected: settings.profileName == profile.name) {
                        choose(profile.name, home: profile.path)
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Chats, sessions, projects, skills, tools, cron jobs and the context and memory files follow the profile. The Kanban board is shared by every profile. Switching starts a new conversation.")
            }

            if !canList || error != nil {
                Section {
                    TextField("Profile name", text: $typedName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(chooseTyped)
                    Button("Use this profile", action: chooseTyped)
                        .disabled(typedName.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("By name")
                } footer: {
                    Text(canList
                         ? "Couldn't load the list, but you can still name a profile."
                         : "Add the Hermes Dashboard login in Connection details to pick from a list. Over the Hermes API, a profile other than Default needs gateway.multiplex_profiles turned on in the gateway's config.")
                }
            }

            if let name = settings.profileName {
                Section {
                    SecureField(hasProfileKey ? "Saved. Enter a new key to replace it" : "API key", text: $profileKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { saveKey(for: name) }
                    Button("Save key") { saveKey(for: name) }
                        .disabled(profileKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasProfileKey {
                        Button("Remove key", role: .destructive) {
                            Keychain.delete(account: Keychain.profileAccount(name))
                            hasProfileKey = false
                        }
                    }
                } header: {
                    Text("Hermes API key for \(name)")
                } footer: {
                    Text("Each profile has its own API_SERVER_KEY, in its .env file on the server, and the gateway needs gateway.multiplex_profiles turned on. Only the Hermes API needs this; the Dashboard login already covers every profile.")
                }
            }
        }
        .navigationTitle("Profile")
        .task { await load() }
        .onAppear { refreshKeyState() }
        .onChange(of: settings.hermesProfile) { refreshKeyState() }
    }

    private func row(title: String, subtitle: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    // Explicit colors: inside a button, the hierarchical styles resolve to the tint.
                    Text(title).foregroundStyle(Color.primary)
                    if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(Color.secondary).lineLimit(2) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func load() async {
        guard canList else { return }
        loading = true
        defer { loading = false }
        do {
            profiles = try await HermesServeClient.shared.profiles()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refreshKeyState() {
        hasProfileKey = settings.profileName.map { Keychain.read(account: Keychain.profileAccount($0)) != nil } ?? false
        profileKey = ""
    }

    private func saveKey(for name: String) {
        guard Keychain.write(account: Keychain.profileAccount(name), value: profileKey) else { return }
        profileKey = ""
        hasProfileKey = true
    }

    private func chooseTyped() {
        let name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        choose(name.lowercased() == "default" ? nil : name, home: "")
    }

    /// The open conversation belongs to the old profile, so a switch starts a fresh one.
    private func choose(_ name: String?, home: String) {
        if name != settings.profileName {
            settings.hermesProfile = name ?? ""
            settings.hermesProfileHome = name == nil ? "" : home
            conversation.reset()
        }
        // A named profile over the Hermes API may still need its key, entered on this screen.
        if name == nil || settings.transport != .hermesSessions || Keychain.read(account: Keychain.profileAccount(name ?? "")) != nil {
            dismiss()
        }
    }
}

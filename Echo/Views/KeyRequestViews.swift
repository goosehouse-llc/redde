import SwiftUI

// MARK: - In the chat

/// A key the agent asked for (`request_secret`), under its reply: which key, for which profile,
/// why, and the button that opens the card it is pasted into. The chat never holds the key.
struct KeyAskCard: View {
    let card: ReplyCard.KeyAsk
    @State private var requests = KeyRequests.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(card.name).chatFont(.subheadline, weight: .semibold, design: .monospaced)
            } icon: {
                Image(systemName: "key.fill").foregroundStyle(.tint)
            }
            if !card.why.isEmpty {
                Text(card.why).chatFont(.callout)
            }
            Text(card.profile == "default"
                 ? String(localized: "Goes into your main agent's .env, never into this chat.")
                 : String(localized: "Goes into \(card.profile)'s .env, never into this chat.",
                          comment: "Key request card in a chat: the key goes into a bot's settings file, by its profile name"))
                .chatFont(.caption)
                .foregroundStyle(.secondary)
            Button {
                requests.show(id: card.id)
            } label: {
                FilledButtonTitle(title: String(localized: "Add Key…")).frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .disabled(requests.loading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
    }
}

// MARK: - The card the key is pasted into

/// One request: who asks, for what, where it goes, and a field the key is pasted into. Save seals
/// it to the request and hands it to the plugin; the field's text is dropped the moment it's sent.
struct KeyRequestSheet: View {
    let request: KeyRequest
    @State private var requests = KeyRequests.shared
    @State private var pasted = ""
    @State private var working = false
    @State private var problem: String?
    @State private var outcome: KeyRequests.Outcome?
    @State private var restarted: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(request.name).font(.title3.weight(.semibold).monospaced()).textSelection(.enabled)
                        if !request.why.isEmpty { Text(request.why) }
                    }
                    .padding(.vertical, 4)
                    LabeledContent(String(localized: "Goes into"), value: request.destination)
                    if request.replace {
                        Label(String(localized: "There's a key by this name already. Saving replaces it."), systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("\(request.who) asks for a key", comment: "Key request card: heading, by the agent that asks")
                }

                if let outcome {
                    Section {
                        switch outcome {
                        case .set(let name):
                            Label(String(localized: "\(name) is saved. Hermes reads it on its next restart.", comment: "Key request card: saved, by the key's name"),
                                  systemImage: "checkmark.circle.fill")
                            if let restarted {
                                Text(restarted).foregroundStyle(.secondary)
                            } else {
                                Button(String(localized: "Restart Hermes Now")) { restart() }.disabled(working)
                            }
                        case .declined:
                            Label(String(localized: "Declined. The agent is told, and nothing was saved."), systemImage: "xmark.circle")
                        }
                    }
                } else {
                    Section {
                        SecureField(String(localized: "Paste the key"), text: $pasted)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .submitLabel(.done)
                            .onSubmit { save() }
                            .disabled(working || requests.canAnswer == false)
                    } footer: {
                        Text(requests.canAnswer == false
                             ? KeyRequestError.noDashboard.errorDescription ?? ""
                             : String(localized: "It goes sealed to your Hermes and straight into that file. It's never shown in a chat, sent to a model, or kept on this device."))
                    }
                    if let problem {
                        Section { Text(problem).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(String(localized: "Key Asked For"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if outcome == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Decline"), role: .destructive) { decline() }.disabled(working)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Save")) { save() }
                            .disabled(working || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || requests.canAnswer == false)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 360)
        .interactiveDismissDisabled(working)
        .onDisappear { pasted = "" }
    }

    private func save() {
        let value = pasted
        guard !working, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                outcome = try await requests.answer(request, with: value)
                pasted = ""
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func decline() {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                try await requests.decline(request)
                pasted = ""
                outcome = .declined
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func restart() {
        working = true
        Task {
            defer { working = false }
            do {
                try await requests.restartHermes()
                restarted = String(localized: "Hermes is restarting. It takes about a minute.")
            } catch {
                restarted = String(localized: "Couldn't restart Hermes: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Settings › Agent › Keys Asked For

/// Every request waiting on this server, each opening its card.
struct KeyRequestsView: View {
    @State private var requests = KeyRequests.shared

    var body: some View {
        Form {
            if requests.canAnswer == false {
                Section { Text(KeyRequestError.noDashboard.errorDescription ?? "") }
            } else if requests.pending.isEmpty {
                Section {
                    Text(requests.loading ? String(localized: "Looking…") : String(localized: "No agent is waiting for a key."))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(requests.pending) { request in
                        Button { requests.showing = request } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(request.name).font(.body.monospaced())
                                Text("\(request.who) · \(request.destination)", comment: "Keys asked for: who asked, and where the key goes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            Section {
            } footer: {
                Text("An agent that needs a key asks for it here instead of in a chat. What you paste goes sealed into that profile's .env on your Hermes: never into a chat, a model or this device.")
            }
        }
        .navigationTitle(String(localized: "Keys Asked For"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await requests.reload() }
        .refreshable { await requests.reload() }
    }
}

// MARK: - Over the app

/// The key card over whatever is on screen, and what is said when it can't be shown.
struct KeyRequestSheets: ViewModifier {
    @State private var requests = KeyRequests.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $requests.showing) { KeyRequestSheet(request: $0) }
            .alert(String(localized: "Key Asked For"), isPresented: Binding(get: { requests.notice != nil }, set: { if !$0 { requests.notice = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { requests.notice = nil }
            } message: {
                Text(requests.notice ?? "")
            }
    }
}

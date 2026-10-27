import SwiftUI

/// The model menu's switches for the open conversation, on the Dashboard connection: fast mode,
/// and running commands without asking (`ChatControls.swift`). Both belong to this conversation
/// on the server, and both are read from the server when the menu opens.
struct ChatControlsSection: View {
    /// The conversation's id on the server.
    let stored: String
    let source: any ChatControlling
    /// "Run commands without asking" is offered: the Dashboard has it, the Hermes API doesn't.
    var offersAutoApprove = true

    @State private var controls: ChatControls?
    @State private var busy = false
    @State private var problem: String?
    @State private var confirmingAutoApprove = false

    /// The server's switches, or sample ones for a look at the menu.
    static var defaultSource: any ChatControlling {
        #if DEBUG
        if DevHooks.demoChatControls { return DemoChatControls() }
        #endif
        // A bot's chat goes by the Dashboard on either Hermes connection (`Conversation.connection`).
        return (Conversation.current?.connection ?? Settings.shared.transport) == .hermesSessions ? RunChatControls.shared : HermesServeClient.shared
    }

    var body: some View {
        Section {
            Toggle("Fast mode", isOn: Binding(get: { controls?.fast ?? false }, set: { on in change { try await source.setFast(on, stored: stored) } }))
                .disabled(controls == nil || busy)
            if offersAutoApprove {
                Toggle("Run commands without asking", isOn: Binding(get: { controls?.autoApprove ?? false }, set: { on in
                    if on { confirmingAutoApprove = true } else { change { try await source.setAutoApprove(false, stored: stored) } }
                }))
                .disabled(controls == nil || busy || controls?.serverNeverAsks == true)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("This conversation")
        } footer: {
            Text(offersAutoApprove ? Self.footer(controls)
                 : String(localized: "\(Self.fastFooter) It is asked for on each of this conversation's turns; a model without one answers as usual.",
                          comment: "Footer: %@ is the sentence explaining fast mode"))
        }
        .task(id: stored) {
            do {
                controls = try await source.chatControls(stored: stored)
            } catch {
                problem = String(localized: "Couldn't read this conversation's settings: \(error.localizedDescription)")
            }
        }
        .confirmationDialog("Run commands without asking?", isPresented: $confirmingAutoApprove, titleVisibility: .visible) {
            Button("Run Without Asking", role: .destructive) { change { try await source.setAutoApprove(true, stored: stored) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In this conversation Hermes will run every command it wants to, including the ones it would have stopped to ask you about.")
        }
    }

    /// One switch flipped: the server's answer is what the switches then show, and a refusal
    /// leaves them where they were.
    private func change(_ work: @escaping () async throws -> ChatControls) {
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do {
                controls = try await work()
            } catch {
                problem = ChatControls.fastRefusal(error.localizedDescription)
            }
        }
    }

    nonisolated static let fastFooter = String(localized: "Fast mode asks the provider for its faster tier, which usually costs more; only some models have one.")

    nonisolated static func footer(_ controls: ChatControls?) -> String {
        let fast = fastFooter
        if controls?.serverNeverAsks == true {
            return String(localized: "\(fast) This server never asks before a command: approvals are off in Hermes's config, for every conversation.",
                          comment: "Footer: %@ is the sentence explaining fast mode")
        }
        return String(localized: "\(fast) Without asking, Hermes runs every command it wants to in this conversation, until you switch it back or Hermes restarts.",
                      comment: "Footer: %@ is the sentence explaining fast mode")
    }
}

import SwiftUI
import WatchKit

/// The one screen: a microphone to ask with, then the question and its answer.
struct AskView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if store.connection == nil {
                    setup
                } else if store.question.isEmpty {
                    hero
                } else {
                    exchange
                }
            }
            .navigationTitle(store.agentName)
            .toolbar {
                if store.connection != nil {
                    // The server's conversations, to carry one on; where they can be listed.
                    if store.canListChats {
                        ToolbarItem(placement: .topBarLeading) {
                            NavigationLink { ChatsView() } label: { Label("Chats", systemImage: "list.bullet") }
                        }
                    }
                    // The crown sets the volume, not the scroll: the control keeps crown focus.
                    ToolbarItem(placement: .topBarTrailing) { VolumeControl().frame(width: 36, height: 36) }
                    // Not while the agent is waiting on the wrist: the bar would sit on the
                    // answer's buttons, and a new question would walk away from this one.
                    if !store.question.isEmpty, !store.isWaitingOnWrist {
                        ToolbarItem(placement: .bottomBar) { askButton }
                    }
                }
            }
        }
        .animation(.default, value: store.status)
        .animation(.default, value: store.question)
        // The Ask Redde intent (Action button, Siri) asks for dictation before the app is on
        // screen; the sheet goes up once it is, and only then.
        .onChange(of: store.dictationRequested) { takeRequestedDictation() }
        .onChange(of: scenePhase) { takeRequestedDictation() }
    }

    // MARK: States

    /// Nothing asked yet: the microphone is the screen.
    private var hero: some View {
        VStack(spacing: 12) {
            Button(action: dictate) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 84, height: 84)
                    .background(.tint, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Text("Ask \(store.agentName)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            // The conversation the question goes into, when one was picked; else which
            // connection the phone handed over: the fast lane is the bare model, no tools.
            Text(store.chatTitle.map { "in “\($0)”" } ?? connectionLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionLabel: String {
        switch store.connection?.kind {
        case .hermesAPI: "Hermes API"
        case .phone: "Through your iPhone"
        case .fastLane, .dashboard, nil: "Fast lane · no tools"
        }
    }

    private var exchange: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let chat = store.chatTitle {
                    Text(chat).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(store.question)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                statusLine
                if !store.reply.isEmpty {
                    Text(PlainText.display(store.reply))
                        .font(.body)
                        .transition(.opacity)
                }
                if !store.reply.isEmpty, store.status == .idle {
                    Button("Play again", systemImage: "speaker.wave.2") { store.repeatReply() }
                        .font(.footnote)
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Room to scroll the last line out from under the Ask bar.
        .contentMargins(.bottom, 48, for: .scrollContent)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch store.status {
        case .thinking:
            Label {
                Text("Thinking")
            } icon: {
                Image(systemName: "ellipsis")
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .speaking:
            HStack {
                Image(systemName: "speaker.wave.3.fill")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(.tint)
                Text("Speaking")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 40, height: 30)
                        .background(.fill.tertiary, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            }
            .font(.footnote)
        case let .approval(approval):
            VStack(alignment: .leading, spacing: 8) {
                Label("Run this?", systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(approval.command)
                    .font(.caption2.monospaced())
                    .lineLimit(5)
                HStack {
                    Button("Deny", role: .destructive) { store.answer(approval, approve: false) }
                    Button("Approve") { store.answer(approval, approve: true) }
                        .tint(.green)
                }
                .buttonStyle(.bordered)
            }
            .font(.footnote)
        case let .question(question):
            VStack(alignment: .leading, spacing: 8) {
                Label(question.text, systemImage: "questionmark.bubble.fill")
                    .foregroundStyle(.orange)
                ForEach(question.choices, id: \.self) { choice in
                    Button(choice) { store.answer(question, with: choice) }
                }
                Button("Answer", systemImage: "mic.fill") { dictateAnswer(to: question) }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
        case let .waitingOnPhone(what):
            Label(what, systemImage: "iphone")
                .font(.footnote)
                .foregroundStyle(.orange)
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Try again", systemImage: "arrow.clockwise") { store.ask(store.question) }
                    .buttonStyle(.bordered)
            }
            .font(.footnote)
        case .idle:
            EmptyView()
        }
    }

    private var askButton: some View {
        Button(action: dictate) {
            Label("Ask", systemImage: "mic.fill")
        }
        .buttonStyle(.borderedProminent)
    }

    private var setup: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Set up Redde on your iPhone first. The watch gets its connection from there.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("Try again") { PhoneLink.shared.requestSync() }
                    .font(.footnote)
            }
        }
    }

    // MARK: Dictation

    private func takeRequestedDictation() {
        guard store.dictationRequested, scenePhase == .active else { return }
        store.dictationRequested = false
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            dictate()
        }
    }

    /// Straight into dictation: SwiftUI's `TextFieldLink` opens the keyboard with dictation a tap
    /// away, while WatchKit's input controller starts listening at once when given no
    /// suggestions. Scribble and the keyboard stay reachable from its own toolbar.
    private func dictate() {
        let store = store
        WKApplication.shared().rootInterfaceController?.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { results in
            if let text = results?.first as? String { store.ask(text) }
        }
    }

    /// The same, for the answer to something the agent asked.
    private func dictateAnswer(to question: WatchRelay.Question) {
        let store = store
        WKApplication.shared().rootInterfaceController?.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { results in
            if let text = results?.first as? String { store.answer(question, with: text) }
        }
    }
}

/// WatchKit's volume dial for the watch's own output; focused, so the Digital Crown turns the
/// volume up and down instead of scrolling the reply.
private struct VolumeControl: WKInterfaceObjectRepresentable {
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: .local)
        control.focus()
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        control.focus()
    }
}

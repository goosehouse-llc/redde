import SwiftUI
import WatchKit

/// A live call on the wrist (`WatchCall`): who holds it and how it is going, the last words each
/// side said, a command or question the agent waits on, and the microphone and hang-up buttons.
struct WatchCallView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var call: WatchCall

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                pulse
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(call.state == .ended && call.problem != nil ? .red : .secondary)
                    .multilineTextAlignment(.center)
                waiting
                if !call.heard.isEmpty {
                    Text(call.heard)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                }
                if !call.said.isEmpty {
                    Text(call.said)
                        .font(.footnote)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                controls
            }
            .scenePadding(.horizontal)
        }
        .navigationTitle(call.engine.name)
        .navigationBarBackButtonHidden()
        .task { await call.start() }
        .onDisappear { call.hangUp() }
        .animation(.default, value: call.state)
    }

    private var status: String {
        switch call.state {
        case .connecting: call.engine.calling
        case .listening: call.isMuted ? String(localized: "Muted", comment: "Watch call: the microphone is off") : String(localized: "Listening", comment: "Watch call")
        case .thinking: String(localized: "\(store.agentName) is on it", comment: "Watch call: the agent works on a request")
        case .speaking: String(localized: "Speaking", comment: "Watch call: the voice is talking")
        case .ended: call.problem ?? String(localized: "Call ended", comment: "Watch call")
        }
    }

    /// The call's mark: still while it connects, breathing as either side talks.
    private var pulse: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: call.state == .ended)) { _ in
            let level = CGFloat(max(call.inputLevel, call.outputLevel))
            Image(systemName: call.state == .thinking ? "ellipsis" : "waveform")
                .font(.system(size: 26, weight: .semibold))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: call.state == .thinking)
                .frame(width: 64, height: 64)
                .background(.tint.opacity(0.25 + 0.5 * min(1, level * 4)), in: Circle())
                .foregroundStyle(.white)
        }
    }

    /// What the agent waits on that the wrist can give, as a question asked on the watch shows it.
    @ViewBuilder
    private var waiting: some View {
        switch store.status {
        case let .approval(approval):
            VStack(alignment: .leading, spacing: 6) {
                Label("Run this?", systemImage: "hand.raised.fill").foregroundStyle(.orange)
                Text(approval.command).font(.caption2.monospaced()).lineLimit(4)
                HStack {
                    Button("Deny", role: .destructive) { store.answer(approval, approve: false) }
                    Button("Approve") { store.answer(approval, approve: true) }.tint(.green)
                }
                .buttonStyle(.bordered)
            }
            .font(.footnote)
        case let .question(question):
            VStack(alignment: .leading, spacing: 6) {
                Label(question.text, systemImage: "questionmark.bubble.fill").foregroundStyle(.orange)
                ForEach(question.choices, id: \.self) { choice in
                    Button(choice) { store.answer(question, with: choice) }
                }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
        case let .waitingOnPhone(what):
            Label(what, systemImage: "iphone").font(.footnote).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if call.state != .ended {
                Button {
                    call.toggleMute()
                } label: {
                    Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .accessibilityLabel(call.isMuted ? Text("Unmute") : Text("Mute"))
            }
            Button {
                call.hangUp()
                dismiss()
            } label: {
                Image(systemName: call.state == .ended ? "xmark" : "phone.down.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(call.state == .ended ? .gray : .red)
            .clipShape(Circle())
            .accessibilityLabel(call.state == .ended ? Text("Close") : Text("Hang Up"))
        }
        .padding(.top, 4)
    }
}

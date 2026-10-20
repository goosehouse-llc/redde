import SwiftUI

/// Talking with a group chat, hands-free: what the person says goes to the room (through the app's
/// voice session, `VoiceSession.sendsTo`), each bot's reply is read aloud as it lands, one after
/// another under that bot's face, and once the round is over the mic opens again. Tapping the mic
/// while a bot is read stops it and listens; the replies not yet read stay on the screen. A bot
/// waiting on the person (a command to approve) holds the mic shut: that is answered on screen.
@Observable
final class GroupVoice {
    private(set) var isOn = false
    /// The bot being read now.
    private(set) var speaker: String?
    /// Replies landed and not read yet, oldest first.
    private var queue: [GroupEvent] = []
    /// The log's last event when voice began, or the last reply read: what follows is read.
    private var readThrough = 0
    @ObservationIgnored private weak var session: VoiceSession?
    @ObservationIgnored private weak var feed: GroupFeed?

    func start(_ feed: GroupFeed, session: VoiceSession) {
        guard !isOn else { return }
        self.feed = feed
        self.session = session
        isOn = true
        queue = []
        readThrough = feed.events.last?.seq ?? 0
        session.cancel()
        session.continuous = true
        session.sendsTo = { [weak feed] in feed?.send($0) }
        session.beginListening()
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        speaker = nil
        queue = []
        session?.sendsTo = nil
        session?.continuous = false
        session?.cancel()
    }

    /// The mic: end what is being said, or (a bot being read, or nothing going on) listen now.
    func mic() {
        guard isOn, let session else { return }
        if session.phase == .listening { session.endListening(); return }
        queue = []
        speaker = nil
        session.beginListening()
    }

    /// The room changed: replies to read, or the person's turn.
    func roomChanged() {
        guard isOn, let feed else { return }
        let landed = feed.events.filter { $0.kind == "message.member" && $0.seq > readThrough && !$0.text.isEmpty }
        if let last = landed.last { readThrough = last.seq }
        queue += landed
        next()
    }

    /// The voice session went quiet: the next reply, or the person's turn.
    func sessionChanged() {
        guard isOn, let session else { return }
        // A stop phrase ends hands-free: voice ends with it.
        if !session.continuous { stop(); return }
        if session.phase == .listening { queue = []; speaker = nil }
        if session.phase == .idle { next() }
    }

    private func next() {
        guard let session, let feed, session.phase == .idle else { return }
        if !queue.isEmpty {
            let reply = queue.removeFirst()
            speaker = reply.actorID
            session.readAloud(reply.text)
            return
        }
        speaker = nil
        // The round is over, and nothing waits on the screen: the person's turn.
        guard !feed.discussing, !feed.state.working, !feed.state.waitsOnPerson, feed.sending.isEmpty else { return }
        session.beginListening()
    }
}

/// In place of the field while talking with the group: who is speaking (the bot's face, handed
/// over as the next one is read), what is going on, what is being heard, and the mic and End.
struct GroupVoiceBar: View {
    let voice: GroupVoice
    let feed: GroupFeed
    let face: (GroupMember?) -> BotFace
    @Environment(VoiceSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var speaking: GroupMember? { voice.speaker.flatMap { feed.room.member($0) } }
    /// A bot whose reply is being written now.
    private var writer: GroupMember? {
        feed.drafts.first { !$0.text.isEmpty && $0.finishedAt == nil }.flatMap { feed.room.member($0.memberID) }
    }

    private var status: String {
        switch session.phase {
        case .listening: return session.liveTranscript.isEmpty ? "Listening…" : session.liveTranscript
        case .speaking: return speaking.map { "\($0.label) is speaking" } ?? "Speaking…"
        case .error(let problem): return problem
        default:
            if feed.state.waitsOnPerson { return "A bot needs you: answer on screen" }
            if let writer { return "\(writer.label) is writing…" }
            if feed.discussing || feed.state.working || !feed.sending.isEmpty { return "The bots are talking…" }
            return "Tap the mic to talk"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Group {
                    if let speaking = speaking ?? writer {
                        BotAvatar(face: face(speaking), size: 40)
                    } else {
                        FaceStack(faces: feed.room.members.prefix(3).map { face($0) }, size: 26)
                    }
                }
                .id(speaking?.id ?? writer?.id ?? "")
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .offset(x: 40).combined(with: .scale(scale: 0.6)).combined(with: .opacity),
                    removal: .offset(x: -40).combined(with: .scale(scale: 0.6)).combined(with: .opacity)))
            }
            .frame(width: 64, height: 44)
            .animation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(duration: 0.5, bounce: 0.3), value: speaking?.id ?? writer?.id)
            Text(status)
                .font(.subheadline)
                .foregroundStyle(session.phase == .listening && !session.liveTranscript.isEmpty ? AnyShapeStyle(theme.textColor) : AnyShapeStyle(.secondary))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: status)
            ComposerButton(symbol: session.phase == .listening ? "arrow.up" : "mic.fill",
                           label: session.phase == .listening ? "Done talking" : "Talk", tint: .accentColor, size: 44) { voice.mic() }
                .symbolEffect(.variableColor.iterative, isActive: session.phase == .listening)
            Button("End voice", systemImage: "xmark") { voice.stop() }
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 44)
                .contentShape(.rect)
                .buttonStyle(.plain)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.impact(weight: .light), trigger: voice.speaker)
    }
}

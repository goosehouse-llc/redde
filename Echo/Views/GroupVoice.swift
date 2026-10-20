import SwiftUI

/// Talking with a group chat, hands-free, on the voice screen (`VoiceView.group`): what the person
/// says goes to the room (through the app's voice session, `VoiceSession.sendsTo`), each bot's
/// reply is read aloud as it lands, one after another, its face up while it is, and once the
/// round is over the mic opens again. Tapping the mic while a bot is read stops it and listens;
/// the replies not yet read stay on the screen. A bot waiting on the person (a command to
/// approve) holds the mic shut: that is answered in the chat. Stop (`halt`) ends all of it until
/// the person taps the mic: the reading, the listening, and the bots' round if one is going.
@Observable
final class GroupVoice {
    private(set) var isOn = false
    /// The bot being read now.
    private(set) var speaker: String?
    /// Stopped: nothing is read and the mic stays shut until the person opens it.
    private(set) var isHeld = false
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
        isHeld = false
        queue = []
        readThrough = feed.events.last?.seq ?? 0
        session.cancel()
        session.continuous = true
        session.sendsTo = { [weak feed] in feed?.send($0) }
        session.beginListening()
    }

    #if DEBUG
    /// `-echo.groupVoice <bot>`: that bot's last reply read aloud, for a look at the screen.
    func demoSpeaking(_ member: String) {
        guard let session, let feed, let id = feed.room.members.first(where: { $0.profile == member || $0.id == member })?.id else { return }
        let text = feed.events.last { $0.kind == "message.member" && $0.actorID == id }?.text ?? "Here's what I found."
        session.cancel()
        speaker = id
        session.readAloud(text, speaker: feed.room.member(id)?.profile ?? id)
    }
    #endif

    func stop() {
        guard isOn else { return }
        isOn = false
        isHeld = false
        speaker = nil
        queue = []
        session?.sendsTo = nil
        session?.continuous = false
        session?.cancel()
    }

    /// Stop on the voice screen: the reply being read and those waiting, the listening, and the
    /// bots' round if one is going (as the chat's Stop), and then quiet until the mic is opened.
    func halt() {
        guard isOn, let session else { return }
        isHeld = true
        queue = []
        speaker = nil
        if let feed, feed.discussing || feed.state.working { feed.stop() }
        session.cancel()
    }

    /// The room changed: replies to read, or the person's turn.
    func roomChanged() {
        guard isOn, let feed else { return }
        let landed = feed.events.filter { $0.kind == "message.member" && $0.seq > readThrough && !$0.text.isEmpty }
        if let last = landed.last { readThrough = last.seq }
        // Stopped: what lands now is on the screen, not read.
        if !isHeld { queue += landed }
        next()
    }

    /// The voice session went quiet: the next reply, or the person's turn.
    func sessionChanged() {
        guard isOn, let session else { return }
        // A stop phrase ends hands-free: voice ends with it.
        if !session.continuous { stop(); return }
        // Listening again (the person opened the mic): no longer stopped.
        if session.phase == .listening { queue = []; speaker = nil; isHeld = false }
        if session.phase == .idle { next() }
    }

    private func next() {
        guard let session, let feed, session.phase == .idle, !isHeld else { return }
        if !queue.isEmpty {
            let reply = queue.removeFirst()
            speaker = reply.actorID
            // In that bot's voice (`BotVoices`): who speaks is heard as well as seen.
            session.readAloud(reply.text, speaker: feed.room.member(reply.actorID)?.profile ?? reply.actorID)
            return
        }
        speaker = nil
        // The round is over, and nothing waits on the screen: the person's turn.
        guard !feed.discussing, !feed.state.working, !feed.state.waitsOnPerson, feed.sending.isEmpty else { return }
        session.beginListening()
    }
}

/// A room on the voice screen (`VoiceView.group`): its talk, its log, and its bots' faces.
struct GroupVoiceScene {
    let voice: GroupVoice
    let feed: GroupFeed
    let face: (GroupMember?) -> BotFace

    /// The bots are at work: a round under way, or a message on its way to it.
    var isTalking: Bool { feed.discussing || feed.state.working || !feed.sending.isEmpty }

    /// A bot whose reply is being written now.
    var writer: GroupMember? {
        feed.drafts.first { !$0.text.isEmpty && $0.finishedAt == nil }.flatMap { feed.room.member($0.memberID) }
    }
}

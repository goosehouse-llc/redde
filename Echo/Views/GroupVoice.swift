import SwiftUI

/// Talking with a group chat, hands-free, on the voice screen (`VoiceView.group`): what the person
/// says goes to the room (through the app's voice session, `VoiceSession.sendsTo`), each bot's
/// reply is read aloud as it is written (from its live session, `GroupDraft`; once it lands where
/// the server's replies aren't followed live), one after another in the order they began, its face
/// up while it is, and once the round is over the mic opens again. While one is read, the next
/// one's first sentence is fetched, so the next bot starts as soon as the one before ends. Tapping
/// the mic while a bot is read stops it and listens; the replies not yet read stay on the screen.
/// A bot waiting on the person (a command to approve) holds the mic shut: that is answered in the
/// chat. Stop (`halt`) ends all of it until the person taps the mic: the reading, the listening,
/// and the bots' round if one is going.
@Observable
final class GroupVoice {
    private(set) var isOn = false
    /// The bot being read now.
    private(set) var speaker: String?
    /// Stopped: nothing is read and the mic stays shut until the person opens it.
    private(set) var isHeld = false
    /// The replies to read, and the one being read (`GroupReplies`).
    @ObservationIgnored private var replies = GroupReplies(since: 0)
    /// How much of the reply being read has gone to the voice, and whether the end of it has.
    @ObservationIgnored private var fed = ""
    @ObservationIgnored private var ended = false
    /// Opens the mic for the person's turn (not in the `-echo.demoDraft` look).
    @ObservationIgnored private var listens = true
    @ObservationIgnored private weak var session: VoiceSession?
    @ObservationIgnored private weak var feed: GroupFeed?
    /// The room's voice is a live call (`LiveRoom`): it listens and says the replies; this hands
    /// them over, whole, and shows who is speaking.
    @ObservationIgnored private(set) var asCall = false

    /// The engine a group chat's call is in: the app's, where group chats are calls.
    static func callEngine(_ settings: Settings = .shared) -> LiveEngine? {
        settings.liveGroupCalls ? settings.voiceEngine.live : nil
    }

    func start(_ feed: GroupFeed, session: VoiceSession) {
        guard !isOn else { return }
        self.feed = feed
        self.session = session
        isOn = true
        isHeld = false
        // What the room already has isn't read; what follows is, and what is being written now.
        replies = GroupReplies(since: feed.events.last?.seq ?? 0)
        (fed, ended) = ("", false)
        session.cancel()
        session.continuous = true
        if let engine = Self.callEngine() {
            asCall = true
            session.roomCall = { [weak feed] in (Self.room(feed), engine) }
            session.beginListening()
            return
        }
        session.sendsTo = { [weak feed] in feed?.send($0) }
        #if DEBUG
        // `-echo.demoDraft` (`-echo.demoRound`): the sample replies are read as they are written,
        // with no listening.
        if DevHooks.has("-echo.demoDraft") || DevHooks.has("-echo.demoRound") { listens = false; return }
        #endif
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
        replies.dropAll()
        session?.prefetch(nil)
        session?.sendsTo = nil
        session?.roomCall = nil
        asCall = false
        session?.continuous = false
        session?.cancel()
    }

    /// The room as its call knows it: its name and members, what has been said in it, and where
    /// what the person says goes.
    private static func room(_ feed: GroupFeed?) -> LiveRoom {
        LiveRoom(name: feed?.room.name ?? "the group", members: (feed?.room.members ?? []).map { ($0.profile, $0.label) },
                 history: { [weak feed] in
                     guard let feed else { return [] }
                     return LiveRoom.history(feed.events) { feed.room.member($0)?.label ?? "A member" }
                 },
                 send: { [weak feed] in feed?.send($0) })
    }

    /// On a call: each reply, once whole, to the call to say; who is saying one, on the screen.
    private func handToCall() {
        guard let session, let feed else { return }
        replies.update(events: feed.events, drafts: feed.drafts)
        while let up = replies.queue.first, up.whole || up.isAbandoned {
            _ = replies.next()
            replies.finishReading()
            session.roomReplied(profile: profile(up.memberID), text: up.text)
        }
        let speaking = session.liveRoomSpeaker.flatMap { profile in feed.room.members.first { $0.profile == profile }?.id }
        if speaker != speaking { speaker = speaking }
        if session.isLive { isHeld = false }
    }

    /// Stop on the voice screen: the reply being read and those waiting, the listening, and the
    /// bots' round if one is going (as the chat's Stop), and then quiet until the mic is opened.
    func halt() {
        guard isOn, let session else { return }
        isHeld = true
        replies.dropAll()
        speaker = nil
        session.prefetch(nil)
        if let feed, feed.discussing || feed.state.working { feed.stop() }
        session.cancel()
    }

    /// The room changed (its log, its state, a reply being written): the reply being read goes on,
    /// the next is begun or fetched ahead, or it is the person's turn.
    func roomChanged() {
        guard isOn, let feed else { return }
        if asCall { return handToCall() }
        replies.update(events: feed.events, drafts: feed.drafts)
        // Stopped: what is written now is on the screen, not read.
        if isHeld { replies.dropAll() }
        readOn()
        next()
        fetchAhead()
    }

    /// The voice session went quiet: the next reply, or the person's turn.
    func sessionChanged() {
        guard isOn, let session else { return }
        if asCall { return handToCall() }
        // A stop phrase ends hands-free: voice ends with it.
        if !session.continuous { stop(); return }
        // Listening again (the person opened the mic): what was waiting is let go, and Stop is over.
        if session.phase == .listening {
            replies.dropAll()
            speaker = nil
            isHeld = false
            session.prefetch(nil)
        }
        if session.phase == .idle {
            // The reply being read has been heard to its end, or was cut short.
            if replies.reading != nil { replies.finishReading() }
            next()
        }
    }

    /// Hands the reply being read whatever more of it has been written, and its end once it has one.
    private func readOn() {
        guard let session, let reply = replies.reading, !ended else { return }
        if reply.text.hasPrefix(fed) {
            session.continueReading(String(reply.text.dropFirst(fed.count)))
        } else {
            // Written over: what a bot wrote beside a tool call isn't its reply, which starts
            // again. What was being said ends at a sentence's end, and the new words follow.
            session.continueReading("\n" + reply.text.dropFirst(reply.text.commonPrefix(with: fed).count))
        }
        fed = reply.text
        if reply.whole || reply.isAbandoned {
            ended = true
            session.endReading()
        }
    }

    private func next() {
        guard let session, let feed, session.phase == .idle, !isHeld, replies.reading == nil else { return }
        if let reply = replies.next() {
            (fed, ended) = ("", false)
            speaker = reply.memberID
            // In that bot's voice (`BotVoices`): who speaks is heard as well as seen.
            guard session.beginReading(speaker: profile(reply.memberID)) else {
                replies.finishReading()
                speaker = nil
                return
            }
            readOn()
            fetchAhead()
            return
        }
        speaker = nil
        // The round is over, and nothing waits on the screen: the person's turn.
        guard listens, !feed.discussing, !feed.state.working, !feed.state.waitsOnPerson, feed.sending.isEmpty else { return }
        session.beginListening()
    }

    /// While one reply is read, the next one's first sentence is fetched.
    private func fetchAhead() {
        guard let session, replies.reading != nil, let up = replies.queue.first else { return }
        session.prefetch(up.text, whole: up.whole, speaker: profile(up.memberID))
    }

    private func profile(_ member: String) -> String { feed?.room.member(member)?.profile ?? member }
}

/// Which of a room's replies the voice reads, in what order, and how much of each is known: from
/// the room's log (its bots' messages) and the replies being written (`GroupDraft`), each read
/// once, from the draft when it was seen being written. A bot passing ("pass") is never read: a
/// draft waits until it can't be one. Pure, so it is testable.
nonisolated struct GroupReplies: Equatable, Sendable {
    struct Reply: Equatable, Sendable {
        var memberID: String
        /// The bot's live session, when it was seen being written (`GroupDraft.id`).
        var draftID: String?
        /// The room's last event when it began: its message comes after.
        var after: Int
        /// Its message in the room, once there.
        var seq: Int?
        var text: String
        /// All of it is known: the room has it, or the bot finished writing it.
        var whole: Bool
        /// Gone before the bot finished it (stopped, failed): what was written is all there is.
        var isAbandoned = false
    }

    /// The room's last event when voice began: messages after it are read.
    let since: Int
    /// Waiting to be read, in the order they began.
    private(set) var queue: [Reply] = []
    private(set) var reading: Reply?
    /// Replies from drafts, read or let go, whose message hasn't come: it isn't read again when it does.
    private var awaiting: [Reply] = []
    private var seenMessages: Set<Int> = []
    private var seenDrafts: Set<String> = []

    init(since: Int) { self.since = since }

    /// The room as it is now: new replies queued, and the one being read and those waiting
    /// brought up to date.
    mutating func update(events: [GroupEvent], drafts: [GroupDraft]) {
        let messages = events.filter { $0.kind == "message.member" && $0.seq > since && !$0.text.isEmpty && $0.actorID != nil }
        for message in messages where !seenMessages.contains(message.seq) {
            seenMessages.insert(message.seq)
            if !attach(message) {
                enqueue(Reply(memberID: message.actorID ?? "", after: message.seq - 1, seq: message.seq,
                              text: message.text, whole: true))
            }
        }
        for draft in drafts {
            guard let member = draft.memberID else { continue }
            if reading?.draftID == draft.id {
                reading?.take(draft)
            } else if let index = queue.firstIndex(where: { $0.draftID == draft.id }) {
                queue[index].take(draft)
            } else if !seenDrafts.contains(draft.id), !Self.mayBePass(draft.text) {
                seenDrafts.insert(draft.id)
                // Its message already in the log (queued from it above): that is the one read.
                guard !messages.contains(where: { $0.actorID == member && $0.seq > draft.after }) else { continue }
                var reply = Reply(memberID: member, draftID: draft.id, after: draft.after, text: "", whole: false)
                reply.take(draft)
                enqueue(reply)
            }
        }
        // A draft gone with no message for it: what was written of it is all there will be. Not
        // yet begun, it isn't read.
        let live = Set(drafts.map(\.id))
        func gone(_ reply: Reply) -> Bool { reply.draftID.map { !live.contains($0) } == true && reply.seq == nil && !reply.whole }
        if let reply = reading, gone(reply) { reading?.isAbandoned = true }
        awaiting += queue.filter(gone)
        queue.removeAll(where: gone)
    }

    /// In the order they began; one begun at the same point as another, after it.
    private mutating func enqueue(_ reply: Reply) {
        queue.insert(reply, at: queue.firstIndex { $0.after > reply.after } ?? queue.endIndex)
    }

    /// The next reply to read, now the one being read.
    mutating func next() -> Reply? {
        guard reading == nil, !queue.isEmpty else { return nil }
        reading = queue.removeFirst()
        return reading
    }

    /// The reply being read is over: heard to its end, or cut short.
    mutating func finishReading() {
        if let reply = reading, reply.seq == nil, reply.draftID != nil { awaiting.append(reply) }
        reading = nil
    }

    /// Everything known is let go unread (the person spoke, or Stop): replies written from now on
    /// are read.
    mutating func dropAll() {
        finishReading()
        awaiting += queue.filter { $0.seq == nil && $0.draftID != nil }
        queue = []
    }

    /// `message` is a reply already known from its draft: that reply is whole now. False when it is new.
    private mutating func attach(_ message: GroupEvent) -> Bool {
        func matches(_ reply: Reply) -> Bool {
            reply.draftID != nil && reply.seq == nil && reply.memberID == message.actorID && reply.after < message.seq
        }
        if var reply = reading, matches(reply) {
            (reply.seq, reply.text, reply.whole) = (message.seq, message.text, true)
            reading = reply
            return true
        }
        if let index = queue.firstIndex(where: matches) {
            (queue[index].seq, queue[index].text, queue[index].whole) = (message.seq, message.text, true)
            return true
        }
        if let index = awaiting.firstIndex(where: matches) {
            awaiting.remove(at: index)
            return true
        }
        return false
    }

    /// Text a bot passing might be writing ("pass", "(pass)", "Pass."), or the start of it.
    static func mayBePass(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.wholeMatch(of: /\(?\s*p(a(s(s)?)?)?\s*\)?\.?/.ignoresCase()) != nil
    }
}

nonisolated private extension GroupReplies.Reply {
    /// The draft's text as it stands, and whether the bot has finished it.
    mutating func take(_ draft: GroupDraft) {
        guard seq == nil else { return }   // the room's message is the word on it
        text = draft.text
        whole = draft.finishedAt != nil && !GroupReplies.mayBePass(draft.text)
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

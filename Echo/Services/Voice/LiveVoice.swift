import Foundation
import os

/// A live call (Settings → Voice → Voice mode, or a bot's own): a voice model, GPT-Live, Gemini
/// Live or Grok Voice (`LiveEngine`), holds the conversation, talking and listening at once, and
/// hands every real request to the agent, whose answer it then says in its own words. Hermes keeps
/// everything else: the model, the tools, the memory, the approvals. This is Hermes Desktop's live
/// voice (tools/voice_live.py and its desktop client), on Redde's connections and with more
/// engines: the call goes straight from the phone to the service over a WebSocket (`LiveCall`),
/// set up with the key kept in Redde (`LiveSetup`), each service's wire worded by its
/// `LiveDialect`. The voice session drives this in place of its recogniser and its voice.
final class LiveVoice {
    enum State: Equatable { case connecting, listening, thinking, speaking, ended }

    private(set) var state: State = .connecting
    /// What the person is saying, from the start of what they're saying now.
    private(set) var heard = ""
    /// What the voice is saying, from the start of what it's saying now.
    private(set) var said = ""
    /// What the agent is doing for the request handed to it.
    private(set) var tool: String?
    private(set) var isMuted = false
    /// Why the call ended, when the person didn't end it.
    private(set) var problem: String?
    /// The call is set up and its audio flowing.
    private(set) var connected = false
    /// Each change, for the voice session to show.
    var onChange: (() -> Void)?
    /// With hands-free off, the call ends once a question has been answered, as Redde's own voice
    /// stops after its answer (asked 2026-10-25). Read as it goes: hands-free can be turned on
    /// mid-call.
    var endsAfterAnswer: () -> Bool = { false }
    /// A request to the agent before the call opens (a wake phrase said with one: "Hey Home, turn
    /// the lights off"): asked as the call's first, and the call opens saying the answer, as a
    /// call handed to another bot does (`handOff`). Set before `start`.
    var opening: String?
    /// The agent's own line, which the call opens saying: an agent's call to the person, answered
    /// (`AgentCalls`). The voice is given it as the agent's last words. Set before `start`.
    var greeting: String?
    /// The agent's line, said already by Redde's own voice (a call answered while locked, its
    /// microphone opened at the unlock): the voice is given it as the agent's last words, and
    /// doesn't say it again. Set before `start`.
    var alreadySaid: String?

    var inputLevel: Float { call?.inputLevel ?? 0 }
    var outputLevel: Float { call?.outputLevel ?? 0 }
    /// Who holds this call.
    let engine: LiveEngine

    private let conversation: Conversation
    private let settings: Settings
    private let dialect: any LiveDialect
    private let makeCall: (LiveCallListening, any LiveDialect) throws -> LiveCalling
    private let setUp: LiveSetup.Resolver
    private let setUpRoom: LiveSetup.RoomResolver
    private var call: LiveCalling?
    /// A group chat this call speaks for (`LiveRoom`): what the person says goes there, and its
    /// members' replies are said, each in its own voice (`roomReplied`). Set before `start`.
    var room: LiveRoom?
    /// The member whose reply is being said (its profile), for the screen's face.
    private(set) var roomSpeaker: String?
    /// Members' replies still to say, in order; one being put on, and one put on not yet heard
    /// (a session that opens saying it), so the next doesn't cut it off.
    private var roomReplies: [(profile: String, text: String)] = []
    private var puttingOnReply = false
    private var replyDue = false
    private lazy var relay = Relay(owner: self)
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "live")

    /// The spoken exchange as transcribed, both sides, for what a handed-over request refers to.
    private var fragments: [LiveFragment] = []
    /// Where the last handed-over request ended in `fragments`: what was said since is the next one's.
    private var handedOverAt = 0
    private var lastSpeaker: LiveFragment.Speaker?
    /// The person's words since they last started talking, judged once they stop: a stop phrase ends the call.
    private var utterance = ""
    private var utteranceSettles: Task<Void, Never>?
    private var voiceSpeaking = false
    /// The request the agent is working on (`session.delegation.created`), and the turn doing it.
    private var delegation: String? {
        // Its answer has gone: what the service plays from now is its voice again (`answered`).
        didSet { if delegation == nil, oldValue != nil { call?.answered() } }
    }
    private var turn: Task<Void, Never>?
    /// Says the agent is still at it while the person waits (`keepPosted`).
    private var posting: Task<Void, Never>?
    private let postEvery: Posting
    private var chunker = SentenceChunker()
    private var spokenAnything = false
    /// Whose voice the call speaks in now (a profile, "default" the main agent's); and, for a
    /// request that went to another bot's chat, its answer gathered whole for that bot's session
    /// to open with (`handOff`).
    private var voiceOf = "default"
    private var collecting = false
    /// Opens a bot's chat for a spoken prefix (`Conversation.goToBot`; a stand-in in tests).
    private let goToBot: (Conversation, String, String) async -> Void
    /// The answer so far, for a dialect that takes it whole (a tool's result).
    private var answer = ""
    /// The Dashboard takes the turn as a live voice one itself (`LiveTurn.surface`).
    private var hermesKnowsLiveTurns = false
    private var eventCount = 0
    private var lastActivity = ContinuousClock.now
    private var quietWatch: Task<Void, Never>?
    /// When `start` began, for the log of how long each step of setting the call up took.
    private var callStarted: ContinuousClock.Instant?

    /// When the voice says the agent is still working: first after this long without an answer,
    /// then every so often; and how long a quiet after an answer ends a call (`endsAfterAnswer`).
    struct Posting {
        var first: Duration = .seconds(15)
        var every: Duration = .seconds(30)
        var answered: Duration = .seconds(3)
    }

    /// When the person last said something, and the voice was last heard.
    private var lastAsked: ContinuousClock.Instant?
    private var lastHeardVoice: ContinuousClock.Instant?
    /// The agent's answer went to the voice and it hasn't said it yet.
    private var answerUnsaid = false
    private var answerCheck: Task<Void, Never>?

    init(conversation: Conversation, settings: Settings = .shared, engine: LiveEngine? = nil,
         makeCall: @escaping (LiveCallListening, any LiveDialect) throws -> LiveCalling = { LiveCall(listener: $0, dialect: $1) },
         setUp: @escaping LiveSetup.Resolver = LiveSetup.resolve,
         setUpRoom: @escaping LiveSetup.RoomResolver = { try await LiveSetup.resolveRoom($0, speaker: $1, settings: $2, engine: $3) },
         posting: Posting = Posting(),
         goToBot: @escaping (Conversation, String, String) async -> Void = { conversation, bot, main in
             _ = try? await conversation.goToBot(bot, mainName: main)
         }) {
        self.conversation = conversation
        self.goToBot = goToBot
        self.settings = settings
        self.engine = engine ?? settings.liveEngine(for: conversation.bot?.profile) ?? .gptLive
        dialect = self.engine.dialect
        self.makeCall = makeCall
        self.setUp = setUp
        self.setUpRoom = setUpRoom
        postEvery = posting
    }

    // MARK: - The call

    /// Sets the call up: the microphone first, so that nothing said while it connects is lost; then
    /// where to connect (`LiveSetup`), then the connection, until the service says the session has
    /// started. The audio session is the caller's, active for voice already.
    func start() async {
        let started = ContinuousClock.now
        callStarted = started
        func took() -> String { (ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds], width: .narrow)) }
        let call: LiveCalling
        do {
            call = try makeCall(relay, dialect)
            self.call = call
            try call.open()
        } catch {
            end(problem: error.localizedDescription)
            return
        }
        note("microphone open after \(took())")
        voiceOf = room == nil ? conversation.bot?.profile ?? "default" : "default"
        do {
            let setup = if let room { try await setUpRoom(room, nil, settings, engine) } else { try await setUp(conversation, settings, engine) }
            guard state != .ended else { return }
            hermesKnowsLiveTurns = setup.hermesKnowsLiveTurns
            var greeting: LiveGreeting? = self.greeting.flatMap { $0.isEmpty || room != nil ? nil : LiveGreeting(line: $0, language: "English") }
            if let opening, !opening.isEmpty, room == nil {
                greeting = await answer(opening)
                note("opening request answered after \(took())")
                guard state != .ended else { return }
            }
            var history = room?.history() ?? LiveSetup.history(conversation.messages)
            if room == nil, let said = self.greeting ?? alreadySaid, !said.isEmpty { history.append(LiveLine(fromPerson: false, text: said)) }
            var connection = try await setup.open(history)
            connection.plan.greeting = greeting
            note("set up with \(setup.label) after \(took())")
            guard state != .ended else { return }
            try await call.connect(connection)
            note("session started after \(took())")
        } catch {
            guard state != .ended else { return }
            end(problem: error.localizedDescription)
        }
    }

    /// The person ends the call. The service is told, so that its bill stops at once, and a moment
    /// after (for that to go out) the connection closes.
    func hangUp() {
        guard state != .ended else { return }
        // A request it handed over stops with it, as a turn Redde's own voice started stops with
        // its Stop: hung up mid-request, the agent went on for minutes (Marta, 2026-10-25). A call
        // that ends otherwise (dropped, ended by the service) leaves the answer to come in the chat.
        if delegation != nil, conversation.isStreaming { conversation.cancel() }
        send(dialect.close())
        let call = call
        Task { try? await Task.sleep(for: .milliseconds(250)); call?.close() }
        self.call = nil
        end(problem: nil)
    }

    // MARK: - A group chat's call

    /// A member's reply, whole: said in its voice once what is being said has been.
    func roomReplied(profile: String, text: String) {
        guard room != nil, state != .ended, !text.isEmpty else { return }
        roomReplies.append((profile, text))
        sayNextRoomReply()
    }

    /// What the person said, to the room; the voice is told it went, and to say nothing of it.
    private func toRoom(_ prompt: String, room: LiveRoom, for id: String) {
        roomReplies.removeAll()   // what was still to be said is over: the person went on
        room.send(prompt)
        let note = "Sent to the group. The members' replies are said to the user in their own voices: say nothing about it."
        if dialect.streamsAnswers { think(note, for: id) } else { send(dialect.answer(note, to: id, final: true, eventID: nextID("say"))) }
        delegation = nil
        tool = nil
        posting?.cancel()
        changed()
    }

    /// The next reply, said by a session in its member's voice that opens saying it, the
    /// microphone and the speaker going on throughout (as `handOff` does): once nothing is being
    /// said, and the last one put on has been heard.
    private func sayNextRoomReply() {
        guard let room, let call, state != .ended, !puttingOnReply, !replyDue, !voiceSpeaking, !roomReplies.isEmpty else {
            if roomReplies.isEmpty, !voiceSpeaking, !puttingOnReply, !replyDue, roomSpeaker != nil {
                roomSpeaker = nil
                changed()
            }
            return
        }
        let (profile, text) = roomReplies.removeFirst()
        puttingOnReply = true
        roomSpeaker = profile
        changed()
        Task { [weak self] in
            guard let self else { return }
            do {
                let setup = try await setUpRoom(room, profile, settings, engine)
                var connection = try await setup.open(room.history())
                connection.plan.greeting = LiveGreeting(line: text, language: "English")
                guard state != .ended else { return }
                try await call.reconnect(connection)
                voiceOf = profile
                replyDue = true
                note("saying \(profile)'s reply")
                // Heard when the voice starts (`callChanged`); a session that never speaks lets go.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard let self, replyDue, !voiceSpeaking else { return }
                    replyDue = false
                    sayNextRoomReply()
                }
            } catch {
                log.error("saying \(profile, privacy: .public)'s reply failed: \(error.localizedDescription, privacy: .public)")
            }
            puttingOnReply = false
            sayNextRoomReply()
        }
    }

    func setMuted(_ muted: Bool) {
        guard muted != isMuted, state != .ended else { return }
        isMuted = muted
        call?.setMuted(muted)
        send(dialect.mute(muted, eventID: nextID(muted ? "mute" : "unmute")))
        changed()
    }

    private func end(problem: String?) {
        guard state != .ended else { return }
        if let callStarted { note("ended after \((ContinuousClock.now - callStarted).formatted(.units(allowed: [.seconds], width: .narrow)))\(problem.map { ": " + $0 } ?? "")") }
        self.problem = problem
        if let problem { log.error("\(self.engine.name, privacy: .public) call ended: \(problem, privacy: .public)") }
        state = .ended
        utteranceSettles?.cancel()
        quietWatch?.cancel()
        answerCheck?.cancel()
        turn?.cancel()
        turn = nil
        posting?.cancel()
        delegation = nil
        roomReplies.removeAll()
        roomSpeaker = nil
        call?.close()
        call = nil
        onChange?()
    }

    private func changed() {
        guard state != .ended else { return }
        let now: State = !connected ? .connecting : voiceSpeaking ? .speaking : delegation != nil ? .thinking : .listening
        state = now
        onChange?()
    }

    // MARK: - What the call says

    fileprivate func received(_ text: String) {
        for event in dialect.read(text) {
            guard state != .ended else { return }
            switch event {
            case .started:
                began()
            case let .transcript(speaker, piece, startMs, endMs):
                // "…" for a silence (ElevenLabs): nothing said.
                if speaker == .person, !piece.contains(where: { $0.isLetter || $0.isNumber }) { continue }
                // Times where the service gives them (GPT-Live), else the call's own clock.
                let now = callStarted.map { Int((ContinuousClock.now - $0) / .milliseconds(1)) } ?? 0
                transcribed(LiveFragment(speaker: speaker, text: piece, startMs: startMs ?? now, endMs: endMs ?? now))
            case let .delegated(id, request):
                delegated(id, request: request)
            case let .withdrawn(ids):
                if let delegation, ids.contains(delegation) { withdraw() }
            case let .failed(message, code):
                // Appends after the call is over, or to a request it has moved on from: expected.
                if code == "context_injection_incomplete" { continue }
                log.error("\(self.engine.name, privacy: .public): \(message, privacy: .public)")
            case let .closed(reason):
                end(problem: reason.map { LiveFailure.readable($0, engine: engine) })
            case .interrupted:
                #if DEBUG
                note("interrupted: the voice's queued audio dropped")
                #endif
            case .audio, .reply:
                break
            }
        }
    }

    fileprivate func callChanged(_ state: LiveCallState) {
        switch state {
        case .speaking:
            voiceSpeaking = true
            replyDue = false
            lastActivity = .now
            lastHeardVoice = .now
            answerUnsaid = false
            answerCheck?.cancel()
            changed()
        case .quiet:
            voiceSpeaking = false
            lastActivity = .now
            lastHeardVoice = .now
            changed()
            checkAnswered()
            sayNextRoomReply()
        case .lost:
            end(problem: String(localized: "The connection to \(engine.name) dropped."))
        }
    }

    private func began() {
        guard !connected else { return }
        if let callStarted { note("connected after \((ContinuousClock.now - callStarted).formatted(.units(allowed: [.milliseconds], width: .narrow)))") }
        connected = true
        #if DEBUG
        if DevHooks.has("-echo.liveMeasure") { measure() }
        #endif
        lastActivity = .now
        watchForQuiet()
        changed()
    }

    private func transcribed(_ fragment: LiveFragment) {
        lastActivity = .now
        fragments.append(fragment)
        if fragments.count > 2_000 {
            fragments.removeFirst(500)
            handedOverAt = max(0, handedOverAt - 500)
        }
        #if DEBUG
        // What each side said, a turn at a time, in the measure log: the exchange, not a guess at it.
        if let lastSpeaker, fragment.speaker != lastSpeaker {
            let turn = lastSpeaker == .person ? heard : said
            if !turn.isEmpty { note("\(lastSpeaker == .person ? "person" : "voice"): \(turn)") }
        }
        #endif
        switch fragment.speaker {
        case .person:
            lastAsked = .now
            answerCheck?.cancel()
            if lastSpeaker != .person { heard = "" }
            heard += fragment.text
            utterance += fragment.text
            // The voice model answers a bare "stop" itself, going quiet, and never hands it over:
            // what the person said is looked at once they've stopped saying it.
            utteranceSettles?.cancel()
            utteranceSettles = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1_500))
                guard !Task.isCancelled, let self else { return }
                let said = utterance
                utterance = ""
                if StopPhrase.matches(said, own: settings.stopPhrases) {
                    log.info("stop phrase heard on the call")
                    hangUp()
                }
            }
        case .voice:
            if lastSpeaker != .voice { said = "" }
            said += fragment.text
        }
        lastSpeaker = fragment.speaker
        onChange?()
    }

    /// Hangs up after Settings' minutes of nobody saying anything and nothing being worked on:
    /// the silence is billed too.
    private func watchForQuiet() {
        quietWatch?.cancel()
        let minutes = settings.liveHangUp
        guard minutes > 0 else { return }
        quietWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                if delegation == nil, !voiceSpeaking, ContinuousClock.now - lastActivity > .seconds(minutes * 60) {
                    log.info("live call quiet for \(minutes) min: hanging up")
                    hangUp()
                    return
                }
            }
        }
    }

    // MARK: - Handing a request to the agent

    /// The voice wants the agent: what the person last said becomes a turn in the conversation,
    /// with the exchange around it for the agent alone (and the voice's own wording of the request,
    /// where it gives one: a tool call's). A newer request stops one still being worked on, so the
    /// answer the voice gives is to what was asked last.
    private func delegated(_ id: String, request: String? = nil) {
        lastActivity = .now
        turn?.cancel()
        if conversation.isStreaming { conversation.cancel() }
        delegation = id
        tool = nil
        spokenAnything = false
        answer = ""
        collecting = false
        chunker = SentenceChunker()
        changed()
        // A tool call can come before the words it answers are written down (Gemini's transcripts
        // come in no set order): a moment for them, or "Home, …" was routed by the voice's own
        // wording, the name gone (2026-10-25). GPT-Live hands over after them.
        let settle: Duration = dialect.streamsAnswers ? .zero : .milliseconds(700)
        turn = Task { [weak self] in
            if settle > .zero { try? await Task.sleep(for: settle) }
            guard let self, delegation == id, !Task.isCancelled else { return }
            let (prompt, context) = asked(wording: request)
            if StopPhrase.matches(prompt, own: settings.stopPhrases) {
                hangUp()
                return
            }
            if let room {
                toRoom(prompt, room: room, for: id)
                return
            }
            #if DEBUG
            note("handed over: \(prompt)")
            #endif
            await work(on: prompt, context: context, for: id)
        }
        posting?.cancel()
        // A room's members answer in their own time: nothing to keep the person posted on.
        guard room == nil else { return }
        posting = Task { [weak self] in await self?.keepPosted(for: id) }
    }

    /// What was asked, for the agent: the person's own words since the last request (a spoken
    /// prefix anywhere in them, `addressed`), else the voice's wording of it (a tool call's), which
    /// goes along in the context too; a prefix in that wording counts where theirs has none.
    private func asked(wording request: String?) -> (prompt: String, context: String) {
        var (prompt, context) = LiveFragment.delegation(from: recentFragments())
        let worded = request?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        if prompt.isEmpty || fragments.allSatisfy({ $0.speaker == .voice }) { prompt = worded.isEmpty ? prompt : worded }
        if !worded.isEmpty, worded != prompt { context += (context.isEmpty ? "" : "\n") + "Voice assistant's request to you: \(worded)" }
        prompt = Self.addressed(prompt, asked: LiveFragment.personTurns(Array(fragments[min(handedOverAt, fragments.count)...])),
                                rules: settings.spokenPrefixes)
        if VoiceRouting.route(prompt, rules: settings.spokenPrefixes) == nil, VoiceRouting.route(worded, rules: settings.spokenPrefixes) != nil {
            prompt = worded
        }
        handedOverAt = fragments.count
        return (prompt, context)
    }

    /// A spoken prefix ("Home, …") said anywhere in what the person asked since the last request,
    /// not only at the start of their last words: the voice talks back, "Home." "Yes?" "Turn the
    /// lights off.", and a backchannel splits a sentence in two. Found 2026-10-25: prefixes never
    /// worked on GPT-Live. `prompt` as it was when none is said, or it starts with one already.
    static func addressed(_ prompt: String, asked: [String], rules: [SpokenPrefix]) -> String {
        guard VoiceRouting.route(prompt, rules: rules) == nil else { return prompt }
        for start in asked.indices.reversed() {
            let since = asked[start...].joined(separator: " ")
            if VoiceRouting.route(since, rules: rules) != nil { return since }
        }
        return prompt
    }

    /// The request went to another bot's chat (a spoken prefix): once its answer is in, the call
    /// goes on as that bot, in its voice, a new session on the same service (a voice can't be
    /// changed within one) that opens saying the answer, the way a preview's voice says its line
    /// (an answer handed to a session already under way, as a note of no request's, went unsaid on
    /// GPT-Live), the microphone and the speaker going on throughout; the person goes on with that
    /// bot. Asked 2026-10-25: "the prefix to Home worked, but it continued in Sol's voice". False
    /// when it couldn't: the voice as it was says the answer.
    private func handOff(asking request: String, saying answer: String) async -> Bool {
        guard let call else { return false }
        let profile = conversation.bot?.profile ?? "default"
        do {
            let setup = try await setUp(conversation, settings, engine)
            var history = LiveSetup.history(conversation.messages)
            history.append(LiveLine(fromPerson: true, text: request))
            var connection = try await setup.open(history)
            connection.plan.greeting = LiveGreeting(line: answer, language: "English")
            guard state != .ended else { return false }
            try await call.reconnect(connection)
            voiceOf = profile
            note("went on as \(agentName)")
            return true
        } catch {
            log.error("handing the call to \(profile, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The call's opening request (`opening`) asked of the agent, its answer whole for the call to
    /// open saying. Shown as the agent at work meanwhile; hanging up stops it.
    private func answer(_ request: String) async -> LiveGreeting {
        delegation = "opening"
        lastAsked = .now
        changed()
        var whole = ""
        let events = conversation.send(request, live: LiveTurn(context: "", surface: hermesKnowsLiveTurns))
        for await event in events {
            guard state != .ended else { break }
            switch event {
            case let .textDelta(delta):
                whole += delta
            case let .toolStarted(name, _, _):
                tool = name
                changed()
            case .toolFinished:
                tool = nil
                changed()
            default:
                break
            }
        }
        delegation = nil
        tool = nil
        if conversation.lastSendWasHeld {
            whole = "That request is waiting behind another one; it goes as soon as that's done."
        } else if let error = conversation.lastError {
            whole = "I couldn't get that from \(agentName): \(error)"
        } else if whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            whole = "\(agentName) finished that request without anything to say."
        }
        answerUnsaid = true
        changed()
        return LiveGreeting(line: whole, language: "English")
    }

    /// Hands-free off: three seconds after something asked has been answered, the call ends, unless
    /// the person goes on talking (his words, 2026-10-25: "unless I keep talking"; the voice ending
    /// on a question of its own no longer keeps it). Not while the agent is working, nor before the
    /// voice has said the agent's answer.
    private static let talking: Float = 0.03
    private func checkAnswered() {
        answerCheck?.cancel()
        guard endsAfterAnswer(), connected else { return }
        answerCheck = Task { [weak self, wait = postEvery.answered] in
            // The person starting to talk keeps the call, heard in the microphone at once (a
            // transcript can come a second or two after they've started, and cancels this): a
            // sound only puts the hang-up off, ten seconds at most, so a noise can't keep the
            // call open (it did, after ElevenLabs' "are you still there?", 2026-10-25).
            let began = ContinuousClock.now
            var quietSince = began
            while ContinuousClock.now - quietSince < wait, ContinuousClock.now - began < .seconds(10) {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if inputLevel > Self.talking { quietSince = .now }
            }
            guard let self, !Task.isCancelled, state != .ended, endsAfterAnswer() else { return }
            guard delegation == nil, !voiceSpeaking, !answerUnsaid else { return }
            guard let asked = lastAsked, let heard = lastHeardVoice, heard > asked else { return }
            note("answered, hands-free off: hanging up")
            hangUp()
        }
    }

    /// The voice no longer wants what it asked (the person moved on): the agent stops too.
    private func withdraw() {
        turn?.cancel()
        turn = nil
        posting?.cancel()
        if conversation.isStreaming { conversation.cancel() }
        delegation = nil
        tool = nil
        collecting = false
        changed()
    }

    /// A long wait isn't silence: until the agent has something to say, the voice says it is still
    /// on it, after `postEvery.first` and then every `postEvery.every`. Said, not quiet progress:
    /// GPT-Live's voice speaks commentary (in its own words) and keeps thinking to itself, and a
    /// delay is an update the person should hear (`LiveDialect.update`). On Marta (2026-10-25) the agent's model took two and a
    /// half minutes to start, its cache emptied by a group chat, and the call sat silent until it
    /// was ended.
    private func keepPosted(for id: String) async {
        let asked = ContinuousClock.now
        var wait = postEvery.first
        while true {
            try? await Task.sleep(for: wait)
            guard delegation == id, !spokenAnything, !Task.isCancelled else { return }
            let seconds = Int((ContinuousClock.now - asked) / .seconds(1))
            let doing = tool.map { ", using \($0)" } ?? ""
            let update = "\(agentName) is still working on it\(doing): \(seconds) seconds so far, not done yet."
            send(dialect.update(update, to: id, eventID: nextID("wait")))
            wait = postEvery.every
        }
    }

    private func work(on prompt: String, context: String, for id: String) async {
        // Spoken prefixes, as in Redde's own voice: "Home, …" goes to that bot's chat first.
        let route = VoiceRouting.route(prompt, rules: settings.spokenPrefixes)
        if let bot = route?.bot { await goToBot(conversation, bot, settings.headerTitle) }
        if let model = route?.model { try? await conversation.switchModel(model, provider: route?.provider) }
        guard delegation == id, !Task.isCancelled else { return }
        // Another bot's chat now: its answer gathered, for the call to go on as that bot saying it.
        let handingOff = (conversation.bot?.profile ?? "default") != voiceOf
        collecting = handingOff
        let events = conversation.send(route?.text ?? prompt, live: LiveTurn(context: context, surface: hermesKnowsLiveTurns))
        var used: [String] = []
        for await event in events {
            guard delegation == id, !Task.isCancelled else { return }
            lastActivity = .now
            switch event {
            case let .textDelta(delta):
                chunker.append(delta).forEach { say($0, for: id) }
            case let .toolStarted(name, _, _):
                if !used.contains(name) { used.append(name) }
                tool = name
                think("\(agentName) is working: \(name). Not done yet.", for: id)
                changed()
            case .toolFinished:
                tool = nil
                changed()
            case .interrupt:
                think("\(agentName) is waiting for the user to answer a request on their iPhone's screen.", for: id)
            default:
                break
            }
        }
        guard delegation == id, !Task.isCancelled else { return }
        if let tail = chunker.flush() { say(tail, for: id) }
        if conversation.lastSendWasHeld {
            say("That request is waiting behind another one; it goes as soon as that's done.", for: id)
        } else if let error = conversation.lastError {
            say("I couldn't get that from \(agentName): \(error)", for: id)
        } else if !spokenAnything, dialect.streamsAnswers, !handingOff {
            think("\(agentName) finished that request without anything to say.", for: id)
        }
        // Whether the agent checked anything, for the voice to know and not say.
        let answered = !conversation.lastSendWasHeld && conversation.lastError == nil
        let checked = LiveAgentTool.checked(used, agent: agentName)
        if answered, dialect.streamsAnswers, !handingOff { think(checked, for: id) }
        let whole = answer.isEmpty ? "\(agentName) finished that request without anything to say." : answer
        if handingOff {
            // The other bot's session opens saying it; where it couldn't open, the voice as it was says it.
            if await !handOff(asking: route?.text ?? prompt, saying: whole) {
                guard delegation == id else { return }
                let final = !dialect.streamsAnswers
                for part in final ? [whole] : LiveFragment.appendable(whole) {
                    send(dialect.answer(part, to: id, final: final, eventID: nextID("say")))
                }
            }
            guard delegation == id else { return }
        } else if !dialect.streamsAnswers {
            // A tool call's result is the whole answer, once.
            send(dialect.answer(answered ? whole + "\n\n" + checked : whole, to: id, final: true, eventID: nextID("say")))
        }
        collecting = false
        // An answer to say: the call goes on until the voice has said it.
        answerUnsaid = spokenAnything || !dialect.streamsAnswers || handingOff
        delegation = nil
        tool = nil
        posting?.cancel()
        changed()
        checkAnswered()
    }

    /// How setting the call up went, in the log; with `-echo.liveMeasure` (DEBUG), in
    /// Library/Caches/live-measure.log as well, with the call's cost to the phone every ten seconds.
    private func note(_ line: String) {
        log.info("\(self.engine.name, privacy: .public): \(line, privacy: .public)")
        #if DEBUG
        LiveMeasure.write(line)
        #endif
    }

    #if DEBUG
    private func measure() {
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        func footprint() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        }
        Task { [weak self] in
            var last = (cpu: cpu(), at: Date.now)
            while let self, state != .ended {
                try? await Task.sleep(for: .seconds(10))
                guard state != .ended else { return }
                let now = (cpu: cpu(), at: Date.now)
                note(String(format: "%@: %.1f%% of a core, %.1f MB, levels %.2f in %.2f out", "\(state)",
                            (now.cpu - last.cpu) / now.at.timeIntervalSince(last.at) * 100, footprint(), inputLevel, outputLevel))
                last = now
            }
        }
        // How long the voice takes to answer, the same way for either call: from the person's last
        // sound to the voice audible after a quiet of 0.7 s or more, read off the levels.
        Task { [weak self] in
            var lastLoud: ContinuousClock.Instant?
            var quietSince = ContinuousClock.now
            var audible = false
            while let self, state != .ended {
                try? await Task.sleep(for: .milliseconds(50))
                let now = ContinuousClock.now
                if inputLevel > 0.02, !audible { lastLoud = now }
                if outputLevel > 0.03 {
                    if !audible, now - quietSince > .milliseconds(700), let lastLoud {
                        note("voice began \((now - lastLoud).formatted(.units(allowed: [.milliseconds], width: .narrow))) after the person's last sound")
                    }
                    audible = true
                } else if audible {
                    audible = false
                    quietSince = now
                }
            }
        }
    }
    #endif

    /// Whose agent this is: the bot's whose chat it is, else the main one's name.
    private var agentName: String { conversation.bot?.name ?? settings.headerTitle }

    /// The agent's answer, a sentence at a time as it is written, for the voice to say.
    private func say(_ text: String, for id: String) {
        let spoken = PlainText.spoken(text)
        // A table's rule or a code block's fence, alone on its line: nothing to say.
        guard spoken.contains(where: { $0.isLetter || $0.isNumber }), !spoken.hasPrefix("`") else { return }
        spokenAnything = true
        guard dialect.streamsAnswers, !collecting else {
            answer += (answer.isEmpty ? "" : " ") + spoken
            return
        }
        for part in LiveFragment.appendable(spoken) {
            send(dialect.answer(part, to: id, final: false, eventID: nextID("say")))
        }
    }

    /// Quiet progress, for the voice to mention if it likes ("it's checking your calendar").
    private func think(_ text: String, for id: String) {
        send(dialect.note(text, to: id, eventID: nextID("think")))
    }

    private func send(_ messages: [JSONValue]) {
        guard let call else { return }
        for message in messages { _ = call.send(type(of: dialect).encode(message)) }
    }

    private func nextID(_ prefix: String) -> String {
        eventCount += 1
        return "\(prefix)_\(eventCount)"
    }

    /// The last five minutes of the exchange, eighty pieces at most, as Hermes Desktop sends.
    private func recentFragments() -> [LiveFragment] {
        guard let last = fragments.last else { return [] }
        return Array(fragments.filter { $0.endMs >= last.endMs - 5 * 60_000 }.suffix(80))
    }
}

/// Why a call couldn't be had, in words.
nonisolated struct LiveFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    /// A machine reason from the service, as a sentence where Redde knows it.
    static func readable(_ reason: String, engine: LiveEngine = .gptLive) -> String {
        switch reason {
        case "connection_lost": String(localized: "The connection to \(engine.name) dropped.")
        case "max_duration", "session_expired", "go_away": String(localized: "The \(engine.name) call reached its time limit.")
        default: reason.contains(" ") ? reason : String(localized: "\(engine.name) ended the call (\(reason)).")
        }
    }
}

/// A piece of the spoken exchange as the service transcribes it.
nonisolated struct LiveFragment: Equatable, Sendable {
    enum Speaker: Equatable, Sendable { case person, voice }
    var speaker: Speaker
    var text: String
    var startMs: Int
    var endMs: Int

    /// The most one append may carry: the service takes 500 tokens; about four characters each, with room.
    static let appendLimit = 1_400

    /// What a handed-over request is: the person's last words (what the chat shows they said),
    /// and the exchange before them, newest last, for the agent alone.
    static func delegation(from fragments: [LiveFragment]) -> (prompt: String, context: String) {
        var turns: [(speaker: Speaker, text: String)] = []
        for fragment in fragments {
            if let last = turns.last, last.speaker == fragment.speaker {
                turns[turns.count - 1].text += fragment.text
            } else {
                turns.append((fragment.speaker, fragment.text))
            }
        }
        func clean(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let prompt = clean(turns.last { $0.speaker == .person }?.text ?? "")
        // What the voice said after the person's last words is its reaction to this very request:
        // "let me check", or a guess at the answer. Given to the agent, "the Christmas tree is off"
        // was taken for a fact and confirmed with no tool called (Home, 2026-10-25). The exchange
        // goes up to the request.
        if let asked = turns.lastIndex(where: { $0.speaker == .person }) { turns.removeSubrange((asked + 1)...) }
        let context = turns.compactMap { turn -> String? in
            let text = clean(turn.text)
            return text.isEmpty ? nil : "\(turn.speaker == .person ? "User" : "Voice assistant"): \(text)"
        }.joined(separator: "\n")
        return (prompt.isEmpty ? String(context.suffix(400)) : prompt, context)
    }

    /// What the person said, a turn at a time (the voice's words between them dividing them), tidied.
    static func personTurns(_ fragments: [LiveFragment]) -> [String] {
        var turns: [String] = []
        var current = ""
        for fragment in fragments {
            if fragment.speaker == .person {
                current += fragment.text
            } else if !current.isEmpty {
                turns.append(current)
                current = ""
            }
        }
        if !current.isEmpty { turns.append(current) }
        return turns.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.filter { !$0.isEmpty }
    }

    /// Text in pieces the service takes: whole sentences where they fit.
    static func appendable(_ text: String, limit: Int = appendLimit) -> [String] {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > limit else { return clean.isEmpty ? [] : [clean] }
        var parts: [String] = []
        var current = ""
        var sentences: [String] = []
        var rest = Substring(clean)
        while let end = rest.firstMatch(of: /[.!?]\s+/) {
            sentences.append(String(rest[...end.range.lowerBound]))
            rest = rest[end.range.upperBound...]
        }
        if !rest.isEmpty { sentences.append(String(rest)) }
        for sentence in sentences {
            if sentence.count > limit {
                if !current.isEmpty { parts.append(current); current = "" }
                var rest = Substring(sentence)
                while !rest.isEmpty { parts.append(String(rest.prefix(limit))); rest = rest.dropFirst(limit) }
                continue
            }
            let joined = current.isEmpty ? sentence : current + " " + sentence
            if joined.count > limit { parts.append(current); current = sentence } else { current = joined }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

/// Hears the call for `LiveVoice`: a call holds what it tells weakly.
private final class Relay: LiveCallListening {
    weak var owner: LiveVoice?
    init(owner: LiveVoice) { self.owner = owner }
    func liveCallReceived(_ event: String) { owner?.received(event) }
    func liveCallChanged(_ state: LiveCallState) { owner?.callChanged(state) }
}

#if DEBUG
/// With `-echo.liveMeasure`: Library/Caches/live-measure.log, a line at a time, read off the
/// phone after a call (`devicectl device copy from`).
enum LiveMeasure {
    /// Every call in a development build, not only those started with `-echo.liveMeasure` (the
    /// costs every ten seconds stay with it): what went on in a call the person made is there to
    /// read afterwards. Started afresh past a megabyte. `name`: another file in Caches, for another
    /// part of voice (wake.log, `WakeListener`).
    static func write(_ line: String, to name: String = "live-measure.log") {
        let file = URL.cachesDirectory.appending(path: name)
        if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: file)
        }
        let text = Date.now.formatted(.iso8601.time(includingFractionalSeconds: true)) + " " + line + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
#endif

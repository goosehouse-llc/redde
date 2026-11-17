import Foundation
import os

// VoiceSession's public actions (listen, mute, pause, stop, answer a call) and its GPT-Live calls.
extension VoiceSession {
    // MARK: - Public actions

    /// The voice screen's camera button. Leaving the voice screen closes the camera; Stop and a
    /// finished reply leave it open, for the next question about the same thing.
    func setLooking(_ on: Bool) {
        lookProblem = nil
        guard on != isLooking else { return }
        isLooking = on   // at once, so the button shows it; taken back if the camera can't be had
        guard on else { eye.close(); return }
        Task {
            let opened = await eye.open()
            if !isLooking {
                eye.close()   // switched off again while it was opening
            } else if !opened {
                isLooking = false
                lookProblem = String(localized: "Redde can't use the camera. Allow it in Settings → Privacy & Security → Camera.")
            }
        }
    }

    /// Tap the mic: start listening. If a reply is being spoken, this barges in. `capturing`:
    /// for a note (`CaptureInbox`), which leaves the conversation and whatever it is doing alone.
    func beginListening(capturing: Bool = false) {
        // On a call already: the microphone opens again if it was shut, and that is all.
        if live != nil { unmute(); return }
        if asking != nil {
            // Tapped while the request is being read out: hear the answer now. The turn is not
            // one to barge in on; it waits for that answer.
            guard phase == .speaking else { return }
            output.stop()
            listenForAnswer()
            return
        }
        // A note is taken between turns, never over a reply: that would end the reply for it.
        if capturing, phase != .idle, !isErrored { return }
        replaying = false
        guard phase == .idle || phase == .speaking || isErrored else { return }
        // A group chat's call, where its voice is one.
        if !capturing, let roomCall {
            output.stop()
            let (room, engine) = roomCall()
            startLive(room: room, engine: engine)
            return
        }
        // GPT-Live: a call instead, where the chat's bot (or the app) has it. A note and a group
        // chat's voice stay Redde's own.
        if !capturing, sendsTo == nil, liveWanted(conversation.bot?.profile) {
            output.stop()
            startLive(alreadySaid: callLineSaid)
            callLineSaid = nil
            return
        }
        isCapturing = capturing
        isMuted = false
        stopMonitor()   // the mic behind a reply closes; listening opens it afresh
        output.stop()
        replyTask?.cancel()
        // Barge-in: stop the server turn too, or it keeps streaming (and billing) unheard. A
        // note has nothing to do with a reply being typed out on the phone meanwhile.
        if conversation.isStreaming, !capturing { conversation.cancel() }
        metrics = VoiceMetrics()
        phase = .listening
        liveTranscript = ""
        Task { await startRecognizer() }
    }

    /// A wake phrase said with a request after it ("Hey Home, turn the lights off",
    /// `WakeListener`): asked at once, as if voice mode had just heard it, in the chat open now;
    /// where that chat has a call, the call opens saying the answer.
    func ask(_ text: String) {
        guard live == nil, asking == nil, phase == .idle || isErrored else { return }
        if sendsTo == nil, liveWanted(conversation.bot?.profile) {
            output.stop()
            startLive(opening: text)
            return
        }
        replaying = false
        isCapturing = false
        isMuted = false
        stopMonitor()
        output.stop()
        replyTask?.cancel()
        metrics = VoiceMetrics()
        phase = .listening
        liveTranscript = text
        Task {
            do { try audio.activateForVoice() } catch {
                log.error("audio for a wake request: \(error.localizedDescription)")
            }
            await handleUtterance(text)
        }
    }

    /// An agent's call, answered (`AgentCalls`): the agent's line said, in its voice, and then the
    /// person heard, hands-free, as on a call, until it ends. Where the agent's chat has a live
    /// voice, the call opens saying the line. `listen` false (a locked iPhone, or Redde's lock): the
    /// line, then `untilThen` ("Unlock your iPhone to answer."), the microphone shut until
    /// `beginListening`; a live call then knows the line was said. `ended`: told when voice mode
    /// ends (`callEnded`).
    func answerCall(saying line: String, listen: Bool, untilThen: String? = nil, ended: @escaping () -> Void) {
        if live != nil || phase != .idle, !isErrored { cancel() }   // (what was going on is over; its own call, if any, with it)
        callEnded = ended
        continuous = true
        callLineSaid = listen ? nil : line
        if listen, sendsTo == nil, liveWanted(conversation.bot?.profile) {
            output.stop()
            startLive(greeting: line)
            return
        }
        replaying = false
        isCapturing = false
        isMuted = false
        output.speaker = conversation.bot?.profile
        do { try audio.activateForVoice() } catch {
            phase = .error(error.localizedDescription); return
        }
        replaying = true
        replayResumesHandsFree = listen
        phase = .speaking
        output.beginReply()
        output.append(line)
        if !listen, let untilThen { output.append(" " + untilThen) }
        output.endReply()
    }

    /// Voice mode is over: the agent's call it answered, if any, ends with it.
    func endCall() {
        guard let callEnded else { return }
        self.callEnded = nil
        callEnded()
    }

    /// The phone locked, or Redde was left for another app, while the mic was open. Listening
    /// now survives the background (the `audio` background mode), so a mic left open on a locked
    /// phone would stay open for good. Unless the person is in a hands-free conversation or on
    /// the car's screen, stop listening and go idle. A reply being thought about or spoken is
    /// left alone: that is what the background modes are for.
    func leftForeground(carPlayConnected: Bool) {
        guard !continuous, !carPlayConnected else { return }
        // A call, too: an open microphone on a locked phone, and a bill running; unless calls are
        // to go on locked (Settings → Voice → Voice mode; asked 2026-10-26: "keep the call live
        // when locked").
        if live != nil {
            if liveWhenLocked() {
                log.info("left the foreground on a live call: kept on, as set")
                return
            }
            log.info("left the foreground on a live call: hanging up")
            cancel()
            return
        }
        // The same goes for the mic behind a reply: the reply plays on, and can't be talked over.
        if phase == .thinking || phase == .speaking { stopMonitor() }
        // And for a mic waiting on an answer: the request stays, on the screen and in its notification.
        if asking != nil, phase == .listening { leaveForTheScreen(saying: false); return }
        guard phase == .listening else { return }
        log.info("left the foreground while listening: stopping")
        cancel()
    }

    /// Shut the mic without ending the conversation, so nothing said in the car is taken for a
    /// question. Only while listening; hands-free stays as it was for when the mic comes back.
    func mute() {
        #if DEBUG
        if barPosed { isMuted = true; return }
        #endif
        if let live {
            guard !isMuted else { return }
            isMuted = true
            live.setMuted(true)
            return
        }
        guard phase == .listening else { return }
        // Muted instead of answering: the request waits on the screen, the turn on the request.
        if asking != nil { leaveForTheScreen(saying: false); return }
        recognizer.cancel()
        isMuted = true
        phase = .idle
        releaseAudioAfterCue()   // the car's own audio comes back while Redde isn't listening
    }

    func unmute() {
        guard isMuted else { return }
        #if DEBUG
        if barPosed { isMuted = false; return }
        #endif
        if let live {
            isMuted = false
            live.setMuted(false)
            return
        }
        beginListening(capturing: isCapturing)   // a note being taken is still a note
    }

    /// Tap again while listening: end the utterance now.
    func endListening() {
        guard phase == .listening else { return }
        Task {
            let text = await recognizer.stop()
            await handleUtterance(text)
        }
    }

    /// The screen stays on while the mic is open and while a reply is being spoken, so auto-lock
    /// doesn't cut a conversation off, and through the wait for the reply in between, up to a
    /// point. A paused reply, an error and idle give auto-lock back.
    func updateScreenAwake() {
        awakeTimeout?.cancel()
        awakeTimeout = nil
        // A call that goes on with the phone locked needn't hold the screen on for the whole of
        // it, its face drawn all the while: a minute after the voice last started or stopped
        // talking, auto-lock has it back (battery review, 2026-11-11). One that would hang up
        // when locked keeps the screen on, as before.
        if live != nil, liveWhenLocked() {
            let on = phase != .idle && !isErrored
            setScreenAwake(on)
            guard on else { return }
            awakeTimeout = Task { [weak self, awakeInCall] in
                try? await Task.sleep(for: awakeInCall)
                guard let self, !Task.isCancelled, live != nil else { return }
                setScreenAwake(false)
            }
            return
        }
        let wanted: Bool
        switch phase {
        case .listening: wanted = true
        case .speaking: wanted = !isPaused
        case .thinking:
            wanted = true
            awakeTimeout = Task { [weak self, awakeWhileThinking] in
                try? await Task.sleep(for: awakeWhileThinking)
                guard let self, !Task.isCancelled, phase == .thinking else { return }
                setScreenAwake(false)
            }
        case .idle, .error: wanted = false
        }
        setScreenAwake(wanted)
    }

    private func setScreenAwake(_ on: Bool) {
        guard on != screenAwake else { return }
        screenAwake = on
        keepAwake(on)
    }

    /// Pause / Play: the voice screen's while a reply is being read, and the car's also while
    /// it is still being thought about. Then the agent works on and the reply waits, whole,
    /// until Play.
    func pauseSpeaking() {
        // A call can't hold what its voice says: Pause shuts the microphone instead.
        if live != nil { mute(); return }
        guard phase == .speaking || phase == .thinking, !isPaused else { return }
        output.pause()
        isPaused = true
        playThinkingSound(false)   // held is quiet
    }

    func resumeSpeaking() {
        if live != nil { unmute(); return }
        guard phase == .speaking || phase == .thinking, isPaused else { return }
        output.resume()
        isPaused = false
    }

    /// The Stop button while speaking: silence the reply and go idle. Hands-free stays
    /// switched on for the next tap; the server turn is cancelled if it is still streaming.
    func stopSpeaking() {
        if live != nil { cancel(); return }
        guard phase == .speaking else { return }
        cancel()
    }

    /// Voice mode opened while a typed reply is still coming in (asked 2026-10-28: "make it fluid
    /// between the two"): what the reply has said so far is read out, and the rest as it comes;
    /// then voice mode goes on as after any reply (listening again, hands-free). Opening it used to
    /// count as talking over the reply, and stopped it. Stop silences the reading; the reply goes
    /// on, on the screen.
    func joinReply() {
        guard live == nil, asking == nil, conversation.isStreaming, replyTask == nil,
              let reply = conversation.messages.last, reply.role == .assistant,
              beginReading(resumeHandsFree: true, speaker: conversation.bot?.profile) else { beginListening(); return }
        let id = reply.id
        joinTask?.cancel()
        joinTask = Task { [weak self] in
            var said = 0
            while let self, !Task.isCancelled, replaying, phase == .speaking {
                let streaming = conversation.isStreaming
                let text = conversation.messages.last { $0.id == id }?.text ?? ""
                if text.count > said {
                    continueReading(String(text.dropFirst(said)))
                    said = text.count
                }
                if !streaming { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            self?.endReading()
        }
    }

    /// The agent going on by itself (2.7): the agents it asked by @name answered, and its reply to
    /// what they said is coming in (`Conversation.relayTags`). Read as `joinReply` reads a typed
    /// reply, once Redde is quiet: after the reply being said, with the mic set aside if it was
    /// open behind it and nothing had been said, and listening again after, hands-free. Never over
    /// the person: once they have begun to speak it stays on the screen. Not on a live call, a
    /// group chat's voice, muted, or with a request being asked.
    func joinFollowOn(reply id: UUID) {
        followOnTask?.cancel()
        followOnTask = Task { [weak self] in
            // A minute at most for the reply before it to finish being said.
            for _ in 0 ..< 600 {
                guard let self, !Task.isCancelled, live == nil, sendsTo == nil, asking == nil, !isMuted else { return }
                switch phase {
                case .thinking, .speaking:
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                case .listening:
                    guard liveTranscript.isEmpty, recognizer.transcript.isEmpty else { return }   // the person is speaking
                    recognizer.cancel()
                    stopMonitor()
                    phase = .idle
                case .idle, .error:
                    break
                }
                if conversation.isStreaming, conversation.messages.last?.id == id {
                    joinReply()
                } else if let text = conversation.messages.last(where: { $0.id == id })?.text, !text.isEmpty {
                    readAloud(text, resumeHandsFree: true, speaker: conversation.bot?.profile)
                } else if continuous {
                    beginListening()
                }
                return
            }
        }
    }

    /// Puts a request made after the reply (the agent wanting to ask others, `AgentAsks`) to the
    /// person aloud, once the reply has been said: there's no turn going on to ask it in.
    func askAfterReply(_ interrupt: Interrupt) {
        followOnTask?.cancel()
        followOnTask = Task { [weak self] in
            for _ in 0 ..< 600 {
                guard let self, !Task.isCancelled, live == nil, sendsTo == nil, asking == nil, !isMuted else { return }
                switch phase {
                case .thinking, .speaking:
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                case .listening, .idle, .error:
                    break
                }
                // Answered on the screen meanwhile, or not one a voice can answer: the card's.
                guard conversation.pendingInterrupt?.interrupt.id == interrupt.id, answersAloud(), SpokenRequest(interrupt) != nil else { return }
                if phase == .listening {
                    guard liveTranscript.isEmpty, recognizer.transcript.isEmpty else { return }   // the person is speaking
                    recognizer.cancel()
                    stopMonitor()
                    phase = .idle
                }
                do { try audio.activateForPlayback() } catch { phase = .error(error.localizedDescription); return }
                output.speaker = conversation.bot?.profile
                output.beginReply()
                _ = ask(interrupt)
                return
            }
        }
    }

    /// The keyboard button (asked 2026-10-28: "it starts but then I click the keyboard… the
    /// message stops"): voice mode stops listening and reading, but the reply goes on, streaming
    /// into the conversation on screen, where it is read instead of heard. On a live call there
    /// is no reply apart from the call's: that ends as it would.
    func handOverToTyping() {
        if live != nil { cancel(); return }
        replyTask?.cancel()   // the turn is the conversation's, and goes on there
        replyTask = nil
        cancel()
    }

    func cancel() {
        #if DEBUG
        // What ends voice mode on an agent's call, for calls.log (a call ended 4 s in, 2026-10-26).
        if callEnded != nil {
            let from = Thread.callStackSymbols.dropFirst().prefix(4).map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first.map(String.init) ?? "" }
            LiveMeasure.write("voice mode stopped on a call, from: \(from.joined(separator: " < "))", to: "calls.log")
        }
        #endif
        callLineSaid = nil
        #if DEBUG
        if barPosed { leaveBar(); return }
        #endif
        if live != nil { endLive(); return }
        defer { endCall() }
        joinTask?.cancel()
        joinTask = nil
        followOnTask?.cancel()
        followOnTask = nil
        replaying = false
        isMuted = false
        isCapturing = false
        stopAsking()
        stopMonitor()
        // Only a turn this session started is ours to cancel: leaving the voice screen while a
        // typed reply streams must not kill it.
        let ownsTurn = replyTask != nil
        replyTask?.cancel()
        replyTask = nil
        output.stop()
        recognizer.cancel()
        if ownsTurn { conversation.cancel() }
        let wasListening = phase == .listening
        phase = .idle
        if wasListening { releaseAudioAfterCue() } else { output.releaseAudio(); audio.deactivate() }
    }

    /// Deactivating in the same beat as the stop cue clips it; give the tone a moment to
    /// finish before handing the session back (other audio resumes ~half a second later).
    func releaseAudioAfterCue() {
        output.releaseAudio()
        Task { [weak self, cueSettle] in
            try? await Task.sleep(for: cueSettle + .milliseconds(100))
            guard let self, phase == .idle || isErrored else { return }
            audio.deactivate()
        }
    }

    // MARK: - GPT-Live

    /// Calls GPT-Live: the microphone allowed and the audio session set up for voice, as for
    /// listening, then the call (`LiveVoice`), whose state is shown as the phase from here on.
    /// `opening`: a request asked before the call opens (`ask`).
    private func startLive(opening: String? = nil, greeting: String? = nil, alreadySaid: String? = nil, room: LiveRoom? = nil,
                           engine: LiveEngine? = nil) {
        // A room's call is in the engine its group chats use, not the open chat's bot's.
        let live = room == nil ? makeLive(conversation) : LiveVoice(conversation: conversation, engine: engine)
        live.opening = opening
        live.greeting = greeting
        live.alreadySaid = alreadySaid
        live.room = room
        self.live = live
        liveBegan = .now
        inBar = false
        isMuted = false
        isCapturing = false
        liveTranscript = ""
        liveSaid = ""
        live.onChange = { [weak self, weak live] in
            guard let self, let live, self.live === live else { return }
            mirrorLive()
        }
        // Hands-free off: one question, one answer, as Redde's own voice does. A room's goes on.
        live.endsAfterAnswer = { [weak self] in room == nil && !(self?.continuous ?? true) }
        activeTool = String(localized: "Calling \(live.engine.name)…", comment: "Voice mode: a live voice call is being opened")
        phase = .thinking
        Task {
            guard await micAllowed() else {
                endLive(problem: String(localized: "Redde can't use the microphone. Allow it in Settings → Privacy & Security → Microphone."))
                return
            }
            guard self.live === live else { return }
            do { try audio.activateForVoice() } catch {
                endLive(problem: error.localizedDescription)
                return
            }
            await live.start()
        }
    }

    /// The call as the phase: connecting and working as thinking, its voice as speaking, the rest
    /// as listening (idle while the microphone is shut).
    private func mirrorLive() {
        guard let live else { return }
        liveTranscript = live.heard
        liveSaid = live.said
        switch live.state {
        case .ended:
            endLive(problem: live.problem)
            return
        case .connecting:
            phase = .thinking
        case .listening:
            activeTool = nil
            phase = isMuted ? .idle : .listening
        case .thinking:
            activeTool = live.tool
            phase = .thinking
        case .speaking:
            let wasSpeaking = phase == .speaking
            phase = .speaking
            if !wasSpeaking { soundStartedAt = .now }
        }
        if live.connected, !liveCued {
            liveCued = true
            earcon(.listening)
            audio.refreshRoute()   // the call's voice processing just reset the output
        }
    }

    /// The call is over: hung up here, or ended by the service or a lost connection (`problem`).
    private func endLive(problem: String? = nil) {
        guard let live else { return }
        #if DEBUG
        if callEnded != nil { LiveMeasure.write("the live call ended on an agent's call\(problem.map { ": " + $0 } ?? "")", to: "calls.log") }
        #endif
        live.onChange = nil
        if live.state != .ended { live.hangUp() }
        isMuted = false
        inBar = false
        liveBegan = nil
        liveSaid = ""
        activeTool = nil
        // While the call is still the session's, so the phase change makes no cue or audio change of its own.
        phase = problem.map { .error($0) } ?? .idle
        self.live = nil
        if liveCued { earcon(.stopped) }
        liveCued = false
        releaseAudioAfterCue()
        endCall()
    }
}

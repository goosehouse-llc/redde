import Foundation
import Observation
import os

// VoiceSession's interruptions: a request answered aloud (or by a nod), and talking over a reply.
extension VoiceSession {
    // MARK: - Answering a request aloud

    /// Puts a request the agent waits on to the person aloud, after whatever of the reply is
    /// still being said. False when Settings doesn't allow it or a voice can't answer it: then
    /// it is the screen's, as it always was.
    func ask(_ interrupt: Interrupt) -> Bool {
        guard answersAloud(), let request = SpokenRequest(interrupt) else { return false }
        // The request is not a reply to talk over: a "yes" said early would end the whole turn.
        stopMonitor()
        asking = request
        unclearAnswers = 0
        activeTool = nil
        phase = .speaking
        output.append("\n\n" + request.prompt)
        output.endReply()
        watchRequest()
        return true
    }

    /// Notices at once when the request is settled some other way: its card on the screen, its
    /// notification, the host's own time limit. The next event of the turn would say so too, but
    /// that can be a long command away, with the mic open all the while.
    private func watchRequest() {
        withObservationTracking {
            _ = conversation.pendingInterrupt?.interrupt.id
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let asking = self.asking else { return }
                if self.conversation.pendingInterrupt?.interrupt.id == asking.id { self.watchRequest() } else { self.answeredElsewhere() }
            }
        }
    }

    /// Opens the mic for the answer. The turn stays as it is, waiting.
    func listenForAnswer() {
        phase = .listening
        liveTranscript = ""
        Task { await startRecognizer() }
        answerTimeout?.cancel()
        answerTimeout = Task { [weak self, answerWindow] in
            try? await Task.sleep(for: answerWindow)
            guard let self, !Task.isCancelled, asking != nil, phase == .listening, recognizer.transcript.isEmpty else { return }
            endListening()   // nothing was said: that is no answer
        }
    }

    func heardAnswer(_ text: String, to request: SpokenRequest) {
        answerTimeout?.cancel()
        liveTranscript = text
        guard conversation.pendingInterrupt?.interrupt.id == request.id else { answeredElsewhere(); return }
        if let answer = request.answer(text) {
            log.info("a request answered aloud")
            answered(answer, to: request)
            return
        }
        unclearAnswers += 1
        guard unclearAnswers < 2 else { leaveForTheScreen(saying: true); return }
        phase = .speaking
        output.speaker = conversation.bot?.profile
        output.beginReply()
        output.append(request.reminder)
        output.endReply()
    }

    /// The answer goes to the agent the way the card's buttons send it.
    private func answered(_ answer: SpokenRequest.Answer, to request: SpokenRequest) {
        asking = nil
        respond(answer)
        // Said back, so a mishearing is heard; the reply carries on behind it.
        phase = .speaking
        output.speaker = conversation.bot?.profile
        output.beginReply()
        output.append(request.confirmation(of: answer) + " ")
        if canBeTalkedOver() { micStaysOpen = true; startMonitor() }
    }

    // MARK: A nod or a shake

    /// A nod or a shake of the head would answer right now: the voice screen says so.
    var headAnswers: Bool { asking?.takesNod == true && head.isSensing }

    /// The AirPods' movement is read from when a request starts being read out until it is
    /// settled, and at no other time. From the start, so that by the time the request has been
    /// read the AirPods are answering and a nod begun on its last words is seen whole.
    func watchHead() {
        guard let asking, asking.takesNod, answersByNod(), audio.route == .headphones else { head.stop(); return }
        head.start { [weak self] gesture in self?.headMoved(gesture) }
    }

    /// A nod approves and a shake denies, but only once the request has been read out and the
    /// mic is open for the answer. A nod along to the reply before it, or to the request while
    /// it is still being read, answers nothing.
    private func headMoved(_ gesture: HeadGesture) {
        guard let asking, phase == .listening, let answer = asking.answer(nod: gesture == .nod) else { return }
        answerTimeout?.cancel()
        guard conversation.pendingInterrupt?.interrupt.id == asking.id else { answeredElsewhere(); return }
        log.info("a request answered by a \(gesture.rawValue, privacy: .public)")
        recognizer.cancel()   // whatever the mic had heard so far is not the answer
        liveTranscript = ""
        answered(answer, to: asking)
    }

    /// No answer came by voice: the request stays where it has been all along, on the screen (the
    /// car's card says "Needs your phone") and in its notification.
    func leaveForTheScreen(saying: Bool) {
        answerTimeout?.cancel()
        asking = nil
        activeTool = "waiting for you"
        if phase == .listening { recognizer.cancel() }
        guard saying else { phase = .thinking; return }
        leftForScreen = true
        phase = .speaking
        output.speaker = conversation.bot?.profile
        output.beginReply()
        output.append(String(localized: "It's waiting for you on your iPhone.", bundle: VoiceWords.current.bundle, comment: "Said aloud in voice mode: a request that has to be answered on the screen"))
        output.endReply()
    }

    /// The request was settled some other way while it was being asked about.
    func answeredElsewhere() {
        guard asking != nil else { return }
        answerTimeout?.cancel()
        asking = nil
        if phase == .listening { recognizer.cancel() }
        output.stop()
        output.speaker = conversation.bot?.profile
        output.beginReply()
        phase = .thinking
    }

    /// The conversation is over: nothing is being asked any more.
    func stopAsking() {
        answerTimeout?.cancel()
        asking = nil
        leftForScreen = false
    }

    // MARK: - Talking over a reply

    /// Whether talking over a reply applies to what this turn plays through (Settings → Voice).
    /// In a car, only with Stop and Skip in the car on, and then for those two words alone: its
    /// speakers are near its microphone, and nothing else said there (the radio, a passenger)
    /// should cut a reply short.
    func canBeTalkedOver() -> Bool {
        if inCar { return commandsInCar() }
        return switch (talkOver(), audio.route) {
        case (.off, _), (_, .car), (.headphones, .speaker): false
        case (_, .headphones), (.everywhere, .speaker): true
        }
    }

    /// Opens the mic behind the reply that is on its way. The recogniser is given nothing yet: it
    /// must not hear Redde's own voice (see `BargeInDetector`).
    func startMonitor() {
        monitorSerial += 1
        let serial = monitorSerial
        monitorTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recognizer.startHeld { [weak self] text in
                    Task { await self?.handleUtterance(text) }
                }
            } catch {
                guard monitorSerial == serial else { return }
                if !(error is CancellationError) { log.error("couldn't keep the mic open behind the reply: \(error.localizedDescription)") }
                // The reply plays as one that can't be talked over.
                monitorTask = nil
                micStaysOpen = false
                audio.setReplying(phase == .thinking || phase == .speaking)
                return
            }
            guard monitorSerial == serial else { return }   // stopped meanwhile; `stopMonitor` closed the mic
            monitorTask = nil
            guard phase == .thinking || phase == .speaking else { recognizer.cancel(); return }
            audio.refreshRoute()   // the engine's voice-processing unit just reset the output
            monitoring = true
            watchIfSpeaking()
        }
    }

    /// Closes the mic behind a reply, however far opening it had got.
    func stopMonitor() {
        guard micStaysOpen || monitoring || monitorTask != nil else { return }
        handOverMic()
        recognizer.cancel()
    }

    /// The mic behind the reply stops being that: closed by the caller, or kept as the listening mic.
    func handOverMic() {
        monitorSerial += 1
        monitorTask = nil
        confirmTask?.cancel()
        confirmTask = nil
        monitoring = false
        micStaysOpen = false
        recognizer.watchForVoice(nil, heard: nil)
    }

    /// Watch for a voice exactly while a reply is being spoken: not while it is paused, not over
    /// the "Okay." after a stop phrase, and not while a voice is already being looked into.
    /// `midReply`: the reply never stopped playing, so there is no start of it to wait out.
    func watchIfSpeaking(midReply: Bool = false) {
        guard monitoring, confirmTask == nil else { return }
        if phase == .speaking, !isPaused, !acknowledging {
            var detector = audio.route == .headphones ? BargeInDetector.headset : .echoCancelled
            if midReply { detector.settle = 0; detector.rearm() }
            recognizer.watchForVoice(detector) { [weak self] in self?.voiceOverReply() }
        } else {
            recognizer.watchForVoice(nil, heard: nil)
        }
    }

    /// Something is being said over the reply. What happens next is Settings → Voice →
    /// Interrupt with.
    private func voiceOverReply() {
        guard monitoring, phase == .speaking, confirmTask == nil else { return }
        #if DEBUG
        // Whether the thinking sound is taken for the person: a voice heard while it plays, or
        // within half a second of it stopping, is noted as such.
        let fromSound = thinkingSoundOn || thinkingSoundStopped.map { ContinuousClock.now - $0 < .milliseconds(500) } == true
        LiveMeasure.write("a voice heard over the reply\(fromSound ? " WHILE THE THINKING SOUND PLAYED" : "") (\(audio.route), output \(String(format: "%.3f", output.meterLevel)))", to: "voice-turns.log")
        #endif
        if inCar || interruption() == .stopWord { listenForStop() } else { holdToHearWords() }
    }

    /// CarPlay connected, or the car's own audio as the route (its Bluetooth alone).
    private var inCar: Bool { carConnected() || audio.route == .car }

    /// "Only stop": the reply plays on, whoever is talking, and the recogniser listens for one
    /// word. It hears what the microphone hears while Redde speaks, which is what went wrong
    /// when any word counted; here whatever else it writes down is ignored, and it listens only
    /// while a voice is actually there. "Stop" ends the reply and the conversation, like the stop
    /// phrase between turns.
    private func listenForStop() {
        log.info("a voice over the reply: listening for \"stop\"")
        recognizer.beginTranscribing(withHeldAudio: true, endsOnSilence: false)
        let own = stopPhrases()
        // In the car "skip" counts too: the rest of the reply isn't read.
        let skips = inCar
        confirmTask = Task { [weak self, stopWordQuiet] in
            let clock = ContinuousClock()
            var heard = ""
            var changedAt = clock.now
            while true {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                let now = recognizer.transcript
                if StopWord.heard(in: now, own: own) {
                    confirmTask = nil
                    stoppedByWord()
                    return
                }
                if skips, StopWord.skipHeard(in: now) {
                    confirmTask = nil
                    skippedByWord()
                    return
                }
                if now != heard { heard = now; changedAt = clock.now }
                if clock.now - changedAt > stopWordQuiet {
                    // The talking is over and the word wasn't in it: back to watching the level.
                    confirmTask = nil
                    recognizer.holdAgain()
                    watchIfSpeaking(midReply: true)
                    return
                }
            }
        }
    }

    /// "Stop" was said over the reply: it ends, the turn with it, and so does hands-free, with
    /// the same "Okay." as a stop phrase between turns.
    private func stoppedByWord() {
        log.info("\"stop\" over the reply")
        stopMonitor()
        replyTask?.cancel()
        replyTask = nil
        if conversation.isStreaming { conversation.cancel() }
        continuous = false
        acknowledging = true
        output.speaker = conversation.bot?.profile
        output.beginReply()   // (drops what was left of the reply)
        output.append(Self.okay)
        output.endReply()
    }

    /// "Skip" was said over the reply, in the car: the rest of it isn't read, as if it had come to
    /// its end. Hands-free listens for what's next; one question, and the conversation is done.
    /// A reply still on its way stops there, what came of it kept in the chat, as when it is
    /// talked over.
    private func skippedByWord() {
        log.info("\"skip\" over the reply")
        replyTask?.cancel()
        replyTask = nil
        if conversation.isStreaming { conversation.cancel() }
        output.stop()
        replyFinishedSpeaking()
    }

    /// "Anything you say": hold the reply and let the recogniser listen, starting a second back,
    /// to a room Redde is no longer talking in. Words within the window make it an interruption;
    /// none, or only a listener's "mm-hm" or "okay", and the reply carries on.
    private func holdToHearWords() {
        log.info("a voice over the reply: holding it to hear whether it is words")
        output.pause()
        recognizer.beginTranscribing(withHeldAudio: true, endsOnSilence: false)
        confirmTask = Task { [weak self, confirmWindow] in
            let clock = ContinuousClock()
            let deadline = clock.now + confirmWindow
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                // ("Okay" may yet become "okay, stop": a listener's noise waits out the window.)
                if !recognizer.transcript.isEmpty, !Backchannel.isOnly(recognizer.transcript) {
                    confirmTask = nil
                    interrupted()
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            confirmTask = nil
            carryOn()
        }
    }

    /// It was words: the reply ends here, as if the mic had been tapped, and what is being said
    /// is the next turn. The recogniser is already listening to it.
    private func interrupted() {
        log.info("talked over: the reply stops")
        handOverMic()
        recognizer.endOnSilence()   // an utterance like any other from here: a pause ends it
        output.stop()
        replyTask?.cancel()
        replyTask = nil
        if conversation.isStreaming { conversation.cancel() }
        metrics = VoiceMetrics()
        metrics.listenStartedAt = .now
        phase = .listening
        liveTranscript = recognizer.transcript
        observeTranscript()
    }

    /// It wasn't words (a cough, a door): the mic goes back to waiting and the reply carries on.
    private func carryOn() {
        guard monitoring, phase == .speaking else { return }
        log.info("no words: the reply carries on")
        recognizer.holdAgain()
        if !isPaused { output.resume() }
        watchIfSpeaking()
    }
}

import Foundation
import Observation
import os

// VoiceSession's pipeline: the recogniser, a turn sent and its reply read, and the thinking sound.
extension VoiceSession {
    // MARK: - Pipeline

    /// Voice-chat mode (and its call-volume buttons) only while the mic is open, which it stays
    /// behind a reply that can be talked over; the at-ear sensor only while speaking, as it blanks
    /// the screen whenever it's covered.
    func audioForPhase() {
        audio.setReplying((phase == .thinking || phase == .speaking) && !micStaysOpen)
        audio.setEarRouting(phase == .speaking)
    }

    func startRecognizer() async {
        do {
            guard await requestPermissions() else {
                throw SpeechRecognizer.Failure.permissionDenied
            }
            guard phase == .listening else { return }   // answered or cancelled meanwhile (a nod can be that quick)
            do {
                try audio.activateForVoice()
            } catch {
                // Siri usually still owns the session right after launching us. Retry for a while.
                log.info("audio activation failed (\(error.localizedDescription)); retrying")
                var attempts = 0
                while attempts < 25 {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard phase == .listening else { return }
                    if (try? audio.activateForVoice()) != nil { break }
                    attempts += 1
                }
                if attempts >= 25 { throw error }
                log.info("audio activated after \(attempts + 1) retries")
            }
            try await recognizer.start { [weak self] text in
                Task { await self?.handleUtterance(text) }
            }
            audio.refreshRoute()   // the engine's voice-processing unit just reset the output
            earcon(.listening)     // audible now: the session is active and routed
            metrics.listenStartedAt = .now
            observeTranscript()
        } catch {
            // Cancelled meanwhile (a tap, an interruption, AirPods out): that path already went idle.
            guard phase == .listening, !(error is CancellationError) else { return }
            log.error("listen failed: \(error.localizedDescription)")
            phase = .error(error.localizedDescription)
            // The session was activated for a listen that never happened; don't keep other
            // apps' audio paused behind it.
            output.releaseAudio(); audio.deactivate()
        }
    }

    func observeTranscript() {
        transcriptWatch &+= 1
        observeTranscript(watch: transcriptWatch)
    }

    private func observeTranscript(watch: Int) {
        withObservationTracking {
            liveTranscript = recognizer.transcript
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.phase == .listening, self.transcriptWatch == watch else { return }
                self.observeTranscript(watch: watch)
            }
        }
    }

    /// What was heard is one letter and nothing else ("Q", "a.", " K "): a digit is a number someone said.
    nonisolated static func isLoneLetter(_ text: String) -> Bool {
        let kept = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }
        return kept.count == 1 && kept.allSatisfy { CharacterSet.letters.contains($0) }
    }

    func handleUtterance(_ text: String) async {
        guard phase == .listening else { return }
        if let asking { heardAnswer(text, to: asking); return }
        metrics.speechEndedAt = .now
        liveTranscript = text
        // A lone letter is noise the recogniser made words of (a car's hum came out as "Q", which a
        // bot took for a whole question and made up a turn around): not sent, as nothing heard is.
        // An answer to a question being asked was taken above, a letter for a choice included.
        guard !text.isEmpty, !Self.isLoneLetter(text) else {
            log.info("empty utterance\(text.isEmpty ? "" : " (a lone letter, dropped)")")
            isCapturing = false
            phase = .idle
            releaseAudioAfterCue()
            return
        }
        // ("Never mind" instead of a note: no note.)
        if StopPhrase.matches(text, own: stopPhrases()) {
            log.info("stop phrase heard: \(text, privacy: .public)")
            isCapturing = false
            continuous = false
            acknowledging = true
            phase = .speaking
            output.speaker = conversation.bot?.profile
            output.beginReply()
            output.append(Self.okay)
            output.endReply()
            return
        }
        if let sendsTo, !isCapturing {
            log.info("said to a group chat")
            sendsTo(text)
            phase = .idle
            releaseAudioAfterCue()
            return
        }
        if isCapturing {
            // A note: kept, to be filed when the server can be reached, and that is all. No turn,
            // and the mic doesn't reopen, hands-free or not.
            log.info("a note taken")
            isCapturing = false
            takeNote(text)
            acknowledging = true
            phase = .speaking
            output.speaker = conversation.bot?.profile
            output.beginReply()
            output.append(String(localized: "Noted.", bundle: VoiceWords.current.bundle, comment: "Said aloud in voice mode, and Siri's answer: a note taken"))
            output.endReply()
            return
        }
        // What the camera sees as the question ends, before anything below takes its time.
        let seen = isLooking ? await eye.still() : nil
        await conversation.initialLoad?.value   // cold launch: the latest transcript may still be decoding
        guard phase == .listening else { return }
        micStaysOpen = canBeTalkedOver()
        phase = .thinking
        activeTool = nil
        metrics.requestSentAt = .now
        output.speaker = conversation.bot?.profile
        output.beginReply()
        // Spoken prefixes: a leading "Claude, …" becomes its text prefix, and a rule that names a
        // model moves the conversation there first (sticky). Only here, on the final endpointed
        // utterance; the composer's text is the user's own. A failed switch still sends: the
        // message is what the person said, the model is a preference.
        let route = VoiceRouting.route(text, rules: Settings.shared.spokenPrefixes)
        let outgoing = route?.text ?? text
        // A rule that names a bot ("Home, …") goes to its chat first, and voice stays there. A bot
        // that can't be reached is said, rather than the message going somewhere else.
        if let bot = route?.bot {
            do {
                if try await !conversation.goToBot(bot, mainName: Settings.shared.headerTitle) {
                    log.error("spoken prefix: no bot \(bot, privacy: .public) to go to here")
                }
            } catch {
                log.error("spoken prefix: couldn't open \(bot, privacy: .public): \(error.localizedDescription)")
                output.endReply()
                phase = .error(String(localized: "Couldn't open that bot's chat: \(error.localizedDescription)"))
                output.releaseAudio(); audio.deactivate()
                return
            }
        }
        if let model = route?.model {
            do { try await conversation.switchModel(model, provider: route?.provider) } catch {
                log.error("spoken prefix: model switch to \(model, privacy: .public) failed: \(error.localizedDescription)")
            }
        }
        // The reply is the chat's bot's, after a prefix may have moved there: read in its voice.
        output.speaker = conversation.bot?.profile
        // In a car (its CarPlay, or its Bluetooth alone), if Settings says so: a short answer.
        let events = conversation.send(outgoing, attachments: seen.map { [$0] } ?? [],
                                       brief: shortInCar() && (carConnected() || audio.route == .car))
        if !conversation.isIncognito { SiriHooks.donateSend(outgoing) }
        if micStaysOpen { startMonitor() }
        replySerial += 1
        let serial = replySerial
        turnOpen = true
        replyTask = Task { [weak self] in
            // A finished task must not keep counting as "our turn": cancel() would then kill a
            // typed reply that started later.
            defer { if let self, self.replySerial == serial { self.replyTask = nil; self.turnOpen = false } }
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                // The turn has moved on while a request was being asked about: it was answered on
                // the screen, from a notification, or by the host's own time limit.
                if let asking, conversation.pendingInterrupt?.interrupt.id != asking.id { answeredElsewhere() }
                switch event {
                case let .textDelta(delta):
                    if metrics.firstTokenAt == nil { metrics.firstTokenAt = .now }
                    if phase == .thinking { phase = .speaking }
                    output.append(delta)
                case .interim:
                    // Working text beside a tool call, already being said as it came ("Let me
                    // check the calendar"): out loud it tells the person what is going on.
                    break
                case .textFinal:
                    // The deltas have already been spoken; re-reading the finished text would
                    // say the whole reply twice. The transcript still gets the corrected copy.
                    break
                case let .usage(usage):
                    metrics.usage = usage
                case .reasoningDelta:
                    if metrics.firstTokenAt == nil { metrics.firstTokenAt = .now }
                case let .toolStarted(name, _, _):
                    activeTool = name
                case .toolFinished:
                    activeTool = nil
                case .done:
                    metrics.replyDoneAt = .now
                    turnOpen = false
                    output.endReply()
                case let .interrupt(interrupt, _):
                    // Conversation holds the request; the voice screen shows the card. Asked
                    // aloud too if Settings says so and it is one a voice can answer.
                    if !ask(interrupt) { activeTool = "waiting for you" }
                case .interruptExpired:
                    activeTool = nil
                case .status, .sessionID, .runID, .subagent, .prefill, .todos, .title, .picture:
                    break
                }
            }
            guard let self else { return }
            if conversation.lastSendWasHeld {
                // Nothing went out: say so, rather than waiting on a reply that isn't coming.
                continuous = false
                acknowledging = true
                phase = .speaking
                output.append(conversation.outbox.first?.state == .waitingForConnection
                    ? "I can't reach your server right now. I'll send that as soon as I can."
                    : "I'll send that after the current reply.")
                output.endReply()
                return
            }
            metrics.contextWindow = conversation.messages.last?.metrics?.contextWindow
            // The stream may end without .done (transport error, cancel); make sure the reply is
            // wound down either way so the session can't hang in .speaking.
            if conversation.lastError == nil { output.endReply() }
            if let error = conversation.lastError {
                output.stop()
                phase = .error(error)
                output.releaseAudio(); audio.deactivate()
            }
        }
    }

    // MARK: - The thinking sound

    /// The agent is at work and there is nothing to hear: before its first word, and in the
    /// middle of a reply while it uses its tools ("Let me check", and then a minute of nothing).
    private var isQuietlyWorking: Bool {
        switch thinkingSoundWanted() {
        case .off: return false
        case .car: if !carConnected(), audio.route != .car { return false }
        case .always: break
        }
        // Not while the turn waits for the person, which is not work; not over a reply that is
        // held; and not into a microphone left open on the phone's own speaker in a reply's
        // pause, where a sound that starts can pass for a voice (`BargeInDetector`). Before the
        // reply nothing listens for a voice (the open microphone only holds its last second), so
        // it plays then (2026-10-27: with Talk over replies on the speaker it never did).
        guard asking == nil, conversation.pendingInterrupt == nil, !isPaused, !acknowledging, !replaying,
              !(micStaysOpen && audio.route == .speaker && phase == .speaking && !Self.thinkingIntoOpenMic) else { return false }
        switch phase {
        case .thinking: return true
        case .speaking: return turnOpen && output.meterLevel < 0.02
        default: return false
        }
    }

    /// While Redde thinks or speaks, the quiet is watched; anywhere else the sound stops at once.
    func watchForQuiet() {
        guard phase == .thinking || phase == .speaking else {
            quietTask?.cancel()
            quietTask = nil
            playThinkingSound(false)
            #if DEBUG
            quietBlockNoted = false
            #endif
            return
        }
        guard quietTask == nil else { return }
        quietTask = Task { [weak self, quietCheck] in
            var since: ContinuousClock.Instant?
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    noteQuietInReply()
                    since = heardNothing(since: since)
                }
                try? await Task.sleep(for: quietCheck)
            }
        }
    }

    /// One look at a reply's quiet (`quietInReply`): set once it has lasted, cleared at its first sound.
    private func noteQuietInReply() {
        guard phase == .speaking, turnOpen, !isPaused, !acknowledging, !replaying, replyLevel < 0.02 else {
            replyQuietSince = nil
            if quietInReply { quietInReply = false }
            return
        }
        let start = replyQuietSince ?? .now
        replyQuietSince = start
        if !quietInReply, ContinuousClock.now - start >= quietInReplyAfter { quietInReply = true }
    }

    /// One look at the quiet: since when there has been nothing to hear, the sound started once
    /// that is long enough and stopped as soon as it isn't so.
    private func heardNothing(since: ContinuousClock.Instant?) -> ContinuousClock.Instant? {
        guard isQuietlyWorking else {
            #if DEBUG
            // Why not, once a turn: it never started in voice mode on Marta (2026-10-27).
            if phase == .thinking, !quietBlockNoted {
                quietBlockNoted = true
                LiveMeasure.write("no thinking sound while the agent works: \(quietBlocker)", to: "voice-turns.log")
            }
            #endif
            playThinkingSound(false)
            return nil
        }
        let start = since ?? .now
        if ContinuousClock.now - start >= thinkingSoundAfter { playThinkingSound(true) }
        return start
    }

    /// The thinking sound's level in the car: about 9 dB under the phone's.
    nonisolated static let carThinkingVolume: Float = 0.35

    func playThinkingSound(_ on: Bool) {
        guard on != thinkingSoundOn else { return }
        thinkingSoundOn = on
        if on {
            // Quieter in the car (asked 2026-10-28: "the CarPlay thinking sound is way too loud"):
            // its speakers play it far louder against the reply than the phone's do.
            thinkingSound.start(volume: carConnected() || audio.route == .car ? Self.carThinkingVolume : 1)
            audio.refreshRoute()   // (starting a sound can put the output back on the earpiece)
        } else {
            thinkingSound.stop()
            thinkingSoundStopped = .now
        }
        #if DEBUG
        let micOpen = micStaysOpen && audio.route == .speaker
        LiveMeasure.write("thinking sound \(on ? "on" : "off") (\(phase), \(audio.route)\(micOpen ? ", the microphone open" : ""))", to: "voice-turns.log")
        #endif
    }

    /// Whether the thinking sound plays into a microphone left open on the phone's speaker in a
    /// reply's pause, where talking over the reply is listened for: on in development builds,
    /// while what it does there is measured (`voiceOverReply` notes a voice heard while it
    /// plays), off in the App Store's until that shows it is never taken for one (2026-10-27).
    #if DEBUG
    static let thinkingIntoOpenMic = true
    #else
    static let thinkingIntoOpenMic = false
    #endif
    #if DEBUG
    /// What keeps the thinking sound from playing now (`isQuietlyWorking`), for the log.
    private var quietBlocker: String {
        var why: [String] = []
        switch thinkingSoundWanted() {
        case .off: why.append("set to Off")
        case .car: if !carConnected(), audio.route != .car { why.append("set to In the car, not in one") }
        case .always: break
        }
        if asking != nil { why.append("a request asked of the person") }
        if conversation.pendingInterrupt != nil { why.append("an approval waiting") }
        if isPaused { why.append("paused") }
        if acknowledging { why.append("acknowledging") }
        if replaying { why.append("replaying") }
        if micStaysOpen, audio.route == .speaker, phase == .speaking, !Self.thinkingIntoOpenMic { why.append("the microphone open on the speaker") }
        return why.isEmpty ? "nothing found (phase \(phase), route \(audio.route))" : why.joined(separator: ", ")
    }
    #endif

    func replyFinishedSpeaking() {
        if asking != nil {
            // The request has been read out, or the reminder said: now the answer.
            listenForAnswer()
            return
        }
        if leftForScreen {
            // "It's waiting on your iPhone" has been said. The turn is still the agent's.
            leftForScreen = false
            phase = .thinking
            return
        }
        if acknowledging {
            acknowledging = false
            phase = .idle
            output.releaseAudio(); audio.deactivate()
            if !continuous { endCall() }   // ("Stop": the call too. "Noted." after a note goes on.)
            return
        }
        if replaying {
            // A replay isn't a new turn: keep the metrics, then resume hands-free or go quiet.
            replaying = false
            phase = .idle
            if continuous, replayResumesHandsFree { beginListening() } else { output.releaseAudio(); audio.deactivate() }
            return
        }
        metrics.speechDoneAt = .now
        lastMetrics = metrics
        log.info("turn: \(self.metrics.summary)")
        #if DEBUG
        // In a file too, to set beside a live call's (live-measure.log): the same requests, timed
        // both ways (2026-10-27).
        LiveMeasure.write("turn: \(metrics.summary)", to: "voice-turns.log")
        #endif
        if monitoring, continuous {
            // Hands-free, and the mic is already open behind the reply: listen on it, rather
            // than close it and open it again. Nothing kept from while Redde spoke is used.
            handOverMic()
            metrics = VoiceMetrics()
            phase = .listening
            liveTranscript = ""
            recognizer.holdAgain()   // (it may be transcribing, waiting for "stop": that is over)
            recognizer.beginTranscribing(withHeldAudio: false, endsOnSilence: true)
            earcon(.listening)
            metrics.listenStartedAt = .now
            observeTranscript()
            return
        }
        phase = .idle
        if continuous {
            beginListening()
        } else {
            output.releaseAudio(); audio.deactivate()
            endCall()   // hands-free turned off on a call: it ends with this reply
        }
    }
}

@preconcurrency import AVFoundation
import CarPlay
import Foundation
import Observation
import UIKit
import os

/// Wake phrases (Settings → Voice → Wake Phrase): while Redde is open on the iPhone or iPad, or on
/// the car's screen, and nothing else uses the microphone, it listens for each agent's phrase
/// ("Hey Sol", "Hey Home"), on the device, and the one heard opens voice mode in its agent's
/// chat; "Hey Home, turn the lights off" asks at once. Conduit has it (asked 2026-10-25).
///
/// The microphone stays open beside other audio, which plays on (`activateForWake`), with no echo
/// cancellation. Nothing is transcribed until its level says someone is talking
/// (`BargeInDetector`); then the second before and the next few are, and let go of as soon as
/// they aren't a wake phrase (`WakeMatch`). It steps aside for anything else that wants the
/// microphone or the session (voice mode, a call, dictation, Read aloud, a voice sample:
/// `AudioSessionController.onClaim`) and comes back a moment after they are done. Off by
/// default, and per device: the orange dot shows while it listens.
@Observable
final class WakeListener {
    static let shared = WakeListener()

    /// Listening for the phrases now.
    private(set) var listening = false

    /// What holds it off besides the microphone being in use: Settings open (where the phrases are
    /// changed), a voice being picked (where samples play), a wake on its way into voice mode,
    /// the composer's dictation.
    enum Hold: String { case settings, voicePicker, handoff, dictation }

    @ObservationIgnored private var holds: Set<Hold> = []
    @ObservationIgnored private let recognizer: SpeechRecognizer = {
        let recognizer = SpeechRecognizer()
        recognizer.echoCancellation = false
        recognizer.heldAudio = 1.5
        return recognizer
    }()
    @ObservationIgnored private let audio = AudioSessionController.shared
    @ObservationIgnored private let log = Logger(subsystem: "com.goosehouse.echo", category: "wake")
    /// The recogniser has been asked to open (it may still be opening).
    @ObservationIgnored private var running = false
    /// Counts the opens, so one that finishes after a stop can tell.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var targets: [WakeTarget] = []
    @ObservationIgnored private var openedAt = ContinuousClock.now
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// When something last took the session from it, and when voice mode was last busy: it waits
    /// a moment after either, for the session to be let go of and music to come back.
    @ObservationIgnored private var claimedAt: ContinuousClock.Instant?
    @ObservationIgnored private var busyAt: ContinuousClock.Instant?
    /// Since when the session has been set up for something else with nothing using it.
    @ObservationIgnored private var unusedSince: ContinuousClock.Instant?
    /// Not before then: after it couldn't open, or an interruption.
    @ObservationIgnored private var retryAt = ContinuousClock.now
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// How long it holds before it opens afresh: one analyzer for hours on end isn't asked of it
    /// anywhere else.
    private static let freshEvery: Duration = .seconds(600)

    private init() {}

    /// Called once at launch: it follows the scenes from here, and the session's claims.
    func begin() {
        guard observers.isEmpty else { return }
        audio.onClaim = { [weak self] in self?.claimed() }
        let center = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification, UIScene.didDisconnectNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // The scene that deactivates still says foreground active as this is posted.
                let leaving = note.name != UIScene.didActivateNotification ? (note.object as? UIScene).map(ObjectIdentifier.init) : nil
                MainActor.assumeIsolated { self?.scenesChanged(leaving: leaving) }
            })
        }
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { self?.interrupted(began: began) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart(after: .seconds(1)) }
        })
        scenesChanged(leaving: nil)
    }

    func hold(_ reason: Hold) {
        holds.insert(reason)
        evaluate()
    }

    /// The hold is over. A voice sample played meanwhile leaves the session as it had it, and
    /// nothing plays once the page is gone: let go of here, or wake phrases would wait for good.
    func release(_ reason: Hold) {
        guard holds.remove(reason) != nil else { return }
        if reason == .settings || reason == .voicePicker, VoiceSession.current?.mightBeBusy != true,
           !AttachmentAudio.shared.isPlaying {
            audio.releaseUnused()
        }
        evaluate()
    }

    /// Looks at once whether it should be listening (a setting changed), rather than at the next tick.
    func evaluate() {
        let want = wanted()
        if want, !running, ContinuousClock.now >= retryAt {
            start()
        } else if !want, running {
            stop()
        } else if running, listening, recognizer.state == .holding {
            // A route change stops the engine under it; the phrases changed; or it has held long enough.
            let stale = !recognizer.isEngineRunning || ContinuousClock.now - openedAt > Self.freshEvery
            if stale || Settings.shared.wakeTargets != targets {
                note(!recognizer.isEngineRunning ? "the microphone stopped under it; opening again" : "opening afresh")
                stop()
                start()
            }
        }
    }

    // MARK: - When

    private func wanted() -> Bool {
        let settings = Settings.shared
        guard settings.wakeListening, holds.isEmpty, surfaceShowing,
              AVAudioApplication.shared.recordPermission == .granted else { return false }
        let now = ContinuousClock.now
        if let voice = VoiceSession.current, voice.mightBeBusy { busyAt = now; unusedSince = nil; return false }
        if let busyAt, now - busyAt < .seconds(1.5) { return false }
        if let claimedAt, now - claimedAt < .seconds(2) { return false }
        let router = LaunchRouter.shared
        guard router.pendingVoice == nil, router.pendingWake == nil, !settings.wakeTargets.isEmpty else { return false }
        guard audio.isFree else {
            // Set up for voice or playback with nothing of Redde's using it: a way out of voice mode
            // that didn't let go. After half a minute of that it is let go of here, or wake phrases
            // would wait for good.
            guard !AttachmentAudio.shared.isPlaying else { unusedSince = nil; return false }
            let since = unusedSince ?? now
            unusedSince = since
            guard now - since > .seconds(30) else { return false }
            note("the audio session was left set up with nothing using it; letting it go")
            audio.releaseUnused()
            unusedSince = nil
            return audio.isFree
        }
        unusedSince = nil
        return true
    }

    /// Redde is on a screen someone is looking at: the iPhone's or iPad's, unlocked by Face ID
    /// where that's on, or the car's.
    private var surfaceShowing: Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            guard scene.activationState == .foregroundActive, ObjectIdentifier(scene) != leavingScene else { return false }
            if scene is CPTemplateApplicationScene { return true }
            return !AppLock.shared.isLocked && !AppLock.shared.isCovered
        }
    }

    /// Redde is on the car's screen: a wake goes there.
    private var carShowing: CarPlaySceneDelegate? {
        let car = UIApplication.shared.connectedScenes.first { $0 is CPTemplateApplicationScene && $0.activationState == .foregroundActive }
        return car?.delegate as? CarPlaySceneDelegate
    }

    @ObservationIgnored private var leavingScene: ObjectIdentifier?

    /// A scene came up or went: the ticker runs while any is in front, looking every two seconds
    /// (for voice mode to be over, the lock to be gone), and the listener stops with the last.
    private func scenesChanged(leaving: ObjectIdentifier?) {
        leavingScene = leaving
        evaluate()
        leavingScene = nil
        let anyInFront = UIApplication.shared.connectedScenes.contains {
            $0.activationState == .foregroundActive && ObjectIdentifier($0) != leaving
        }
        if anyInFront, ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    self?.evaluate()
                }
            }
        } else if !anyInFront {
            ticker?.cancel()
            ticker = nil
        }
    }

    /// The log, and in a development build Library/Caches/wake.log too, to read off the phone
    /// after trying it. What was said goes only to that file, never to the system log.
    private func note(_ line: String, said: String? = nil) {
        #if DEBUG
        LiveMeasure.write(line + (said.map { ": " + $0 } ?? ""), to: "wake.log")
        #endif
        log.notice("\(line, privacy: .public)")
    }

    // MARK: - Listening

    private func start() {
        running = true
        attempt += 1
        let attempt = attempt
        targets = Settings.shared.wakeTargets
        recognizer.hints = targets.map(\.phrase)
        Task { [weak self] in await self?.open(attempt) }
    }

    private func open(_ attempt: Int) async {
        do {
            try audio.activateForWake()
            // It ends what it transcribes itself (`follow`), never by the recogniser's endpointing.
            try await recognizer.startHeld { _ in }
        } catch {
            guard attempt == self.attempt, running else { return }
            if !(error is CancellationError) { note("can't listen", said: error.localizedDescription) }
            running = false
            audio.deactivateWake()
            retryAt = .now + .seconds(20)
            return
        }
        guard attempt == self.attempt, running else {
            recognizer.cancelNow()
            return
        }
        openedAt = .now
        listening = true
        note("listening for \(targets.map(\.phrase).joined(separator: ", ")) on \(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portType.rawValue).joined(separator: ","))")
        watch()
    }

    /// Lets go of the microphone at once; the session too unless another is taking it (`claimed`).
    private func stop(releasing: Bool = true) {
        running = false
        listening = false
        following?.cancel()
        following = nil
        recognizer.cancelNow()
        if releasing { audio.deactivateWake() }
    }

    private func restart(after delay: Duration) {
        guard running else { return }
        stop()
        retryAt = .now + delay
    }

    /// Voice mode, dictation or a sample is taking the session: out of the way now, back once they're done.
    private func claimed() {
        claimedAt = .now
        guard running else { return }
        note("the microphone is wanted elsewhere; waiting")
        stop(releasing: false)
    }

    private func interrupted(began: Bool) {
        if began {
            if running { stop(releasing: false) }
            retryAt = .now + .seconds(3)
        } else {
            evaluate()
        }
    }

    /// The level says someone is talking: how loud a voice must be, above the room and at least,
    /// with no echo cancellation; the car's noise sets its own floor. A start, to be tuned on the phone.
    private func watch() {
        var detector = BargeInDetector(minimum: -46)
        detector.margin = 12
        detector.hold = 0.12
        detector.settle = 0.3
        detector.rearm()
        recognizer.watchForVoice(detector) { [weak self] in self?.voiceHeard() }
    }

    private func voiceHeard() {
        guard running, recognizer.state == .holding else { return }
        recognizer.beginTranscribing(withHeldAudio: true, endsOnSilence: false)
        #if DEBUG
        note("a voice: transcribing")
        #endif
        following?.cancel()
        following = Task { [weak self] in await self?.follow() }
    }

    /// What is transcribed, as it comes. No phrase at its start, with more words than a phrase
    /// has, or for too long, and it was something else: held again. A phrase, and what follows it
    /// is listened to until the words stop coming, by the words and the sound, not the
    /// recogniser's endpointing: with no echo cancellation a room's noise never read as quiet to
    /// it, and "Hey Saul" waited 17 s for a pause (Marta, 2026-10-25).
    private func follow() async {
        let began = ContinuousClock.now
        let longest = targets.map { WakeMatch.words($0.phrase).count }.max() ?? 2
        var found: (target: WakeTarget, at: ContinuousClock.Instant)?
        var said = "", changedAt = began, loudAt = began
        while running, recognizer.state == .listening, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            guard running, recognizer.state == .listening, !Task.isCancelled else { return }
            let now = ContinuousClock.now
            let text = recognizer.transcript
            if text != said { said = text; changedAt = now }
            if recognizer.meterLevel > 0.15 { loudAt = now }
            guard let phrase = found else {
                if let match = WakeMatch.match(text, targets: targets) {
                    found = (match.target, now)
                    note("heard \(match.target.phrase)", said: text)
                    continue
                }
                let words = WakeMatch.words(text).count
                if words > longest + WakeMatch.lead || now - began > (words == 0 ? .seconds(2.5) : .seconds(5)) {
                    #if DEBUG
                    note(text.isEmpty ? "nothing in it" : "not a wake phrase", said: text.nilIfEmpty)
                    #endif
                    recognizer.holdAgain(finalizing: true)
                    watch()
                    return
                }
                continue
            }
            // Done: a second without new words and half a second without sound, or three seconds
            // without new words in a room that is never quiet, or fifteen seconds on.
            let wordless = now - changedAt
            guard (wordless > .seconds(1) && now - loudAt > .milliseconds(500)) || wordless > .seconds(3)
                    || now - phrase.at > .seconds(15) else { continue }
            let final = await recognizer.stop()
            ended(final, volatile: said, heard: phrase.target)
            return
        }
    }

    /// What was said with a phrase in it is over: voice mode, in its agent's chat, on the car's
    /// screen if Redde is on it, with what was said after the phrase asked. The final words decide,
    /// else the last tentative ones, else the phrase heard as it was said.
    private func ended(_ text: String, volatile: String, heard: WakeTarget) {
        guard running else { return }
        let found = WakeMatch.match(text, targets: targets) ?? WakeMatch.match(volatile, targets: targets)
        let target = found?.target ?? heard
        let asking = found?.rest.nilIfEmpty
        running = false
        listening = false
        note("waking \(target.name)\(carShowing == nil ? "" : " in the car")\(asking == nil ? "" : ", asking")", said: asking)
        // Until voice mode has it: the session stays as it is meanwhile, for voice to take over.
        holds.insert(.handoff)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.release(.handoff)   // whatever happened to it
        }
        if let car = carShowing {
            Task { await car.woke(profile: target.profile, asking: asking) }
        } else {
            LaunchRouter.shared.requestWake(profile: target.profile, asking: asking)
        }
    }
}

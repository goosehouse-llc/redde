import AVFoundation
import Foundation
import Observation
import UIKit
import os

/// Owns the shared AVAudioSession for the voice loop and reports interruptions (calls, Siri,
/// CarPlay). One category for the whole loop so the route doesn't flap between listen and speak.
@Observable
final class AudioSessionController {
    static let shared = AudioSessionController()
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "audio")

    var onInterruption: (() -> Void)?
    /// Voice or playback is about to take the session from wake phrases (`WakeListener`), which
    /// must let the microphone go first: called before anything changes.
    var onClaim: (() -> Void)?
    /// Fired when the interruption ends; `shouldResume` mirrors the system's hint.
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    /// Headphones or a car went away mid-reply. Apple's guidance is to pause, not to re-route
    /// the audio onto the loudspeaker.
    var onOutputDeviceLost: (() -> Void)?

    /// The voice session is on headphones or a Bluetooth headset (not the phone, not a car). Echo
    /// cancellation isn't needed there, and turning it off keeps the mic's full quality.
    private(set) var onHeadphones = false
    /// A headset has been on the route at some point in this voice session. While it's set the
    /// speaker is never forced: a Bluetooth link renegotiating (a mode change, the recogniser's
    /// engine stopping) reads as the phone alone for a moment, on the route AND in the available
    /// inputs, and a speaker override taken then sticks. Cleared when the system reports the
    /// device gone (`.oldDeviceUnavailable`) or the session ends.
    private var headsetSeen = false

    /// Which configuration is active, if any. Every `setCategory` and `setActive` posts a route
    /// change that re-runs the routing logic; in hands-free each turn would pay for all of them,
    /// so an already-active session in the same mode is left alone. Cleared by `deactivate()`
    /// and by an interruption, after which the system needs the activation again.
    private enum Mode { case voice, playback, wake }
    private var activeMode: Mode?
    /// Nothing but wake phrases holds the session, if anything does.
    var isFree: Bool { activeMode == nil || activeMode == .wake }
    /// The mode chosen for listening: voice chat (echo cancellation), or default on a headset that
    /// records at full bandwidth. Replies play in `.default` (see `setReplying`).
    private var listeningMode: AVAudioSession.Mode = .voiceChat

    private var observer: NSObjectProtocol?
    private var proximityObserver: NSObjectProtocol?
    /// Where the sensor last saw the phone. It's only watched while a reply is spoken, and it
    /// reads "nothing near" whenever it's off or has just come on; routing on that sent every
    /// listening chime, and the start of every reply, to the loudspeaker at the ear. Between
    /// replies the route stays where the last real reading put it.
    private var lastAtEar = false
    /// Takes a reading once the sensor has had a moment to settle after coming on.
    private var proximitySettle: Task<Void, Never>?
    /// Whether the device's orientation is being followed (for face down, which the sensor also
    /// reads as near), so the calls to begin and end it stay balanced.
    private var watchingOrientation = false
    /// Looks at the route again once playback has started (`refreshRoute`).
    private var routeRecheck: Task<Void, Never>?
    private var routeObserver: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Extract the Sendable bits before hopping actors.
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated { self?.handle(rawType: raw, rawOptions: options) }
        }
        // Permanent, so headphones coming out during Replay pause it too; `applyOutputRoute`
        // already ignores playback-only sessions.
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.routeChanged(rawReason: raw) }
        }
    }

    /// What the voice session is playing through right now.
    var route: VoiceRoute {
        let session = AVAudioSession.sharedInstance()
        let car = session.currentRoute.outputs.contains { $0.portType == .carAudio }
            || (session.availableInputs ?? []).contains { $0.portType == .carAudio }
        return car ? .car : onHeadphones ? .headphones : .speaker
    }

    func activateForVoice() throws {
        if activeMode == .wake { onClaim?() }
        let session = AVAudioSession.sharedInstance()
        if activeMode != .voice {
            lastAtEar = false   // a new voice session starts on the speaker until the sensor says otherwise
            headsetSeen = false
            // No `.defaultToSpeaker`: the speaker/earpiece choice is made by the proximity sensor.
            // No mixing option either: ducked music would still play into the open microphone, so
            // other audio pauses for the voice loop and resumes on deactivate (like Siri).
            // AirPods (and other headsets) that can record at full bandwidth: use it. The option
            // only works with the default mode, and the headset itself keeps the reply out of the
            // mic, so voice-chat processing isn't needed. HFP stays as the fallback if the route
            // changes.
            let highQuality = Self.headsetSupportsHighQualityRecording(session)
            do {
                try session.setCategory(.playAndRecord, mode: highQuality ? .default : .voiceChat,
                                        options: highQuality ? [.allowBluetoothHFP, .allowBluetoothA2DP, .bluetoothHighQualityRecording]
                                                             : [.allowBluetoothHFP, .allowBluetoothA2DP])
            } catch where highQuality {
                log.error("high-quality headset recording unavailable: \(error.localizedDescription)")
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
            }
            // Short hardware buffers, so mic taps (and the voice-mode waveform) arrive every few ms
            // instead of in ~100 ms lumps. A request, not a promise; the route may round it up.
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true, options: [])
            listeningMode = session.mode
            activeMode = .voice
        }
        updateRouteFacts()
        applyEarRouting()
    }

    /// Replay and Read aloud: nothing records, so no voice-chat configuration — its default
    /// output is the earpiece, and every playback engine start put it back there however often
    /// the speaker override was re-applied. Plain spoken-audio playback goes to the loudspeaker,
    /// or to headphones / Bluetooth / CarPlay when connected. Listening switches back to
    /// `activateForVoice`.
    func activateForPlayback() throws {
        if activeMode == .wake { onClaim?() }
        stopProximityRouting()
        guard activeMode != .playback else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true, options: [])
        activeMode = .playback
        updateRouteFacts()
    }

    /// Wake phrases (`WakeListener`): the microphone open beside whatever else plays, which plays
    /// on (mixed, not ducked and not paused), and on the speaker rather than the earpiece.
    /// Bluetooth headphones stay in their music mode, so the phone's own microphone listens; in the
    /// car, the car's. A session its owner never let go of ends first, other audio told, so music
    /// paused for it starts again.
    func activateForWake() throws {
        guard activeMode != .wake else { return }
        let session = AVAudioSession.sharedInstance()
        if activeMode != nil {
            stopProximityRouting()
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            activeMode = nil
        }
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true, options: [])
        activeMode = .wake
        headsetSeen = false
        updateRouteFacts()
        if let car = session.availableInputs?.first(where: { $0.portType == .carAudio }), session.preferredInput?.uid != car.uid {
            try? session.setPreferredInput(car)
        }
    }

    /// Nothing of Redde's uses the session any more, as `WakeListener` sees it (a voice sample's
    /// page gone, voice mode idle a while): let go, if it is still set up for voice or playback.
    func releaseUnused() {
        guard activeMode == .playback || activeMode == .voice else { return }
        release()
    }

    /// Wake phrases no longer listened for: the session let go, if it is still theirs.
    func deactivateWake() {
        guard activeMode == .wake else { return }
        release()
    }

    /// A Bluetooth headset input that can record at full bandwidth is available.
    private static func headsetSupportsHighQualityRecording(_ session: AVAudioSession) -> Bool {
        (session.availableInputs ?? []).contains { port in
            [.bluetoothHFP, .bluetoothLE].contains(port.portType)
                && port.bluetoothMicrophoneExtension?.highQualityRecording.isSupported == true
        }
    }

    private func updateRouteFacts() {
        let route = AVAudioSession.sharedInstance().currentRoute
        let headphonePorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        onHeadphones = !route.outputs.isEmpty && route.outputs.allSatisfy { headphonePorts.contains($0.portType) }
        if onHeadphones, activeMode == .voice { headsetSeen = true }
        let highQualityHeadsetMic = route.inputs.contains { $0.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled == true }
        let available = (AVAudioSession.sharedInstance().availableInputs ?? []).map(\.portType.rawValue).joined(separator: ",")
        log.notice("route: headphones=\(self.onHeadphones) hqHeadsetMic=\(highQualityHeadsetMic) out=\(route.outputs.map(\.portType.rawValue).joined(separator: ","), privacy: .public) in=\(route.inputs.map(\.portType.rawValue).joined(separator: ","), privacy: .public) available=\(available, privacy: .public)")
    }

    /// Voice or playback is done with the session. Not when wake phrases have it by then (a voice
    /// session lets go a moment after its last cue): that is theirs to let go (`deactivateWake`).
    func deactivate() {
        guard activeMode != .wake else { return }
        release()
    }

    private func release() {
        stopProximityRouting()
        activeMode = nil
        headsetSeen = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // .isBusy here means an audio engine is still running; other apps stay ducked until it stops.
            log.error("deactivate failed: \(error.localizedDescription)")
        }
    }

    /// While Redde thinks and speaks nothing records, so the session leaves voice-chat mode. In it
    /// the volume buttons set the call volume, which the reply (its own audio engine) doesn't play
    /// at: they did nothing until a Replay. Back to the listening mode before the mic opens again.
    /// Not on a headset: the buttons already drive it in either mode, and the switch makes a
    /// Bluetooth link renegotiate (HFP to A2DP and back), which is where a reply asked through
    /// AirPods ended up on the phone.
    func setReplying(_ on: Bool) {
        guard activeMode == .voice, !headsetSeen else { return }
        let session = AVAudioSession.sharedInstance()
        let target: AVAudioSession.Mode = on ? .default : listeningMode
        guard session.mode != target else { return }
        do {
            try session.setMode(target)
            log.notice("mode → \(target.rawValue, privacy: .public)")
        } catch {
            log.error("mode change failed: \(error.localizedDescription)")
        }
        applyOutputRoute(force: true)   // a mode change can put the output back on the receiver
    }

    // MARK: - Speaker vs. earpiece

    /// Voice mode says when a reply is being spoken; only then does the ear matter.
    private var earRoutingWanted = false

    /// While Redde speaks: watch the proximity sensor so raising the phone moves the reply to the
    /// earpiece. Not while listening or thinking: the sensor blanks the screen whenever anything
    /// is near it, which blacked out the screen during a long wait for an answer.
    func setEarRouting(_ on: Bool) {
        earRoutingWanted = on
        guard activeMode == .voice else { return }
        applyEarRouting()
    }

    /// CarPlay when a car is connected. Otherwise: phone at the ear → earpiece; anywhere else →
    /// speaker, like the Phone app. Headphones and Bluetooth are left alone. The sensor is only
    /// watched while a reply is spoken and the earpiece setting is on: it also blanks the screen
    /// whenever anything is near it.
    private func applyEarRouting() {
        let atEarEnabled = earRoutingWanted && Settings.shared.earpieceAtEar
        UIDevice.current.isProximityMonitoringEnabled = atEarEnabled
        watchOrientation(atEarEnabled)
        if !Settings.shared.earpieceAtEar { lastAtEar = false }
        proximitySettle?.cancel()
        if atEarEnabled {
            if proximityObserver == nil {
                proximityObserver = NotificationCenter.default.addObserver(
                    forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.proximityChanged() }
                }
            }
            // The sensor posts only on a change: a phone put down between replies reads "not
            // near" without a notification, so look once it has settled.
            proximitySettle = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, UIDevice.current.isProximityMonitoringEnabled else { return }
                self?.proximityChanged()
            }
        } else if let proximityObserver {
            NotificationCenter.default.removeObserver(proximityObserver)
            self.proximityObserver = nil
        }
        applyOutputRoute(force: true)
    }

    private func proximityChanged() {
        // A phone face down on the table reads as near as well, and that is no ear: a reply
        // that came after a long wait, the phone put down for it, played on the earpiece
        // (2026-10-21 and -22).
        let near = UIDevice.current.proximityState
        lastAtEar = near && UIDevice.current.orientation != .faceDown
        if near, !lastAtEar { log.notice("near, but face down: not at the ear") }
        applyOutputRoute(force: true)
    }

    private func watchOrientation(_ on: Bool) {
        guard on != watchingOrientation else { return }
        watchingOrientation = on
        if on { UIDevice.current.beginGeneratingDeviceOrientationNotifications() } else { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
    }

    private func stopProximityRouting() {
        proximitySettle?.cancel()
        routeRecheck?.cancel()
        watchOrientation(false)
        lastAtEar = false
        UIDevice.current.isProximityMonitoringEnabled = false
        if let proximityObserver { NotificationCenter.default.removeObserver(proximityObserver) }
        proximityObserver = nil
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.none)
        try? session.setPreferredInput(nil)
    }

    private func routeChanged(rawReason: UInt?) {
        let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ?? .unknown
        updateRouteFacts()
        switch reason {
        case .oldDeviceUnavailable:
            log.notice("output device went away; pausing rather than re-routing")
            headsetSeen = false
            onOutputDeviceLost?()
            return
        default:
            applyOutputRoute(force: false)
        }
    }

    /// Re-asserts speaker/earpiece. The voice-processing audio unit resets the output to the
    /// receiver when the recognizer's engine starts, after the session was already routed. And
    /// looks again a moment later, once playback has really started: a reply still went to the
    /// earpiece after this (2026-10-22), and the log says so if it was the route.
    func refreshRoute() {
        applyOutputRoute(force: true)
        routeRecheck?.cancel()
        routeRecheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            if outputs.contains(where: { $0.portType == .builtInReceiver }), !(Settings.shared.earpieceAtEar && lastAtEar) {
                log.notice("receiver after playback started; routing again")
            }
            applyOutputRoute(force: false)
        }
    }

    /// `force`: apply the override even if the current route already looks right. Right after
    /// activation the reported route can still be the previous session's (replay went to the
    /// receiver because it "was already on the speaker"). Route-change notifications pass false
    /// so our own override, which re-posts a change, can't loop.
    private func applyOutputRoute(force: Bool) {
        let session = AVAudioSession.sharedInstance()
        // Playback-only (Replay) routes itself; the speaker override is a play-and-record thing.
        guard session.category == .playAndRecord else { return }

        // CarPlay wins whenever a car is connected: use its mic and speakers, no proximity games.
        if let carInput = session.availableInputs?.first(where: { $0.portType == .carAudio }) {
            do {
                try session.overrideOutputAudioPort(.none)
                if session.preferredInput?.uid != carInput.uid {
                    try session.setPreferredInput(carInput)
                    log.notice("output → CarPlay")
                }
            } catch {
                log.error("CarPlay routing failed: \(error.localizedDescription)")
            }
            return
        }
        if session.preferredInput != nil { try? session.setPreferredInput(nil) }

        let builtInOnly = session.currentRoute.outputs.allSatisfy {
            $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
        }
        // Headphones / Bluetooth: don't fight the user. Judged by the session's memory of a
        // headset, not by the route of the moment: while a Bluetooth link renegotiates, the route
        // and even the available inputs read as the phone alone (seen in the log: mode → Default,
        // then "output → speaker", then a Speaker route). A speaker override taken in that gap
        // outlives it and every later route change re-asserts it, so a reply asked through
        // AirPods came out of the phone. Never by a headset that is only available: iOS listed
        // one with nothing connected (2026-10-22), and every reply stayed on the earpiece, the
        // speaker override cleared each time it was taken.
        if headsetSeen {
            if builtInOnly, session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
                try? session.overrideOutputAudioPort(.none)
                log.notice("headset connected; speaker override cleared")
            }
            return
        }
        guard builtInOnly else { return }
        let atEar = Settings.shared.earpieceAtEar && lastAtEar
        let onSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        guard force || onSpeaker == atEar else { return }
        do {
            try session.overrideOutputAudioPort(atEar ? .none : .speaker)
            log.notice("output → \(atEar ? "earpiece" : "speaker")")
        } catch {
            log.error("output override failed: \(error.localizedDescription)")
        }
    }

    private func handle(rawType raw: UInt?, rawOptions: UInt) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            log.notice("audio session interrupted")
            activeMode = nil
            onInterruption?()
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            log.notice("audio session interruption ended, shouldResume=\(shouldResume)")
            onInterruptionEnded?(shouldResume)
        @unknown default:
            break
        }
    }
}

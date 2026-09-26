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
    /// Fired when the interruption ends; `shouldResume` mirrors the system's hint.
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    /// Headphones or a car went away mid-reply. Apple's guidance is to pause, not to re-route
    /// the audio onto the loudspeaker.
    var onOutputDeviceLost: (() -> Void)?

    /// The voice session is on headphones or a Bluetooth headset (not the phone, not a car). Echo
    /// cancellation isn't needed there, and turning it off keeps the mic's full quality.
    private(set) var onHeadphones = false

    /// Which configuration is active, if any. Every `setCategory` and `setActive` posts a route
    /// change that re-runs the routing logic; in hands-free each turn would pay for all of them,
    /// so an already-active session in the same mode is left alone. Cleared by `deactivate()`
    /// and by an interruption, after which the system needs the activation again.
    private enum Mode { case voice, playback }
    private var activeMode: Mode?

    private var observer: NSObjectProtocol?
    private var proximityObserver: NSObjectProtocol?
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

    func activateForVoice() throws {
        let session = AVAudioSession.sharedInstance()
        if activeMode != .voice {
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
        stopProximityRouting()
        guard activeMode != .playback else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true, options: [])
        activeMode = .playback
        updateRouteFacts()
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
        let highQualityHeadsetMic = route.inputs.contains { $0.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled == true }
        log.info("route: headphones=\(self.onHeadphones) hqHeadsetMic=\(highQualityHeadsetMic) out=\(route.outputs.map(\.portType.rawValue).joined(separator: ","), privacy: .public) in=\(route.inputs.map(\.portType.rawValue).joined(separator: ","), privacy: .public)")
    }

    func deactivate() {
        stopProximityRouting()
        activeMode = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // .isBusy here means an audio engine is still running; other apps stay ducked until it stops.
            log.error("deactivate failed: \(error.localizedDescription)")
        }
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
        if !atEarEnabled, let proximityObserver {
            NotificationCenter.default.removeObserver(proximityObserver)
            self.proximityObserver = nil
        }
        applyOutputRoute(force: true)
        if atEarEnabled, proximityObserver == nil {
            proximityObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyOutputRoute(force: true) }
            }
        }
    }

    private func stopProximityRouting() {
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
        case .categoryChange:
            return
        case .oldDeviceUnavailable:
            log.info("output device went away; pausing rather than re-routing")
            onOutputDeviceLost?()
            return
        default:
            applyOutputRoute(force: false)
        }
    }

    /// Re-asserts speaker/earpiece. The voice-processing audio unit resets the output to the
    /// receiver when the recognizer's engine starts, after the session was already routed.
    func refreshRoute() { applyOutputRoute(force: true) }

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
                    log.info("output → CarPlay")
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
        guard builtInOnly else { return } // headphones / Bluetooth: don't fight the user
        let atEar = Settings.shared.earpieceAtEar && UIDevice.current.proximityState
        let onSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        guard force || onSpeaker == atEar else { return }
        do {
            try session.overrideOutputAudioPort(atEar ? .none : .speaker)
            log.info("output → \(atEar ? "earpiece" : "speaker")")
        } catch {
            log.error("output override failed: \(error.localizedDescription)")
        }
    }

    private func handle(rawType raw: UInt?, rawOptions: UInt) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            log.info("audio session interrupted")
            activeMode = nil
            onInterruption?()
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            log.info("audio session interruption ended, shouldResume=\(shouldResume)")
            onInterruptionEnded?(shouldResume)
        @unknown default:
            break
        }
    }
}

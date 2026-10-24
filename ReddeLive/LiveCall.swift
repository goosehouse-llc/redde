import AVFoundation
import Foundation
import os
@preconcurrency import WebRTC

/// The WebRTC side of a GPT-Live call (`LiveCalling`), in a framework of its own that the app
/// loads only when a call starts (`LiveEngine`). The app has already set up and activated the
/// audio session for voice (`AudioSessionController`); WebRTC takes it as it is, with its
/// echo cancellation, rather than set up one of its own.
@objc(ReddeLiveCall)
final class LiveCall: NSObject, LiveCalling {
    /// What the app looks the class up by, and makes a call with.
    @objc(makeWithListener:)
    static func make(listener: LiveCallListening) -> LiveCall { LiveCall(listener: listener) }

    private weak var listener: LiveCallListening?
    private let engine: Engine
    private var offerDone: ((String?, String?) -> Void)?
    private var acceptDone: ((String?) -> Void)?
    private var offerSettled = false
    private var setDescription = false
    private var gathered = false
    private var gatherLimit: Task<Void, Never>?
    private var lossCheck: Task<Void, Never>?

    private init(listener: LiveCallListening) {
        self.listener = listener
        engine = Engine()
        super.init()
        engine.reporter.withLock { reporter in
            reporter = { [weak self] event in
                // On the main queue, in the order WebRTC gave them: the transcript comes in pieces.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(event) } }
            }
        }
    }

    func makeOffer(_ done: @escaping (String?, String?) -> Void) {
        offerDone = done
        if let problem = engine.open() { finishOffer(problem: problem); return }
        // Every candidate is wanted in the offer, as the service takes no more after it; with
        // host addresses only (no STUN, as Hermes Desktop does it) they are all there in a tenth
        // of a second on an iPhone (measured). A second, should one be slow.
        gatherLimit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.gathered = true
            self?.offerIfReady()
        }
        engine.makeOffer()
    }

    func accept(_ answer: String, done: @escaping (String?) -> Void) {
        acceptDone = done
        engine.accept(answer) { [weak self] problem in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.accepted(problem) } }
        }
    }

    private func accepted(_ problem: String?) {
        if problem == nil { engine.startMeter() }
        acceptDone?(problem)
        acceptDone = nil
    }

    func send(_ event: String) -> Bool { engine.send(event) }

    func setMuted(_ muted: Bool) { engine.setMuted(muted) }

    var inputLevel: Float { engine.levels.withLock { $0.input } }
    var outputLevel: Float { engine.levels.withLock { $0.output } }

    func close() {
        gatherLimit?.cancel()
        lossCheck?.cancel()
        listener = nil
        engine.close()
    }

    private func heard(_ event: Engine.Event) {
        switch event {
        case let .described(problem):
            if let problem { finishOffer(problem: problem); return }
            setDescription = true
            offerIfReady()
        case .gathered:
            gathered = true
            offerIfReady()
        case let .received(text):
            listener?.liveCallReceived(text)
        case .connected:
            lossCheck?.cancel()
            listener?.liveCallChanged(LiveCallState.connected.rawValue)
        case .disconnected:
            // A phone moving between networks drops the connection for a moment; ICE often finds
            // it again. Lost only if it hasn't within a few seconds.
            lossCheck?.cancel()
            lossCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.listener?.liveCallChanged(LiveCallState.lost.rawValue)
            }
        case .failed:
            listener?.liveCallChanged(LiveCallState.lost.rawValue)
        case let .speaking(on):
            listener?.liveCallChanged((on ? LiveCallState.speaking : .quiet).rawValue)
        }
    }

    private func offerIfReady() {
        guard setDescription, gathered, !offerSettled else { return }
        gatherLimit?.cancel()
        guard let offer = engine.localSDP else { finishOffer(problem: "WebRTC made no offer."); return }
        offerSettled = true
        offerDone?(offer, nil)
        offerDone = nil
    }

    private func finishOffer(problem: String) {
        guard !offerSettled else { return }
        offerSettled = true
        gatherLimit?.cancel()
        offerDone?(nil, problem)
        offerDone = nil
    }
}

/// The WebRTC objects of one call, and their delegate. WebRTC calls back on threads of its own,
/// so this is nonisolated and tells `LiveCall` what happened through `reporter`. The connection,
/// channel and track are set on the main thread before WebRTC has anything to call back about,
/// and never changed after (closing closes them; they go with the call); the meter is the main
/// thread's alone, and the loudness count the statistics thread's.
private nonisolated final class Engine: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case described(String?), gathered, received(String), connected, disconnected, failed, speaking(Bool)
    }

    /// Where events go; nothing once the call is closed.
    let reporter = OSAllocatedUnfairLock<(@Sendable (Event) -> Void)?>(initialState: nil)
    private func report(_ event: Event) { reporter.withLock { $0 }?(event) }
    /// The person's and the voice's loudness, as the last statistics had them.
    let levels = OSAllocatedUnfairLock(initialState: (input: Float(0), output: Float(0)))

    /// Made once and kept: making it again for every call is wasted work, and it holds little
    /// while no call is up (back to the app's footprint after a call, measured).
    private static let factory = OSAllocatedUnfairLock<RTCPeerConnectionFactory?>(initialState: nil)
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var mic: RTCAudioTrack?
    private var meter: DispatchSourceTimer?
    private var speaking = false
    private var quietReads = 0
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "live")

    var localSDP: String? { peer?.localDescription?.sdp }

    /// The audio, the connection, the microphone's track and the event channel; why not, if not.
    func open() -> String? {
        let session = AVAudioSession.sharedInstance()
        let audio = RTCAudioSession.sharedInstance()
        // The app's audio session as it is: its category, mode and options. WebRTC sets these
        // again whenever its audio unit starts, so they have to be the app's.
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = session.category.rawValue
        config.categoryOptions = session.categoryOptions
        config.mode = session.mode.rawValue
        RTCAudioSessionConfiguration.setWebRTC(config)
        audio.useManualAudio = true
        audio.audioSessionDidActivate(session)
        let factory = Self.factory.withLock { factory in
            if let factory { return factory }
            RTCInitializeSSL()
            let made = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
            factory = made
            return made
        }
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: configuration, constraints: none, delegate: self) else {
            return "WebRTC couldn't make a connection."
        }
        let mic = factory.audioTrack(with: factory.audioSource(with: none), trackId: "mic")
        peer.add(mic, streamIds: ["live"])
        // Before the offer, so that the offer carries the channel.
        let channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())
        channel?.delegate = self
        self.peer = peer
        self.mic = mic
        self.channel = channel
        // The audio unit starts now, while the service is asked for the call: it takes a moment.
        audio.isAudioEnabled = true
        return nil
    }

    func makeOffer() {
        guard let peer else { return }
        let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peer.offer(for: none) { [weak self] offer, error in
            guard let self else { return }
            guard let offer else { report(.described(error?.localizedDescription ?? "WebRTC made no offer.")); return }
            peer.setLocalDescription(offer) { [weak self] error in
                self?.report(.described(error?.localizedDescription))
            }
        }
    }

    func accept(_ answer: String, done: @escaping @Sendable (String?) -> Void) {
        guard let peer else { done("The call has ended."); return }
        peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer)) { error in
            done(error?.localizedDescription)
        }
    }

    func send(_ event: String) -> Bool {
        guard let channel, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: Data(event.utf8), isBinary: false))
    }

    func setMuted(_ muted: Bool) { mic?.isEnabled = !muted }

    func close() {
        reporter.withLock { $0 = nil }
        meter?.cancel()
        meter = nil
        let audio = RTCAudioSession.sharedInstance()
        audio.isAudioEnabled = false
        channel?.close()
        peer?.close()
        audio.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
        levels.withLock { $0 = (0, 0) }
    }

    // MARK: Loudness

    /// How loud each side is, from the connection's statistics eight times a second: what the
    /// voice screen moves with, and whether the voice is speaking (with half a second of quiet
    /// before it counts as stopped, so a pause between words doesn't).
    func startMeter() {
        guard meter == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(125), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.readLevels() }
        meter = timer
        timer.resume()
    }

    private func readLevels() {
        peer?.statistics { [weak self] report in
            guard let self else { return }
            var input: Float = 0, output: Float = 0
            for stats in report.statistics.values where (stats.values["kind"] as? String) == "audio" {
                let level = (stats.values["audioLevel"] as? NSNumber)?.floatValue ?? 0
                switch stats.type {
                case "media-source": input = max(input, level)
                case "inbound-rtp": output = max(output, level)
                default: break
                }
            }
            let read = (input: input, output: output)
            levels.withLock { $0 = read }
            let loud = output > 0.03
            quietReads = loud ? 0 : quietReads + 1
            let now = loud || (speaking && quietReads < 4)
            if now != speaking {
                speaking = now
                self.report(.speaking(now))
            }
        }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { report(.gathered) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected, .completed: report(.connected)
        case .disconnected: report(.disconnected)
        case .failed: report(.failed)
        default: break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed { log.info("event channel closed") }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, let text = String(data: buffer.data, encoding: .utf8) else { return }
        report(.received(text))
    }
}

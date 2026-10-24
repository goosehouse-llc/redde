import Foundation

// The WebRTC side of a GPT-Live call lives in ReddeLive.framework, which carries WebRTC (12 MB of
// code) and is loaded only when a call starts (`LiveEngine`): linked, it would load with every
// launch, 20 to 50 ms each time on an iPhone 15 Pro Max (measured 2026-10-24), for a mode most
// people never turn on. So the app never links it and calls it through these Objective-C
// protocols, compiled into both and matched by their Objective-C names.

/// One call: the microphone, the connection to OpenAI's voice and the `oai-events` channel.
@MainActor
@objc(ReddeLiveCalling) protocol LiveCalling: NSObjectProtocol {
    /// Opens the microphone, the connection and the event channel. `done` gets the SDP offer for
    /// the service, or why there is none.
    func makeOffer(_ done: @escaping (_ offer: String?, _ problem: String?) -> Void)
    /// The service's SDP answer. `done` gets nil once it is applied, or why it couldn't be.
    func accept(_ answer: String, done: @escaping (_ problem: String?) -> Void)
    /// One JSON event out on the channel; false while it isn't open.
    func send(_ event: String) -> Bool
    /// The microphone held shut, or open again.
    func setMuted(_ muted: Bool)
    /// How loud the person and the voice are right now, 0…1, a few times a second.
    var inputLevel: Float { get }
    var outputLevel: Float { get }
    /// Everything closed, the audio given back.
    func close()
}

/// What a call tells the app, always on the main thread.
@MainActor
@objc(ReddeLiveCallListening) protocol LiveCallListening: NSObjectProtocol {
    /// A JSON event from the service.
    func liveCallReceived(_ event: String)
    /// `LiveCallState`'s raw value.
    func liveCallChanged(_ state: String)
}

/// What a call can tell of itself: connected, the voice audible or quiet, the connection lost.
nonisolated enum LiveCallState: String, Sendable {
    case connected, speaking, quiet, lost
}

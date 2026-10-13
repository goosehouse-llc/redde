import CoreMotion
import Foundation
import Observation
import os

/// A nod or a shake of the head, as headphones that sense movement report it.
nonisolated enum HeadGesture: String, Sendable, Equatable { case nod, shake }

/// Tells a nod from a shake from everything else a head does, from the angles AirPods report
/// about 25 times a second. It is fed every sample while a request waits for its answer
/// (Settings → Voice → Nod or shake to answer) and answers when a gesture is complete.
///
/// A nod approves a command, so it has to be meant. The head has to swing back and forth three
/// times in a row (down, up, down: a nod and a half, which a look down at the phone and back is
/// not), each swing far enough, quick enough, and mostly in its own direction: a head that
/// rolls, or moves on a slant, is doing something else. A shake is the same, sideways.
///
/// The numbers are estimates, not yet measured on a head: a nod that is meant taken to swing
/// 10 to 15 degrees, a listener's small one 3 to 6, a head on a walk 1 to 2, and a swing to
/// take a quarter to half a second. A DEBUG build writes down what the AirPods report
/// (`HeadGestures`) so they can be set from real ones.
nonisolated struct HeadGestureDetector: Sendable, Equatable {
    /// Where the head points, in radians, and when, in seconds: a `CMDeviceMotion`'s attitude
    /// and timestamp.
    struct Sample: Sendable, Equatable {
        var time: TimeInterval
        /// Chin down and up: a nod.
        var pitch: Double
        /// Left and right: a shake.
        var yaw: Double
        /// Ear to shoulder: neither.
        var roll: Double
    }

    /// How far the head has to travel in each swing: 6°.
    var swing = 6.0 * .pi / 180
    /// How far it has to come back before a swing counts as over: 2.5°. A smaller wobble is
    /// part of the swing.
    var turn = 2.5 * .pi / 180
    /// How long a swing may take, the pause at its end included. A head that stays put for
    /// longer has stopped, and what it does next starts from there.
    var longest = 0.7
    /// How many swings in a row make a gesture.
    var swings = 3
    /// How much the head may move in other directions during a swing, as a share of the swing.
    var stray = 0.75

    private var last: Sample?
    private var nod = Swings()
    private var shake = Swings()

    /// One sample. A gesture once it is complete; the count starts over then.
    mutating func feed(_ sample: Sample) -> HeadGesture? {
        defer { last = sample }
        guard let last else { return nil }
        let seconds = sample.time - last.time
        // A gap in what the AirPods send: what came before it is no part of what comes after.
        guard seconds > 0, seconds < 0.3 else { nod = Swings(); shake = Swings(); return nil }
        let pitch = Self.change(from: last.pitch, to: sample.pitch)
        let yaw = Self.change(from: last.yaw, to: sample.yaw)
        let roll = Self.change(from: last.roll, to: sample.roll)
        let nodded = move(\.nod, by: pitch, beside: abs(yaw) + abs(roll), at: sample.time)
        let shook = move(\.shake, by: yaw, beside: abs(pitch) + abs(roll), at: sample.time)
        guard nodded || shook else { return nil }
        nod = Swings(); shake = Swings()
        // Both at once is a head going round, not an answer.
        return nodded && shook ? nil : nodded ? .nod : .shake
    }

    /// The swings in one direction: where the one under way started, how far it has got, and
    /// how many before it counted.
    private struct Swings: Sendable, Equatable {
        /// The angle, added up from the changes.
        var position = 0.0
        /// +1 or -1 once the head is moving; 0 while it is still.
        var direction = 0.0
        /// Where the swing under way started, and when the head left there.
        var from = 0.0
        var left = 0.0
        /// The farthest it has got, and when it got there.
        var far = 0.0
        var reached = 0.0
        /// How much the head has moved in other directions meanwhile.
        var aside = 0.0
        var count = 0
    }

    /// Moves one direction's swings on by `angle`. True when that completed a gesture.
    private mutating func move(_ which: WritableKeyPath<Self, Swings>, by angle: Double, beside: Double, at time: TimeInterval) -> Bool {
        var s = self[keyPath: which]
        defer { self[keyPath: which] = s }
        s.position += angle
        s.aside += beside
        if s.direction == 0 {
            guard abs(s.position - s.from) >= turn else { s.left = time; s.aside = 0; return false }
            s.direction = s.position > s.from ? 1 : -1
            s.far = s.position
            s.reached = time
        } else if (s.position - s.far) * s.direction > 0 {
            s.far = s.position
            s.reached = time
        } else if abs(s.position - s.far) >= turn {
            // The head has turned back: the swing that got to `far` is over.
            let size = abs(s.far - s.from)
            let counts = size >= swing && s.reached - s.left <= longest && s.aside <= size * stray
            s.count = counts ? s.count + 1 : 0
            s.from = s.far
            s.left = s.reached
            s.direction = -s.direction
            s.far = s.position
            s.reached = time
            s.aside = 0
            return s.count >= swings
        } else if time - s.reached > longest {
            // It has stopped where it got to.
            s = Swings(position: s.position, from: s.position, left: time)
        }
        return false
    }

    /// From one angle to the next, the short way round (yaw runs from -π to π and over).
    private static func change(from: Double, to: Double) -> Double {
        atan2(sin(to - from), cos(to - from))
    }
}

/// Reads head movement from AirPods that sense it (AirPods Pro, AirPods Max, AirPods 3 and
/// later) and reports nods and shakes. Only while a request waits for its answer in voice mode:
/// `VoiceSession` starts it when the request starts being read out and stops it when the
/// request is settled. The movement is read here and kept nowhere, except by a DEBUG build.
///
/// Not run on a head yet: the simulator has no headphone motion.
@Observable
final class HeadGestures {
    static let shared = HeadGestures()

    /// Movement is arriving: headphones that sense it are in, and iOS lets Redde read it.
    private(set) var isSensing = false

    @ObservationIgnored private lazy var manager = CMHeadphoneMotionManager()
    @ObservationIgnored private var detector = HeadGestureDetector()
    @ObservationIgnored private var heard: ((HeadGesture) -> Void)?
    @ObservationIgnored private let log = Logger(subsystem: "com.goosehouse.echo", category: "voice")

    /// Whether this device can read headphone movement at all; Settings offers the switch only then.
    static var isAvailable: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-echo.headGestures") { return true }
        #endif
        return shared.manager.isDeviceMotionAvailable
    }

    func start(heard: @escaping (HeadGesture) -> Void) {
        stop()
        guard manager.isDeviceMotionAvailable else { return }
        self.heard = heard
        detector = HeadGestureDetector()
        // Formed as a nonisolated closure that says where it runs: a main-actor closure the
        // system calls anywhere else traps.
        let handler: @Sendable (CMDeviceMotion?, (any Error)?) -> Void = { [weak self] motion, _ in
            guard let motion else { return }
            let sample = HeadGestureDetector.Sample(time: motion.timestamp, pitch: motion.attitude.pitch,
                                                    yaw: motion.attitude.yaw, roll: motion.attitude.roll)
            let rate = motion.rotationRate
            MainActor.assumeIsolated { self?.feed(sample, rate: (rate.x, rate.y, rate.z)) }
        }
        manager.startDeviceMotionUpdates(to: .main, withHandler: handler)
    }

    func stop() {
        guard heard != nil else { return }
        heard = nil
        manager.stopDeviceMotionUpdates()
        isSensing = false
        #if DEBUG
        writeNotes()
        #endif
    }

    /// Has iOS ask for Motion & Fitness now, at the switch in Settings, and not in the middle of
    /// a conversation the first time a request is read out. False once the person has said no.
    func askToSense() async -> Bool {
        guard manager.isDeviceMotionAvailable else { return false }
        if CMHeadphoneMotionManager.authorizationStatus() == .notDetermined {
            let idle = heard == nil
            if idle { manager.startDeviceMotionUpdates() }
            var waited = 0
            while CMHeadphoneMotionManager.authorizationStatus() == .notDetermined, waited < 60 {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
            if idle, heard == nil { manager.stopDeviceMotionUpdates() }
        }
        let status = CMHeadphoneMotionManager.authorizationStatus()
        return status != .denied && status != .restricted
    }

    private func feed(_ sample: HeadGestureDetector.Sample, rate: (x: Double, y: Double, z: Double)) {
        guard let heard else { return }   // (one already on its way when `stop()` came)
        if !isSensing { isSensing = true }
        let gesture = detector.feed(sample)
        #if DEBUG
        note(sample, rate: rate, gesture: gesture)
        #endif
        guard let gesture else { return }
        log.info("head: \(gesture.rawValue, privacy: .public)")
        heard(gesture)
    }

    #if DEBUG
    /// What the AirPods reported while the last requests waited, for setting the detector's
    /// numbers from a real head: `Library/Application Support/head-motion.csv` in the app's
    /// container, the newest watch last.
    @ObservationIgnored private var notes: [String] = []

    private func note(_ sample: HeadGestureDetector.Sample, rate: (x: Double, y: Double, z: Double), gesture: HeadGesture?) {
        guard notes.count < 3000 else { return }   // two minutes of one request is plenty
        notes.append(String(format: "%.3f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%@", sample.time, sample.pitch, sample.yaw, sample.roll,
                            rate.x, rate.y, rate.z, gesture?.rawValue ?? ""))
    }

    private func writeNotes() {
        guard !notes.isEmpty else { return }
        defer { notes = [] }
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "head-motion.csv")
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if text.utf8.count > 1_000_000 { text = "" }
        text += "# \(Date.now.formatted(.iso8601))\ntime,pitch,yaw,roll,rate_x,rate_y,rate_z,gesture\n" + notes.joined(separator: "\n") + "\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
    #endif
}

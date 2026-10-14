import AVFoundation
import CoreImage
import UIKit
import os

/// The camera in voice mode: opened from the voice screen, it shows what it sees where the orb
/// was, and each question asked meanwhile goes with a picture of that moment. The picture is a
/// frame of the running video, so nothing clicks and nothing waits on a shutter; the back
/// camera, since this is for showing the agent something.
///
/// Not run on a phone yet: the simulator has no camera. Whether the camera and voice mode's
/// microphone get along there is to be seen.
final class VoiceCamera {
    static let shared = VoiceCamera()

    /// What a voice session is given: the phone's camera, or a made-up one when asked for.
    static var forApp: any VoiceLooking {
        #if DEBUG
        if DevHooks.has("-echo.voiceLook") { return DemoEye() }
        #endif
        return shared
    }

    private let feed = CameraFeed()
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "voice")

    var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }
    var viewfinder: AVCaptureSession? { feed.session }

    func open() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
        default: return false
        }
        let running = await feed.start()
        if !running { log.error("the camera didn't start") }
        return running
    }

    func close() { feed.stop() }

    func still() -> Attachment? {
        guard let (frame, angle) = feed.newest(within: CameraStill.freshness) else { return nil }
        return CameraStill.attachment(from: frame, angle: angle)
    }
}

/// The capture session and its newest frame. Off the main actor: frames arrive on a queue of
/// their own, thirty a second, and starting a session blocks until the camera is up.
nonisolated final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.goosehouse.echo.voice-camera")
    private let lock = NSLock()
    private var frame: (buffer: CVPixelBuffer, at: Date)?
    /// Says how far a frame has to be turned to stand upright, the way the device is held now.
    private var upright: AVCaptureDevice.RotationCoordinator?
    private var configured = false

    func start() async -> Bool {
        await withCheckedContinuation { done in
            queue.async {
                if !self.configured { self.configured = self.configure() }
                if self.configured, !self.session.isRunning { self.session.startRunning() }
                done.resume(returning: self.session.isRunning)
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.lock.withLock { self.frame = nil }
        }
    }

    /// The last frame and the turn it needs, unless it is older than `age`: a camera that iOS
    /// has taken away (the app left the screen) must not hand over what it saw before.
    func newest(within age: TimeInterval, now: Date = .now) -> (CVPixelBuffer, CGFloat)? {
        lock.withLock {
            guard let frame, now.timeIntervalSince(frame.at) <= age else { return nil }
            return (frame.buffer, upright?.videoRotationAngleForHorizonLevelCapture ?? 90)
        }
    }

    private func configure() -> Bool {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        lock.withLock { upright = coordinator }
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = sampleBuffer.imageBuffer else { return }
        keep(buffer)
    }

    /// One frame held at a time: holding more would starve the camera of buffers to fill.
    func keep(_ buffer: CVPixelBuffer, at: Date = .now) {
        lock.withLock { frame = (buffer, at) }
    }
}

/// A frame of video made into a picture to send.
nonisolated enum CameraStill {
    /// How old the newest frame may be and still count as what the camera sees now.
    static let freshness: TimeInterval = 1

    private static let context = CIContext()

    /// The turn iOS asks for, as the orientation a picture carries: a phone held upright gives
    /// frames lying on their side, to be turned a quarter clockwise.
    static func orientation(angle: CGFloat) -> CGImagePropertyOrientation {
        switch (Int(angle.rounded()) % 360 + 360) % 360 {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
    }

    static func attachment(from frame: CVPixelBuffer, angle: CGFloat) -> Attachment? {
        let image = CIImage(cvPixelBuffer: frame).oriented(orientation(angle: angle))
        guard let turned = context.createCGImage(image, from: image.extent) else { return nil }
        return Attachment.image(UIImage(cgImage: turned), filename: "camera.jpg")
    }
}

#if DEBUG
/// `-echo.voiceLook`: a camera for the simulator, which has none. It sees one drawn picture.
final class DemoEye: VoiceLooking {
    private(set) var isOpen = false
    let isAvailable = true
    let viewfinder: AVCaptureSession? = nil

    func open() async -> Bool { isOpen = true; return true }
    func close() { isOpen = false }

    func still() -> Attachment? {
        guard isOpen else { return nil }
        let size = CGSize(width: 720, height: 960)
        let picture = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemOrange.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 210, y: 330, width: 300, height: 300))
        }
        return Attachment.image(picture, filename: "camera.jpg")
    }
}
#endif

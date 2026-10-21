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

    func still() async -> Attachment? {
        guard let (frame, angle) = feed.newest(within: CameraStill.freshness) else { return nil }
        // Turned and made a JPEG off the main actor: a 1080p frame took tens of milliseconds
        // there, between the question's end and its going. The feed is done with the buffer.
        nonisolated(unsafe) let pixels = frame
        return await Task.detached(priority: .userInitiated) { CameraStill.attachment(from: pixels, angle: angle) }.value
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
/// `-echo.voiceLook`: a camera for the simulator, which has none. It sees one drawn picture, a
/// houseplant that wants water, and the voice screen shows it where a camera's picture would be.
final class DemoEye: VoiceLooking {
    /// When one was last opened, for a demo that plays what follows a question asked with it.
    static var openedAt: Date?
    private(set) var isOpen = false
    let isAvailable = true
    let viewfinder: AVCaptureSession? = nil
    let picture = DemoEye.plant()

    func open() async -> Bool {
        isOpen = true
        Self.openedAt = .now
        return true
    }

    func close() { isOpen = false }

    func still() -> Attachment? {
        guard isOpen else { return nil }
        return Attachment.image(picture, filename: "camera.jpg")
    }

    /// A pothos in a terracotta pot on a table, drooping, one leaf gone yellow.
    static func plant() -> UIImage {
        let size = CGSize(width: 720, height: 960)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            // A warm wall, lit from a window on the left, and the table.
            let wall = CGGradient(colorsSpace: nil, colors: [UIColor(red: 0.97, green: 0.90, blue: 0.77, alpha: 1).cgColor,
                                                             UIColor(red: 0.78, green: 0.66, blue: 0.53, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(wall, start: .zero, end: CGPoint(x: 720, y: 720), options: [])
            UIColor(red: 0.55, green: 0.36, blue: 0.22, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 720, width: 720, height: 240))
            UIColor(red: 0.46, green: 0.29, blue: 0.17, alpha: 1).setStroke()
            cg.setLineWidth(3)
            for y in stride(from: 752.0, to: 960, by: 48) {
                cg.move(to: CGPoint(x: 0, y: y))
                cg.addCurve(to: CGPoint(x: 720, y: y + 8), control1: CGPoint(x: 240, y: y - 10), control2: CGPoint(x: 480, y: y + 18))
                cg.strokePath()
            }
            // The pot, its shadow and rim, and dry soil.
            UIColor.black.withAlphaComponent(0.2).setFill()
            cg.fillEllipse(in: CGRect(x: 214, y: 772, width: 330, height: 42))
            let pot = UIBezierPath()
            pot.move(to: CGPoint(x: 236, y: 580))
            pot.addLine(to: CGPoint(x: 484, y: 580))
            pot.addLine(to: CGPoint(x: 452, y: 792))
            pot.addLine(to: CGPoint(x: 268, y: 792))
            pot.close()
            UIColor(red: 0.80, green: 0.42, blue: 0.27, alpha: 1).setFill()
            pot.fill()
            UIColor(red: 0.88, green: 0.51, blue: 0.34, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 218, y: 548, width: 284, height: 58), cornerRadius: 12).fill()
            UIColor(red: 0.55, green: 0.43, blue: 0.33, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 236, y: 538, width: 248, height: 30))
            // Stems over the rim, hanging.
            UIColor(red: 0.27, green: 0.45, blue: 0.20, alpha: 1).setStroke()
            cg.setLineWidth(8)
            cg.setLineCap(.round)
            for (start, one, two, end) in [((340.0, 548.0), (290.0, 380.0), (150.0, 390.0), (128.0, 660.0)),
                                           ((382.0, 548.0), (430.0, 370.0), (580.0, 390.0), (600.0, 690.0)),
                                           ((356.0, 548.0), (330.0, 380.0), (280.0, 330.0), (250.0, 440.0)),
                                           ((370.0, 548.0), (410.0, 330.0), (470.0, 330.0), (492.0, 460.0))] {
                cg.move(to: CGPoint(x: start.0, y: start.1))
                cg.addCurve(to: CGPoint(x: end.0, y: end.1), control1: CGPoint(x: one.0, y: one.1), control2: CGPoint(x: two.0, y: two.1))
                cg.strokePath()
            }
            // Heart-shaped leaves along them, hanging from where they join; one has gone yellow.
            let green = UIColor(red: 0.30, green: 0.58, blue: 0.27, alpha: 1)
            let light = UIColor(red: 0.42, green: 0.68, blue: 0.32, alpha: 1)
            let yellow = UIColor(red: 0.87, green: 0.76, blue: 0.27, alpha: 1)
            for (x, y, turn, size, color) in [(232.0, 372.0, 0.9, 92.0, light), (170.0, 470.0, 0.45, 96.0, green), (136.0, 590.0, 0.15, 100.0, light),
                                              (300.0, 350.0, 0.5, 80.0, green), (262.0, 430.0, 0.2, 84.0, yellow),
                                              (500.0, 370.0, -0.9, 92.0, green), (566.0, 470.0, -0.45, 98.0, light), (598.0, 610.0, -0.15, 100.0, green),
                                              (448.0, 340.0, -0.5, 82.0, light), (488.0, 448.0, -0.2, 86.0, green)] {
                cg.saveGState()
                cg.translateBy(x: x, y: y)
                cg.rotate(by: turn)
                let leaf = UIBezierPath()
                leaf.move(to: .zero)
                leaf.addCurve(to: CGPoint(x: 0, y: size), controlPoint1: CGPoint(x: -size * 0.8, y: -size * 0.2), controlPoint2: CGPoint(x: -size * 0.45, y: size * 0.75))
                leaf.addCurve(to: .zero, controlPoint1: CGPoint(x: size * 0.45, y: size * 0.75), controlPoint2: CGPoint(x: size * 0.8, y: -size * 0.2))
                color.setFill()
                leaf.fill()
                UIColor.white.withAlphaComponent(0.28).setStroke()
                let vein = UIBezierPath()
                vein.move(to: CGPoint(x: 0, y: size * 0.1))
                vein.addLine(to: CGPoint(x: 0, y: size * 0.85))
                vein.lineWidth = 3
                vein.stroke()
                cg.restoreGState()
            }
        }
    }
}
#endif

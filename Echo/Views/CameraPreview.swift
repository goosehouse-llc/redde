import AVFoundation
import SwiftUI

/// A running camera's picture, filling whatever frame it is given.
#if os(iOS)
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.show(session)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        /// Says how the picture has to be turned as the device is, and when that changes.
        private var upright: AVCaptureDevice.RotationCoordinator?
        private var turning: NSKeyValueObservation?

        func show(_ session: AVCaptureSession) {
            preview.session = session
            preview.videoGravity = .resizeAspectFill
            // The view can be on screen before the camera is up, and only then is there a camera
            // to ask which way up the picture goes.
            NotificationCenter.default.addObserver(self, selector: #selector(started), name: AVCaptureSession.didStartRunningNotification, object: session)
            follow()
        }

        /// Posted from the camera's own queue.
        @objc nonisolated private func started() {
            Task { @MainActor in self.follow() }
        }

        private func follow() {
            guard upright == nil, let camera = (preview.session?.inputs.first as? AVCaptureDeviceInput)?.device else { return }
            let upright = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: preview)
            self.upright = upright
            turn(to: upright.videoRotationAngleForHorizonLevelPreview)
            // Formed as a closure that says where it runs: one the system calls elsewhere traps.
            let turned: @Sendable (AVCaptureDevice.RotationCoordinator, NSKeyValueObservedChange<CGFloat>) -> Void = { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                Task { @MainActor in self?.turn(to: angle) }
            }
            turning = upright.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new], changeHandler: turned)
        }

        private func turn(to angle: CGFloat) {
            guard let connection = preview.connection, connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }
}
#else
/// The Mac's: its camera's picture in a layer-backed view, filling the frame.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer = preview
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
#endif

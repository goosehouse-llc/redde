import AVFoundation
import SwiftUI
import VisionKit

/// The camera, looking for a Redde setup code (a QR code of a `redde://connect` link). It hands
/// the first one it reads to `onCode` and closes; any other QR code gets a line saying so.
struct SetupCodeScanner: View {
    var onCode: (SetupCodeOffer) -> Void

    /// Whether this device can scan at all (not the simulator, not the iPad app on a Mac).
    static var isSupported: Bool { DataScannerViewController.isSupported }

    private enum Access { case asking, allowed, denied }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var access = Access.asking
    @State private var wrongCode = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch access {
                case .asking:
                    ProgressView().tint(.white)
                case .allowed:
                    CodeCamera { text in read(text) }
                        .ignoresSafeArea()
                    VStack {
                        Spacer()
                        Text(wrongCode ? "That isn't a Redde setup code." : "Point the camera at a Redde setup code.")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: .capsule)
                            .padding(.bottom, 32)
                    }
                case .denied:
                    ContentUnavailableView {
                        Label("No camera access", systemImage: "camera.fill")
                    } description: {
                        Text("Allow the camera for Redde in Settings to scan a setup code, or paste the setup link instead.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                    .foregroundStyle(.white)
                }
            }
            .navigationTitle("Scan a setup code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task { access = await Self.cameraAccess() ? .allowed : .denied }
    }

    private func read(_ text: String) {
        guard let offer = SetupCodeOffer(text: text) else {
            wrongCode = true
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode(offer)
        dismiss()
    }

    /// Asks the first time; afterwards the answer given then.
    private static func cameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }
}

/// VisionKit's live scanner, set to QR codes only.
private struct CodeCamera: UIViewControllerRepresentable {
    var onText: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced,
                                                recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false,
                                                isGuidanceEnabled: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onText = onText
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onText: (String) -> Void
        /// A code stays in view for many frames: each text is reported once.
        private var seen: Set<String> = []

        init(onText: @escaping (String) -> Void) { self.onText = onText }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in addedItems {
                guard let text = code.payloadStringValue, seen.insert(text).inserted else { continue }
                onText(text)
            }
        }
    }
}

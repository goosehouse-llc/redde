import CoreImage.CIFilterBuiltins
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

/// "Set up another device": a server's connection as a QR code and a link, for Redde on another
/// phone or iPad to scan or open. Addresses and names only until the person asks for the
/// passwords too, which takes Face ID or the passcode, as showing a saved password does anywhere.
struct SetupCodeView: View {
    let server: HermesServer

    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var withSecrets = false
    @State private var code = SetupCode()
    @State private var picture: UIImage?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            Form {
                if code.transport == nil {
                    Section {
                        Label("There is no connection to hand over yet. Set this one up first.",
                              systemImage: "info.circle")
                    }
                } else {
                    Section {
                        if let picture {
                            Image(uiImage: picture)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(14)
                                // White in every appearance: a camera reads dark on light.
                                .background(.white, in: .rect(cornerRadius: 16))
                                .frame(maxWidth: 300)
                                .frame(maxWidth: .infinity)
                                .listRowBackground(Color.clear)
                                .accessibilityLabel("Setup code for \(server.title)")
                                .accessibilityIdentifier("setup-code")
                        } else {
                            Label("This connection is too long to show as a code. Copy the link instead.", systemImage: "info.circle")
                        }
                    } footer: {
                        if picture != nil {
                            Text("On the other device, open Redde and choose Scan a setup code, or point its Camera at this.")
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                        }
                    }

                    Section {
                        Toggle("Include passwords and keys", isOn: Binding(get: { withSecrets }, set: { setSecrets($0) }))
                        Button("Copy link", systemImage: "doc.on.doc") { copy() }
                    } footer: {
                        Text(withSecrets
                             ? "This code now holds \(holds). Anyone who scans or receives it can use your server: show it only to your own devices."
                             : "The code holds \(holds). Passwords and keys are left out and typed in on the other device.")
                    }
                }
            }
            .navigationTitle("Set up another device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .toast($toast)
            .task { render() }
        }
    }

    /// What is in the code, in words.
    private var holds: String {
        var parts: [String] = []
        if !code.dashboardURL.isEmpty { parts.append(withSecrets ? "the Dashboard address and login" : "the Dashboard address and user name") }
        if !code.apiURL.isEmpty { parts.append(withSecrets ? "the Hermes API address and key" : "the Hermes API address") }
        if !code.accessID.isEmpty { parts.append(withSecrets ? "the Cloudflare Access token" : "the Cloudflare Access client ID") }
        if !code.modelURL.isEmpty { parts.append(withSecrets && !code.modelKey.isEmpty ? "the model endpoint and its key" : "the model endpoint") }
        return ListFormatter.localizedString(byJoining: parts)
    }

    private func render() {
        code = SetupCode(server: server, settings: settings, secrets: withSecrets)
        picture = code.transport == nil ? nil : QRCode.image(for: code.url.absoluteString)
    }

    private func setSecrets(_ on: Bool) {
        guard on else {
            withSecrets = false
            render()
            return
        }
        Task {
            guard await Self.confirmOwner() else { return }
            withSecrets = true
            render()
        }
    }

    private func copy() {
        // A link with passwords in it doesn't stay on the clipboard.
        let expiry = Date.now.addingTimeInterval(withSecrets ? 120 : 3_600)
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: code.url.absoluteString]], options: [.expirationDate: expiry])
        toast = withSecrets ? "Link copied for two minutes" : "Link copied"
    }

    /// Face ID, Touch ID or the passcode. A device with none set has nothing to ask.
    private static func confirmOwner() async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Put your passwords in the setup code")) ?? false
    }
}

/// A QR code of a piece of text, one pixel per module (scale it up without smoothing).
nonisolated enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

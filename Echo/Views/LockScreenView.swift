import SwiftUI

/// Full-window cover while the app is locked. Content underneath is blurred, not hidden, so the
/// unlock feels like lifting a veil rather than relaunching.
struct LockScreenView: View {
    @Environment(\.theme) private var theme
    @State private var lock = AppLock.shared

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text("Redde is locked")
                    .font(.title3.weight(.semibold))
                Button {
                    Task { await lock.authenticate() }
                } label: {
                    Label("Unlock with \(AppLock.biometryName)", systemImage: AppLock.biometrySymbol)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        // The theme's words for its accent (2026-11-25: white on Arcade's lime was
                        // hard to read; `ProminentButton` does the same for the filled buttons).
                        .foregroundStyle(theme.userText)
                }
                .buttonStyle(.glassProminent)
                .tint(theme.accent)
                .disabled(lock.authenticating)
                if let error = lock.lastError {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                }
            }
        }
    }
}

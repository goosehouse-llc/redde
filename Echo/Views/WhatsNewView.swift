import SwiftUI

/// The "What's New" sheet: one version's highlights, shown once after an update and from
/// Settings → About.
struct WhatsNewView: View {
    let release: WhatsNew.Release
    var onContinue: () -> Void = {}
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What's New in Redde")
                        .font(.largeTitle.weight(.bold))
                    Text("Version \(release.version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                ForEach(release.items) { item in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: item.symbol)
                            .font(.title2)
                            .foregroundStyle(theme.accent)
                            .frame(width: 36)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.headline)
                            Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                onContinue()
                dismiss()
            } label: {
                // The theme's text for accent buttons: white on a pale accent is unreadable.
                Text("Continue").font(.headline).foregroundStyle(theme.userText).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}

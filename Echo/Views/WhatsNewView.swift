import SwiftUI

/// The "What's New" sheet: one version's highlights, shown once after an update and from
/// Settings → About.
struct WhatsNewView: View {
    let release: WhatsNew.Release
    /// Redde has the wide layout (an iPad, an iPhone Duo open): what's new there is shown too.
    var wide = UIDevice.current.userInterfaceIdiom == .pad
    var onContinue: () -> Void = {}
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    /// Ahead of Your Day's button under its item: once, to someone not offered it before
    /// (`AheadOfYourDay.offersSetup`); set as the sheet first appears, so it stays while it is up.
    @State private var offersSetup: Bool?
    @State private var settingUp = false

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

                ForEach(release.items.filter { item in
                    let idiom = UIDevice.current.userInterfaceIdiom
                    return (!item.phoneOnly || idiom == .phone) && (!item.padOnly || idiom == .pad || wide)
                }) { item in
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
                    if item.action == .aheadOfYourDay, offersSetup == true {
                        Button { settingUp = true } label: {
                            Label(String(localized: "Set Up Ahead of Your Day…", comment: "What's New: the button under Ahead of your day that opens its one-step setup"),
                                  systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(theme.accent)
                        .controlSize(.regular)
                        .padding(.leading, 52)
                        .padding(.top, -16)
                    }
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
        .onAppear {
            if offersSetup == nil {
                offersSetup = AheadOfYourDay.offersSetup(in: release, answered: AheadOfYourDay.answered())
            }
        }
        // Offered once: closing What's New answers it, taken or not; Settings → Agent keeps it.
        .onDisappear { if offersSetup == true, !settingUp { AheadOfYourDay.markAnswered() } }
        .sheet(isPresented: $settingUp) { AheadOfYourDayView() }
    }
}

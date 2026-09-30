import StoreKit
import SwiftUI

/// Settings → About → Support Redde.
struct TipJarView: View {
    @State private var jar = TipJar.shared
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "heart.fill")
                        .font(.largeTitle)
                        .foregroundStyle(theme.accent)
                        .accessibilityHidden(true)
                    Text("Redde is made by one small company, with no ads, no accounts and no tracking. If it's useful to you, a tip helps keep it going.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            switch jar.state {
            case .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .unavailable:
                Section {
                    Label("Tips aren't available right now. Nothing's wrong on your side; every feature is already yours.", systemImage: "heart")
                        .foregroundStyle(.secondary)
                }
            case .thanked:
                Section {
                    VStack(spacing: 8) {
                        Text("Thank you!").font(.title2.weight(.semibold))
                        Text("It really does help.").foregroundStyle(.secondary)
                        Button("Done") { jar.reset() }.padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            case .ready, .purchasing:
                Section {
                    ForEach(jar.options) { option in
                        tipRow(option)
                    }
                } footer: {
                    Text("A one-time tip through the App Store. It doesn't unlock anything: every feature is already yours.")
                }
            }
        }
        .navigationTitle("Support Redde")
        .navigationBarTitleDisplayMode(.inline)
        .task { await jar.load() }
    }

    private func tipRow(_ option: TipJar.Option) -> some View {
        let busy = jar.state == .purchasing(option.id)
        return Button {
            Task { await jar.buy(option) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: TipJar.symbol(for: option.id))
                    .font(.title3)
                    .foregroundStyle(theme.accent)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                Text(option.name)
                Spacer()
                if busy {
                    ProgressView()
                } else {
                    Text(option.price)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.userText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.accent, in: .capsule)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(jar.state != .ready)
        .accessibilityLabel("\(option.name), \(option.price)")
    }
}

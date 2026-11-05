import SwiftUI

/// Settings → Phone tools → Health: which kinds of Apple Health data the agent may read, each on
/// its own. Turning one on is when iOS asks for reading it; nothing is ever written to Health.
struct HealthShareView: View {
    @State private var settings = Settings.shared
    /// Kinds iOS is being asked about.
    @State private var asking: Set<HealthKind> = []

    var body: some View {
        Form {
            Section {
                Text("Your agent reads only what you turn on here, when it asks: totals, averages, nights and workouts, never every sample. It goes to your own Hermes and nowhere else, and Redde never writes to Health.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(HealthKind.Group.allCases) { group in
                Section {
                    ForEach(group.kinds) { kind in
                        Toggle(isOn: binding(kind)) {
                            HStack {
                                Text(kind.label)
                                if asking.contains(kind) { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(asking.contains(kind))
                    }
                } header: {
                    HStack {
                        Text(group.label)
                        Spacer()
                        if group.kinds.count > 1 {
                            let all = group.kinds.allSatisfy { settings.phoneTools.health.contains($0.rawValue) }
                            Button(all ? String(localized: "None", comment: "Turns off every kind of Health data in a group") : String(localized: "All", comment: "Turns on every kind of Health data in a group")) {
                                set(group.kinds, !all)
                            }
                            .font(.footnote)
                            .textCase(nil)
                        }
                    }
                }
            }
            Section {
            } footer: {
                Text("If Health says no to a kind, your agent finds nothing there. You can change it on this \(device) in Settings → Health → Data Access & Devices → Redde.")
            }
        }
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    private func binding(_ kind: HealthKind) -> Binding<Bool> {
        Binding(get: { settings.phoneTools.health.contains(kind.rawValue) }, set: { set([kind], $0) })
    }

    /// Turned off at once; turned on once iOS has been asked (one question for a whole group).
    private func set(_ kinds: [HealthKind], _ on: Bool) {
        guard on else { kinds.forEach { settings.phoneTools.share($0, false) }; return }
        let wanted = kinds.filter { !settings.phoneTools.health.contains($0.rawValue) }
        asking.formUnion(wanted)
        Task {
            #if os(iOS)
            let allowed = await DeviceHealth.allow(wanted)
            #else
            let allowed = false
            #endif
            if allowed { wanted.forEach { settings.phoneTools.share($0, true) } }
            asking.subtract(wanted)
        }
    }
}

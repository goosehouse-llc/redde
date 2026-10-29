#if os(iOS)
import SwiftUI

/// Settings → Agent → Health (`HealthDays`): off until turned on; what is read and what the agent
/// gets, shown as the agent will read it.
struct HealthDaysView: View {
    @State private var on = HealthSummary.isOn()
    @State private var summary = HealthSummary.load()
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Toggle("Health-Aware Days", isOn: Binding(get: { on }, set: { turn($0) }))
                    .disabled(working || !HealthDays.available)
            } footer: {
                Text("Your agent's Morning Ideas, Evening Wrap-up and Week Ahead take your day into account: a lighter set of ideas after a short night, a nudge after a day without moving. Redde reads last night's sleep, your steps and your workouts from Apple Health on this iPhone. Only a one-line summary goes to your Hermes, in those scheduled jobs; nothing from Health goes into your chats, and nothing is written to Health.")
            }
            if on {
                Section {
                    if let line = summary?.line {
                        Text(line).font(.footnote).textSelection(.enabled)
                    } else {
                        Text("Nothing from Health yet: no sleep, steps or workouts saved today and yesterday, or Redde wasn't allowed to read them (Settings › Health › Data Access & Devices › Redde).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Read Again and Send") { Task { await again() } }.disabled(working)
                } header: {
                    Text("What Your Agent Gets")
                } footer: {
                    Text("Said again when new sleep or a workout is saved, and when you open Redde. Turn this off and it's taken out of the jobs.")
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(.red).font(.footnote) } }
        }
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func turn(_ value: Bool) {
        working = true
        Task {
            defer { working = false }
            if value {
                do {
                    try await HealthDays.turnOn()
                    problem = nil
                } catch {
                    problem = error.localizedDescription
                }
            } else {
                await HealthDays.turnOff()
            }
            on = HealthSummary.isOn()
            summary = HealthSummary.load()
        }
    }

    private func again() async {
        working = true
        defer { working = false }
        await HealthDays.refresh(force: true)
        summary = HealthSummary.load()
    }
}
#endif

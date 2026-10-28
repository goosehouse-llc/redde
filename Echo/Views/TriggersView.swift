import SwiftUI

/// Settings → Agent → Triggers from Your iPhone (asked 2026-10-28, after Grok Bot): Shortcuts
/// automations run Redde's background actions on their own (arriving home, a time of day, a Focus,
/// CarPlay), so the iPhone's own triggers start an agent's work. Nothing new runs here: the page
/// says how, with recipes.
struct TriggersView: View {
    private struct Recipe: Identifiable {
        var when: LocalizedStringResource
        var symbol: String
        var action: LocalizedStringResource
        var message: LocalizedStringResource
        var id: String { symbol }
    }

    private let recipes = [
        Recipe(when: "When I arrive home", symbol: "house", action: "Ask a Redde Bot a Question, to Home",
               message: "I'm home: warm the house to 21° and turn on the hall light."),
        Recipe(when: "When I leave work", symbol: "figure.walk.departure", action: "Ask Redde a Question",
               message: "What did I say I'd pick up on the way home?"),
        Recipe(when: "At 7:00 on weekdays", symbol: "alarm", action: "Ask Redde a Question",
               message: "What's my first meeting, and do I need an umbrella?"),
        Recipe(when: "When the Sleep Focus turns on", symbol: "bed.double", action: "Ask a Redde Bot a Question, to Home",
               message: "Goodnight: lock the doors and turn off the lights downstairs."),
        Recipe(when: "When CarPlay connects", symbol: "car", action: "Ask Redde a Question",
               message: "Anything I should know before I drive?"),
    ]

    var body: some View {
        Form {
            Section {
                Text("Your iPhone can start your agent's work by itself, with a Shortcuts automation: when you arrive somewhere or leave, at a time of day, when a Focus turns on, when CarPlay connects. The automation runs one of Redde's actions in the background, and the answer comes as a notification.")
            }
            Section {
                step(1, "Open Shortcuts, then Automation, then New Automation.")
                step(2, "Pick what starts it (Arrive, Time of Day, a Focus, CarPlay…), and choose Run Immediately.")
                step(3, "Add Redde's Ask a Redde Bot a Question (to a bot, in its own chat) or Ask Redde a Question (to your agent), and type what it should do.")
                if let url = URL(string: "shortcuts://") {
                    Link(destination: url) { Label("Open Shortcuts", systemImage: "square.2.layers.3d") }
                }
            } header: {
                Text("How")
            } footer: {
                Text("With App Lock on, Redde waits for your iPhone to be unlocked before it asks, as it does for Siri.")
            }
            Section("Ideas") {
                ForEach(recipes) { recipe in
                    VStack(alignment: .leading, spacing: 4) {
                        Label { Text(recipe.when).font(.body.weight(.semibold)) } icon: { Image(systemName: recipe.symbol) }
                        Text(recipe.action).font(.caption).foregroundStyle(.secondary)
                        Text("“\(String(localized: recipe.message))”").font(.callout)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Triggers from Your iPhone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.callout.weight(.bold)).foregroundStyle(.tint).monospacedDigit()
            Text(text)
        }
    }
}

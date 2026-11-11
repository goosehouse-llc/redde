import SwiftUI

/// Edit Bot → Phone Tools: which of this phone's areas one bot may use (asked 2026-11-10, a health
/// bot that reads the Apple Watch's data). Only the areas on in Settings → Phone tools, at the
/// access set there; a bot starts with Calendar and Reminders (`PhoneToolsSettings.botDefault`).
/// Kept on this phone, per server, and told to the plugin at once (`DeviceToolsService.publishBots`).
struct BotPhoneToolsView: View {
    let bot: HermesBot
    let name: String
    @State private var settings = Settings.shared
    @State private var service = DeviceToolsService.shared

    private var server: String { settings.activeServerID.uuidString }
    /// The areas on for the main agent, which are the ones a bot can be given (Apple Home only
    /// where there is one).
    private var open: [DeviceArea] { settings.phoneTools.open.filter { $0 != .home || DeviceHome.available } }

    var body: some View {
        Form {
            if !settings.phoneTools.on || open.isEmpty {
                Section {
                    Text("Turn on Phone tools and the areas you want in Settings → Phone tools first. A bot can be given only the ones that are on there.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(open) { area in
                        Toggle(isOn: given(area)) {
                            Label(area.label, systemImage: area.symbol)
                        }
                        if area == .health, settings.phoneTools.given(bot.name, server: server).contains(.health) {
                            let shared = settings.phoneTools.sharedHealth.count
                            Text(shared == 0
                                 ? String(localized: "Nothing in Health is shared yet: choose what in Settings → Phone tools → Health.")
                                 : String(localized: "It reads the \(shared) kinds of Health data shared in Settings → Phone tools → Health.",
                                          comment: "Edit Bot → Phone Tools: how many kinds of Apple Health data a bot given Health may read"))
                                .font(.footnote)
                                .foregroundStyle(shared == 0 ? .red : .secondary)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(name) asks Redde for these the way your agent does, with the same rules: what asks you first still asks, and the question says it's \(name) asking. Off ones aren't offered to it at all.",
                             comment: "Edit Bot → Phone Tools: what giving a bot an area means; the bot's name twice")
                        Text("Every bot starts with Calendar and Reminders, when they're on in Settings → Phone tools.",
                             comment: "Edit Bot → Phone Tools: the areas a bot has before they're changed")
                    }
                }
                if service.botsUnsupported {
                    Section {
                        Text("Redde's plugin on your Hermes is older than 1.24.0, which gives bots phone tools of their own. Update it in Settings → Redde Plugin.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Phone Tools")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: settings.phoneTools) { await service.publishBots() }
    }

    private func given(_ area: DeviceArea) -> Binding<Bool> {
        Binding(get: { settings.phoneTools.given(bot.name, server: server).contains(area) },
                set: { settings.phoneTools.give(bot.name, server: server, area, $0) })
    }

    /// In a word, for Edit Bot's row: "Off", "Health", "Health, Calendar", "4 areas".
    static func summary(_ bot: HermesBot, settings: Settings = .shared) -> String {
        let open = settings.phoneTools.open(for: bot.name, server: settings.activeServerID.uuidString)
        switch open.count {
        case 0: return String(localized: "Off", comment: "Edit Bot → Phone Tools: the bot has none")
        case 1, 2: return open.map(\.label).formatted(.list(type: .and))
        default: return String(localized: "\(open.count) areas", comment: "Edit Bot → Phone Tools: how many areas the bot may use")
        }
    }
}

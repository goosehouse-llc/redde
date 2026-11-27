import SwiftUI

/// Settings › Your Day › Agents Bring Up (plugin 1.58.0, `proactive.py`; asked 2026-11-27, "now build
/// the muse gaps", after the proactivity setting of Meta's Muse): one dial for what every agent
/// brings up on its own, kept on the server, so every device shows the same. What the person asked
/// for (replies, reminders, briefings, Heads-Ups, watches) is never held back; the notification
/// levels (`NoteLevels`) say how loudly the rest comes.
enum AgentsBringUp: String, CaseIterable, Identifiable {
    case off, less, normal, more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .less: String(localized: "Less Often", comment: "Agents Bring Up: only what matters soon")
        case .normal: String(localized: "Normal", comment: "Agents Bring Up: as agents always have")
        case .more: String(localized: "More Often", comment: "Agents Bring Up: more ideas, nice-to-know ones too")
        }
    }

    var about: String {
        switch self {
        case .off:
            String(localized: "Agents bring up nothing on their own: no ideas or Follow-Through cards, and Morning Ideas and When You've Gone Quiet don't run. A sign-in that may not be you, and plans you made, still come.",
                   comment: "Agents Bring Up: under Off")
        case .less:
            String(localized: "Only what matters soon: bills, trips, dates and what's due today or tomorrow, and at most one set of ideas a day from each agent.",
                   comment: "Agents Bring Up: under Less Often")
        case .normal:
            String(localized: "Ideas, Follow-Through cards and check-ins as they come up.", comment: "Agents Bring Up: under Normal")
        case .more:
            String(localized: "More ideas, nice-to-know ones too. Ideas you leave alone take longer to go quiet.", comment: "Agents Bring Up: under More Often")
        }
    }

    /// "redde-push proactive less" → `.less`.
    static func parse(_ reply: String) -> AgentsBringUp? {
        let words = reply.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard words.count == 3, words[0] == "redde-push", words[1] == "proactive" else { return nil }
        return AgentsBringUp(rawValue: String(words[2]))
    }

    enum Read: Equatable { case level(AgentsBringUp), tooOld, unreachable }

    /// The dial as the server has it, after `set` when one is given.
    static func read(setting: AgentsBringUp? = nil, through plugin: PushService.PluginCommand) async -> Read {
        do {
            let reply = try await plugin(setting.map { "proactive set \($0.rawValue)" } ?? "proactive")
            return parse(reply).map(Read.level) ?? .tooOld
        } catch PushError.noPlugin {
            return .tooOld
        } catch {
            return .unreachable
        }
    }
}

struct AgentsBringUpSection: View {
    let canReachGateway: Bool
    var plugin: PushService.PluginCommand = PushService.command(over: Settings.shared)
    @State private var read: AgentsBringUp.Read?
    @State private var saving = false

    private var level: AgentsBringUp? {
        if case .level(let level) = read { return level }
        return nil
    }

    var body: some View {
        Section {
            Picker(selection: Binding(get: { level ?? .normal }, set: { choose($0) })) {
                ForEach(AgentsBringUp.allCases) { Text($0.title).tag($0) }
            } label: {
                Label { Text("Agents Bring Up", comment: "Settings › Your Day: one dial for what every agent brings up on its own") } icon: {
                    Image(systemName: "dial.medium")
                }
            }
            .disabled(level == nil || saving)
            .accessibilityIdentifier("agents-bring-up")
        } footer: {
            switch read {
            case .level(let level):
                Text("\(level.about) What you ask for always comes: replies, reminders, briefings, Heads-Ups and watches.",
                     comment: "Agents Bring Up: footer; the first part says what the chosen level does")
            case .tooOld:
                Text("Agents Bring Up takes the Redde plugin 1.58: update it in Settings › Redde Plugin.", comment: "Agents Bring Up: the plugin is too old")
            case .unreachable:
                Text("Couldn't reach your Hermes. Try again in a moment.")
            case nil:
                Text("How much your agents bring up on their own.", comment: "Agents Bring Up: footer while it loads")
            }
        }
        .task(id: canReachGateway) {
            guard canReachGateway else { return }
            read = await AgentsBringUp.read(through: plugin)
        }
    }

    private func choose(_ new: AgentsBringUp) {
        guard new != level else { return }
        let before = read
        read = .level(new)
        saving = true
        Task {
            let answer = await AgentsBringUp.read(setting: new, through: plugin)
            read = answer == .unreachable ? before : answer
            saving = false
        }
    }
}

import SwiftUI

/// A chat's ··· → Make This a Routine… (asked 2026-10-28, after Grok Bot's teach-it-once
/// routines): what the agent did here, kept as a Hermes skill it can do again on its own
/// (`RoutineNote`), and, if the person wants, a schedule that runs it, each run's answer coming
/// as a notification and staying in Briefings (a `[redde-notify]` job). The skill is the agent's
/// to write, with its skill tool: the Hermes API has no other way to make one.
struct RoutineSheet: View {
    let conversation: Conversation

    enum Often: String, CaseIterable, Identifiable {
        case asked, daily, weekdays, weekly
        var id: String { rawValue }
        var label: LocalizedStringResource {
            switch self {
            case .asked: "Only when I ask"
            case .daily: "Every day"
            case .weekdays: "Weekdays"
            case .weekly: "Every week"
            }
        }
    }

    @State private var name = ""
    @State private var often = Often.asked
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
    @State private var weekday = Calendar.current.component(.weekday, from: .now)
    @State private var saving = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    /// A schedule goes in the profile the chat is with: possible over the Dashboard for any, over
    /// the Hermes API for the agent Redde is on alone.
    private var canSchedule: Bool {
        #if DEBUG
        if DemoDay.on { return true }   // the day's video: as on the Dashboard
        #endif
        guard let backend = CronBackend.current() else { return false }
        if case .serve = backend { return conversation.bot?.viaAPI != true }
        return conversation.bot == nil && conversation.elsewhere == nil
    }

    private var profile: String? { conversation.bot?.profile ?? conversation.elsewhere?.profile }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                } footer: {
                    Text("Your agent keeps what it did in this chat as a skill, the steps to do it again by itself, and tells you when it's saved.")
                }
                Section {
                    Picker("Run It", selection: $often) {
                        ForEach(Often.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!canSchedule)
                    if often != .asked {
                        if often == .weekly {
                            Picker("Day", selection: $weekday) {
                                ForEach(1 ... 7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                            }
                        }
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    if canSchedule {
                        Text("On a schedule, each run's answer comes as a notification and stays in Briefings. Its schedule is in Cron. Otherwise, ask for it by name whenever you like.")
                    } else {
                        Text("This chat's routine runs when you ask for it by name: a schedule for it needs the Hermes Dashboard.")
                    }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Make This a Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if name.isEmpty { name = conversation.title } }
        }
    }

    /// The cron schedule, and how it reads to the agent.
    private var schedule: (cron: String, words: String)? {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let (hour, minute) = (parts.hour ?? 8, parts.minute ?? 0)
        let at = String(format: "%02d:%02d", hour, minute)
        switch often {
        case .asked: return nil
        case .daily: return ("\(minute) \(hour) * * *", "every day at \(at)")
        case .weekdays: return ("\(minute) \(hour) * * 1-5", "on weekdays at \(at)")
        case .weekly:
            let english = Calendar(identifier: .gregorian)
            var named = english
            named.locale = Locale(identifier: "en")
            return ("\(minute) \(hour) * * \(weekday - 1)", "every \(named.weekdaySymbols[weekday - 1]) at \(at)")
        }
    }

    private func save() async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let skill = RoutineNote.slug(name)
        saving = true
        defer { saving = false }
        let scheduled = canSchedule ? schedule : nil
        if let scheduled, let backend = CronBackend.current() {
            do {
                try await backend.create(name: "[redde-notify] " + name, schedule: scheduled.cron,
                                         prompt: RoutineNote.jobPrompt(name: name, skill: skill), deliver: "local", profile: profile)
            } catch {
                problem = error.localizedDescription
                return
            }
        }
        conversation.makeRoutine(name: name, skill: skill, when: scheduled?.words)
        dismiss()
    }
}

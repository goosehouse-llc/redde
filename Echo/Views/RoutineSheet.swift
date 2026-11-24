import SwiftUI

/// A chat's ··· → Make This a Routine… (asked 2026-10-28, after Grok Bot's teach-it-once
/// routines): what the agent did here, kept as a Hermes skill it can do again on its own
/// (`RoutineNote`), and, if the person wants, a schedule that runs it, each run's answer coming
/// as a notification and staying in Briefings (a `[redde-notify]` job). The skill is the agent's
/// to write, with its skill tool: the Hermes API has no other way to make one.
struct RoutineSheet: View {
    let conversation: Conversation
    /// From a message's menu: a reply's ⋯ (asked 2026-11-04), whose request becomes the routine,
    /// or a long press on the person's own message (2026-11-24), which is the request.
    var message: UUID? = nil

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
            .onAppear { if name.isEmpty { name = asked.map(Self.name(from:)) ?? conversation.title } }
        }
    }

    /// What was asked, for the message it was opened from.
    private var asked: String? { message.flatMap(conversation.asked(for:)) }

    /// A name from a request: its first line, cut within 40 characters at the end of a clause when
    /// one is well in ("What's on my calendar tomorrow, and remind me…" → "What's on my calendar
    /// tomorrow", 2026-11-24), otherwise at a word.
    nonisolated static func name(from asked: String) -> String {
        let line = asked.split(separator: "\n").first.map(String.init) ?? asked
        guard line.count > 40 else { return line }
        let cut = line.prefix(40)
        let clause = cut.lastIndex { ",;:".contains($0) }.flatMap { cut.distance(from: cut.startIndex, to: $0) >= 12 ? $0 : nil }
        let end = clause ?? cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
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
        conversation.makeRoutine(name: name, skill: skill, when: scheduled?.words, asked: asked)
        dismiss()
    }
}

/// Make This a Routine from a message's menu: the message it was asked from (a reply, or the
/// person's own), for ContentView's sheet.
@Observable
final class RoutineAsk {
    static let shared = RoutineAsk()
    var message: UUID?
}

/// Make This a Routine… in a message's menu, a reply's or the person's own (`MessageRow`), on a
/// Hermes chat that isn't incognito or a worker's, and not while a reply comes in. A view of its
/// own so that only it, not every row, is drawn again when the chat starts or stops streaming.
struct MakeRoutineButton: View {
    let message: UUID
    @Environment(Conversation.self) private var conversation: Conversation?

    var body: some View {
        if let conversation, conversation.connection.isHermes, !conversation.isIncognito, !conversation.isWorkerTranscript,
           !conversation.isStreaming {
            Button("Make This a Routine…", systemImage: "repeat") { RoutineAsk.shared.message = message }
        }
    }
}

import EventKit
import SwiftUI

/// Settings → Calendars (`CalendarChoice`, asked 2026-10-30: "choose which calendars to
/// look at"): all of them, or only the ones switched on here. Offered are this device's calendars,
/// by account as Calendar lists them, once Redde may see them (a button asks), and the ones calendar
/// cards have named, which are the agent's: its calendars are on the server, matched by title.
/// Under them, where new events go, how calendar cards color events, the Up Next tile and
/// Reminders on Their Day (a page of the first screen since 2026-11-15; under Agent before).
struct CalendarsSettingsView: View {
    private let settings = Settings.shared
    /// The switch is off, so the calendars show to choose from, even with none chosen yet.
    @State private var limiting = !Settings.shared.agendaCalendars.isEmpty
    @State private var access = ComposerContext.calendarAccess
    @State private var accounts: [Account] = []
    @State private var seen: [String] = []
    /// This device's calendars that can be added to, for New Events.
    @State private var writable: [Row] = []
    @State private var newEvents = Settings.shared.newEventsCalendar
    @Environment(\.openURL) private var openURL

    /// One account's calendars ("iCloud", "Gmail"), each by its title and its own colour.
    nonisolated struct Account: Identifiable, Sendable {
        var id: String
        var title: String
        var calendars: [Row]
    }

    /// One calendar, known by its identifier: two in one account can have the same title (a
    /// subscription and a calendar of the same name), and a list keyed by title showed one twice
    /// and the other not at all.
    nonisolated struct Row: Identifiable, Sendable {
        var id: String
        var title: String
        var color: Color
    }

    var body: some View {
        Form {
            Section {
                Toggle("All Calendars", isOn: Binding(get: { !limiting }, set: { all in
                    limiting = !all
                    if all { settings.agendaCalendars = [] }
                }))
                .settingRow(.allCalendars)
            } footer: {
                limiting
                    ? Text("Only the calendars switched on here. With none on, all of them. Phone tools read and add to only these on this device.")
                    : Text("Your agent looks at every calendar when you ask what's on, calendar cards show every event, and phone tools can read and add to every calendar on this device.")
            }
            if limiting {
                ForEach(accounts) { account in
                    Section(account.title) {
                        ForEach(account.calendars) { row($0.title, color: $0.color) }
                    }
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others, id: \.self) { row($0, color: AgendaCard.color(of: $0)) }
                    } header: {
                        Text("On Calendar Cards")
                    }
                }
                deviceAccess
            }
            // Below the calendars to choose from, so they stay under the switch that shows them.
            if access == .granted, !writable.isEmpty {
                Section {
                    Picker("New Events", selection: $newEvents) {
                        Text("Calendar's Default").tag("")
                        ForEach(writable) { calendar in
                            Label { Text(calendar.title) } icon: { Image(systemName: "circle.fill").imageScale(.small).foregroundStyle(calendar.color) }
                                .tag(calendar.title)
                        }
                        // Chosen on another device, by iCloud, and not one of this one's.
                        if !newEvents.isEmpty, !writable.contains(where: { $0.title == newEvents }) { Text(newEvents).tag(newEvents) }
                    }
                    .onChange(of: newEvents) { settings.newEventsCalendar = newEvents }
                    .settingRow(.newEvents)
                } footer: {
                    Text("Where an event your agent adds goes, unless you ask for another calendar. Calendar's Default is the one set in Settings → Apps → Calendar.")
                }
            }
            // How calendar cards color events (on Settings → Appearance until 2026-11-15).
            Section {
                Picker(selection: Binding(get: { settings.eventColor }, set: { settings.eventColor = $0 })) {
                    ForEach(Settings.EventColor.allCases) { choice in
                        if let color = choice.color {
                            Label { Text(choice.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(color) }.tag(choice)
                        } else {
                            Text(choice.label).tag(choice)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calendar Events")
                        Text("On a calendar card: each calendar in its own color, or every event in one.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .settingRow(.eventColors)
            }
            // The calendar in the chat list too (also on Settings → Chat List): the next event as a
            // Today tile, and reminders on a list on their day.
            UpNextTileSection()
            RemindersOnTheirDaySection()
        }
        .navigationTitle("Calendars")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// The calendars cards named and those chosen elsewhere (another device, by iCloud) that
    /// aren't this device's.
    private var others: [String] {
        let mine = Set(accounts.flatMap { $0.calendars.map { $0.title.lowercased() } })
        var out: [String] = []
        for name in seen + settings.agendaCalendars where !mine.contains(name.lowercased()) && !out.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            out.append(name)
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func row(_ title: String, color: some ShapeStyle) -> some View {
        Toggle(isOn: Binding(get: { isChosen(title) }, set: { choose(title, $0) })) {
            Label { Text(title) } icon: { Image(systemName: "circle.fill").imageScale(.small).foregroundStyle(color) }
        }
    }

    /// Asking to see this device's calendars, or where to allow it once refused.
    @ViewBuilder private var deviceAccess: some View {
        switch access {
        case .granted:
            EmptyView()
        case .notAsked:
            Section {
                Button("Show Calendars on This Device") {
                    Task {
                        _ = await DeviceCalendar.allowed(.event)
                        await load()
                    }
                }
            } footer: {
                Text("Adds this device's calendars to the list. Only their names are used, to match the calendars your agent reads.")
            }
        case .refused:
            Section {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } footer: {
                Text("To list this device's calendars too, allow Redde full access to Calendars in Settings, under Privacy & Security.")
            }
        }
        if accounts.isEmpty, others.isEmpty {
            Section {
            } footer: {
                Text("Calendars show up here once a calendar card has shown them.")
            }
        }
    }

    private func isChosen(_ title: String) -> Bool {
        settings.agendaCalendars.contains { $0.caseInsensitiveCompare(title) == .orderedSame }
    }

    private func choose(_ title: String, _ on: Bool) {
        var chosen = settings.agendaCalendars.filter { $0.caseInsensitiveCompare(title) != .orderedSame }
        if on { chosen.append(title) }
        settings.agendaCalendars = chosen
    }

    /// This device's calendars, read off the main actor (`CalendarReader`).
    private func load() async {
        access = ComposerContext.calendarAccess
        seen = CalendarChoice.seen
        guard access == .granted else {
            accounts = []
            writable = []
            return
        }
        let read = await CalendarReader.shared.read { store in
            (accounts: Self.deviceAccounts(in: store),
             writable: store.calendars(for: .event).filter(\.allowsContentModifications)
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map(Self.row))
        }
        accounts = read.accounts
        writable = read.writable
    }

    nonisolated private static func row(_ calendar: EKCalendar) -> Row {
        Row(id: calendar.calendarIdentifier, title: calendar.title, color: Color(cgColor: calendar.cgColor))
    }

    /// This device's calendars by account, iCloud and the other accounts first, then the ones on
    /// the device alone, subscriptions and birthdays, as Calendar orders them. Never asks. A
    /// calendar EventKit gives no account is listed under no name rather than left out.
    nonisolated static func deviceAccounts(in store: EKEventStore) -> [Account] {
        func rank(_ type: EKSourceType) -> Int {
            switch type {
            case .calDAV, .exchange, .mobileMe: 0
            case .local: 1
            case .subscribed: 2
            case .birthdays: 3
            @unknown default: 2
            }
        }
        let bySource = Dictionary(grouping: store.calendars(for: .event)) { $0.source?.sourceIdentifier ?? "" }
        return bySource.compactMap { key, calendars -> (rank: Int, account: Account)? in
            guard !calendars.isEmpty else { return nil }
            let source = calendars.first?.source
            let rows = calendars.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(row)
            return (source.map { rank($0.sourceType) } ?? 2, Account(id: key, title: source?.title ?? "", calendars: rows))
        }
        .sorted { ($0.rank, $0.account.title) < ($1.rank, $1.account.title) }
        .map(\.account)
    }
}

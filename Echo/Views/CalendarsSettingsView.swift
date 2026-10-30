import EventKit
import SwiftUI

/// Settings → Agent → Calendars (`CalendarChoice`, asked 2026-10-30: "choose which calendars to
/// look at"): all of them, or only the ones switched on here. Offered are this device's calendars,
/// by account as Calendar lists them, once Redde may see them (a button asks), and the ones calendar
/// cards have named, which are the agent's: its calendars are on the server, matched by title.
struct CalendarsSettingsView: View {
    private let settings = Settings.shared
    /// The switch is off, so the calendars show to choose from, even with none chosen yet.
    @State private var limiting = !Settings.shared.agendaCalendars.isEmpty
    @State private var access = ComposerContext.calendarAccess
    @State private var accounts: [Account] = []
    @State private var seen: [String] = []
    @Environment(\.openURL) private var openURL

    /// One account's calendars ("iCloud", "Gmail"), each by its title and its own colour.
    struct Account: Identifiable {
        var id: String
        var title: String
        var calendars: [(title: String, color: Color)]
    }

    var body: some View {
        Form {
            Section {
                Toggle("All Calendars", isOn: Binding(get: { !limiting }, set: { all in
                    limiting = !all
                    if all { settings.agendaCalendars = [] }
                }))
            } footer: {
                limiting
                    ? Text("Only the calendars switched on here. With none on, all of them.")
                    : Text("Your agent looks at every calendar when you ask what's on, and calendar cards show every event.")
            }
            if limiting {
                ForEach(accounts) { account in
                    Section(account.title) {
                        ForEach(account.calendars, id: \.title) { row($0.title, color: $0.color) }
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
        }
        .navigationTitle("Calendars")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
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
                        load()
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

    private func load() {
        access = ComposerContext.calendarAccess
        accounts = access == .granted ? Self.deviceAccounts() : []
        seen = CalendarChoice.seen
    }

    /// This device's calendars by account, iCloud and the other accounts first, then the ones on
    /// the device alone, subscriptions and birthdays, as Calendar orders them. Never asks.
    private static func deviceAccounts() -> [Account] {
        let store = EKEventStore()
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
        return bySource.values.compactMap { calendars -> (rank: Int, account: Account)? in
            guard let source = calendars.first?.source else { return nil }
            let rows = calendars.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map { (title: $0.title, color: Color(cgColor: $0.cgColor)) }
            return (rank(source.sourceType), Account(id: source.sourceIdentifier, title: source.title, calendars: rows))
        }
        .sorted { ($0.rank, $0.account.title) < ($1.rank, $1.account.title) }
        .map(\.account)
    }
}

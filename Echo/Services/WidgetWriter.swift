#if os(iOS)
import EventKit
import SwiftUI
import UserNotifications
import WidgetKit

/// The app's hand in the Home Screen widgets (revamped 2026-11-24): what they show, written into
/// the app group as it changes (`WidgetFeed`), and what their buttons do, run here the way the
/// same buttons in Redde run (`WidgetActions`). A widget's reloads are counted, so each kind is
/// reloaded only when what it shows changed.
@MainActor
enum WidgetWriter {
    /// At launch, before anything a widget's button started the app for can arrive.
    /// Set by `-echo.demoWidgets`: the made-up day and agents stay as written.
    static var holding = false

    static func start() {
        WidgetActions.run = { await perform($0) }
        NeedsYou.shared?.set(MeasureUnits.temperature, forKey: WidgetWeather.unitsKey)
        // The calendars changed while Redde runs: Up Next's day again.
        if calendarChanges == nil {
            calendarChanges = NotificationCenter.default.addObserver(forName: CalendarReader.changed, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { dayChanged() }
            }
        }
    }

    private static var calendarChanges: NSObjectProtocol?

    /// Redde came forward: taps made while it couldn't take them, and what the widgets show, read again.
    static func cameForward() {
        Task {
            for action in WidgetActions.drain() { await perform(action) }
        }
        NeedsYou.shared?.set(MeasureUnits.temperature, forKey: WidgetWeather.unitsKey)
        dayChanged()
        agentsChanged()
        reload(WidgetKind.day)
    }

    static func reload(_ kind: String) { WidgetCenter.shared.reloadTimelines(ofKind: kind) }

    // MARK: - Buttons

    static func perform(_ action: WidgetAction) async {
        switch action {
        case let .tick(list, item, done):
            let lists = TodayLists.shared
            if lists.lists.isEmpty { lists.restore() }
            guard let kept = lists.lists.first(where: { $0.id == list }), let found = kept.items.first(where: { $0.id == item }) else { return }
            if found.done != done { lists.toggle(found, in: kept) }
            await lists.settle()
        case let .answer(request, choice):
            await answer(request, choice: choice)
        case let .notNow(id):
            if let idea = AgentIdea.all().first(where: { $0.id == id }) { IdeasInbox.shared.remove(idea) }
            reload(WidgetKind.day)
        case let .step(id, index, done):
            if let goal = GoalReport.showing().first(where: { $0.id == id }) { _ = await Goals.tick(goal, step: index, done: done) }
            reload(WidgetKind.goals)
        case let .remind(title, start):
            await remindToLeave(title, start: start)
        }
    }

    /// A choice tapped on Needs You: to the card when this chat still has it, else to the
    /// question the session waits on over the Dashboard, provided it is still that one.
    private static func answer(_ id: String, choice: String) async {
        guard let request = NeedsYou.waiting().first(where: { $0.id == id }) else { return }
        if let conversation = Conversation.current, NeedsYou.key(session: conversation.serverSessionID, conversation: conversation.id) == id,
           let pending = conversation.pendingInterrupt, case let .clarify(asked) = pending.interrupt, asked.questions.count == 1,
           let question = asked.questions.first, request.digest == nil || PushNote.digest(of: question.question) == request.digest {
            BackgroundTurn.shared.begin()
            conversation.respond(clarify: [question.id: choice])
            return
        }
        guard let session = request.session, let digest = request.digest else { return }
        await Notifier.shared.answerPushedQuestion(sessionID: session, digest: digest, answer: choice)?.value
    }

    /// Remind Me in 10: a notification for the event, ten minutes on.
    private static func remindToLeave(_ title: String, start: Date) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time to leave", comment: "A reminder asked for on the Up Next widget, ten minutes on")
        content.body = String(localized: "\(title) at \(start.formatted(date: .omitted, time: .shortened))",
                              comment: "A reminder to leave, asked for on the Up Next widget: the event and when it starts")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: LeaveTime.reminderPrefix + "widget." + PushNote.digest(of: title),
                                            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Up Next's day

    /// The calendar's next day and a half and the leaving times worked out, for Up Next.
    static func dayChanged(now: Date = .now) {
        guard !holding else { return }
        Task {
            let events: [DayAhead.Event]
            if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
                events = await CalendarReader.shared.read { store -> [DayAhead.Event] in
                    let calendars = DeviceCalendar.shared(in: store)
                    guard calendars?.isEmpty != true else { return [] }
                    return store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600),
                                                                           end: now.addingTimeInterval(DayAhead.reach), calendars: calendars))
                        .filter { $0.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined && $0.status != .canceled }
                        .prefix(60)
                        .map { event in
                            DayAhead.Event(id: event.eventIdentifier ?? UUID().uuidString,
                                           title: event.title ?? String(localized: "(untitled)", comment: "A calendar event with no title"),
                                           start: event.startDate, end: event.endDate,
                                           place: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                                           color: event.calendar.flatMap { hex($0.cgColor) }, allDay: event.isAllDay)
                        }
                }
            } else {
                events = []
            }
            let leaves = LeaveBy.worked().values.filter { $0.start > now && !$0.done(at: now) }.map { worked in
                DayAhead.Leave(title: worked.title, start: worked.start, leave: worked.leave, travel: worked.travel, mode: worked.mode,
                               latitude: worked.toLatitude, longitude: worked.toLongitude, place: worked.place.nilIfEmpty)
            }
            if DayAhead(events: events, leaves: leaves.sorted { $0.leave < $1.leave }, written: now).save() { reload(WidgetKind.upNext) }
        }
    }

    nonisolated private static func hex(_ color: CGColor?) -> String? {
        guard let color, let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = rgb.components, c.count >= 3 else { return nil }
        let byte = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c[0]), byte(c[1]), byte(c[2]))
    }

    // MARK: - Your Agents

    private static var pendingAgents: Task<Void, Never>?

    /// The agents' status changed, or a reply came: Your Agents written again a moment later
    /// (status comes in bursts).
    static func agentsChanged() {
        guard !holding else { return }
        pendingAgents?.cancel()
        pendingAgents = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            writeAgents()
        }
    }

    private static func writeAgents(now: Date = .now) {
        let settings = Settings.shared
        let directory = BotDirectory.shared
        let roster = directory.key == settings.connectionKey ? directory.roster : nil
        let open = Conversation.current
        let words = !settings.requireBiometrics
        var agents: [WidgetAgents.Agent] = []

        // The main agent: its chat's state while one is open, else what is waiting on the person.
        let mainName = settings.headerTitle
        var mainStatus: WidgetAgents.Status = .idle
        if let open, open.bot == nil {
            if open.pendingInterrupt != nil { mainStatus = .needsYou } else if open.isStreaming { mainStatus = .working }
        }
        let snapshot = WidgetSnapshot.load()
        let mainLine = snapshot.flatMap { $0.agent == nil ? $0 : nil }
        agents.append(.init(id: ProfileCatalog.defaultID, name: mainName, status: mainStatus,
                            line: words ? mainLine.map { PlainText.display($0.reply) } : nil, at: mainLine?.date,
                            face: face(directory.mainFace, profile: ProfileCatalog.defaultID, name: mainName), isMain: true))

        // Then the bots, as the chat list has them.
        if let open, let roster {
            for bot in roster.bots where !bot.isDefault && !bot.isHidden {
                let kind = ChatActivity.shared.kind(of: bot, open: open, settings: settings)
                let status: WidgetAgents.Status = kind == .needsYou ? .needsYou : kind == .working ? .working : .idle
                let name = bot.label(mainName: mainName)
                agents.append(.init(id: bot.name, name: name, status: status,
                                    line: words ? bot.preview.map(PlainText.display) : nil, at: bot.lastActive,
                                    face: roster.faces[bot.name].flatMap { face($0, profile: bot.name, name: name) }, isMain: false))
                if agents.count >= 8 { break }
            }
        }
        WidgetImages.prune(prefix: "face", keeping: Set(agents.compactMap(\.face)))
        if WidgetAgents(agents: agents, written: now).save() { reload(WidgetKind.agents) }
    }

    /// A face drawn once into the app group, by what it looks like.
    private static func face(_ face: BotFace, profile: String, name: String) -> String? {
        let file = WidgetImages.name(for: profile + "|" + String(describing: face) + "|\(Settings.shared.botFaces)", prefix: "face")
            .replacingOccurrences(of: ".jpg", with: ".png")
        if WidgetImages.has(file) { return file }
        guard let picture = BotAvatar.picture(of: face, named: name, side: 64, scale: 2) else { return nil }
        WidgetImages.write(picture, as: file, side: 64, png: true)
        return file
    }

    // MARK: - Lists

    /// The lists were kept again (`TodayLists`): the widget, and the watch lists' posters for it.
    static func listsChanged(_ lists: [TodayList]) {
        reload(WidgetKind.lists)
        reload(WidgetKind.day)
        let wanted = lists.filter { $0.kind == .watch }.flatMap { $0.items.prefix(12) }.compactMap(\.poster)
        let names = Set(wanted.map { WidgetImages.name(for: $0) })
        WidgetImages.prune(prefix: "poster", keeping: names)
        let missing = wanted.filter { !WidgetImages.has(WidgetImages.name(for: $0)) }
        guard !missing.isEmpty else { return }
        Task {
            for address in missing {
                guard let url = URL(string: address), let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = UIImage(data: data) else { continue }
                WidgetImages.write(image, as: WidgetImages.name(for: address), side: 90)
            }
            reload(WidgetKind.lists)
        }
    }
}
#else
import Foundation

/// The Mac has none of the iPhone's Home Screen widgets.
@MainActor
enum WidgetWriter {
    static func start() {}
    static func cameForward() {}
    static func reload(_ kind: String) {}
    static func dayChanged(now: Date = .now) {}
    static func agentsChanged() {}
    static func listsChanged(_ lists: [TodayList]) {}
}
#endif

import SwiftUI

/// What the agent set to come back (`ReplyCard.reminder`, asked 2026-10-30: "remind me to…", "set a
/// timer for 20 minutes", "every Monday, tell me…"): what, when (how long from now, and the time),
/// how it repeats, and where it lives; a timer counts down, drawn each second only where it counts.
/// A set one says so, with where it lives; Change… and Cancel sit in its ⋯ menu (2026-11-10: two
/// large buttons, always there, were easy to press by mistake, and nothing said it was set). They
/// ask the agent with a message, and it changes or cancels it with the tool it set it with; the
/// card then says what was asked. A timer restarts at its length, or takes a new one; the others
/// take a new time from a picker (2026-11-10, asked), sent to the agent as the exact time.
struct ReminderCard: View {
    let card: ReplyCard.Reminder
    let whole: ReplyCard
    @State private var answers = CardAnswers.shared
    @State private var editing: Editing?
    @State private var change = ""
    @State private var newTime = Date.now
    @State private var newMinutes = 10
    @FocusState private var focused: Bool
    @Environment(\.answerCard) private var answerer
    @Environment(\.pinnedCard) private var pinned
    @Environment(\.theme) private var theme

    private var answered: String? { answers.said[whole.key] }

    /// What the card is open for: a time from the picker, a timer's length, or a change in words.
    enum Editing { case time, length, words }

    /// Its length in whole minutes, where a timer has one.
    private var minutes: Int? { card.kind == .timer ? card.duration.flatMap { Self.minutes($0) } : nil }

    var body: some View {
        CardBox(spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: Self.symbol(card.kind))
                    .chatFont(.title3, weight: .semibold)
                    .foregroundStyle(theme.accent)
                    .frame(width: 44, height: 44)
                    .background(theme.accent.opacity(0.14), in: .rect(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.kindName(card.kind)).textCase(.uppercase).tracking(0.4)
                        .chatFont(.caption2, weight: .bold).foregroundStyle(theme.accent)
                    Text(card.title).chatFont(.headline).fixedSize(horizontal: false, vertical: true)
                    if let at = card.at {
                        TimelineView(.everyMinute) { context in
                            Text(verbatim: Self.when(at, now: context.date)).chatFont(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } else if let when = card.when {
                        Text(when).chatFont(.subheadline).foregroundStyle(.secondary)
                    }
                    if let repeats = card.repeats {
                        Label(repeats, systemImage: "repeat").chatFont(.footnote).foregroundStyle(.secondary).padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if card.kind == .timer, let at = card.at { countdown(to: at) }
            if let answered {
                place
                AnsweredLine(text: answered.contains("tapped Cancel") ? String(localized: "Asked to cancel", comment: "Under a reminder card once Cancel was tapped")
                             : answered.contains("tapped Restart") ? String(localized: "Asked to restart it", comment: "Under a timer card once Restart was tapped")
                             : String(localized: "Asked to change it", comment: "Under a reminder card once a change was sent"))
            } else if !card.isSet {
                place
                // Nothing behind it: say so, and offer to set it for real (2026-11-03).
                Label(String(localized: "Nothing was set: this is only a card", comment: "Under a reminder card that no tool set"),
                      systemImage: "exclamationmark.triangle.fill")
                    .chatFont(.footnote, weight: .semibold).foregroundStyle(.orange)
                if let answerer, !pinned {
                    Button { setIt(answerer) } label: { TintedCapsule(title: String(localized: "Set It", comment: "A reminder card's button when nothing was set: asks the agent to set it for real")) }
                        .buttonStyle(.plain)
                        .disabled(answerer.busy)
                        .accessibilityHint(Text("Asks your agent to set it for real", comment: "VoiceOver hint: a reminder card's Set It"))
                }
            } else if let editing, let answerer, !pinned {
                place
                switch editing {
                case .words: changeField(answerer)
                case .time: timeField(answerer)
                case .length: lengthField(answerer)
                }
            } else {
                setLine
            }
        }
    }

    /// Where it lives, as the agent said.
    @ViewBuilder private var place: some View {
        if let place = card.place {
            Label(place, systemImage: Self.placeSymbol(place))
                .chatFont(.caption).foregroundStyle(.secondary)
        }
    }

    /// "✓ Set · Reminders", and the menu to change or cancel it.
    private var setLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            Text(String(localized: "reminder.set", defaultValue: "Set", comment: "Under a reminder, timer or alarm card: it was set"))
                .chatFont(.caption, weight: .semibold)
            if let place = card.place {
                Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                Label(place, systemImage: Self.placeSymbol(place)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let answerer, !pinned { menu(answerer) }
        }
        .chatFont(.caption)
    }

    /// The time left, large, and a ring of it where the timer's length is known: redrawn each
    /// second here alone, until it is over and then no more (a finished timer's card went on
    /// being redrawn every second for as long as it was on screen).
    private func countdown(to end: Date) -> some View {
        TimelineView(.explicit(sequence(first: Date.now) { $0 < end ? min($0.addingTimeInterval(1), end) : nil })) { context in
            let left = max(0, end.timeIntervalSince(context.date))
            HStack(spacing: 14) {
                if let duration = card.duration, duration > 0 {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.1), lineWidth: 5)
                        Circle().trim(from: 0, to: left / duration)
                            .stroke(theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: left > 0 ? Self.clock(left) : String(localized: "task.done", defaultValue: "Done", comment: "A task, finished (not the Done button): a ticked checklist item, the agent's finished task, the Kanban column, the title after a plugin change"))
                        .chatFont(size: 40, weight: .semibold).monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text(left > 0 ? String(localized: "Ends at \(end.formatted(date: .omitted, time: .shortened))", comment: "Under a timer card's countdown, e.g. Ends at 3:45 PM")
                         : String(localized: "Ended at \(end.formatted(date: .omitted, time: .shortened))", comment: "Under a timer card's countdown once it is over"))
                        .chatFont(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if left <= 0, answered == nil, editing == nil, let minutes, let answerer, !pinned {
                    Button { restart(answerer, minutes) } label: {
                        Label(String(localized: "timer.restart", defaultValue: "Restart", comment: "A timer card's button and menu item: start the timer again at its full length"), systemImage: "arrow.counterclockwise").chatFont(.subheadline, weight: .semibold)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(theme.accent)
                    .disabled(answerer.busy)
                    .accessibilityHint(Text("Starts the timer again at its full length", comment: "VoiceOver hint: a timer card's Restart"))
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14))
            .accessibilityElement(children: .combine)
        }
    }

    private func menu(_ answerer: CardAnswerer) -> some View {
        Menu {
            if let minutes {
                Button { restart(answerer, minutes) } label: { Label(String(localized: "timer.restart", defaultValue: "Restart", comment: "A timer card's button and menu item: start the timer again at its full length"), systemImage: "arrow.counterclockwise") }
                    .accessibilityHint(Text("Starts the timer again at its full length", comment: "VoiceOver hint: a timer card's Restart"))
            }
            if card.kind == .timer {
                Button { newMinutes = minutes ?? 10; editing = .length } label: {
                    Label(String(localized: "Change Length…", comment: "A timer card's menu: pick how long it runs"), systemImage: "timer")
                }
            } else {
                Button { newTime = Self.startingTime(card); editing = .time } label: {
                    Label(String(localized: "Change Time…", comment: "A reminder, alarm or scheduled message card's menu: pick a new time"), systemImage: "clock")
                }
            }
            Button { editing = .words; focused = true } label: {
                Label(String(localized: "Other Change…", comment: "A reminder card's menu: tell the agent in words what to change"), systemImage: "pencil")
            }
            .accessibilityHint(Text("Lets you say what to change", comment: "VoiceOver hint: a reminder card's Change"))
            Button(role: .destructive) { cancel(answerer) } label: {
                Label(String(localized: "Cancel", comment: "A reminder card's button: asks the agent to cancel it"), systemImage: "xmark")
            }
            .accessibilityHint(Text("Asks your agent to cancel it", comment: "VoiceOver hint: a reminder card's Cancel"))
        } label: {
            Image(systemName: "ellipsis.circle").chatFont(.title3).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .disabled(answerer.busy)
        .padding(.vertical, -10)   // its 44-point target, without making the line that tall
        .accessibilityLabel("More for \(card.title)")
    }

    private func changeField(_ answerer: CardAnswerer) -> some View {
        HStack(spacing: 8) {
            TextField(String(localized: "What should change? e.g. 4 PM instead", comment: "A reminder card's field for a change"), text: $change)
                .textFieldStyle(.plain)
                .focused($focused)
                .chatFont(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.primary.opacity(0.06), in: .capsule)
                .onSubmit { send(answerer) }
            closeButton
            sendButton(disabled: change.trimmingCharacters(in: .whitespaces).isEmpty || answerer.busy) { send(answerer) }
        }
    }

    /// A new time: a day and a time, or a time of day where it repeats.
    private func timeField(_ answerer: CardAnswerer) -> some View {
        HStack(spacing: 8) {
            if card.repeats != nil || card.at == nil && card.when != nil {
                DatePicker(String(localized: "New time", comment: "VoiceOver: a reminder card's time picker"), selection: $newTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            } else {
                DatePicker(String(localized: "New time", comment: "VoiceOver: a reminder card's time picker"), selection: $newTime, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
            Spacer(minLength: 0)
            closeButton
            sendButton(disabled: answerer.busy) { sendTime(answerer) }
        }
    }

    /// A timer's new length, from a minute to a day, by the minute and then by five.
    private func lengthField(_ answerer: CardAnswerer) -> some View {
        HStack(spacing: 8) {
            Stepper(value: Binding(get: { newMinutes }, set: { newMinutes = Self.stepped(from: newMinutes, to: $0) }), in: 1 ... Self.longestMinutes) {
                Text(verbatim: Self.length(TimeInterval(newMinutes * 60))).chatFont(.headline).monospacedDigit()
                    .contentTransition(.numericText())
            }
            .accessibilityLabel(Text("Timer length", comment: "VoiceOver: a timer card's length stepper"))
            closeButton
            sendButton(disabled: answerer.busy) { sendLength(answerer) }
        }
    }

    private var closeButton: some View {
        Button { editing = nil } label: {
            Image(systemName: "xmark").chatFont(.subheadline, weight: .semibold).foregroundStyle(.secondary)
                .frame(width: 36, height: 36).background(Color.primary.opacity(0.06), in: .circle)
                .frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Don't Change", comment: "VoiceOver: closes a reminder card's change without sending"))
    }

    private func sendButton(disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up").chatFont(.subheadline, weight: .bold).foregroundStyle(theme.userText)
                .frame(width: 36, height: 36).background(theme.accent, in: .circle)
                .frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(Text("Send", comment: "VoiceOver: a reminder card's send button for a change"))
    }

    private func sendTime(_ answerer: CardAnswerer) {
        let message = Self.move(card, to: newTime)
        editing = nil
        answerer.answer(whole, message.shown, message.said)
    }

    private func sendLength(_ answerer: CardAnswerer) {
        let message = Self.lengthen(card, minutes: newMinutes)
        editing = nil
        answerer.answer(whole, message.shown, message.said)
    }

    private func restart(_ answerer: CardAnswerer, _ minutes: Int) {
        let message = Self.restart(card, minutes: minutes)
        answerer.answer(whole, message.shown, message.said)
    }

    private func send(_ answerer: CardAnswerer) {
        let said = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        let message = Self.change(card, said)
        editing = nil
        answerer.answer(whole, message.shown, message.said)
    }

    private func setIt(_ answerer: CardAnswerer) {
        let message = Self.setForReal(card)
        answerer.answer(whole, message.shown, message.said)
    }

    private func cancel(_ answerer: CardAnswerer) {
        let message = Self.cancel(card)
        answerer.answer(whole, message.shown, message.said)
    }

    // MARK: Words

    /// "Set the reminder “Call dentist” for 3:30 PM for real.": a card no tool set.
    static func setForReal(_ card: ReplyCard.Reminder, now: Date = .now) -> (shown: String, said: String) {
        let time = card.at.map { Calendar.current.isDate($0, inSameDayAs: now) ? $0.formatted(date: .omitted, time: .shortened)
                                                                               : $0.formatted(date: .abbreviated, time: .shortened) } ?? card.when ?? ""
        let shown = time.isEmpty ? String(localized: "Set the reminder “\(card.title)” for real.", comment: "The message a reminder card's Set It sends, with no time")
                                 : String(localized: "Set the reminder “\(card.title)” for \(time) for real.", comment: "The message a reminder card's Set It sends, with its time")
        // A reminder in Apple Reminders on the phone first (2026-11-09: "I'm getting Redde cron jobs
        // instead of reminders in iPhone"); an alarm or a timer the phone's alarm tool; a message at
        // a time a job on the Hermes.
        let how = switch card.kind {
        case .reminder: "with phone_reminders_add (Apple Reminders on their iPhone), or a reminders tool of your own that writes to Apple Reminders; "
            + "only with neither, your cron tool (a job named '[redde-notify] \(card.title)', one run)"
        case .timer, .alarm: "with phone_alarms_set (on their iPhone)"
        case .schedule: "with your cron tool (one job, at that time)"
        }
        return (shown, "the reminder card for \(card.kind.rawValue) \(named(card)) was only a card: nothing was set. Set it now \(how), "
                + "then show a fresh 'reminder' card with its id; if that time has passed, ask")
    }

    static func cancel(_ card: ReplyCard.Reminder) -> (shown: String, said: String) {
        let shown = switch card.kind {
        case .reminder: String(localized: "Cancel the reminder “\(card.title)”", comment: "The message a reminder card's Cancel sends")
        case .timer: String(localized: "Cancel the timer “\(card.title)”", comment: "The message a timer card's Cancel sends")
        case .alarm: String(localized: "Cancel the alarm “\(card.title)”", comment: "The message an alarm card's Cancel sends")
        case .schedule: String(localized: "Cancel the scheduled message “\(card.title)”", comment: "The message a scheduled message card's Cancel sends")
        }
        return (shown, "the user tapped Cancel on the reminder card: cancel the \(card.kind.rawValue) \(named(card)) with the tool you set it with, then say in a line that it's cancelled")
    }

    static func change(_ card: ReplyCard.Reminder, _ said: String) -> (shown: String, said: String) {
        let shown = switch card.kind {
        case .reminder: String(localized: "Change the reminder “\(card.title)”: \(said)", comment: "The message a reminder card's Change sends, with what to change")
        case .timer: String(localized: "Change the timer “\(card.title)”: \(said)", comment: "The message a timer card's Change sends, with what to change")
        case .alarm: String(localized: "Change the alarm “\(card.title)”: \(said)", comment: "The message an alarm card's Change sends, with what to change")
        case .schedule: String(localized: "Change the scheduled message “\(card.title)”: \(said)", comment: "The message a scheduled message card's Change sends, with what to change")
        }
        return (shown, "the user tapped Change on the reminder card for the \(card.kind.rawValue) \(named(card)) and wrote: \(said). Change it with the tool you set it with "
                    + "(or cancel it and set it again), then show a fresh 'reminder' card")
    }

    /// "Restart the timer “Pasta” (20 min)": again at its length, from now.
    static func restart(_ card: ReplyCard.Reminder, minutes: Int) -> (shown: String, said: String) {
        let length = length(TimeInterval(minutes * 60))
        return (String(localized: "Restart the timer “\(card.title)” (\(length))", comment: "The message a timer card's Restart sends, with its length, e.g. 20 min"),
                "the user tapped Restart on the reminder card for the timer \(named(card)): cancel it if it is still running, then set it again "
                + "for \(minutes) minutes from now, with the same title, with the tool you set it with (phone_alarms_set for one on their iPhone), then show a fresh 'reminder' card with its id")
    }

    /// "Change the timer “Pasta” to 25 min": a new length, from now.
    static func lengthen(_ card: ReplyCard.Reminder, minutes: Int) -> (shown: String, said: String) {
        let length = length(TimeInterval(minutes * 60))
        return (String(localized: "Change the timer “\(card.title)” to \(length)", comment: "The message a timer card's Change Length sends, e.g. to 25 min"),
                "the user tapped Change Time on the reminder card for the timer \(named(card)) and picked a new length: cancel it if it is still running, then set it again "
                + "for \(minutes) minutes from now, with the same title, with the tool you set it with (phone_alarms_set for one on their iPhone), then show a fresh 'reminder' card with its id")
    }

    /// "Move the reminder “Call dentist” to 4:00 PM": a time from the picker, exactly; a time of
    /// day where it repeats.
    static func move(_ card: ReplyCard.Reminder, to time: Date, now: Date = .now) -> (shown: String, said: String) {
        let daily = card.repeats != nil || card.at == nil && card.when != nil
        let words = daily || Calendar.current.isDate(time, inSameDayAs: now) ? time.formatted(date: .omitted, time: .shortened)
                                                                              : time.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        let shown = switch card.kind {
        case .reminder, .timer: String(localized: "Move the reminder “\(card.title)” to \(words)", comment: "The message a reminder card's Change Time sends, e.g. to 4:00 PM")
        case .alarm: String(localized: "Move the alarm “\(card.title)” to \(words)", comment: "The message an alarm card's Change Time sends, e.g. to 6:30 AM")
        case .schedule: String(localized: "Move the scheduled message “\(card.title)” to \(words)", comment: "The message a scheduled message card's Change Time sends")
        }
        let exact = daily ? "the time of day \(Self.clockTime(time)), for every time it repeats"
                          : ISO8601DateFormatter.string(from: time, timeZone: .current, formatOptions: [.withInternetDateTime])
        return (shown, "the user tapped Change Time on the reminder card for the \(card.kind.rawValue) \(named(card)) and picked a new time: \(exact). "
                + "Move it there with the tool you set it with (or cancel it and set it again), keeping its title and how it repeats, then show a fresh 'reminder' card with its id")
    }

    /// Where the picker starts: its own time while that is ahead, else an hour from now, on the hour.
    static func startingTime(_ card: ReplyCard.Reminder, now: Date = .now, calendar: Calendar = .current) -> Date {
        if let at = card.at, at > now || card.repeats != nil { return at }
        let hour = now.addingTimeInterval(3600)
        return calendar.dateInterval(of: .hour, for: hour)?.start ?? hour
    }

    /// "16:00": a time of day, for the agent.
    static func clockTime(_ time: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The longest timer, a day, as the phone's alarms tool takes (`DeviceAlarms.longestTimer`,
    /// which the Mac doesn't build).
    static let longestMinutes = 24 * 60

    /// Whole minutes, at least one.
    static func minutes(_ seconds: TimeInterval) -> Int? {
        seconds > 0 ? (seconds / 60).nearestInt(in: 1 ... longestMinutes) : nil
    }

    /// The stepper's next value: by the minute up to 10, by five past that.
    static func stepped(from old: Int, to new: Int) -> Int {
        let up = new > old
        if old < 10 || (old == 10 && !up) { return new }
        let next = up ? (old / 5 + 1) * 5 : (old - 1) / 5 * 5
        return min(max(next, 1), Self.longestMinutes)
    }

    /// "20 min", "1 hr, 30 min".
    static func length(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private static func named(_ card: ReplyCard.Reminder) -> String {
        "\"\(card.title)\"" + (card.id.map { " (id \($0))" } ?? "")
            + (card.at.map { " at \(ISO8601DateFormatter.string(from: $0, timeZone: .current, formatOptions: [.withInternetDateTime]))" } ?? "")
    }

    /// "in 20 min · 3:45 PM" (today, or within six hours), "Tomorrow, 9:00 AM · in 18 hr", "20 min ago · 3:45 PM".
    static func when(_ at: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = at.formatted(date: .omitted, time: .shortened)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = calendar.locale ?? .current
        formatter.calendar = calendar
        let relative = formatter.localizedString(for: at, relativeTo: now)
        // Today, or within a few hours (a timer past midnight): how long first.
        if calendar.isDate(at, inSameDayAs: now) || abs(at.timeIntervalSince(now)) < 6 * 3600 { return relative + " · " + time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(at, inSameDayAs: tomorrow) {
            return String(localized: "Tomorrow, \(time)", comment: "When a reminder goes off, tomorrow at a time") + " · " + relative
        }
        let day = abs(at.timeIntervalSince(now)) < 6 * 86_400 ? at.formatted(.dateTime.weekday(.wide)) : at.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return day + ", " + time
    }

    /// "19:42", "1:05:00".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = seconds.rounded(.up).nearestInt(in: 0 ... Int(ReplyCards.longestSpan)) ?? 0
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func symbol(_ kind: ReplyCard.Reminder.Kind) -> String {
        switch kind {
        case .reminder: "bell"
        case .timer: "timer"
        case .alarm: "alarm"
        case .schedule: "clock.arrow.circlepath"
        }
    }

    static func kindName(_ kind: ReplyCard.Reminder.Kind) -> String {
        switch kind {
        case .reminder: String(localized: "Reminder", comment: "A reminder card's kind")
        case .timer: String(localized: "Timer", comment: "A reminder card's kind")
        case .alarm: String(localized: "Alarm", comment: "A reminder card's kind")
        case .schedule: String(localized: "Scheduled message", comment: "A reminder card's kind: a message the agent sends at a time")
        }
    }

    /// Where it lives, as the agent said ("Reminders", "Hermes", "an alarm on this iPhone"), by its mark.
    static func placeSymbol(_ place: String) -> String {
        let said = place.lowercased()
        if said.contains("reminders") { return "checklist" }
        if said.contains("iphone") || said.contains("phone") || said.contains("alarm") { return "iphone" }
        if said.contains("calendar") { return "calendar" }
        return "server.rack"
    }
}

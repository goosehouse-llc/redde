import SwiftUI

/// What the agent set to come back (`ReplyCard.reminder`, asked 2026-10-30: "remind me to…", "set a
/// timer for 20 minutes", "every Monday, tell me…"): what, when (how long from now, and the time),
/// how it repeats, and where it lives; a timer counts down, drawn each second only where it counts.
/// Change… and Cancel ask the agent with a message, and it changes or cancels it with the tool it
/// set it with; the card then says what was asked.
struct ReminderCard: View {
    let card: ReplyCard.Reminder
    let whole: ReplyCard
    @State private var answers = CardAnswers.shared
    @State private var changing = false
    @State private var change = ""
    @FocusState private var focused: Bool
    @Environment(\.answerCard) private var answerer
    @Environment(\.pinnedCard) private var pinned
    @Environment(\.theme) private var theme

    private var answered: String? { answers.said[whole.key] }

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
            if let place = card.place {
                Label(place, systemImage: Self.placeSymbol(place))
                    .chatFont(.caption).foregroundStyle(.secondary)
            }
            if let answered {
                AnsweredLine(text: answered.contains("tapped Cancel") ? String(localized: "Asked to cancel", comment: "Under a reminder card once Cancel was tapped")
                             : String(localized: "Asked to change it", comment: "Under a reminder card once a change was sent"))
            } else if let answerer, !pinned {
                if changing { changeField(answerer) } else { buttons(answerer) }
            }
        }
    }

    /// The time left, large, and a ring of it where the timer's length is known: redrawn each
    /// second here alone.
    private func countdown(to end: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
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
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14))
            .accessibilityElement(children: .combine)
        }
    }

    private func buttons(_ answerer: CardAnswerer) -> some View {
        HStack(spacing: 10) {
            Button { changing = true; focused = true } label: { TintedCapsule(title: String(localized: "Change…", comment: "A reminder card's button: tell the agent what to change")) }
                .accessibilityHint(Text("Lets you say what to change", comment: "VoiceOver hint: a reminder card's Change"))
            Button { cancel(answerer) } label: { TintedCapsule(title: String(localized: "Cancel", comment: "A reminder card's button: asks the agent to cancel it"), role: .destructive) }
                .accessibilityHint(Text("Asks your agent to cancel it", comment: "VoiceOver hint: a reminder card's Cancel"))
        }
        .buttonStyle(.plain)
        .disabled(answerer.busy)
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
            Button { send(answerer) } label: {
                Image(systemName: "arrow.up").chatFont(.subheadline, weight: .bold).foregroundStyle(theme.userText)
                    .frame(width: 36, height: 36).background(theme.accent, in: .circle)
                    .frame(width: 44, height: 44).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(change.trimmingCharacters(in: .whitespaces).isEmpty || answerer.busy)
            .accessibilityLabel(Text("Send", comment: "VoiceOver: a reminder card's send button for a change"))
        }
    }

    private func send(_ answerer: CardAnswerer) {
        let said = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        let message = Self.change(card, said)
        changing = false
        answerer.answer(whole, message.shown, message.said)
    }

    private func cancel(_ answerer: CardAnswerer) {
        let message = Self.cancel(card)
        answerer.answer(whole, message.shown, message.said)
    }

    // MARK: Words

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
        let s = Int(seconds.rounded(.up))
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

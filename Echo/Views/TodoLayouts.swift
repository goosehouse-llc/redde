import SwiftUI

/// The pieces of a to-do list's other layouts (2026-11-25, "build the todo list mockups too"),
/// picked in its Change Look (`Settings.TodoLayout`): Next Up, Agent Can Help, Week and Notepad.
/// By When, the default, is `TodayListView`'s own. Each row keeps the list's long press and swipe
/// (`ListItemActions`), applied where these are put on the page.

/// A colour to fill a card with and the words that read on it: the list's colour with near-black
/// words when it's light, else that colour deepened under white ones.
struct FilledCard {
    let fill: Color
    let ink: Color

    init(_ mark: Color, in environment: EnvironmentValues) {
        if GoalCard.luminance(of: mark, in: environment) > 0.4 {
            fill = mark
            ink = Color(red: 0.03, green: 0.07, blue: 0.05)
        } else {
            fill = CardInk.readable(mark, drawnIn: .light)
            ink = .white
        }
    }
}

// MARK: Next Up

/// The next thing to do, large, in the list's colour: Mark Done, or Later (tomorrow, or a day picked).
struct NextUpCard: View {
    let item: TodayList.Item
    let mark: Color
    let done: () -> Void
    let tomorrow: () -> Void
    let pick: () -> Void
    @Environment(\.self) private var environment

    var body: some View {
        let card = FilledCard(mark, in: environment)
        VStack(alignment: .leading, spacing: 0) {
            Text("Next Up", comment: "A to-do list's layout: the next thing to do large, the rest after it")
                .textCase(.uppercase)
                .chatFont(.caption, weight: .heavy)
                .tracking(1)
            Text(item.text)
                .chatFont(.title, weight: .heavy)
                .lineLimit(4)
                .padding(.top, 8)
            if let plan = item.plan {
                Text(verbatim: plan)
                    .chatFont(.callout, weight: .semibold)
                    .padding(.top, 5)
            }
            HStack(spacing: 10) {
                Button(action: done) {
                    Text("Mark Done")
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(card.fill)
                        .background(card.ink, in: .rect(cornerRadius: 15))
                        .contentShape(.rect(cornerRadius: 15))
                }
                .accessibilityIdentifier("next-up-done")
                Menu {
                    Button(action: tomorrow) {
                        Label { Text("Tomorrow", comment: "An agenda card's day") } icon: { Image(systemName: "sunrise") }
                    }
                    Button(action: pick) {
                        Label { Text("Pick a Date…", comment: "Next Up: Later's menu, choose another day and time") } icon: { Image(systemName: "calendar") }
                    }
                } label: {
                    Text("Later")
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(card.ink, lineWidth: 2) }
                        .contentShape(.rect(cornerRadius: 15))
                }
                .accessibilityIdentifier("next-up-later")
            }
            .buttonStyle(.plain)
            .chatFont(.body, weight: .bold)
            .padding(.top, 18)
        }
        .foregroundStyle(card.ink)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card.fill, in: .rect(cornerRadius: 24))
    }
}

// MARK: Agent Can Help

/// A to-do the agent can do part of: its words, its day, the tick, and what the agent would do,
/// a tap away.
struct HelpCard: View {
    let item: TodayList.Item
    let mark: Color
    let toggle: () -> Void
    /// Nil where the agent can't be asked from here.
    let ask: (() -> Void)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = CardInk.readable(mark, drawnIn: scheme)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.text)
                        .chatFont(.body, weight: .bold)
                    if let plan = item.plan {
                        Text(verbatim: plan)
                            .chatFont(.footnote, weight: .semibold)
                            .foregroundStyle(ink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: toggle) {
                    ListTick(on: item.done, mark: mark)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Mark Done"))
            }
            if let help = item.help {
                Button { ask?() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "bolt.fill")
                            .accessibilityHidden(true)
                        Text(verbatim: help)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                    .chatFont(.subheadline, weight: .semibold)
                    .foregroundStyle(ink)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(minHeight: 46)
                    .background(mark.opacity(scheme == .dark ? 0.22 : 0.14), in: .rect(cornerRadius: 13))
                    .contentShape(.rect(cornerRadius: 13))
                }
                .buttonStyle(.plain)
                .disabled(ask == nil)
                .accessibilityHint(Text("Asks your agent to do it", comment: "VoiceOver hint: a to-do's help line on the Agent Can Help layout"))
                .accessibilityIdentifier("help-\(item.id)")
            }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }
}

// MARK: Week

/// This week's days, today filled in the list's colour, a dot under each day with something on
/// it. A tap shows only that day; again, every day.
struct TodoWeekStrip: View {
    let days: [Date]
    let busy: Set<Date>
    @Binding var picked: Date?
    let mark: Color
    @Environment(\.self) private var environment
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let card = FilledCard(mark, in: environment)
        HStack(spacing: 5) {
            ForEach(days, id: \.self) { day in
                let today = Calendar.current.isDateInToday(day), chosen = picked == day, has = busy.contains(day)
                Button { picked = chosen ? nil : day } label: {
                    VStack(spacing: 2) {
                        Text(day, format: .dateTime.weekday(.abbreviated))
                            .textCase(.uppercase)
                            .chatFont(.caption2, weight: .bold)
                            .foregroundStyle(today ? AnyShapeStyle(card.ink) : AnyShapeStyle(.secondary))
                        Text(day, format: .dateTime.day())
                            .chatFont(.title3, weight: .heavy)
                            .foregroundStyle(today ? card.ink : .primary)
                        Circle()
                            .fill(has ? (today ? card.ink : CardInk.readable(mark, drawnIn: scheme)) : .clear)
                            .frame(width: 6, height: 6)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 74)
                    .background(today ? card.fill : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                    .overlay {
                        if chosen { RoundedRectangle(cornerRadius: 14).strokeBorder(CardInk.readable(mark, drawnIn: scheme), lineWidth: 2.5) }
                    }
                    .contentShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(day, format: .dateTime.weekday(.wide).month(.wide).day()))
                .accessibilityValue(has ? Text("Has to-dos", comment: "VoiceOver: a day on a to-do list's week strip with something on it") : Text(verbatim: ""))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }
}

/// A dated to-do on the week's timeline: a node on the line, its day and time over it, and the
/// to-do on a card with its tick.
struct TimelineRow: View {
    let item: TodayList.Item
    let mark: Color
    let first: Bool
    let last: Bool
    let toggle: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var overdue: Bool { (item.when ?? .now) < Calendar.current.startOfDay(for: .now) }

    var body: some View {
        let ink = overdue ? CardInk.readable(.orange, drawnIn: scheme) : CardInk.readable(mark, drawnIn: scheme)
        let today = item.when.map(Calendar.current.isDateInToday) ?? false
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 2)
                    .padding(.top, first ? 8 : 0)
                    .padding(.bottom, last ? 30 : 0)
                Circle()
                    .strokeBorder(ink, lineWidth: 2)
                    .background(Circle().fill(today ? ink : Color(.systemGroupedBackground)))
                    .frame(width: 12, height: 12)
                    .padding(.top, 4)
            }
            .frame(width: 14)
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let when = item.when {
                    Text(when, format: .dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
                        .chatFont(.footnote, weight: .bold)
                        .foregroundStyle(ink)
                }
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.text)
                                .chatFont(.body, weight: .semibold)
                            if let company = item.company, !company.isEmpty {
                                Text("with \(company)", comment: "A list item's plan: who it's with, after its date (\"Thu, Nov 26, 7:30 PM · with Robin\")")
                                    .chatFont(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ListTick(on: item.done, mark: mark)
                            .frame(width: 44, height: 44)
                    }
                    .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 4)
                    .frame(minHeight: 58)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 15))
                    .contentShape(.rect(cornerRadius: 15))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 12)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A to-do with no day yet, on the week's page: a dashed card. A tap gives it a day; its tick
/// checks it off.
struct LooseCard: View {
    let item: TodayList.Item
    let mark: Color
    let plan: () -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button(action: plan) {
                Text(item.text)
                    .chatFont(.subheadline, weight: .semibold)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 11).padding(.vertical, 9)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Gives it a day", comment: "VoiceOver hint: a to-do with no day on the Week layout"))
            Button(action: toggle) {
                ListTick(on: item.done, mark: mark)
                    .frame(width: 40, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Mark Done"))
        }
        .frame(minHeight: 78)
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
    }
}

// MARK: Notepad

/// A yellow legal pad: the same paper in light and dark, navy ink, blue rules and a red margin.
enum PadPaper {
    static let paper = Color(red: 0xFB / 255, green: 0xF0 / 255, blue: 0xA8 / 255)
    static let ink = Color(red: 0x1B / 255, green: 0x23 / 255, blue: 0x47 / 255)
    static let faded = Color(red: 0x45 / 255, green: 0x4B / 255, blue: 0x6A / 255)
    static let rule = Color(red: 0xBF / 255, green: 0xD0 / 255, blue: 0xDE / 255)
    static let margin = Color(red: 0xE5 / 255, green: 0x8B / 255, blue: 0x83 / 255)
    static let binding = Color(red: 0x7A / 255, green: 0x2F / 255, blue: 0x2B / 255)
    static let red = Color(red: 0x8F / 255, green: 0x21 / 255, blue: 0x1C / 255)
    static let tick = Color(red: 0x1F / 255, green: 0x7A / 255, blue: 0x3A / 255)
    /// Where the margin runs, from the paper's leading edge.
    static let marginX: CGFloat = 46

    /// Handwriting: the system's Noteworthy, scaled with the text size.
    static func hand(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(bold ? "Noteworthy-Bold" : "Noteworthy-Light", size: size, relativeTo: style)
    }
}

/// A row's paper: yellow with the red margin down it.
struct PadRowBackground: View {
    var body: some View {
        PadPaper.paper
            .overlay(alignment: .leading) {
                PadPaper.margin.frame(width: 2).padding(.leading, PadPaper.marginX)
            }
    }
}

/// The pad's top: its red binding, punched.
struct PadBinding: View {
    var body: some View {
        HStack {
            ForEach(0 ..< 9, id: \.self) { _ in
                Circle().fill(Color.black.opacity(0.78)).frame(width: 10, height: 10)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(PadPaper.binding)
        .accessibilityHidden(true)
    }
}

/// A to-do written on the pad: a hand-drawn box (ticked once it's done, the words crossed out) and
/// its day ringed in red.
struct PadRow: View {
    let item: TodayList.Item

    /// "2:00 PM" today, "Fri" this week, "Dec 7" further off.
    private var mark: String? {
        guard !item.done, let when = item.when else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(when) { return when.formatted(.dateTime.hour().minute()) }
        let week = calendar.dateInterval(of: .weekOfYear, for: .now)
        if let week, week.contains(when) { return when.formatted(.dateTime.weekday(.abbreviated)) }
        return when.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(item.done ? PadPaper.faded : PadPaper.ink, lineWidth: 2.5)
                    .frame(width: 21, height: 21)
                    .rotationEffect(.degrees(-3))
                if item.done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(PadPaper.tick)
                        .offset(x: 3, y: -3)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: PadPaper.marginX, height: 44)
            .accessibilityHidden(true)
            Text(item.text)
                .font(PadPaper.hand(item.done ? 19 : 21))
                .foregroundStyle(item.done ? PadPaper.faded : PadPaper.ink)
                .strikethrough(item.done, color: PadPaper.faded)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
            if let mark {
                Text(verbatim: mark)
                    .font(PadPaper.hand(15, bold: true, relativeTo: .footnote))
                    .foregroundStyle(PadPaper.red)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(PadPaper.red, lineWidth: 2) }
                    .rotationEffect(.degrees(-3))
                    .padding(.leading, 6)
            }
        }
        .padding(.trailing, 8)
        .frame(minHeight: item.done ? 48 : 54)
        .animation(.snappy(duration: 0.2), value: item.done)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [item.text, item.plan].compactMap { $0 }.joined(separator: ", ")))
    }
}

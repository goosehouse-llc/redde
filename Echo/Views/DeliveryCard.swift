import SwiftUI

/// A package on its way (`ReplyCard.delivery`, asked 2026-10-31): what's in it and who brings it,
/// when it should come ("Arrives Thursday") or when it came, a track from ordered to delivered,
/// the last scan, the tracking number to copy, and the carrier's page. It shows what the agent
/// looked up and never checks again by itself: Refresh asks the agent. A carrier's page is opened
/// in the browser; Redde never talks to a carrier.
struct DeliveryCard: View {
    let card: ReplyCard.Delivery
    let whole: ReplyCard
    private let shown: Shown
    @State private var copied = false
    @State private var history = false
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    init(card: ReplyCard.Delivery, whole: ReplyCard) {
        self.card = card
        self.whole = whole
        shown = Shown(card)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardBox(spacing: 14) {
                CardTitle(symbol: card.stage == .delivered ? "shippingbox.fill" : "shippingbox", title: shown.title, subtitle: shown.subtitle)
                headline
                track
                if let last = card.events.first { scan(last, newest: true) }
                if history {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(card.events.dropFirst().enumerated()), id: \.offset) { _, event in scan(event, newest: false) }
                    }
                    .transition(.opacity)
                }
                if card.events.count > 1 {
                    Button { withAnimation(.snappy(duration: 0.25)) { history.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text(history ? String(localized: "Fewer updates", comment: "A delivery card's button: hides its older scans")
                                 : String(localized: "All updates (\(card.events.count))", comment: "A delivery card's button: shows all its scans, with how many"))
                            Image(systemName: history ? "chevron.up" : "chevron.down").imageScale(.small)
                        }
                        .chatFont(.footnote, weight: .semibold).foregroundStyle(theme.accent)
                        .frame(minHeight: 44).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -10)
                }
                if let tracking = card.tracking { trackingRow(tracking) }
                if let note = card.note { Text(note).chatFont(.caption).foregroundStyle(.secondary) }
                if let url = shown.url {
                    Button { openURL(url) } label: { LinkCapsule(title: shown.view) }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Opens the carrier's tracking page in your browser", comment: "VoiceOver hint: a delivery card's Track button"))
                }
            }
            CardChips(chips: card.stage == .delivered ? [] : [Refresh.refresh], whole: whole,
                      title: { _ in String(localized: "Refresh", comment: "A chip under a score card: asks the agent for the latest score") },
                      symbol: { _ in "arrow.clockwise" },
                      hint: { _ in Text("Asks your agent to check the tracking again", comment: "VoiceOver hint: a delivery card's Refresh") },
                      asked: { $0.contains("tapped Refresh") ? .refresh : nil }, send: { _ in Self.refresh(card) })
        }
    }

    enum Refresh: Hashable { case refresh }

    // MARK: Where it stands

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if card.problem { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Self.warning).accessibilityHidden(true) }
                Text(verbatim: shown.headline).chatFont(.title3, weight: .bold)
                    .foregroundStyle(card.problem ? Self.warning : card.stage == .delivered ? PurchaseCard.good : Color.primary)
            }
            if let detail = shown.detail {
                Text(verbatim: detail).chatFont(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Ordered, Shipped, Out for delivery, Delivered: dots on a line, the ones done filled.
    private var track: some View {
        let reached = ReplyCard.Delivery.Stage.allCases.firstIndex(of: card.stage) ?? 0
        let colour = card.problem ? Self.warning : card.stage == .delivered ? PurchaseCard.good : theme.accent
        let grey = Color.primary.opacity(0.12)
        let last = ReplyCard.Delivery.Stage.allCases.count - 1
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(ReplyCard.Delivery.Stage.allCases.enumerated()), id: \.offset) { n, stage in
                VStack(spacing: 6) {
                    ZStack {
                        HStack(spacing: 0) {
                            Rectangle().fill(n == 0 ? Color.clear : n <= reached ? colour : grey).frame(height: 4)
                            Rectangle().fill(n == last ? Color.clear : n < reached ? colour : grey).frame(height: 4)
                        }
                        ZStack {
                            Circle().fill(n <= reached ? colour : grey)
                            if n == reached {
                                Circle().fill(.background.secondary).padding(4)
                                Circle().fill(colour).padding(6.5)
                            }
                        }
                        .frame(width: n == reached ? 22 : 12, height: n == reached ? 22 : 12)
                    }
                    .frame(height: 22)
                    Text(Self.name(stage))
                        .chatFont(.caption2, weight: n == reached ? .bold : .regular)
                        .foregroundStyle(n == reached ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Progress", comment: "VoiceOver: a delivery card's track from ordered to delivered"))
        .accessibilityValue(Text("\(Self.name(card.stage)), step \(reached + 1) of 4", comment: "VoiceOver: where a package stands on a delivery card's track, e.g. Shipped, step 2 of 4"))
    }

    private func scan(_ event: ReplyCard.Delivery.Scan, newest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: newest ? "mappin.and.ellipse" : "circle.fill")
                .imageScale(newest ? .medium : .small)
                .foregroundStyle(newest ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.tertiary))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.text).chatFont(.subheadline, weight: newest ? .semibold : .regular)
                let line = [event.place, event.at.map { Self.when($0) }].compactMap(\.self).joined(separator: " · ")
                if !line.isEmpty { Text(verbatim: line).chatFont(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func trackingRow(_ number: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Tracking number", comment: "A delivery card's label over its tracking number").chatFont(.caption2).foregroundStyle(.secondary)
                Text(verbatim: number).chatFont(.footnote, weight: .medium).monospaced().lineLimit(1).minimumScaleFactor(0.7).textSelection(.enabled)
            }
            Spacer(minLength: 6)
            Button {
                UIPasteboard.general.string = number
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label(copied ? String(localized: "Copied", comment: "A delivery card's Copy button, once the number is copied") : String(localized: "Copy"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .chatFont(.footnote, weight: .semibold)
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(theme.accent.opacity(0.12), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: copied) { _, now in now }
            .accessibilityLabel(Text("Copy tracking number", comment: "VoiceOver: a delivery card's Copy button"))
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14))
    }

    // MARK: Words

    static func refresh(_ card: ReplyCard.Delivery) -> (shown: String, said: String) {
        let named = [card.carrier, card.tracking.map { "tracking \($0)" }, card.title.map { "(\($0))" }].compactMap(\.self).joined(separator: " ")
        return (String(localized: "Check on the package", comment: "The message a delivery card's Refresh sends"),
                "the user tapped Refresh on the delivery card: look up \(named) again with your tools and show a fresh 'delivery' card; "
                    + "never guess a status, a place or a date")
    }

    static func name(_ stage: ReplyCard.Delivery.Stage) -> String {
        switch stage {
        case .ordered: String(localized: "Ordered", comment: "A package on a delivery card: the order is placed, not shipped yet")
        case .shipped: String(localized: "Shipped", comment: "A package on a delivery card: on its way")
        case .outForDelivery: String(localized: "Out for delivery", comment: "A package on a delivery card: with the driver today")
        case .delivered: String(localized: "Delivered", comment: "A package on a delivery card: it has come")
        }
    }

    /// "Today, 6:12 AM", "Yesterday, 4:30 PM", "Mon, Nov 2, 9:00 AM": in this phone's time.
    static func when(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today, \(time)", comment: "When a game starts: today at a time") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday, \(time)", comment: "When a package was scanned: yesterday at a time")
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + ", " + time
    }

    /// "Arrives today", "Arrives tomorrow", "Arrives Thursday", "Arrives Nov 12": the day it should come.
    static func arrives(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<0: return String(localized: "Was due \(date.formatted(.dateTime.weekday(.wide)))", comment: "A delivery card: the day it should have come has passed, e.g. Was due Monday")
        case 0: return String(localized: "Arrives today", comment: "A delivery card: it should come today")
        case 1: return String(localized: "Arrives tomorrow", comment: "A delivery card: it should come tomorrow")
        case 2 ... 6: return String(localized: "Arrives \(date.formatted(.dateTime.weekday(.wide)))", comment: "A delivery card: the weekday it should come, e.g. Arrives Thursday")
        default: return String(localized: "Arrives \(date.formatted(.dateTime.month(.abbreviated).day()))", comment: "A delivery card: the day it should come, e.g. Arrives Nov 12")
        }
    }

    static let warning = shade(light: (0.75, 0.38, 0), dark: (1.0, 0.62, 0.25))
}

extension DeliveryCard {
    /// What the card says, worked out once.
    struct Shown {
        var title: String
        var subtitle: String?
        var headline: String
        var detail: String?
        var url: URL?
        /// "Track at UPS".
        var view: String

        init(_ card: ReplyCard.Delivery, now: Date = .now, calendar: Calendar = .current) {
            title = card.title ?? card.carrier.map { String(localized: "\($0) package", comment: "A delivery card's title when the agent named only the carrier, e.g. UPS package") }
                ?? String(localized: "Package", comment: "A delivery card's title when the agent named neither what is in it nor the carrier")
            subtitle = [card.from.map { String(localized: "From \($0)", comment: "A delivery card: where the package comes from, e.g. From Apple") },
                        card.title != nil ? card.carrier : nil].compactMap(\.self).joined(separator: " · ").nilIfEmpty
            let time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
            switch card.stage {
            case .delivered:
                if let at = card.deliveredAt {
                    headline = String(localized: "Delivered \(DeliveryCard.day(at, now: now, calendar: calendar))", comment: "A delivery card: the day it came, e.g. Delivered today")
                    detail = String(localized: "at \(time(at))", comment: "A delivery card: the time it came, after its day, e.g. at 2:14 PM")
                } else {
                    headline = DeliveryCard.name(.delivered)
                }
            default:
                if card.problem, let status = card.status {
                    headline = status
                    detail = card.expected.map { DeliveryCard.arrives($0, now: now, calendar: calendar) } ?? card.expectedWords
                } else if let expected = card.expected {
                    headline = DeliveryCard.arrives(expected, now: now, calendar: calendar)
                    detail = card.window ?? (card.expectedAllDay ? nil : String(localized: "by \(time(expected))", comment: "A delivery card: the time it should come by, e.g. by 8 PM"))
                    if let status = card.status, detail == nil { detail = status }
                } else if let words = card.expectedWords {
                    headline = String(localized: "Arrives \(words)", comment: "A delivery card: when it should come, in the agent's words, e.g. Arrives Monday or Tuesday")
                    detail = card.window ?? card.status
                } else {
                    headline = card.status ?? DeliveryCard.name(card.stage)
                }
            }
            url = card.url.flatMap(URL.init(string:)) ?? ReplyCard.Delivery.trackingPage(carrier: card.carrier, number: card.tracking)
            view = card.carrier.map { String(localized: "Track at \($0)", comment: "A delivery card's button: opens the carrier's tracking page, e.g. Track at UPS") }
                ?? String(localized: "Track Package", comment: "A delivery card's button: opens the tracking page, its carrier not named")
        }
    }

    /// "today", "yesterday", "Thursday", "Nov 2".
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return String(localized: "delivered.today", defaultValue: "today", comment: "A delivery card: delivered today (after Delivered)")
        case 1: return String(localized: "delivered.yesterday", defaultValue: "yesterday", comment: "A delivery card: delivered yesterday (after Delivered)")
        case 2 ... 6: return date.formatted(.dateTime.weekday(.wide))
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

import SwiftUI
import WidgetKit
#if WIDGET_VIEWS_IN_TESTS
@testable import Echo   // the unit tests draw these; in the extension the shared types are its own
#endif

// MARK: - Needs you

struct NeedsYouEntry: TimelineEntry {
    let date: Date
    let requests: [WaitingRequest]
    var hidesWords = false

    /// Something waiting is worth the top of a Smart Stack; nothing waiting isn't.
    var relevance: TimelineEntryRelevance? { requests.isEmpty ? nil : TimelineEntryRelevance(score: 100) }

    /// Now, and again each time one of the requests runs out: Hermes has given up on it by
    /// then, and the widget lets go of it without the app having to run.
    static func timeline(_ requests: [WaitingRequest], from now: Date, hidesWords: Bool) -> [NeedsYouEntry] {
        let live = requests.filter { $0.until > now }
        return [NeedsYouEntry(date: now, requests: live, hidesWords: hidesWords)]
            + Set(live.map(\.until)).sorted().map { end in
                NeedsYouEntry(date: end, requests: live.filter { $0.until > end }, hidesWords: hidesWords)
            }
    }

    static let sample = NeedsYouEntry(date: .now, requests: [
        WaitingRequest(id: "sample", kind: .approval, title: "Clear out the old builds", text: "rm -rf ~/builds/2025-*",
                       session: nil, since: .now, until: .now.addingTimeInterval(300)),
    ])
}

struct NeedsYouProvider: TimelineProvider {
    func placeholder(in context: Context) -> NeedsYouEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (NeedsYouEntry) -> Void) {
        completion(context.isPreview ? .sample : NeedsYouEntry(date: .now, requests: NeedsYou.waiting(), hidesWords: NeedsYou.hidesWords))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NeedsYouEntry>) -> Void) {
        // The app and the notification extension reload this when the list changes; between
        // those the entries themselves see each request out.
        completion(Timeline(entries: NeedsYouEntry.timeline(NeedsYou.waiting(), from: .now, hidesWords: NeedsYou.hidesWords), policy: .never))
    }
}

/// What the agent is waiting on the person for, in each size the widget comes in.
struct NeedsYouCard: View {
    let requests: [WaitingRequest]
    var hidesWords = false
    let family: WidgetFamily

    private var first: WaitingRequest? { requests.first }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(Self.count(requests.count), systemImage: requests.isEmpty ? "checkmark.circle" : "hand.raised.fill")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if requests.isEmpty {
                    Image(systemName: "checkmark").font(.title3.weight(.semibold))
                } else {
                    VStack(spacing: 0) {
                        Image(systemName: "hand.raised.fill").font(.caption.weight(.semibold))
                        Text("\(requests.count)").font(.title3.weight(.bold)).monospacedDigit()
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.count(requests.count))
        case .accessoryRectangular:
            if let first {
                VStack(alignment: .leading, spacing: 1) {
                    Label(requests.count > 1 ? "\(requests.count) need you" : "Needs you", systemImage: first.symbol)
                        .font(.headline).lineLimit(1).widgetAccentable()
                    Text(words(first)).font(.caption).lineLimit(2).privacySensitive()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("Nothing needs you", systemImage: "checkmark.circle").font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .systemMedium:
            if requests.isEmpty { nothing } else { rows(2) }
        default:
            if let first { small(first) } else { nothing }
        }
    }

    private func small(_ request: WaitingRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Needs you", systemImage: request.symbol).font(.caption.weight(.semibold)).foregroundStyle(.tint)
            // Which conversation; the symbol above says what kind of request it is.
            Text(hidesWords ? request.name : request.title ?? request.name)
                .font(.footnote.weight(.semibold)).lineLimit(1).privacySensitive()
            Text(words(request))
                .font(request.kind == .approval && !hidesWords ? .caption.monospaced() : .caption)
                .lineLimit(3).privacySensitive()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text(requests.count > 1 ? "and \(requests.count - 1) more" : "since \(request.since.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// A row for each request, each opening its own conversation.
    private func rows(_ most: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Needs you", systemImage: "hand.raised.fill").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                Spacer(minLength: 0)
                if requests.count > most {
                    Text("\(requests.count) waiting").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(requests.prefix(most)) { request in
                Link(destination: Self.destination(request)) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: request.symbol).font(.footnote).foregroundStyle(.tint).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(hidesWords ? request.headline : request.title ?? request.headline)
                                    .font(.footnote.weight(.semibold)).lineLimit(1).privacySensitive()
                                Spacer(minLength: 4)
                                Text(request.since, style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(words(request))
                                .font(request.kind == .approval && !hidesWords ? .caption.monospaced() : .caption)
                                .foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                .lineLimit(requests.count == 1 ? 4 : 1).privacySensitive()
                        }
                    }
                    .foregroundStyle(Color.primary)   // a link's label would otherwise take the tint
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
    }

    private var nothing: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.tint)
            Text("Nothing needs you").font(.footnote.weight(.semibold))
            if family != .systemSmall {
                Text("A command to approve or a question from your agent shows here.")
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func words(_ request: WaitingRequest) -> String {
        hidesWords || request.text.isEmpty ? request.hiddenLine : request.text
    }

    nonisolated static func count(_ n: Int) -> String {
        n == 0 ? "Nothing needs you" : n == 1 ? "1 waiting on you" : "\(n) waiting on you"
    }

    /// Where a tap goes: the conversation that waits, when the server has a session for it.
    nonisolated static func destination(_ request: WaitingRequest?) -> URL {
        request?.session.map(EchoURL.session) ?? EchoURL.open
    }
}

struct NeedsYouWidgetView: View {
    let entry: NeedsYouEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        NeedsYouCard(requests: entry.requests, hidesWords: entry.hidesWords, family: family)
            .widgetURL(NeedsYouCard.destination(entry.requests.first))
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NeedsYou.widgetKind, provider: NeedsYouProvider()) { entry in
            NeedsYouWidgetView(entry: entry)
        }
        .configurationDisplayName("Needs you")
        .description("A command waiting for your approval, or a question from your agent.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Context

struct ContextEntry: TimelineEntry {
    let date: Date
    let reading: ContextReading?
    var hidesWords = false

    static let sample = ContextEntry(date: .now, reading: ContextReading(used: 54_210, window: 128_000, title: "Plan the weekend hike", date: .now))
}

struct ContextProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContextEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (ContextEntry) -> Void) {
        completion(context.isPreview ? .sample : ContextEntry(date: .now, reading: ContextReading.load(), hidesWords: NeedsYou.hidesWords))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ContextEntry>) -> Void) {
        // The app reloads this when a reply brings a new reading.
        completion(Timeline(entries: [ContextEntry(date: .now, reading: ContextReading.load(), hidesWords: NeedsYou.hidesWords)], policy: .never))
    }
}

/// How full the model's context is in the conversation Redde was last in, as the chat's header
/// shows it: a ring, the share, and the tokens behind it.
struct ContextCard: View {
    let reading: ContextReading?
    var hidesWords = false
    let family: WidgetFamily

    private var share: Double { reading?.share ?? 0 }
    private var percent: String { reading == nil ? "–" : share.formatted(.percent.precision(.fractionLength(0))) }
    /// Amber from three quarters, red from nine tenths, as in the app: where a new conversation helps.
    private var tint: AnyShapeStyle {
        share >= 0.9 ? AnyShapeStyle(.red) : share >= 0.75 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint)
    }
    private var title: String? { hidesWords ? nil : reading?.title }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(reading == nil ? "Context: no reading yet" : "Context \(percent) full", systemImage: "circle.dashed")
        case .accessoryCircular:
            Gauge(value: share) {
                Text("ctx")
            } currentValueLabel: {
                Text(reading == nil ? "–" : "\(Int((share * 100).rounded()))")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel("Context")
            .accessibilityValue(spoken)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Context").font(.headline).widgetAccentable()
                    Spacer(minLength: 0)
                    Text(percent).font(.headline).monospacedDigit()
                }
                // Drawn here: a bar of the system's own doesn't take the Lock Screen's one colour well.
                Capsule().fill(.tertiary).frame(height: 5).overlay(alignment: .leading) {
                    GeometryReader { bar in
                        Capsule().frame(width: reading == nil ? 0 : max(5, bar.size.width * share))
                    }
                }
                .widgetAccentable()
                Text(reading.map { "\($0.amounts) tokens" } ?? "No reading yet").font(.caption).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Context")
            .accessibilityValue(spoken)
        default:
            VStack(spacing: 6) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 9)
                    Circle().trim(from: 0, to: share).stroke(tint, style: .init(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(percent).font(.title2.weight(.bold)).monospacedDigit().minimumScaleFactor(0.7)
                        Text("context").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 1) {
                    if let title {
                        Text(title).font(.caption.weight(.semibold)).lineLimit(1).privacySensitive()
                    }
                    Text(reading.map { "\($0.amounts) tokens" } ?? "No reading yet").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Context")
            .accessibilityValue(spoken)
        }
    }

    private var spoken: String {
        guard let reading else { return "No reading yet" }
        return "\(reading.used.formatted()) of \(reading.window.formatted()) tokens, \(percent)"
    }
}

struct ContextWidgetView: View {
    let entry: ContextEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ContextCard(reading: entry.reading, hidesWords: entry.hidesWords, family: family)
            .widgetURL(EchoURL.open)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ContextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ContextReading.widgetKind, provider: ContextProvider()) { entry in
            ContextWidgetView(entry: entry)
        }
        .configurationDisplayName("Context")
        .description("How full the model's context is in your latest conversation.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

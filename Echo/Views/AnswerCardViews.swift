import SwiftUI

/// What a card's tap does: the conversation's `answerCard`, given to the transcript. Nil where a
/// card can't be answered (a group chat, a transcript read elsewhere): the card is shown, and its
/// buttons are off.
struct CardAnswerer {
    var answer: (ReplyCard, _ shown: String, _ said: String) -> Void
    /// A reply is coming in: a tap waits.
    var busy: Bool
}

extension EnvironmentValues {
    @Entry var answerCard: CardAnswerer? = nil
}

/// The frame an answerable card sits in: the newer cards' (the agent's question, `ClarifyCard`),
/// restyled with the review and the checklist (asked 2026-10-30): its kind's mark in a tinted
/// tile, its title and a line under it, and "Needs you" while it waits.
private struct AnswerBox<Content: View>: View {
    var symbol: String
    var title: String?
    var subtitle: String? = nil
    /// Unanswered, and a tap answers it.
    var needsYou = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title { AnswerHeader(symbol: symbol, title: title, subtitle: subtitle, needsYou: needsYou) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

/// A card's header: its mark on a wash of the theme's colour, its title, the line under it.
private struct AnswerHeader: View {
    var symbol: String
    var title: String
    var subtitle: String?
    var needsYou: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .chatFont(.subheadline, weight: .semibold)
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.14), in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).chatFont(.subheadline, weight: .semibold)
                if let subtitle { Text(subtitle).chatFont(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 6)
            if needsYou {
                Text("Needs you").tracking(0.4).textCase(.uppercase)
                    .chatFont(.caption2, weight: .bold)
                    // The orange of a request that waits, dark enough on the light card to read.
                    .foregroundStyle(scheme == .dark ? Color(red: 0.94, green: 0.63, blue: 0.25) : Color(red: 0.66, green: 0.34, blue: 0))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.16), in: .rect(cornerRadius: 6))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension ColorScheme {
    /// The plain sheet a card's content is on (white; near black in the dark), and its panels and
    /// grey buttons (white; a dark grey): as the designs have them, whatever the chat behind is.
    var cardPaper: Color { self == .dark ? Color(white: 0.07) : .white }
    var cardPanel: Color { self == .dark ? Color(white: 0.17) : .white }
}

/// A card's quieter button: a grey capsule as tall as a finger, beside the filled one.
private struct GreyCapsule<Style: ShapeStyle>: View {
    let text: Text
    let style: Style
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        text
            .foregroundStyle(style)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(scheme.cardPanel, in: .capsule)
            .overlay { Capsule().strokeBorder(.separator.opacity(0.35), lineWidth: 0.5) }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(.capsule)
    }
}

/// How a card was answered, under it.
private struct AnsweredLine: View {
    var text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .chatFont(.caption, weight: .medium)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

// MARK: - Review before it acts

/// What the agent made ready (an email, a booking, an order), and the button that lets it go
/// ahead. Drawn by the app, so what the person approves is what the card says, not words a page
/// or a message could pass off as a button. Drawn as the thing itself (asked 2026-10-30): an email
/// or a message on a sheet of paper, who it's to with their initials, its subject, its words;
/// anything else as its details, row by row. Edit opens the same sheet for changes, and the
/// button acts on what it says then.
struct ReviewCard: View {
    let card: ReplyCard.Review
    let whole: ReplyCard
    /// Its kind and the order of its parts, worked out once.
    private let kind: ReplyCard.Review.Kind
    private let pieces: [Piece]
    @State private var values: [String] = []
    @State private var editing = false
    @FocusState private var focused: Int?
    @State private var answers = CardAnswers.shared
    @Environment(\.answerCard) private var answerer
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    /// A part of the sheet: who it's to, a detail, the subject, a message's words.
    private enum Piece: Hashable {
        case to(Int), row(Int), subject(Int), body(Int)
        var words: Int? { if case let .body(i) = self { i } else { nil } }
    }

    init(card: ReplyCard.Review, whole: ReplyCard) {
        self.card = card
        self.whole = whole
        kind = card.shownKind
        let layout = card.layout
        pieces = (layout.to.map { [Piece.to($0)] } ?? []) + layout.rows.map(Piece.row)
            + (layout.subject.map { [Piece.subject($0)] } ?? []) + (layout.body.map { [Piece.body($0)] } ?? [])
    }

    private var answered: String? { answers.said[whole.key] }
    private var editable: Bool { editing && answered == nil && answerer != nil }
    /// A message goes out: its button has the paper plane.
    private var sends: Bool { kind == .email || kind == .message || card.action.lowercased().hasPrefix("send") }

    var body: some View {
        AnswerBox(symbol: Self.symbol(kind), title: card.title, subtitle: card.subtitle, needsYou: answered == nil && answerer != nil) {
            paper
            if let note = card.note {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle").accessibilityHidden(true)
                    Text(note)
                }
                .chatFont(.caption)
                .foregroundStyle(.secondary)
            }
            if let answered {
                AnsweredLine(text: answered.hasPrefix("cancelled") ? String(localized: "Cancelled") : String(localized: "Done: \(card.action)"))
            } else if let answerer {
                buttons(answerer)
            }
        }
        .onAppear { if values.isEmpty { values = card.fields.map(\.value) } }
        // Editing starts in its words, where a change most often is.
        .onChange(of: editing) { _, now in focused = now ? pieces.lazy.compactMap(\.words).first ?? card.fields.indices.first : nil }
    }

    static func symbol(_ kind: ReplyCard.Review.Kind) -> String {
        switch kind {
        case .email: "envelope"
        case .message: "message"
        case .event: "calendar"
        case .purchase: "bag"
        case .other: "checkmark.shield"
        }
    }

    /// The thing itself, on a plain sheet: a row for each detail, a message's words below them.
    private var paper: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 0) {
            ForEach(Array(pieces.enumerated()), id: \.element) { n, piece in
                if n > 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                switch piece {
                case let .to(i):
                    GridRow(alignment: .center) {
                        label(i)
                        HStack(spacing: 8) {
                            avatar(value(i))
                            entry(i) { Text(value(i)).chatFont(.subheadline, weight: .medium) }
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .row(i) where card.fields[i].long:
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.fields[i].label).chatFont(.footnote).foregroundStyle(.secondary)
                        entry(i) { Text(value(i)).chatFont(.subheadline).lineSpacing(3) }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                case let .row(i), let .subject(i):
                    GridRow {
                        label(i)
                        entry(i) { Text(value(i)).chatFont(.subheadline, weight: .medium) }
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .body(i):
                    entry(i) { Text(value(i)).chatFont(.subheadline).lineSpacing(4) }
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scheme.cardPaper, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
        .textSelection(.enabled)
        .animation(.snappy(duration: 0.25), value: editing)
    }

    private func label(_ index: Int) -> some View {
        Text(card.fields[index].label).chatFont(.footnote).foregroundStyle(.secondary)
            .padding(.vertical, 12)
            .gridColumnAlignment(.leading)
    }

    /// A detail as it reads, or, editing, its field.
    @ViewBuilder
    private func entry<Shown: View>(_ index: Int, @ViewBuilder shown: () -> Shown) -> some View {
        if editable {
            let long = card.fields[index].long
            TextField(card.fields[index].label, text: binding(index), axis: long ? .vertical : .horizontal)
                .lineLimit(long ? 2 ... 12 : 1 ... 1)
                .chatFont(.subheadline)
                .textFieldStyle(.plain)
                .focused($focused, equals: index)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.fill.tertiary, in: .rect(cornerRadius: 8))
        } else {
            shown()
        }
    }

    /// Who it's to: their initials (a figure for a number) on a colour of their own.
    private func avatar(_ to: String) -> some View {
        let letters = ReplyCard.Review.initials(to)
        let colors: [Color] = [.purple, .blue, .teal, .orange, .pink, .indigo, .green]
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in to.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Group {
            if letters.isEmpty { Image(systemName: "person.fill") } else { Text(verbatim: letters) }
        }
        .chatFont(size: 11, weight: .bold)
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(colors[Int(hash % UInt64(colors.count))], in: .circle)
        .accessibilityHidden(true)
    }

    private func buttons(_ answerer: CardAnswerer) -> some View {
        HStack(spacing: 10) {
            Button(role: .cancel) { cancel(answerer) } label: { GreyCapsule(text: Text("Cancel"), style: .primary) }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Tells the agent not to do it", comment: "VoiceOver hint: a review card's Cancel"))
            Button { editing.toggle() } label: { GreyCapsule(text: editing ? Text("Done") : Text("Edit"), style: .tint) }
                .buttonStyle(.plain)
                .accessibilityHint(editing ? Text("Shows it as it will go", comment: "VoiceOver hint: a review card's Done, after editing")
                                           : Text("Lets you change it first", comment: "VoiceOver hint: a review card's Edit"))
            Spacer(minLength: 0)
            Button { go(answerer) } label: {
                HStack(spacing: 6) {
                    if sends { Image(systemName: "paperplane.fill").foregroundStyle(answerer.busy ? Color.secondary : theme.userText) }
                    FilledButtonTitle(title: card.action)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(Text("Tells the agent to go ahead with exactly this", comment: "VoiceOver hint: a review card's main button (Send, Book)"))
        }
        .chatFont(.subheadline, weight: .semibold)
        .buttonBorderShape(.capsule)
        .disabled(answerer.busy)
    }

    private func value(_ index: Int) -> String { values.indices.contains(index) ? values[index] : card.fields[index].value }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(get: { value(index) }, set: { new in
            if values.count != card.fields.count { values = card.fields.map(\.value) }
            values[index] = new
        })
    }

    private func go(_ answerer: CardAnswerer) {
        editing = false
        let changed = card.fields.indices.contains { value($0) != card.fields[$0].value }
        let details = card.fields.indices.map { "\(card.fields[$0].label): \(value($0))" }.joined(separator: "; ")
        let said = "the user tapped \"\(card.action)\" on \"\(card.title)\"\(changed ? ", after changing it" : ""). Go ahead with exactly this — \(details)"
        answerer.answer(.review(card), String(localized: "\(card.action): \(card.title)", comment: "The message a review card's button sends: its button, then its title"), said)
    }

    private func cancel(_ answerer: CardAnswerer) {
        editing = false
        answerer.answer(.review(card), String(localized: "Cancel: \(card.title)", comment: "The message a review card's Cancel sends"),
                        "cancelled: the user cancelled \"\(card.title)\". Don't do it")
    }
}

// MARK: - Pick one

struct ChoiceCard: View {
    let card: ReplyCard.Choice
    let whole: ReplyCard
    @State private var picked: Set<Int> = []
    @State private var answers = CardAnswers.shared
    @Environment(\.answerCard) private var answerer
    @Environment(\.colorScheme) private var scheme

    private var answered: String? { answers.said[whole.key] }

    var body: some View {
        AnswerBox(symbol: card.multiple ? "checklist" : "hand.tap", title: card.title) {
            ForEach(Array(card.options.enumerated()), id: \.offset) { index, option in
                Button { tap(index) } label: { row(option, index: index) }
                    .buttonStyle(.plain)
                    .disabled(answered != nil || answerer == nil || answerer?.busy == true)
                    .accessibilityAddTraits(isPicked(index) ? .isSelected : [])
                    .accessibilityHint(card.multiple ? Text("Picks it, or leaves it out", comment: "VoiceOver hint: an option of a card where several may be picked")
                                                     : Text("Sends it as your pick", comment: "VoiceOver hint: an option of a card where one is picked"))
            }
            if answered != nil {
                let picked = card.options.indices.filter(isPicked).map { card.options[$0].title }
                AnsweredLine(text: String(localized: "Picked: \(picked.joined(separator: ", "))"))
            } else if card.multiple, let answerer {
                HStack {
                    Spacer(minLength: 0)
                    Button { send(answerer) } label: {
                        FilledButtonTitle(title: String(localized: "Send")).padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 32)
                    }
                    .chatFont(.subheadline, weight: .semibold)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(picked.isEmpty || answerer.busy)
                    .accessibilityHint(Text("Sends what you picked", comment: "VoiceOver hint: the Send of a card where several may be picked"))
                }
            }
        }
    }

    private func isPicked(_ index: Int) -> Bool {
        if let answered { return answered.contains(card.options[index].title) }
        return picked.contains(index)
    }

    private func row(_ option: ReplyCard.Option, index: Int) -> some View {
        HStack(spacing: 10) {
            if let image = option.image, let url = URL(string: image) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                    .frame(width: 52, height: 52)
                    .clipShape(.rect(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title).chatFont(.callout, weight: .semibold)
                if let detail = option.detail { Text(detail).chatFont(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            Spacer(minLength: 6)
            Image(systemName: isPicked(index) ? "checkmark.circle.fill" : (card.multiple ? "circle" : "chevron.right"))
                .foregroundStyle(isPicked(index) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .padding(10)
        .background(isPicked(index) ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(scheme.cardPanel), in: .rect(cornerRadius: 14))
        .opacity(answered != nil && !isPicked(index) ? 0.5 : 1)
        .contentShape(.rect)
    }

    private func tap(_ index: Int) {
        if card.multiple {
            if picked.contains(index) { picked.remove(index) } else { picked.insert(index) }
        } else if let answerer {
            picked = [index]
            send(answerer)
        }
    }

    private func send(_ answerer: CardAnswerer) {
        let titles = picked.sorted().map { card.options[$0].title }
        let from = card.title.map { "from \"\($0)\"" } ?? "from the options"
        answerer.answer(.choice(card), titles.joined(separator: ", "),
                        "\(from) the user picked: \(titles.map { "\"\($0)\"" }.joined(separator: ", "))")
    }
}

// MARK: - Checklist

extension Color {
    /// This colour where it reads on `background` (a contrast of 3:1, what a mark needs), else
    /// `fallback`: a pale theme colour (Paper's tan, a yellow, a pale sky) on a light card isn't seen.
    func readable(on background: Color, or fallback: Color, in environment: EnvironmentValues) -> Color {
        func luminance(_ c: Color.Resolved) -> Double {
            0.2126 * Double(c.linearRed) + 0.7152 * Double(c.linearGreen) + 0.0722 * Double(c.linearBlue)
        }
        let a = luminance(resolve(in: environment)), b = luminance(background.resolve(in: environment))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05) >= 3 ? self : fallback
    }
}

/// A list to tick off in place (a packing or a shopping list), as a card (asked 2026-10-28: "a
/// more fun way like a card"; drawn to the approved design 2026-10-30): a ring of how much is
/// done, green when it all is, its title and how it stands ("Nov 7 – 8 · 3 of 8 packed"), then its
/// groups, each a panel of rows to tick with a word beside an item ("×2"); a group folds away
/// with a tap on its name, and by itself when it is done or the list is long. Its marks are the
/// theme's colour where that reads (made readable in every theme 2026-10-28). Ticks are kept on
/// the phone; Send tells the agent how it stands; its menu pins it to the chat list, puts it in
/// Reminders, or shares it.
struct ChecklistCard: View {
    let card: ReplyCard.Checklist
    let whole: ReplyCard
    /// Its groups, worked out once.
    private let groups: [(title: String?, items: [Int])]
    /// Shown pinned, away from its chat: no Send there.
    @Environment(\.pinnedCard) private var pinned
    @State private var answers = CardAnswers.shared
    @State private var pins = PinnedCards.shared
    @State private var folded: Set<String> = []
    @State private var unfolded: Set<String> = []
    @State private var exported: String?
    @Environment(\.answerCard) private var answerer
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(Conversation.self) private var conversation: Conversation?

    /// Past this many, groups start folded and open with a tap.
    private static let foldPast = 24

    init(card: ReplyCard.Checklist, whole: ReplyCard) {
        self.card = card
        self.whole = whole
        groups = card.sections
    }

    private var done: Set<Int> {
        Set(answers.ticks[whole.key] ?? card.items.indices.filter { card.items[$0].done })
    }

    /// Ticked differently from what the agent last heard.
    private func changed(_ done: Set<Int>) -> Bool {
        let told = answers.said[whole.key].map(Self.ticked(in:)) ?? Set(card.items.indices.filter { card.items[$0].done })
        return told != done
    }

    /// How it stands, in the agent's word for it where it gave one: "3 of 8 packed".
    private func standing(_ count: Int) -> String {
        guard let verb = card.verb else { return String(localized: "\(count) of \(card.items.count) done") }
        return String(localized: "\(count) of \(card.items.count) \(verb)",
                      comment: "A checklist's progress in the agent's word for an item done: 3 of 8 packed")
    }

    var body: some View {
        let done = self.done
        let allDone = !card.items.isEmpty && done.count == card.items.count
        // The marks: the theme's colour where it reads on the list's panel, else its text.
        let mark = theme.accent.readable(on: scheme.cardPanel, or: scheme == .dark ? .white : .black,
                                         in: { var e = EnvironmentValues(); e.colorScheme = scheme; return e }())
        AnswerBox(symbol: "checklist", title: nil) {
            header(done.count, allDone: allDone, mark: mark)
            // A group's name is as tall as a finger, its panel right under it: the groups need no gap.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    groupView(group.title, items: group.items, done: done, mark: mark)
                }
            }
            .padding(.top, groups.first?.title == nil ? 0 : -10)
            footer(done)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .sensoryFeedback(.success, trigger: allDone) { _, now in now }
        .animation(.snappy(duration: 0.25), value: done)
        .alert(exported ?? "", isPresented: Binding(get: { exported != nil }, set: { if !$0 { exported = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func header(_ count: Int, allDone: Bool, mark: Color) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 5)
                Circle().trim(from: 0, to: card.items.isEmpty ? 0 : Double(count) / Double(card.items.count))
                    .stroke(allDone ? Color.green : mark, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(count, format: .number).chatFont(size: 13, weight: .bold).monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
            }
            .frame(width: 43, height: 43)
            .padding(2.5)
            .animation(.snappy(duration: 0.25), value: count)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(standing(count))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).chatFont(.headline, weight: .bold).lineLimit(2)
                Text(([card.subtitle].compactMap { $0 } + [standing(count)]).joined(separator: " · "))
                    .chatFont(.footnote).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityHidden(card.subtitle == nil)
            }
            Spacer(minLength: 6)
            menu
        }
    }

    private var menu: some View {
        Menu {
            if pins.isPinned(whole.key) {
                Button("Unpin from Chats", systemImage: "pin.slash") { pins.unpin(whole.key) }
            } else {
                Button("Pin to Chats", systemImage: "pin") {
                    pins.pin(whole, title: card.title, conversation: conversation?.id, agent: conversation?.bot?.name)
                }
            }
            #if os(iOS)
            Button("Add to Reminders", systemImage: "checklist") { Task { exported = await ChecklistExport.toReminders(card, done: done) } }
            #endif
            Button("Copy", systemImage: "doc.on.doc") { ChecklistExport.copy(ChecklistExport.text(card, done: done)) }
            ShareLink(item: ChecklistExport.text(card, done: done)) { Label("Share…", systemImage: "square.and.arrow.up") }
        } label: {
            Image(systemName: "ellipsis.circle").chatFont(.title3).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .accessibilityLabel("More for \(card.title)")
        .accessibilityHint(Text("Pin it, put it in Reminders, copy or share it", comment: "VoiceOver hint: a checklist card's menu"))
    }

    @ViewBuilder
    private func groupView(_ title: String?, items: [Int], done: Set<Int>, mark: Color) -> some View {
        let id = title ?? ""
        let ticked = items.filter(done.contains).count
        let isFolded = title != nil && !unfolded.contains(id)
            && (folded.contains(id) || ticked == items.count || card.items.count > Self.foldPast)
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Button {
                    if isFolded { unfolded.insert(id); folded.remove(id) } else { folded.insert(id); unfolded.remove(id) }
                } label: {
                    HStack(spacing: 6) {
                        Text(title).tracking(0.6).textCase(.uppercase).chatFont(.caption, weight: .semibold)
                        Spacer(minLength: 6)
                        if isFolded {
                            if ticked == items.count { Image(systemName: "checkmark.circle.fill").foregroundStyle(mark) }
                            Text("\(ticked)/\(items.count)").monospacedDigit()
                            Image(systemName: "chevron.right").imageScale(.small)
                        }
                    }
                    .chatFont(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2).padding(.bottom, 6)
                    .frame(minHeight: 44, alignment: .bottom)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(isFolded ? Text("\(ticked) of \(items.count) done") : Text(verbatim: ""))
                .accessibilityHint(isFolded ? Text("Shows its items", comment: "VoiceOver hint: a folded group of a checklist card")
                                            : Text("Hides its items", comment: "VoiceOver hint: an open group of a checklist card"))
            }
            if !isFolded {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element) { n, index in
                        if n > 0 { Divider() }
                        row(index, on: done.contains(index), mark: mark)
                    }
                }
                .background(scheme.cardPanel, in: .rect(cornerRadius: 14))
            }
        }
    }

    private func row(_ index: Int, on: Bool, mark: Color) -> some View {
        let item = card.items[index]
        return Button { toggle(index) } label: {
            HStack(spacing: 12) {
                ZStack {
                    if on {
                        Circle().fill(mark)
                        Image(systemName: "checkmark").chatFont(size: 11, weight: .heavy)
                            .foregroundStyle(mark == theme.accent ? theme.userText : (scheme == .dark ? Color.black : .white))
                    } else {
                        Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5)
                    }
                }
                .frame(width: 22, height: 22)
                Text(item.text).chatFont(.subheadline)
                    .strikethrough(on, color: .secondary)
                    .foregroundStyle(on ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let note = item.note { Text(note).chatFont(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? Text("Done") : Text("Not done"))
        .accessibilityHint(on ? Text("Marks it not done", comment: "VoiceOver hint: a ticked item of a checklist card")
                              : Text("Marks it done", comment: "VoiceOver hint: an item of a checklist card not ticked yet"))
    }

    @ViewBuilder
    private func footer(_ done: Set<Int>) -> some View {
        if let answerer, changed(done), !pinned {
            Button { send(answerer) } label: {
                Label(String(localized: "Send"), systemImage: "paperplane.fill")
                    .chatFont(.subheadline, weight: .semibold)
                    .foregroundStyle(answerer.busy ? Color.secondary : theme.userText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6).frame(minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(answerer.busy)
            .accessibilityHint(Text("Tells the agent what's done", comment: "VoiceOver hint: a checklist card's Send"))
        }
    }

    private func toggle(_ index: Int) {
        var now = done
        if now.contains(index) { now.remove(index) } else { now.insert(index) }
        answers.setTicks(whole.key, now.sorted())
    }

    private func send(_ answerer: CardAnswerer) {
        let done = self.done
        let yes = card.items.indices.filter { done.contains($0) }.map { card.items[$0].text }
        let no = card.items.indices.filter { !done.contains($0) }.map { card.items[$0].text }
        let said = "\"\(card.title)\" now has done (\(done.sorted().map(String.init).joined(separator: ","))): \(yes.joined(separator: "; ")); not done: \(no.joined(separator: "; "))"
        answerer.answer(.checklist(card), String(localized: "\(card.title): \(done.count) of \(card.items.count) done"), said)
    }

    /// The ticks a sent answer said ("done (0,2): …").
    static func ticked(in said: String) -> Set<Int> {
        guard let open = said.range(of: "done ("), let close = said[open.upperBound...].firstIndex(of: ")") else { return [] }
        return Set(said[open.upperBound ..< close].split(separator: ",").compactMap { Int($0) })
    }
}

// MARK: - Quick form

struct FormCard: View {
    let card: ReplyCard.Form
    let whole: ReplyCard
    @State private var values: [String] = []
    @State private var answers = CardAnswers.shared
    @Environment(\.answerCard) private var answerer
    @Environment(\.colorScheme) private var scheme

    private var answered: String? { answers.said[whole.key] }

    var body: some View {
        AnswerBox(symbol: "list.bullet.rectangle", title: card.title) {
            ForEach(Array(card.fields.enumerated()), id: \.offset) { index, field in
                entry(field, index: index)
            }
            if let answered {
                AnsweredLine(text: String(localized: "Sent")).accessibilityHint(answered)
            } else if let answerer {
                HStack {
                    Spacer(minLength: 0)
                    Button { send(answerer) } label: {
                        FilledButtonTitle(title: card.action).padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 32)
                    }
                    .chatFont(.subheadline, weight: .semibold)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(answerer.busy || missing)
                    .accessibilityHint(Text("Sends what you filled in", comment: "VoiceOver hint: a form card's button"))
                }
            }
        }
        .disabled(answered != nil || answerer == nil)
        .onAppear { if values.isEmpty { values = card.fields.map(\.value) } }
    }

    private var missing: Bool {
        card.fields.indices.contains { card.fields[$0].required && value($0).trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func value(_ index: Int) -> String { values.indices.contains(index) ? values[index] : card.fields[index].value }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(get: { value(index) }, set: { new in
            if values.count != card.fields.count { values = card.fields.map(\.value) }
            values[index] = new
        })
    }

    @ViewBuilder
    private func entry(_ field: ReplyCard.Form.Entry, index: Int) -> some View {
        let label = field.label + (field.required ? " *" : "")
        switch field.kind {
        case .toggle:
            Toggle(label, isOn: Binding(get: { ["true", "yes", "on", "1"].contains(value(index).lowercased()) },
                                        set: { binding(index).wrappedValue = $0 ? "yes" : "no" }))
                .chatFont(.callout)
        case .date, .time:
            DatePicker(label, selection: Binding(get: { Self.date(value(index), kind: field.kind) ?? .now },
                                                 set: { binding(index).wrappedValue = Self.text($0, kind: field.kind) }),
                       displayedComponents: field.kind == .date ? .date : .hourAndMinute)
                .chatFont(.callout)
        case .choice:
            HStack {
                Text(label).chatFont(.callout)
                Spacer(minLength: 8)
                Picker(label, selection: binding(index)) {
                    if value(index).isEmpty { Text("Choose").tag("") }
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
        case .text, .long, .number:
            VStack(alignment: .leading, spacing: 3) {
                Text(label).chatFont(.caption, weight: .medium).foregroundStyle(.secondary)
                TextField(field.label, text: binding(index), axis: field.kind == .long ? .vertical : .horizontal)
                    .lineLimit(field.kind == .long ? 2 ... 6 : 1 ... 1)
                    #if os(iOS)
                    .keyboardType(field.kind == .number ? .decimalPad : .default)
                    #endif
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(scheme.cardPanel, in: .rect(cornerRadius: 10))
                    .chatFont(.callout)
            }
        }
    }

    private func send(_ answerer: CardAnswerer) {
        // A date or a time not touched is sent as shown.
        let filled = card.fields.indices.map { i -> String in
            var v = value(i)
            if v.isEmpty, [.date, .time].contains(card.fields[i].kind) { v = Self.text(.now, kind: card.fields[i].kind) }
            return "\(card.fields[i].label): \(v.isEmpty ? "(left empty)" : v)"
        }
        answerer.answer(.form(card), String(localized: "Sent: \(card.title)", comment: "The message a form card's button sends"),
                        "the user filled in \"\(card.title)\" — \(filled.joined(separator: "; "))")
    }

    static func date(_ text: String, kind: ReplyCard.Form.Entry.Kind) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in kind == .date ? ["yyyy-MM-dd"] : ["HH:mm", "H:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                guard kind == .time else { return date }
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                return Calendar.current.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: .now)
            }
        }
        return nil
    }

    static func text(_ date: Date, kind: ReplyCard.Form.Entry.Kind) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = kind == .date ? "yyyy-MM-dd" : "HH:mm"
        return formatter.string(from: date)
    }
}

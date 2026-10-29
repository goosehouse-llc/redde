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

/// The frame an answerable card sits in: the same as the others', with its kind's mark.
private struct AnswerBox<Content: View>: View {
    var symbol: String
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label { Text(title).chatFont(.subheadline, weight: .semibold) } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
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

/// What the agent made ready (an email, a booking, an order), its details editable, and the
/// button that lets it go ahead. Drawn by the app, so what the person approves is what the card
/// says, not words a page or a message could pass off as a button.
struct ReviewCard: View {
    let card: ReplyCard.Review
    let whole: ReplyCard
    @State private var values: [String] = []
    @State private var answers = CardAnswers.shared
    @Environment(\.answerCard) private var answerer

    private var answered: String? { answers.said[whole.key] }

    var body: some View {
        AnswerBox(symbol: "checkmark.shield", title: card.title) {
            ForEach(Array(card.fields.enumerated()), id: \.offset) { index, field in
                VStack(alignment: .leading, spacing: 3) {
                    Text(field.label).chatFont(.caption, weight: .medium).foregroundStyle(.secondary).textCase(.uppercase)
                    if answered == nil, answerer != nil {
                        TextField(field.label, text: binding(index), axis: field.long ? .vertical : .horizontal)
                            .lineLimit(field.long ? 2 ... 10 : 1 ... 1)
                            .chatFont(.callout)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(.background, in: .rect(cornerRadius: 10))
                    } else {
                        Text(value(index)).chatFont(.callout).textSelection(.enabled)
                    }
                }
            }
            if let note = card.note { Text(note).chatFont(.caption).foregroundStyle(.secondary) }
            if let answered {
                AnsweredLine(text: answered.hasPrefix("cancelled") ? String(localized: "Cancelled") : String(localized: "Done: \(card.action)"))
            } else if let answerer {
                HStack {
                    Button(String(localized: "Cancel"), role: .cancel) { cancel(answerer) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button { go(answerer) } label: { FilledButtonTitle(title: card.action).frame(minWidth: 80) }
                        .buttonStyle(.borderedProminent)
                }
                .disabled(answerer.busy)
            }
        }
        .onAppear { if values.isEmpty { values = card.fields.map(\.value) } }
    }

    private func value(_ index: Int) -> String { values.indices.contains(index) ? values[index] : card.fields[index].value }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(get: { value(index) }, set: { new in
            if values.count != card.fields.count { values = card.fields.map(\.value) }
            values[index] = new
        })
    }

    private func go(_ answerer: CardAnswerer) {
        let changed = card.fields.indices.contains { value($0) != card.fields[$0].value }
        let details = card.fields.indices.map { "\(card.fields[$0].label): \(value($0))" }.joined(separator: "; ")
        let said = "the user tapped \"\(card.action)\" on \"\(card.title)\"\(changed ? ", after changing it" : ""). Go ahead with exactly this — \(details)"
        answerer.answer(.review(card), String(localized: "\(card.action): \(card.title)", comment: "The message a review card's button sends: its button, then its title"), said)
    }

    private func cancel(_ answerer: CardAnswerer) {
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

    private var answered: String? { answers.said[whole.key] }

    var body: some View {
        AnswerBox(symbol: card.multiple ? "checklist" : "hand.tap", title: card.title) {
            ForEach(Array(card.options.enumerated()), id: \.offset) { index, option in
                Button { tap(index) } label: { row(option, index: index) }
                    .buttonStyle(.plain)
                    .disabled(answered != nil || answerer == nil || answerer?.busy == true)
            }
            if answered != nil {
                let picked = card.options.indices.filter(isPicked).map { card.options[$0].title }
                AnsweredLine(text: String(localized: "Picked: \(picked.joined(separator: ", "))"))
            } else if card.multiple, let answerer {
                Button { send(answerer) } label: { FilledButtonTitle(title: String(localized: "Send")) }
                    .buttonStyle(.borderedProminent)
                    .disabled(picked.isEmpty || answerer.busy)
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
        .background(isPicked(index) ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.background), in: .rect(cornerRadius: 12))
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

/// A list to tick off in place (a packing or a shopping list), as a card of its own: its emoji and
/// title over a wash of the theme's colour, a ring of how much is done, its sections to fold away,
/// and a small celebration when it is all done (asked 2026-10-28: "a more fun way like a card").
/// It sits on the theme's own surface, light or dark as the theme is, its marks in the theme's
/// colour only where that reads (made readable in every theme 2026-10-28). Ticks are kept on the
/// phone; Send tells the agent how it stands; its menu pins it to the chat list, puts it in
/// Reminders, or shares it.
struct ChecklistCard: View {
    let card: ReplyCard.Checklist
    let whole: ReplyCard
    /// Shown pinned, away from its chat: no Send there.
    @Environment(\.pinnedCard) private var pinned
    @State private var answers = CardAnswers.shared
    @State private var pins = PinnedCards.shared
    @State private var folded: Set<String> = []
    @State private var unfolded: Set<String> = []
    @State private var exported: String?
    @Environment(\.answerCard) private var answerer
    @Environment(\.theme) private var theme
    @Environment(\.self) private var environment
    @Environment(Conversation.self) private var conversation: Conversation?

    /// Past this many, sections start folded and open with a tap.
    private static let foldPast = 24

    private var done: Set<Int> {
        Set(answers.ticks[whole.key] ?? card.items.indices.filter { card.items[$0].done })
    }

    /// Ticked differently from what the agent last heard.
    private var changed: Bool {
        let told = answers.said[whole.key].map(Self.ticked(in:)) ?? Set(card.items.indices.filter { card.items[$0].done })
        return told != done
    }

    private var progress: Double { card.items.isEmpty ? 0 : Double(done.count) / Double(card.items.count) }
    private var allDone: Bool { !card.items.isEmpty && done.count == card.items.count }
    /// The marks: the theme's colour where it reads on the card, else its text.
    private var mark: Color { theme.accent.readable(on: theme.surfaceColor, or: theme.textColor, in: environment) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(Array(card.sections.enumerated()), id: \.offset) { _, section in
                sectionView(section.title, items: section.items)
            }
            footer
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .foregroundStyle(theme.textColor)
        .background {
            RoundedRectangle(cornerRadius: 22).fill(theme.surfaceColor)
                .overlay(alignment: .top) {
                    // The theme's colour, as a wash under the header only: the list stays on the plain surface.
                    LinearGradient(colors: [theme.accent.opacity(0.28), theme.accent.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 120)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
                }
        }
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(theme.textColor.opacity(0.08), lineWidth: 1) }
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
        .sensoryFeedback(.success, trigger: allDone) { _, now in now }
        .animation(.snappy(duration: 0.25), value: done)
        .alert(exported ?? "", isPresented: Binding(get: { exported != nil }, set: { if !$0 { exported = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(card.emoji ?? "✅")
                .font(.system(size: 30))
                .frame(width: 48, height: 48)
                .background(theme.surfaceColor.opacity(0.7), in: .rect(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.system(.title3, design: .rounded, weight: .bold)).lineLimit(2)
                Text(allDone ? String(localized: "All done!") : String(localized: "\(done.count) of \(card.items.count) done"))
                    .chatFont(.caption, weight: .medium).monospacedDigit().foregroundStyle(theme.textColor.opacity(0.65))
            }
            Spacer(minLength: 6)
            ZStack {
                Circle().stroke(theme.textColor.opacity(0.12), lineWidth: 5)
                Circle().trim(from: 0, to: progress)
                    .stroke(mark, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if allDone {
                    Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(mark)
                } else {
                    Text("\(Int((progress * 100).rounded()))%").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                }
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
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
            Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(theme.textColor.opacity(0.6))
                .frame(width: 32, height: 40).contentShape(.rect)
        }
        .accessibilityLabel("More for \(card.title)")
    }

    @ViewBuilder
    private func sectionView(_ title: String?, items: [Int]) -> some View {
        let id = title ?? ""
        let finished = items.allSatisfy(done.contains)
        let isFolded = title != nil && !unfolded.contains(id)
            && (folded.contains(id) || finished || card.items.count > Self.foldPast)
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Button {
                    if isFolded { unfolded.insert(id); folded.remove(id) } else { folded.insert(id); unfolded.remove(id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(isFolded ? 0 : 90))
                        Text(title).chatFont(.subheadline, weight: .bold)
                        Spacer(minLength: 6)
                        if finished { Image(systemName: "checkmark.seal.fill").foregroundStyle(mark) }
                        Text("\(items.filter(done.contains).count)/\(items.count)")
                            .chatFont(.caption, weight: .semibold).monospacedDigit().foregroundStyle(theme.textColor.opacity(0.6))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if !isFolded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items, id: \.self) { index in row(index) }
                }
                .padding(8)
                .background(theme.textColor.opacity(0.045), in: .rect(cornerRadius: 14))
            }
        }
    }

    private func row(_ index: Int) -> some View {
        let on = done.contains(index)
        return Button { toggle(index) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? mark : theme.textColor.opacity(0.35))
                    .symbolEffect(.bounce, value: on)
                Text(card.items[index].text).chatFont(.callout)
                    .strikethrough(on, color: theme.textColor.opacity(0.45))
                    .foregroundStyle(on ? theme.textColor.opacity(0.5) : theme.textColor)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder
    private var footer: some View {
        if allDone {
            Text("Everything's done. Nice! 🎉").chatFont(.subheadline, weight: .semibold)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
        }
        if let answerer, changed, !pinned {
            Button { send(answerer) } label: {
                Label(String(localized: "Send"), systemImage: "paperplane.fill")
                    .chatFont(.subheadline, weight: .semibold)
                    .foregroundStyle(theme.userText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .tint(theme.accent)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(answerer.busy)
        }
    }

    private func toggle(_ index: Int) {
        var now = done
        if now.contains(index) { now.remove(index) } else { now.insert(index) }
        answers.setTicks(whole.key, now.sorted())
    }

    private func send(_ answerer: CardAnswerer) {
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

    private var answered: String? { answers.said[whole.key] }

    var body: some View {
        AnswerBox(symbol: "list.bullet.rectangle", title: card.title) {
            ForEach(Array(card.fields.enumerated()), id: \.offset) { index, field in
                entry(field, index: index)
            }
            if let answered {
                AnsweredLine(text: String(localized: "Sent")).accessibilityHint(answered)
            } else if let answerer {
                Button { send(answerer) } label: { FilledButtonTitle(title: card.action).frame(minWidth: 80) }
                    .buttonStyle(.borderedProminent)
                    .disabled(answerer.busy || missing)
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
                    .background(.background, in: .rect(cornerRadius: 10))
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

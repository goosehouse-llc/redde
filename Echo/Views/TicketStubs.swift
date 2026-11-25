import SwiftUI

/// The Ticket Stubs layout of a watch list (2026-11-25, "let's try out the Ticket stubs mockup"):
/// each film still to watch is a paper ticket, its poster, its name and its night, with a stub at
/// the end that tears off when it's watched; the watched ones pile up below as used stubs. Picked
/// per list in Change Look (`Settings.FilmLayout`); the Clean List (`FilmRow`) is the default.
enum TicketPaper {
    /// The same paper in light and dark, as a real ticket is.
    static let paper = Color(red: 0xF4 / 255, green: 0xEF / 255, blue: 0xE3 / 255)
    static let ink = Color(red: 0x1B / 255, green: 0x1A / 255, blue: 0x22 / 255)
    static let softInk = Color(red: 0x4C / 255, green: 0x46 / 255, blue: 0x3D / 255)
    static let label = Color(red: 0x5F / 255, green: 0x58 / 255, blue: 0x4D / 255)
    static let perforation = Color(red: 0xB9 / 255, green: 0xB0 / 255, blue: 0x9E / 255)

    /// A used stub: darker paper in dark, older paper in light.
    static func used(_ scheme: ColorScheme) -> (paper: Color, ink: Color, edge: Color) {
        scheme == .dark
            ? (Color(red: 0x2A / 255, green: 0x29 / 255, blue: 0x25 / 255), Color(red: 0xE8 / 255, green: 0xE3 / 255, blue: 0xD6 / 255),
               Color(red: 0x8D / 255, green: 0x87 / 255, blue: 0x78 / 255))
            : (Color(red: 0xE6 / 255, green: 0xE0 / 255, blue: 0xD2 / 255), softInk, Color(red: 0xA3 / 255, green: 0x9B / 255, blue: 0x88 / 255))
    }
}

/// One side of a ticket's tear line: rounded at its outer end, square at the tear, with half a
/// round notch cut from the top and the bottom of the tear.
nonisolated struct TicketPiece: Shape {
    /// Where the tear is: the body's trailing edge, the stub's leading one.
    var tear: HorizontalEdge
    var corner: CGFloat = 16
    var notch: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        let outer = corner, inner: CGFloat = 0
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: tear == .leading ? inner : outer, bottomLeadingRadius: tear == .leading ? inner : outer,
            bottomTrailingRadius: tear == .trailing ? inner : outer, topTrailingRadius: tear == .trailing ? inner : outer,
            style: .continuous
        ).path(in: rect)
        let x = tear == .leading ? rect.minX : rect.maxX
        var holes = Path()
        holes.addEllipse(in: CGRect(x: x - notch, y: rect.minY - notch, width: notch * 2, height: notch * 2))
        holes.addEllipse(in: CGRect(x: x - notch, y: rect.maxY - notch, width: notch * 2, height: notch * 2))
        return shape.subtracting(holes)
    }
}

/// A film still to watch, as a ticket. A tap on the ticket plans its night (or moves it); the
/// round tick on the stub tears the stub off and counts it watched.
struct TicketRow: View {
    let item: TodayList.Item
    let mark: Color
    let plan: () -> Void
    let tear: () -> Void
    @State private var torn = false
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var still

    private var size: CGFloat { min(max(scale, 1), 1.6) }
    /// The list's colour, deep enough to read on the paper.
    private var stubInk: Color { CardInk.readable(mark, drawnIn: .light, on: TicketPaper.paper) }

    var body: some View {
        let height = 138 * size, stub = 74 * size, poster = 92 * size
        HStack(spacing: 0) {
            Button(action: plan) {
                HStack(spacing: 0) {
                    CardPicture(url: item.poster.flatMap(URL.init(string:)), symbol: "film", width: poster, height: height,
                                fill: true, corner: 0, pixels: 300)
                    words
                        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .background(TicketPaper.paper)
                .clipShape(TicketPiece(tear: .trailing))
                .contentShape(TicketPiece(tear: .trailing))
            }
            .buttonStyle(.plain)

            stubPiece
                .frame(width: stub, height: height)
                .rotationEffect(.degrees(torn ? 18 : 0), anchor: .topLeading)
                .offset(x: torn ? 10 : 0, y: torn ? 70 : 0)
                .opacity(torn ? 0 : 1)
        }
        .frame(height: height)
        .compositingGroup()
        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        #if os(iOS)
        .contentShape(.contextMenuPreview, .rect(cornerRadius: 16))
        #endif
        .sensoryFeedback(.impact(weight: .medium), trigger: torn) { _, now in now }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [item.name, item.year.map(String.init), item.plan].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAction { tearOff() }
        .accessibilityAction(named: item.when == nil ? Text("Set Date", comment: "A to-do's long-press menu: give it a day and time")
                                                     : Text("Change Date", comment: "A to-do's long-press menu: move it to another day or time")) { plan() }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ADMIT ONE", comment: "Ticket Stubs: the small word at the top of a film's ticket, as on a cinema ticket")
                .chatFont(.caption2, weight: .heavy)
                .tracking(1.2)
                .foregroundStyle(TicketPaper.label)
            Text(item.name)
                .chatFont(.title3, weight: .heavy)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .foregroundStyle(TicketPaper.ink)
                .padding(.top, 3)
            Spacer(minLength: 6)
            Group {
                if let when = item.when {
                    Text(when, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        .fontWeight(.semibold)
                    if let company = item.company, !company.isEmpty {
                        Text("with \(company)", comment: "A list item's plan: who it's with, after its date (\"Thu, Nov 26, 7:30 PM · with Robin\")")
                    }
                } else {
                    Text("No night yet", comment: "Ticket Stubs: a film's ticket with no night planned for it")
                        .fontWeight(.semibold)
                    Text("Tap to plan one", comment: "Ticket Stubs: under \"No night yet\" on a film's ticket; a tap picks the night")
                }
            }
            .chatFont(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(TicketPaper.softInk)
        }
    }

    private var stubPiece: some View {
        VStack(spacing: 4) {
            Button { tearOff() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 17 * size, weight: .heavy))
                    .foregroundStyle(stubInk)
                    .frame(width: 46 * size, height: 46 * size)
                    .overlay { Circle().strokeBorder(stubInk, lineWidth: 2) }
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            if let year = item.year {
                Text(verbatim: String(year))
                    .chatFont(.caption2, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(TicketPaper.softInk)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TicketPaper.paper)
        .clipShape(TicketPiece(tear: .leading))
        .overlay(alignment: .leading) {
            Perforation()
                .stroke(TicketPaper.perforation, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                .frame(width: 2)
                .padding(.vertical, 12)
        }
    }

    /// The stub drops away, then the film counts watched. Without motion, at once.
    private func tearOff() {
        guard !torn else { return }
        guard !still else { return tear() }
        withAnimation(.easeIn(duration: 0.3)) { torn = true }
        Task {
            try? await Task.sleep(for: .milliseconds(280))
            tear()
            // Still here (it couldn't be counted): the stub comes back.
            try? await Task.sleep(for: .seconds(1.5))
            torn = false
        }
    }
}

/// The tear line, down the middle of its frame.
private nonisolated struct Perforation: Shape {
    func path(in rect: CGRect) -> Path {
        Path { line in
            line.move(to: CGPoint(x: rect.midX, y: rect.minY))
            line.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}

/// The watched films as a pile of used stubs, each a little askew, overlapping, scrolled sideways.
struct StubPile: View {
    let items: [TodayList.Item]
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1
    @Environment(\.colorScheme) private var scheme

    private static let turns: [Double] = [-4, 3, -2, 4, -3, 2]
    private var size: CGFloat { min(max(scale, 1), 1.5) }

    var body: some View {
        let used = TicketPaper.used(scheme)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: -22 * size) {
                ForEach(Array(items.enumerated()), id: \.element.id) { n, item in
                    VStack(alignment: .leading, spacing: 6) {
                        CardPicture(url: item.poster.flatMap(URL.init(string:)), symbol: "film", width: nil, height: 40 * size,
                                    fill: true, corner: 4, pixels: 200)
                            .saturation(0.4)
                        Text(item.name)
                            .chatFont(.caption2, weight: .bold)
                            .lineLimit(3)
                            .foregroundStyle(used.ink)
                    }
                    .padding(9)
                    .frame(width: 92 * size, height: 112 * size, alignment: .top)
                    .background(used.paper, in: .rect(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(used.edge, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    }
                    .rotationEffect(.degrees(Self.turns[n % Self.turns.count]))
                    .zIndex(Double(n))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: items.map(\.name).joined(separator: ", ")))
    }
}

import SwiftUI

/// One stop on a goal's trail (2026-11-25, the goal page mockups' B): its mark on the line down
/// the left, the line into it and out of it, and what it says beside them. The line is the
/// agent's colour where the trail has been and grey ahead; none above the first stop or below the
/// last. Rows sit flush, so each row's pieces of line meet the next's.
struct TrailStop<Marker: View, Content: View>: View {
    /// Where the mark's middle is, from the top of the row.
    let markY: CGFloat
    let into: Color?
    let out: Color?
    @ViewBuilder let marker: Marker
    @ViewBuilder let content: Content

    static var gutter: CGFloat { 44 }

    var body: some View {
        content
            .padding(.leading, Self.gutter + 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        Rectangle().fill(into ?? .clear).frame(width: 3, height: markY)
                        Rectangle().fill(out ?? .clear).frame(width: 3).frame(maxHeight: .infinity)
                    }
                    .frame(width: Self.gutter)
                    marker.position(x: Self.gutter / 2, y: markY)
                }
                .frame(width: Self.gutter)
                .accessibilityHidden(true)
            }
    }
}

/// The marks on the trail.
enum TrailMark {
    /// A step done: a filled dot with a tick.
    static func done(_ card: FilledCard) -> some View {
        Circle().fill(card.fill)
            .frame(width: 22, height: 22)
            .overlay { Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(card.ink) }
    }

    /// Steps done folded into one: two dots, one behind the other.
    static func folded(_ card: FilledCard) -> some View {
        ZStack {
            Circle().fill(card.fill.opacity(0.45)).frame(width: 22, height: 22).offset(y: -5)
            done(card)
        }
    }

    /// Where the trail has got to and it waits on them: the agent's face in a ring that glows.
    static func waiting(face: BotFace, name: String, mark: Color) -> some View {
        ZStack {
            Circle().fill(mark.opacity(0.2)).frame(width: 46, height: 46)
            Circle().fill(Color(.systemGroupedBackground)).frame(width: 34, height: 34)
            Circle().strokeBorder(mark, lineWidth: 3).frame(width: 34, height: 34)
            BotAvatar(face: face, name: name, size: 20)
        }
    }

    /// Their next step: a bold ring.
    static var next: some View {
        Circle().fill(Color(.systemGroupedBackground))
            .frame(width: 22, height: 22)
            .overlay { Circle().strokeBorder(Color.primary, lineWidth: 3) }
    }

    /// The agent's step on its board: a ring in its colour with a dot.
    static func agent(_ mark: Color) -> some View {
        Circle().fill(Color(.systemGroupedBackground))
            .frame(width: 18, height: 18)
            .overlay { Circle().strokeBorder(mark, lineWidth: 2.5) }
            .overlay { Circle().fill(mark).frame(width: 6, height: 6) }
    }

    /// Their step after the next one: a small grey ring.
    static var later: some View {
        Circle().fill(Color(.systemGroupedBackground))
            .frame(width: 16, height: 16)
            .overlay { Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 2) }
    }

    /// The finish: a flag, filled once the last step is done.
    static func finish(done: Bool, _ card: FilledCard) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(done ? card.fill : Color(.secondarySystemGroupedBackground))
            .frame(width: 34, height: 34)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(done ? .clear : Color.secondary.opacity(0.6), lineWidth: 2)
            }
            .overlay { Image(systemName: "flag.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(done ? card.ink : .primary) }
    }
}

/// A goal's target date in words, "By March 23": its own key, since "By %@" is who made a plugin
/// ("Von %@", "Autor: %@"), which read wrong under a goal (2026-11-25).
func goalBy(_ date: String) -> String {
    String(localized: "goal.by", defaultValue: "By \(date)", comment: "A goal's target date, e.g. By March 23: the day it should be done by")
}

extension Settings.GoalLayout {
    var name: Text {
        switch self {
        case .trail: Text("Trail", comment: "A goal page's layout: the plan as a trail from the first step to the goal's date")
        case .week: Text("This Week", comment: "A goal page's layout: the person's next step large, what the agent asks, how far along")
        case .lanes: Text("Who Does What", comment: "A goal page's layout: the plan in two lanes, the person's steps and the agent's")
        case .log: Text("Check-in Log", comment: "A goal page's layout: each check-in the agent made and what the person told it, newest first")
        case .list: Text(String(localized: "goal.layout.list", defaultValue: "List", comment: "A goal page's layout: the page in sections, what needs you, the plan, the last check-in"))
        }
    }

    var symbol: String {
        switch self {
        case .trail: "point.topleft.down.to.point.bottomright.curvepath"
        case .week: "star.circle"
        case .lanes: "person.2"
        case .log: "text.bubble"
        case .list: "list.bullet"
        }
    }
}

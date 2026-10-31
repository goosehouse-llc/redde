import SwiftUI

/// A game, or a few (`ReplyCard.score`, asked 2026-10-30: "did the Magic win?", "when's the next
/// game?"): the two teams (a circle in the team's colour with its letters; no logos), the score,
/// how it stands (Final; Live with the period and the clock, gently pulsing; or when it starts,
/// in this phone's time, and where to watch), the league and the venue. It shows what the agent
/// looked up and never checks again by itself: Refresh asks the agent for the latest.
struct ScoreCard: View {
    let card: ReplyCard.Scores
    let whole: ReplyCard
    @State private var answers = CardAnswers.shared
    @Environment(\.answerCard) private var answerer
    @Environment(\.pinnedCard) private var pinned

    private var leagues: [String] { card.games.compactMap(\.league).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardBox(spacing: 12) {
                CardTitle(symbol: Self.sport(leagues.first), title: leagues.count == 1 ? leagues[0] : String(localized: "Scores", comment: "A score card's title for games of several leagues"))
                ForEach(Array(card.games.enumerated()), id: \.offset) { index, game in
                    if index > 0 { Divider() }
                    GameView(game: game, league: leagues.count > 1 ? game.league : nil)
                }
                if let note = card.note {
                    Text(note).chatFont(.caption).foregroundStyle(.secondary)
                }
            }
            if let said = answers.said[whole.key], said.contains("tapped Refresh") {
                AnsweredLine(text: String(localized: "Asked for the latest", comment: "Under a score card once Refresh was tapped")).padding(.leading, 6)
            } else if let answerer, !pinned, card.games.contains(where: { $0.status != .final }) {
                Button { refresh(answerer) } label: {
                    CardChip(title: String(localized: "Refresh", comment: "A chip under a score card: asks the agent for the latest score"),
                             symbol: "arrow.clockwise", busy: answerer.busy)
                }
                .buttonStyle(.plain)
                .disabled(answerer.busy)
                .accessibilityHint(Text("Asks your agent for the latest score", comment: "VoiceOver hint: a score card's Refresh"))
                .padding(.horizontal, 2)
            }
        }
    }

    private func refresh(_ answerer: CardAnswerer) {
        let message = Self.refresh(card)
        answerer.answer(whole, message.shown, message.said)
    }

    static func refresh(_ card: ReplyCard.Scores) -> (shown: String, said: String) {
        let games = card.games.map { "\($0.away.name) at \($0.home.name)" + ($0.league.map { " (\($0))" } ?? "") }.joined(separator: "; ")
        return (String(localized: "Update the score", comment: "The message a score card's Refresh sends"),
                "the user tapped Refresh on the score card: look up \(games) again with your tools and show a fresh 'score' card; never guess a score")
    }

    /// The sport's mark, by its league.
    static func sport(_ league: String?) -> String {
        let said = (league ?? "").lowercased()
        let words = Set(said.split { !$0.isLetter })
        if !words.isDisjoint(with: ["nba", "wnba", "ncaab", "euroleague", "basketball"]) { return "basketball" }
        if !words.isDisjoint(with: ["nfl", "ncaaf", "football"]) && !said.contains("premier") { return "football" }
        if !words.isDisjoint(with: ["mlb", "baseball"]) { return "baseball" }
        if !words.isDisjoint(with: ["nhl", "hockey"]) { return "hockey.puck" }
        if !words.isDisjoint(with: ["atp", "wta", "tennis"]) { return "tennis.racket" }
        if !words.isDisjoint(with: ["mls", "premier", "liga", "serie", "bundesliga", "ligue", "uefa", "champions", "fifa", "soccer", "cup"]) { return "soccerball" }
        return "sportscourt"
    }

    /// "Today, 7:30 PM", "Tomorrow, 7:30 PM", "Sat, Nov 1, 7:30 PM": in this phone's time.
    static func start(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today, \(time)", comment: "When a game starts: today at a time") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "Tomorrow, \(time)", comment: "When a reminder goes off, tomorrow at a time")
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + ", " + time
    }

    /// "#0077C0" as a colour.
    static func colour(_ hex: String?) -> Color? {
        guard let hex, let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// Whether white reads on a team's colour (else black).
    static func light(_ hex: String?) -> Bool {
        guard let hex, let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return true }
        let r = Double(value >> 16 & 0xFF), g = Double(value >> 8 & 0xFF), b = Double(value & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 < 0.62
    }
}

/// One game: how it stands, the away team over the home team, where and on what.
private struct GameView: View {
    let game: ReplyCard.Scores.Game
    /// Named on the game where the card holds several leagues.
    let league: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                status
                Spacer(minLength: 0)
                if let league { Text(league).chatFont(.caption, weight: .medium).foregroundStyle(.secondary) }
            }
            VStack(spacing: 8) {
                team(game.away, side: .away)
                team(game.home, side: .home)
            }
            let place = [game.venue, game.broadcast].compactMap(\.self)
            if !place.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: game.broadcast != nil && game.status != .final ? "tv" : "mappin.and.ellipse").imageScale(.small)
                    Text(verbatim: place.joined(separator: " · ")).lineLimit(1)
                }
                .chatFont(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    @ViewBuilder private var status: some View {
        switch game.status {
        case .final:
            Text("Final", comment: "A game on a score card is over").textCase(.uppercase).tracking(0.5)
                .chatFont(.caption, weight: .bold).foregroundStyle(.secondary)
        case .live:
            HStack(spacing: 6) {
                LiveDot()
                Text("Live", comment: "A game on a score card is being played").textCase(.uppercase).tracking(0.5)
                    .chatFont(.caption, weight: .bold).foregroundStyle(.red)
                if let clock = [game.period, game.clock].compactMap(\.self).joined(separator: " ").nilIfEmpty {
                    Text(verbatim: clock).chatFont(.caption, weight: .semibold).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        case .upcoming:
            Text(verbatim: game.start.map { ScoreCard.start($0) } ?? String(localized: "Upcoming", comment: "A game on a score card hasn't started"))
                .chatFont(.caption, weight: .semibold).foregroundStyle(.tint)
        }
    }

    private func team(_ team: ReplyCard.Scores.Team, side: ReplyCard.Scores.Team.Side) -> some View {
        let lost = game.winner != nil && game.winner != side
        return HStack(spacing: 12) {
            Text(verbatim: team.mark)
                .chatFont(size: team.mark.count > 3 ? 10 : 12, weight: .heavy)
                .foregroundStyle(ScoreCard.light(team.color) ? Color.white : Color.black)
                .frame(width: 36, height: 36)
                .background(ScoreCard.colour(team.color) ?? Color.secondary.opacity(0.6), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(team.name).chatFont(.body, weight: lost ? .regular : .semibold).foregroundStyle(lost ? .secondary : .primary).lineLimit(1)
                if let record = team.record { Text(record).chatFont(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            Spacer(minLength: 8)
            if game.status != .upcoming, let score = team.score {
                if game.winner == side {
                    Image(systemName: "arrowtriangle.left.fill").chatFont(.caption2).foregroundStyle(.secondary)
                }
                Text(score, format: .number).chatFont(.title2, weight: .bold).monospacedDigit()
                    .foregroundStyle(lost ? .secondary : .primary)
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
    }

    /// "Final: Orlando Magic 112, Boston Celtics 104", "Live, Q3 4:12: …", "Sat, Nov 1, 7:30 PM: Magic at Heat".
    private var spoken: String {
        let head: String = switch game.status {
        case .final: String(localized: "Final", comment: "A game on a score card is over")
        case .live: ([String(localized: "Live", comment: "A game on a score card is being played")] + [game.period, game.clock].compactMap(\.self)).joined(separator: " ")
        case .upcoming: game.start.map { ScoreCard.start($0) } ?? String(localized: "Upcoming", comment: "A game on a score card hasn't started")
        }
        func said(_ t: ReplyCard.Scores.Team) -> String { [t.name, game.status == .upcoming ? nil : t.score.map(String.init)].compactMap(\.self).joined(separator: " ") }
        let teams = game.status == .upcoming ? String(localized: "score.awayAtHome", defaultValue: "\(game.away.name) at \(game.home.name)", comment: "VoiceOver: a game not started, the away team at the home team")
            : said(game.away) + ", " + said(game.home)
        return [head + ": " + teams, game.venue, game.broadcast].compactMap(\.self).joined(separator: ", ")
    }
}

/// Live: a red dot breathing slowly (the symbol's own pulse, which moves nothing else); still
/// with Reduce Motion.
private struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(.red)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            .accessibilityHidden(true)
    }
}
